"""Profile lifecycle: a *profile* binds a specific source system to its matching
provenance (Odoo core ref + addons repo/ref + discovered deps) and the immutable
Odoo image built from that provenance. Mask runs and developer environments are
launched *from* a profile, so the data and the code always match.

Secrets:
  * source DB password + SSH bastion key -> AWS Secrets Manager (referenced by
    ARN; only non-secret metadata lives in the profile's YAML file).
  * GitHub token (for cloning the private addons repo) -> a Coder *user secret*
    named ``git-token-<profile_id>`` with a per-profile env-var target
    ``GH_PAT_<UPPER_ID>``. Coder injects it into every workspace the owner
    launches, so discover / build / env-launch all read it from the workspace
    env with no AWS Secrets Manager round-trip and no plaintext in the profile
    or in template parameters. Only the secret *name* is persisted in the
    profile (``git_token_secret`` field); the value is write-only in Coder.
"""
from __future__ import annotations

import re
import subprocess
import uuid
from typing import Any, Optional
from urllib.parse import quote

import boto3

from . import config, store
from .pipeline import parse_dsn

# ---------------------------------------------------------------------------
# components: multi-repo/multi-service profile support
#
# A profile binds ONE shared source DB to a list of *components* -- each an
# independently versioned repo with its own build/run shape (`kind`). Today's
# single-repo profile (odoo_series/addons_git_url/etc. as flat top-level
# fields) is not a separate code path: components_of() synthesizes the
# equivalent single-element [{"kind": "odoo", ...}] list for it, so every
# caller (discover/build/mask/env-create) only ever iterates
# `profiles.components_of(profile)` -- one component is just the N=1 case of
# the general loop.
# ---------------------------------------------------------------------------

KNOWN_COMPONENT_KINDS = ("odoo", "docker", "process", "static")
_NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")


def components_of(profile: dict[str, Any]) -> list[dict[str, Any]]:
    """The profile's components -- the one shape every pipeline stage
    iterates, whether the profile is legacy single-repo or new multi-repo.

    New-style profiles set ``components`` directly (validated at create/
    update time by _validate_components). Legacy profiles have none --
    synthesize a single kind="odoo" component from the flat odoo_*/addons_*
    fields already on the profile, so the two are indistinguishable to
    callers."""
    comps = profile.get("components")
    if comps:
        return comps
    return [{
        "name": "odoo",
        "kind": "odoo",
        "repo_url": profile.get("addons_git_url"),
        "repo_ref": profile.get("addons_git_ref"),
        "port": None,
        "odoo": {
            "odoo_series": profile.get("odoo_series"),
            "odoo_git_url": profile.get("odoo_git_url"),
            "odoo_git_ref": profile.get("odoo_git_ref"),
            "needs_enterprise": profile.get("needs_enterprise"),
            "enterprise_source": profile.get("enterprise_source"),
        },
    }]


def dependencies_of(profile: dict[str, Any]) -> list[dict[str, Any]]:
    """Shared infra a profile's components declare needing (e.g. redis).
    Generic and operator-declared -- never assumed/auto-provisioned."""
    return profile.get("dependencies") or []


def _validate_components(components: Any) -> list[dict[str, Any]]:
    """Fail fast on malformed component lists at create/update time, rather
    than deep inside discover/build/env-create much later. Deliberately
    light: shape + kind + name-uniqueness checks only, not a full schema
    validator."""
    if not isinstance(components, list) or not components:
        raise ValueError("components must be a non-empty list")
    seen: set[str] = set()
    for i, c in enumerate(components):
        if not isinstance(c, dict):
            raise ValueError(f"components[{i}] must be a mapping")
        name = c.get("name")
        if not name or not _NAME_RE.match(str(name)):
            raise ValueError(
                f"components[{i}].name must be a non-empty [a-z0-9-]+ string "
                f"(got {name!r})")
        if name in seen:
            raise ValueError(f"duplicate component name: {name!r}")
        seen.add(name)
        kind = c.get("kind")
        if kind not in KNOWN_COMPONENT_KINDS:
            raise ValueError(
                f"components[{i}] ({name!r}): kind must be one of "
                f"{KNOWN_COMPONENT_KINDS} (got {kind!r})")
        if not c.get("repo_url") and kind != "odoo":
            raise ValueError(f"components[{i}] ({name!r}): repo_url is required")
        expose = c.get("expose")
        if expose is not None:
            if not isinstance(expose, dict) or not isinstance(expose.get("port"), int):
                raise ValueError(
                    f"components[{i}] ({name!r}): expose must be a mapping with an "
                    f"integer port, e.g. {{port: 3000}} (got {expose!r})")
            # Optional: the app tile's entry path (e.g. facade's Swagger UI
            # lives at /docs, not /). Defaults to "/" if omitted.
            path = expose.get("path")
            if path is not None and not isinstance(path, str):
                raise ValueError(
                    f"components[{i}] ({name!r}): expose.path must be a string "
                    f"(got {path!r})")
    return components


