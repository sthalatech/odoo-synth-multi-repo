"""Configuration loader: reads the repo's config.yaml (single source of truth)
and deploy/state.env so the backend uses the
exact same infra values as the shell pipeline. No values are duplicated here.

config.yaml also carries the structured sections the old lib/config.yml
held (destination, mask_profiles, neutralize_defaults, environments) — now
consolidated into the one file. ``panel()`` returns those sections as a dict.
"""
from __future__ import annotations
import os
from pathlib import Path
from functools import lru_cache

import yaml

# lib/backend/config.py -> repo root is two levels up
REPO_ROOT = Path(__file__).resolve().parents[2]
PANEL_DIR = Path(__file__).resolve().parents[1]
YAML_CONFIG = REPO_ROOT / "config.yaml"
LEGACY_PANEL_CONFIG = PANEL_DIR / "config.yml"


def _parse_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        out[key] = val
    return out


def _load_secrets_env() -> None:
    """Auto-source deploy/secrets.env into os.environ (var not already set).

    config.yaml stores secrets as ``{ ref: env:NAME }``; at runtime those are
    resolved from the process environment by lib/backend/yamlconfig.py
    (ref_value -> os.environ.get). secrets.env is the gitignored file the
    guided installer (deploy/00_setup.sh) writes the DB/Odoo passwords to, so
    secrets stay out of config.yaml (which is more likely to be shared or
    committed). Auto-loading it here -- before config is parsed -- means users
    no longer have to manually run `set -a; . deploy/secrets.env; set +a` in
    every shell. Real env vars always win (CI/containers can inject directly);
    a missing or unreadable file is a silent no-op.
    """
    path = REPO_ROOT / "deploy" / "secrets.env"
    if not path.exists():
        return
    try:
        for raw in path.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            if not key or key in os.environ:
                continue  # real env wins; never clobber
            val = val.strip()
            if len(val) >= 2 and val[0] in "\"'" and val[-1] == val[0]:
                val = val[1:-1]
            os.environ[key] = val
    except OSError:
        pass  # best-effort: never block config load on a secrets read error


def _parse_yaml_env(path: Path) -> dict[str, str]:
    """Load config.yaml into a flat {ENV_VAR: value} dict in-process.

    Shares one loader with deploy/_yaml_to_env.py (lib/backend/yamlconfig.py)
    so the Python backend and the shell pipeline read identical values.
    Resolves ref:env: / ref:ssm: secret forms. Raises FileNotFoundError if
    *path* is missing -- load() treats a missing config.yaml as a hard error,
    which is what we want (the old subprocess path silently returned {} and
    produced an empty config that failed opaquely downstream).
    """
    from . import yamlconfig
    return yamlconfig.load_env_dict(path)


@lru_cache(maxsize=1)
def load() -> dict[str, str]:
    """config.yaml is the base; state.env (created by the deploy scripts)
    overlays the resolved AWS resource ids/endpoints. Real OS env wins over
    both so the container can be reconfigured without editing files."""
    _load_secrets_env()  # make ref:env: secrets resolvable before yaml parse
    cfg: dict[str, str] = {}
    yaml_path = REPO_ROOT / "config.yaml"
    if not yaml_path.exists():
        raise RuntimeError(
            "config.yaml not found at repo root. Copy config.example.yaml to "
            "config.yaml and fill it in (see the README).")
    cfg.update(_parse_yaml_env(yaml_path))
    cfg.update(_parse_env_file(REPO_ROOT / "deploy" / "state.env"))
    # allow override / injection from the real environment
    for k in list(cfg.keys()):
        if k in os.environ:
            cfg[k] = os.environ[k]
    for k in ("AWS_REGION", "AWS_ACCESS_KEY_ID", "AWS_PROFILE"):
        if k in os.environ:
            cfg[k] = os.environ[k]
    return cfg


def get(key: str, default: str | None = None) -> str | None:
    return load().get(key, default)