def _validate_dependencies(dependencies: Any) -> list[dict[str, Any]]:
    if not isinstance(dependencies, list):
        raise ValueError("dependencies must be a list")
    for i, d in enumerate(dependencies):
        if not isinstance(d, dict) or not d.get("name") or not d.get("kind"):
            raise ValueError(f"dependencies[{i}] must have name + kind")
    return dependencies


def _region() -> str:
    return config.require("AWS_REGION")


def _secret_prefix() -> str:
    e = config.environments_cfg() if hasattr(config, "environments_cfg") else {}
    return (e.get("secret_prefix") or "odoo-synth/env").rsplit("/", 1)[0] + "/profile"


def _is_profile_scoped_secret(arn: Optional[str]) -> bool:
    """True if a secret ARN/name was minted by this profile store (and is thus
    safe for `profile delete` to delete). Secrets outside the profile prefix
    -- e.g. a reused `odoo-synth/env/git-token` passed via `--git-token-secret`
    -- are owned elsewhere and must NOT be deleted here."""
    if not arn:
        return False
    name = arn.split(":", 6)[-1] if arn.startswith("arn:") else arn
    return name.startswith(_secret_prefix() + "/")


def _put_secret(name: str, value: str) -> str:
    """Create-or-update a Secrets Manager secret; return its ARN."""
    sm = boto3.client("secretsmanager", region_name=_region())
    try:
        resp = sm.create_secret(Name=name, SecretString=value,
                                Description="odoo-synth profile secret")
        return resp["ARN"]
    except sm.exceptions.ResourceExistsException:
        sm.put_secret_value(SecretId=name, SecretString=value)
        return sm.describe_secret(SecretId=name)["ARN"]


def _coder_git_token_name(profile_id: str) -> str:
    """The Coder user-secret name for a profile's GitHub token."""
    return f"git-token-{profile_id}"


def _coder_git_token_env(profile_id: str) -> str:
    """The per-profile env-var target Coder injects the token under.

    One unique env var per profile avoids collisions, since Coder user secrets
    are per-user global (a single user owns every workspace, so two profiles
    can't both own the same var -- last write would win). The name must NOT
    start with ``GIT_`` (Coder reserves ``GIT_*`` env vars), so we use
    ``GH_PAT_<UPPER_ID>``. Workspaces re-export it as ``GIT_TOKEN`` for the
    container / git clone (via ``${!GIT_TOKEN_ENV}`` indirection)."""
    return "GH_PAT_" + profile_id.upper().replace("-", "_")


def _coder_env() -> dict[str, str]:
    """Env for shelling out to the coder CLI (CODER_URL + session token)."""
    import os
    from .pipeline import _coder_env as _pipeline_coder_env
    return {**os.environ, **_pipeline_coder_env()}


def _put_coder_git_token(profile_id: str, token: str) -> str:
    """Create-or-update the profile's Coder user secret holding the GitHub PAT.

    The token is injected into every workspace the owner launches as
    ``$GH_PAT_<UPPER_ID>``. Returns the secret *name* (not an ARN) so it can
    be stored in the profile and deleted later. The value is write-only in
    Coder -- it cannot be read back via the CLI/API."""
    name = _coder_git_token_name(profile_id)
    env_target = _coder_git_token_env(profile_id)
    # create; if it already exists, fall back to update. stdin=/dev/null so the
    # CLI never blocks on an interactive prompt (e.g. if --value is somehow
    # ignored), and a generous timeout (120s) so a slow first-call doesn't
    # fail under network latency.
    create = subprocess.run(
        ["coder", "secret", "create", name,
         "--description", f"odoo-synth git token for profile {profile_id}",
         "--env", env_target, "--value", token],
        env=_coder_env(), stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=120)
    if create.returncode == 0:
        return name
    # exists -> update the value + env target
    update = subprocess.run(
        ["coder", "secret", "update", name, "--env", env_target, "--value", token],
        env=_coder_env(), stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=120)
    if update.returncode != 0:
        raise RuntimeError(
            f"could not create/update Coder secret {name!r}: "
            f"create rc={create.returncode} ({create.stderr.strip()}); "
            f"update rc={update.returncode} ({update.stderr.strip()})")
    return name