def _load_fresh() -> dict[str, str]:
    """Same as load() but WITHOUT the lru_cache — re-reads config.yaml +
    state.env from disk on every call. Used for secrets so a value rotated on
    disk takes effect on the next run without restarting the panel."""
    _load_secrets_env()  # pick up rotated secrets on disk each call
    cfg: dict[str, str] = {}
    yaml_path = REPO_ROOT / "config.yaml"
    if not yaml_path.exists():
        raise RuntimeError(
            "config.yaml not found at repo root. Copy config.example.yaml to "
            "config.yaml and fill it in (see the README).")
    cfg.update(_parse_yaml_env(yaml_path))
    cfg.update(_parse_env_file(REPO_ROOT / "deploy" / "state.env"))
    for k in list(cfg.keys()):
        if k in os.environ:
            cfg[k] = os.environ[k]
    return cfg


def get_fresh(key: str, default: str | None = None) -> str | None:
    """Read a config value bypassing the cache (for secrets that may rotate)."""
    val = os.environ.get(key)
    if val is not None:
        return val
    return _load_fresh().get(key, default)


def require(key: str) -> str:
    val = get(key)
    if not val:
        raise RuntimeError(f"missing required config value: {key}")
    return val


# ---------------------------------------------------------------------------
# structured panel sections (destination, mask profiles, neutralize defaults,
# environments) — now consolidated into config.yaml. Falls back to the legacy
# lib/config.yml for back-compat if config.yaml has no such section.
# ---------------------------------------------------------------------------

@lru_cache(maxsize=1)
def _yaml_doc() -> dict:
    if YAML_CONFIG.exists():
        try:
            return yaml.safe_load(YAML_CONFIG.read_text()) or {}
        except Exception:  # noqa: BLE001 — malformed yaml shouldn't crash config
            return {}
    return {}


@lru_cache(maxsize=1)
def panel() -> dict:
    """The structured config sections. config.yaml is the source of truth; the
    legacy lib/config.yml overlays only keys not present in config.yaml
    (so an old config.yml still works, but config.yaml wins).

    Normalizes the mask-related keys to a flat top-level shape
    (``mask_profiles``, ``neutralize_defaults``, ``reset_admin_login``) whether
    they are authored nested under ``mask:`` (the documented example form) or at
    the top level (the older config.yml form)."""
    doc = _yaml_doc()
    out: dict = {}
    for k in ("destination", "mask_profiles", "neutralize_defaults",
              "reset_admin_login", "environments", "aws"):
        if k in doc:
            out[k] = doc[k]
    # nested-under-mask normalization (config.example.yaml form)
    mask = doc.get("mask", {}) or {}
    if "profiles" in mask:
        out.setdefault("mask_profiles", mask["profiles"])
    if "neutralize_defaults" in mask:
        out.setdefault("neutralize_defaults", mask["neutralize_defaults"])
    if "reset_admin_login" in mask:
        out.setdefault("reset_admin_login", mask["reset_admin_login"])
    if "gm_jobs" in mask and isinstance(out.get("neutralize_defaults"), dict):
        out["neutralize_defaults"].setdefault("gm_jobs", mask["gm_jobs"])
    # legacy overlay (only keys missing from config.yaml)
    if LEGACY_PANEL_CONFIG.exists():
        try:
            legacy = yaml.safe_load(LEGACY_PANEL_CONFIG.read_text()) or {}
        except Exception:  # noqa: BLE001
            legacy = {}
        for k, v in legacy.items():
            out.setdefault(k, v)
    return out


def _resolve_conn(c: dict) -> dict:
    """Resolve *_env references in a connection block into concrete values."""
    def val(direct_key: str, env_key: str, default: str | None = None) -> str | None:
        if c.get(direct_key) is not None:
            return str(c[direct_key])
        env_name = c.get(env_key)
        if env_name:
            return get(env_name, default)
        return default

    # secrets are read fresh (bypass cache) so a rotated password on disk takes
    # effect on the next run without a panel restart.
    def secret(direct_key: str, env_key: str) -> str:
        if c.get(direct_key) is not None:
            return str(c[direct_key])
        env_name = c.get(env_key)
        if env_name:
            return get_fresh(env_name, "") or ""
        return ""

    return {
        "label": c.get("label"),
        "host": val("host", "host_env"),
        "port": str(c.get("port", 5432)),
        "dbname": val("dbname", "dbname_env"),
        "user": val("user", "user_env"),
        "password": secret("password", "password_env"),
    }


def destination() -> dict:
    """The masked destination DB creds (user/password/dbname).

    RDS-free (Phase B): the masker runs a throwaway in-task postgres and the
    host is supplied by the task (127.0.0.1), so `host` is typically empty.

    The `destination:` config block was removed (DB creds are mask/run-time
    concerns, not install-time). The creds now resolve from the TARGET_DB_*
    env vars that the mask runner sets directly. A residual `destination:`
    block in config.yaml (if any) is still honored for backward compat.
    """
    d = panel().get("destination", {}) or {}
    if not d:
        # No config block: resolve from the env vars the mask runner exports.
        return {
            "label": "Masked DB (ephemeral in-task postgres)",
            "host": get("TARGET_DB_HOST") or None,
            "port": get("TARGET_DB_PORT") or "5432",
            "dbname": get("TARGET_DB_NAME") or None,
            "user": get("TARGET_DB_USER") or None,
            "password": get_fresh("TARGET_DB_PASSWORD", "") or "",
        }
    return _resolve_conn(d)


def mask_profiles() -> list[dict]:
    return panel().get("mask_profiles", []) or []


def neutralize_defaults() -> dict:
    return panel().get("neutralize_defaults", {}) or {}


def dump_s3_bucket() -> str | None:
    """The S3 bucket for masked dumps + build/discovery artifacts.

    config.yaml is the source of truth: ``mask.dumps_bucket`` (a direct value).
    Falls back to the legacy ``aws.dump_s3_bucket[_env]`` panel keys, then the
    resolved ``DUMP_S3_BUCKET`` env var (set by the YAML loader's alias).
    """
    doc = _yaml_doc()
    mask = doc.get("mask", {}) or {}
    if mask.get("dumps_bucket"):
        return str(mask["dumps_bucket"])
    aws = panel().get("aws", {}) or {}
    if aws.get("dump_s3_bucket"):
        return str(aws["dump_s3_bucket"])
    env_name = aws.get("dump_s3_bucket_env")
    if env_name:
        return get(env_name)
    return get("DUMP_S3_BUCKET")


def dump_s3_prefix() -> str:
    doc = _yaml_doc()
    mask = doc.get("mask", {}) or {}
    if mask.get("dumps_prefix"):
        return str(mask["dumps_prefix"]).strip("/")
    aws = panel().get("aws", {}) or {}
    return aws.get("dump_s3_prefix", "masked-dumps")


# ---------------------------------------------------------------------------
# developer environments (EC2 workspaces via Coder, seeded from a masked dump)
# ---------------------------------------------------------------------------

def environments_cfg() -> dict:
    return panel().get("environments", {}) or {}


def _env_val(key: str, env_key: str, default: str | None = None) -> str | None:
    """Resolve environments.<key> or environments.<env_key> (an env-var name)."""
    e = environments_cfg()
    if e.get(key) is not None:
        return str(e[key])
    name = e.get(env_key)
    if name:
        return get(name, default)
    return default