def _resolve_git_token_secret(payload: dict[str, Any], profile_id: str) -> str | None:
    """Mint the profile's GitHub token into a Coder user secret.

    ``git_token`` -- a raw PAT; stored as the Coder user secret
    ``git-token-<profile_id>`` (injected into workspaces as
    ``$GH_PAT_<UPPER_ID>``). Returns the secret *name* (persisted in the
    profile's ``git_token_secret`` field). If no token is supplied, returns
    None (caller leaves the field as-is on update, or unset on create)."""
    token = payload.get("git_token")
    if token:
        return _put_coder_git_token(profile_id, token)
    return None


def _delete_secret(arn: Optional[str]) -> None:
    if not arn:
        return
    # Only delete secrets this profile store created. A secret passed in via
    # --git-token-secret (e.g. the shared odoo-synth/env/git-token) is owned by
    # the env/deploy layer and must survive a profile delete.
    if not _is_profile_scoped_secret(arn):
        return
    try:
        boto3.client("secretsmanager", region_name=_region()).delete_secret(
            SecretId=arn, ForceDeleteWithoutRecovery=True)
    except Exception:  # noqa: BLE001
        pass


def _get_secret(arn: Optional[str]) -> str:
    if not arn:
        return ""
    sm = boto3.client("secretsmanager", region_name=_region())
    return sm.get_secret_value(SecretId=arn).get("SecretString", "")


# ---------------------------------------------------------------------------
# CRUD orchestration
# ---------------------------------------------------------------------------

def create(payload: dict[str, Any]) -> str:
    """Create a profile from a form payload. Secrets are extracted from the
    payload, written to Secrets Manager, and only their ARNs are persisted."""
    profile_id = payload.get("id") or ("prof_" + uuid.uuid4().hex[:8])
    label = payload.get("label") or profile_id

    fields: dict[str, Any] = {
        "description": payload.get("description"),
        "pr_base": payload.get("pr_base"),
        "mask_inputs": _mask_inputs(payload),
        "image_status": "draft",
    }
    # Legacy single-repo (kind=odoo) fields: only written when the caller
    # didn't supply `components` directly, so a multi-repo profile's YAML
    # doesn't end up with two conflicting sources of truth for the same
    # odoo component (components_of() already ignores these when
    # `components` is set -- this just keeps the persisted file clean).
    if not payload.get("components"):
        fields.update({
            "odoo_series": payload.get("odoo_series"),
            "odoo_git_url": payload.get("odoo_git_url") or "https://github.com/odoo/odoo",
            "odoo_git_ref": payload.get("odoo_git_ref"),          # manual (decision 2a)
            "addons_git_url": payload.get("addons_git_url"),
            "addons_git_ref": payload.get("addons_git_ref"),
            "needs_enterprise": 1 if payload.get("needs_enterprise") else 0,
            "enterprise_source": payload.get("enterprise_source"),
        })

    # source connection: split DSN into non-secret conn + password secret
    dsn = payload.get("source_dsn")
    if dsn:
        p = parse_dsn(dsn)
        fields["source_conn"] = {
            "host": p["host"], "port": p["port"], "dbname": p["dbname"],
            "user": p["user"],
            "ssh_enabled": bool(payload.get("ssh_enabled")),
            "ssh_bastion": payload.get("ssh_bastion"),
        }
        if p["password"]:
            fields["source_password_secret"] = _put_secret(
                f"{_secret_prefix()}/{profile_id}/source-password", p["password"])

    if payload.get("ssh_key"):
        fields["ssh_key_secret"] = _put_secret(
            f"{_secret_prefix()}/{profile_id}/ssh-key", payload["ssh_key"])
    fields["git_token_secret"] = _resolve_git_token_secret(payload, profile_id)

    # multi-repo: optional. Omitted entirely -> components_of() synthesizes
    # the single-component odoo shape from the flat fields above, so a
    # profile created the existing (single-repo) way is unaffected.
    if payload.get("components") is not None:
        fields["components"] = _validate_components(payload["components"])
    if payload.get("dependencies") is not None:
        fields["dependencies"] = _validate_dependencies(payload["dependencies"])

    store.create_profile(profile_id, label, **fields)
    return profile_id