def environments_settings() -> dict:
    """Concrete launch settings for developer environments, resolved from env."""
    e = environments_cfg()
    return {
        "enabled": bool(e.get("enabled", True)),
        # Coder control plane: the server URL + a session token drive the `coder`
        # CLI shim in environments.py. The Coder server (deployed by
        # deploy/11_coder_server.sh) launches workspace VMs from the template.
        # Coder URL + token: state.env (written by deploy/11_coder_server.sh +
        # 11b_coder_login.sh) takes priority over a hardcoded value in
        # config.yaml -- the deploy scripts write the actual server URL + a
        # freshly-minted token there, so a stale hardcoded coder_url in
        # config.yaml (e.g. from a prior Coder server) does not win.
        "coder_url": get("CODER_URL", "") or _env_val("coder_url", "coder_url_env") or "",
        "coder_session_token": get_fresh("CODER_SESSION_TOKEN", "")
                                or _env_val("coder_session_token", "coder_session_token_env") or "",
        # Workspace VM inputs (passed as Coder template parameters). These reuse
        # the existing thin golden AMI + env instance profile + env SG + subnet
        # baked by deploy/09_dev_env.sh -- no new AWS artifacts per environment.
        "ami_id": _env_val("ami_id", "ami_id_env"),
        "instance_type": e.get("instance_type", "t3.large"),
        "subnet_id": _env_val("subnet_id", "subnet_id_env"),
        "security_group_id": _env_val("security_group_id", "security_group_id_env"),
        "instance_profile": _env_val("instance_profile", "instance_profile_env"),
        "db_name": e.get("db_name", "odoo"),
        # The provenance-baked Odoo image the env runs against the masked DB. A
        # run may override this (result.odoo_image); this is the fallback.
        "odoo_image": odoo_image(),
        # Developer addons repo cloned into the workspace + bind-mounted into the
        # odoo container as live-dev addons. Per-PROFILE / per-workspace: resolved
        # from state.env (ENV_REPO_URL/BRANCH, set at env-create time) -- config.yaml
        # no longer carries addons defaults.
        "repo_url": _env_val("repo_url", "repo_url_env"),
        "repo_branch": _env_val("repo_branch", "repo_branch_env"),
        # Optional GitHub token for cloning a private addons repo, stored as a
        # Coder user secret injected into the workspace as $GH_PAT_<UPPER_ID>.
        # Here we expose the env-var NAME the workspace reads (state.env:
        # ENV_GIT_TOKEN_ENV), not the value (write-only in Coder).
        "git_token_env": _env_val("git_token_env", "git_token_env_env"),
    }


def odoo_image() -> str | None:
    """The provenance-baked Odoo image (ECR odoo:<tag>) the dev env runs."""
    e = environments_cfg()
    if e.get("odoo_image"):
        return str(e["odoo_image"])
    name = e.get("odoo_image_env")
    if name and get(name):
        return get(name)
    proj = get("PROJECT")
    region = get("AWS_REGION")
    acct = get("AWS_ACCOUNT_ID")
    tag = e.get("odoo_image_tag", "latest")
    if proj and region and acct:
        return f"{acct}.dkr.ecr.{region}.amazonaws.com/{proj}/odoo:{tag}"
    return None



def environments_configured() -> bool:
    s = environments_settings()
    # The Coder control plane (URL + a usable session token) is required; the
    # AMI/SG/profile/subnet are required to pass to the Coder template. The
    # token check uses coder_token() (validates the configured token and falls
    # back to the on-disk keyring session) so an interactive `coder login` is
    # sufficient even when config.yaml/state.env still holds a stale token.
    return bool(s["enabled"] and s["coder_url"] and coder_token()
                and s["ami_id"] and s["security_group_id"] and s["instance_profile"])


# ---------------------------------------------------------------------------
# Coder session token resolution with keyring fallback.
# ---------------------------------------------------------------------------
# The configured CODER_SESSION_TOKEN (from config.yaml / state.env / env) is
# the *preferred* auth for the `coder` CLI shim + the direct HTTP API calls.
# But it can go stale: the wizard mints a long-lived token, yet a redeploy of
# the Coder server (or a manual --rebuild) invalidates it, and an interactive
# `coder login` after that stores a fresh session only in the OS keyring --
# NOT in config.yaml/state.env. If we then shell out to `coder ...` with the
# stale CODER_SESSION_TOKEN set in the subprocess env, the Coder CLI uses it
# *instead of* the keyring (a non-empty env var wins over the keyring fallback
# in the CLI's InitClient), and every call fails with "signed out".
#
# coder_token() validates the configured token against CODER_URL with a cheap
# /api/v2/users/me probe and, if it is rejected, returns "" so the caller omits
# CODER_SESSION_TOKEN from the subprocess env (or the Coder-Session-Token
# header) -- letting the coder CLI fall back to its keyring session. The probe
# result is cached for the process lifetime (a single CLI invocation) so the
# many coder subprocess calls in one `profile create` / `env create` do not
# each re-probe.
@lru_cache(maxsize=1)
def _configured_coder_token() -> str:
    return get_fresh("CODER_SESSION_TOKEN", "") or ""


def coder_url() -> str:
    """The Coder server origin (CODER_URL), resolved the same way the env
    settings resolve it (config.yaml -> state.env -> env var)."""
    s = environments_settings()
    return s.get("coder_url") or get("CODER_URL", "") or ""


def public_domain() -> str:
    """The base domain browser-facing app/dashboard URLs are built under, e.g.
    "98.91.135.76.nip.io" today or a real Cloudflare-managed domain later --
    swapping providers is just changing this one value in deploy/state.env,
    with no code change. Falls back to "<coder host>.nip.io" (the historical
    bare-IP-only behavior) if unset, for a deploy that hasn't set it yet."""
    v = get("PUBLIC_DOMAIN", "")
    if v:
        return v
    from urllib.parse import urlsplit
    host = urlsplit(coder_url()).hostname or ""
    return f"{host}.nip.io" if host else ""


def public_scheme() -> str:
    """The scheme browser-facing app/dashboard URLs are built with. Defaults
    to "https"; set PUBLIC_SCHEME=http in deploy/state.env only for a
    plain-HTTP deploy (e.g. Caddy/TLS not set up yet)."""
    return get("PUBLIC_SCHEME", "") or "https"


@lru_cache(maxsize=1)
def _configured_token_valid() -> bool | None:
    """Has the configured CODER_SESSION_TOKEN been verified against CODER_URL?

    Returns True (valid), False (rejected/stale), or None (unverified -- e.g.
    no token configured or no URL to probe). Cached for the process lifetime.
    """
    tok = _configured_coder_token()
    url = coder_url()
    if not tok or not url:
        return None
    import urllib.request
    import urllib.error
    req = urllib.request.Request(
        f"{url.rstrip('/')}/api/v2/users/me",
        headers={"Coder-Session-Token": tok})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001 -- any failure => don't trust the token
        return False


@lru_cache(maxsize=1)
def _keyring_session_token() -> str:
    """Read the session token the Coder CLI stores on disk after an interactive
    `coder login` (Linux: no OS keyring, so it is a plain file). On Linux the
    CLI writes the token to ~/.config/coderv2/session and the server URL it
    authenticated against to ~/.config/coderv2/url. We return the token only if
    that URL matches CODER_URL, so a session for a different (e.g. previous)
    Coder server is not reused. Returns "" if absent/mismatched."""
    import os
    url = coder_url()
    if not url:
        return ""
    url = url.rstrip("/")
    cfg_dir = os.environ.get(
        "CODER_CONFIG_DIR",
        os.path.join(os.path.expanduser("~"), ".config", "coderv2"))
    try:
        with open(os.path.join(cfg_dir, "url"), "r") as f:
            sess_url = f.read().strip()
        if not sess_url or sess_url.rstrip("/") != url:
            return ""
        with open(os.path.join(cfg_dir, "session"), "r") as f:
            tok = f.read().strip()
        return tok or ""
    except Exception:  # noqa: BLE001 -- missing/unreadable => no fallback
        return ""


@lru_cache(maxsize=1)
def _resolved_coder_token() -> str:
    """Pick the effective Coder session token: the configured one if valid,
    else the on-disk keyring/session token (from an interactive `coder login`)
    if it matches CODER_URL. Returns "" if neither is usable, so the coder CLI
    subprocess falls back to its own keyring read, and direct HTTP API calls
    (which cannot use the keyring) fail with a clear auth error instead of
    silently using a stale token."""
    if _configured_token_valid() is True:
        return _configured_coder_token()
    return _keyring_session_token()


def coder_token() -> str:
    """The session token to use for Coder CLI/API calls.

    Returns the configured CODER_SESSION_TOKEN if it is valid against CODER_URL,
    otherwise the on-disk session token from an interactive `coder login` (if
    it matches CODER_URL), otherwise "" (so the coder CLI subprocess falls back
    to its own keyring read). This is what makes an interactive `coder login`
    on the operator's host sufficient even when config.yaml/state.env still
    holds a stale token from a prior deploy."""
    return _resolved_coder_token()