def update(profile_id: str, payload: dict[str, Any]) -> None:
    existing = store.get_profile(profile_id)
    if not existing:
        raise KeyError(profile_id)

    fields: dict[str, Any] = {}
    for k in ("label", "description", "odoo_series", "odoo_git_url",
              "odoo_git_ref", "addons_git_url", "addons_git_ref",
              "enterprise_source", "odoo_conf_extra", "masking_rules",
              "agent_name", "agent_system_prompt", "pr_base"):
        if k in payload:
            fields[k] = payload[k]
    if "needs_enterprise" in payload:
        fields["needs_enterprise"] = 1 if payload["needs_enterprise"] else 0
    if any(k in payload for k in _MASK_KEYS):
        merged = dict(existing.get("mask_inputs") or {})
        merged.update(_mask_inputs(payload))
        fields["mask_inputs"] = merged
    # multi-repo: whole-list replace (like masking_rules), not a per-field merge.
    if "components" in payload:
        fields["components"] = _validate_components(payload["components"])
    if "dependencies" in payload:
        fields["dependencies"] = _validate_dependencies(payload["dependencies"])

    dsn = payload.get("source_dsn")
    if dsn:
        p = parse_dsn(dsn)
        fields["source_conn"] = {
            "host": p["host"], "port": p["port"], "dbname": p["dbname"],
            "user": p["user"],
            "ssh_enabled": bool(payload.get("ssh_enabled",
                                            (existing.get("source_conn") or {}).get("ssh_enabled"))),
            "ssh_bastion": payload.get("ssh_bastion",
                                       (existing.get("source_conn") or {}).get("ssh_bastion")),
        }
        if p["password"]:
            fields["source_password_secret"] = _put_secret(
                f"{_secret_prefix()}/{profile_id}/source-password", p["password"])
    if payload.get("ssh_key"):
        fields["ssh_key_secret"] = _put_secret(
            f"{_secret_prefix()}/{profile_id}/ssh-key", payload["ssh_key"])
    fields["git_token_secret"] = _resolve_git_token_secret(payload, profile_id)

    store.update_profile(profile_id, **fields)


def delete(profile_id: str) -> None:
    p = store.get_profile(profile_id)
    if not p:
        return
    # AWS Secrets Manager: source DB password + SSH key.
    for k in ("source_password_secret", "ssh_key_secret"):
        _delete_secret(p.get(k))
    # The profile's Coder user secret (git-token-<id>) is left in place --
    # it is write-only, harmless, and deletable manually if desired
    # (`coder secret delete git-token-<profile_id>`).
    store.delete_profile(profile_id)


def public_view(p: dict[str, Any]) -> dict[str, Any]:
    """A profile dict safe to return to the UI: secret ARNs replaced by booleans."""
    d = dict(p)
    for k in ("source_password_secret", "ssh_key_secret", "git_token_secret"):
        d[k + "_set"] = bool(d.pop(k, None))
    return d


def run_params(profile_id: str, overrides: Optional[dict[str, Any]] = None) -> dict[str, Any]:
    """Reconstruct the pipeline params for a mask run from a saved profile.

    Fetches the source password + SSH key from Secrets Manager and rebuilds the
    source DSN and mask inputs so the pipeline can run unchanged. ``overrides``
    may carry per-run knobs (e.g. ``produce_dump``) supplied at launch time.
    """
    p = store.get_profile(profile_id)
    if not p:
        raise KeyError(profile_id)

    conn = p.get("source_conn") or {}
    if not conn.get("host"):
        raise ValueError("profile has no source connection configured")
    password = _get_secret(p.get("source_password_secret"))
    user = quote(conn.get("user") or "postgres", safe="")
    auth = f"{user}:{quote(password, safe='')}@" if password else f"{user}@"
    source_dsn = (f"postgresql://{auth}{conn['host']}:{conn.get('port', 5432)}"
                  f"/{conn.get('dbname', '')}")

    params: dict[str, Any] = {
        "operation": "mask",
        "source_dsn": source_dsn,
        "ssh_enabled": bool(conn.get("ssh_enabled")),
        "ssh_bastion": conn.get("ssh_bastion"),
        "ssh_key": _get_secret(p.get("ssh_key_secret")) if conn.get("ssh_enabled") else None,
        # Provenance: the profile's immutable build. The pipeline records this on
        # the run result so an environment seeded from the run runs identical
        # code to the masked data.
        "odoo_image": p.get("image_uri"),
        # Editable per-source greenmask profile (generated during discovery).
        # When present the pipeline uploads it to S3 and points the masker at it
        # instead of the baked profile.
        "mask_rules": p.get("masking_rules") or "",
    }
    params.update(p.get("mask_inputs") or {})
    if overrides:
        params.update({k: v for k, v in overrides.items() if v is not None})
    return params


# ---------------------------------------------------------------------------

_MASK_KEYS = (
    "mask_profile", "admin_password", "gm_jobs", "neutralize_mail",
    "neutralize_fetchmail", "neutralize_payment", "neutralize_smtp_param",
    "reset_admin_login", "produce_dump", "subset_days", "exclude_table_data",
)


def _mask_inputs(payload: dict[str, Any]) -> dict[str, Any]:
    return {k: payload[k] for k in _MASK_KEYS if k in payload and payload[k] is not None}


def git_token_env_name(profile_id: str) -> str:
    """The env var Coder injects the profile's git token under (GH_PAT_<ID>).

    Used by the discover/build/env-launch paths to tell each workspace which
    Coder-injected env var holds this profile's token.
    """
    return _coder_git_token_env(profile_id)
