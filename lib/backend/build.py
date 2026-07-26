"""Provenance image build orchestration (Phase 2, decision 1b).

Bakes a profile's provenance (Odoo core ref + custom addons ref) plus its
*discovered* python deps into an immutable Odoo image on a dedicated, ephemeral
EC2 builder — never on the panel host. The builder downloads the odoo/ build
context, builds, pushes ``odoo:<profile_id>-<discovery_hash>`` to ECR, reports a
result JSON to S3, then self-terminates. We poll S3 for that result and, on
success, advance the profile to ``ready`` with the new immutable image_uri
(keeping prior images in image_history — decision 4: immutable retention).
"""
from __future__ import annotations

import io
import json
import tarfile
import time
import urllib.request
import uuid
from typing import Callable, Optional

import boto3

from . import config, store, profiles

LogSink = Callable[[str], None]

BUILD_CONTEXT = config.REPO_ROOT / "odoo"
ENTERPRISE_ZIP = BUILD_CONTEXT / "enterprise.zip"


def _have_enterprise_zip() -> bool:
    """True if a local odoo/enterprise.zip bundle is present to bake in."""
    return ENTERPRISE_ZIP.is_file()

# The build runs as a Coder workspace from the odoo-synth-builder template
# (download context -> docker build -> push -> PUT result -> poweroff). The panel keeps
# orchestration: package context, presign URLs, launch the workspace, poll S3
# for the result.
BUILDER_TEMPLATE = "odoo-synth-builder"


def _coder_env() -> dict:
    """Env for the coder CLI (server URL + session token + AWS creds). Mirrors
    environments._coder_env so the builder workspace launches with the same
    auth as dev envs."""
    s = config.environments_settings()
    env: dict = {
        "CODER_URL": s.get("coder_url") or config.coder_url() or "",
    }
    tok = config.coder_token()
    if tok:
        env["CODER_SESSION_TOKEN"] = tok
    for k in ("AWS_REGION", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
              "AWS_SESSION_TOKEN", "AWS_DEFAULT_REGION"):
        v = config.get(k)
        if v:
            env[k] = v
    return env


def _region() -> str:
    return config.require("AWS_REGION")


def _ecr_registry() -> str:
    acct = boto3.client("sts", region_name=_region()).get_caller_identity()["Account"]
    return f"{acct}.dkr.ecr.{_region()}.amazonaws.com"


def _make_context_tarball(include_enterprise: bool = False) -> bytes:
    """Tar.gz the odoo/ build context.

    The unzipped ``enterprise/`` tree is always excluded (it's redundant with
    the compact ``enterprise.zip`` and would bloat the upload). When the
    profile needs enterprise, ``enterprise.zip`` is included so the builder can
    unzip it into ``enterprise/`` before ``docker build`` (mirroring
    ``deploy/02_build_push.sh``); otherwise it's skipped so non-enterprise
    images stay small and enterprise-free.
    """
    buf = io.BytesIO()
    skip = {".git", "enterprise", "custom-addons"}
    skip_files = set()
    if not include_enterprise:
        skip_files.add("enterprise.zip")
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for p in sorted(BUILD_CONTEXT.rglob("*")):
            rel = p.relative_to(BUILD_CONTEXT)
            if rel.parts and rel.parts[0] in skip:
                continue
            if rel.name in skip_files:
                continue
            tar.add(p, arcname=str(rel), recursive=False)
    return buf.getvalue()


def _s3():
    return boto3.client("s3", region_name=_region())


def _bucket() -> str:
    b = config.dump_s3_bucket()
    if not b:
        raise RuntimeError("no S3 bucket configured (set the dump_s3_bucket)")
    return b


def _upload_context(profile_id: str, include_enterprise: bool = False) -> tuple[str, str]:
    """Upload the context tarball; return (get_url, s3_uri)."""
    bucket = _bucket()
    prefix = config.dump_s3_prefix().rstrip("/").rsplit("/", 1)[0] + "/builds"
    key = f"{prefix}/{profile_id}/{uuid.uuid4().hex[:12]}/context.tgz"
    s3 = _s3()
    s3.put_object(Bucket=bucket, Key=key,
                  Body=_make_context_tarball(include_enterprise=include_enterprise))
    get_url = s3.generate_presigned_url(
        "get_object", Params={"Bucket": bucket, "Key": key}, ExpiresIn=6 * 3600)
    return get_url, f"s3://{bucket}/{key}"


def _presign_result(profile_id: str) -> tuple[str, str, str]:
    bucket = _bucket()
    prefix = config.dump_s3_prefix().rstrip("/").rsplit("/", 1)[0] + "/builds"
    key = f"{prefix}/{profile_id}/{uuid.uuid4().hex[:12]}/result.json"
    s3 = _s3()
    put_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": bucket, "Key": key, "ContentType": "application/json"},
        ExpiresIn=12 * 3600)
    get_url = s3.generate_presigned_url(
        "get_object", Params={"Bucket": bucket, "Key": key}, ExpiresIn=12 * 3600)
    return put_url, get_url, key


def _builder_settings() -> dict:
    """Launch settings for the ephemeral builder. Falls back to the developer-
    environment settings (same AMI/subnet/SG/instance-profile) but allows a
    dedicated `build.*` override and a beefier default instance type."""
    e = config.environments_cfg()
    b = (config.panel().get("build") or {}) if hasattr(config, "panel") else {}
    s = config.environments_settings()
    return {
        "ami_id": b.get("ami_id") or config.get("BUILD_AMI_ID") or s.get("ami_id"),
        "instance_type": b.get("instance_type") or config.get("BUILD_INSTANCE_TYPE") or "m5.xlarge",
        "subnet_id": b.get("subnet_id") or s.get("subnet_id"),
        "security_group_id": b.get("security_group_id") or s.get("security_group_id"),
        "instance_profile": (b.get("instance_profile")
                             or config.get("BUILD_INSTANCE_PROFILE")
                             or s.get("instance_profile")),
        "assign_public_ip": bool(b.get("assign_public_ip", s.get("assign_public_ip", True))),
        "volume_size": int(b.get("volume_size", 40)),
    }


def _launch_builder_workspace(image_uri: str, context_get: str, result_put: str,
                               profile: dict, odoo_component: dict, s: dict) -> str:
    """Option E: launch the build as a Coder workspace from the
    odoo-synth-builder template (build_mode=odoo, the default -- unchanged
    from before multi-repo support). The workspace's startup_script runs the
    same build logic (download context -> docker build -> push to ECR -> PUT
    result JSON to S3 -> poweroff). Returns the workspace name (the panel
    polls S3 for the result, exactly as before).

    odoo_component is profiles.components_of(profile)'s "odoo" entry --
    repo_url/ref/odoo.* live there, not on the top-level profile dict, for a
    multi-repo profile (components_of() synthesizes them from the flat
    fields for a legacy single-repo profile, so this is the same call either
    way)."""
    import os
    import subprocess

    # Fail fast when critical launch settings are missing -- same rationale as
    # pipeline._launch_runner: an empty ami_id silently falls back to stock
    # Ubuntu (no Docker) in the Terraform template, producing a confusing
    # "docker not found" error minutes later.
    missing = [k for k in ("ami_id", "security_group_id", "instance_profile", "subnet_id")
               if not s.get(k)]
    if missing:
        raise RuntimeError(
            f"builder launch settings missing from config: {', '.join(missing)}. "
            "These come from deploy/state.env (written by deploy/09_dev_env.sh "
            "and 11_coder_server.sh): ENV_AMI_ID, ENV_SG_ID, ENV_SUBNET_ID, "
            "ENV_INSTANCE_PROFILE. Run the deploy pipeline first (bash deploy/00_setup.sh).")

    # The FROM image for the per-profile build. The public odoo:<series> image
    # is the default; odoo_image_base (from state/Coder param) can override it
    # (e.g. a pre-warmed base mirrored into ECR for airgapped builds). We no
    # longer build a project-level odoo:latest base at install time.
    base = s.get("odoo_image_base") or "odoo:17"
    deps = " ".join(profile.get("python_deps") or [])
    odoo_cfg = odoo_component.get("odoo") or {}
    odoo_ref = odoo_cfg.get("odoo_git_ref") or odoo_cfg.get("odoo_series") or ""
    params = [
        ("ami_id", s.get("ami_id") or ""),
        ("instance_profile", s.get("instance_profile") or ""),
        ("subnet_id", s.get("subnet_id") or ""),
        ("security_group_id", s.get("security_group_id") or ""),
        ("region", _region()),
        ("instance_type", s.get("instance_type") or "m5.xlarge"),
        ("image_uri", image_uri),
        ("context_get_url", context_get),
        ("result_put_url", result_put),
        ("odoo_image_base", base),
        ("odoo_git_url", odoo_cfg.get("odoo_git_url")
         or "https://github.com/odoo/odoo"),
        ("odoo_git_ref", odoo_ref),
        ("custom_addons_git_url", odoo_component.get("repo_url") or ""),
        ("custom_addons_git_ref", odoo_component.get("repo_ref") or ""),
        ("python_deps", deps),
        # The git token is a Coder user secret injected into the workspace as
        # $GH_PAT_<UPPER_ID>; pass the env-var NAME (not the value) so the
        # builder startup can read it. Empty when the profile has no token.
        ("git_token_env", profiles.git_token_env_name(profile.get("id") or "")
         if profile.get("git_token_secret") else ""),
        ("issue", profile.get("id") or ""),
        # Multi-repo build_mode params -- unused on this (odoo) path, but must
        # still be passed explicitly: `coder create` falls back to prompting
        # interactively for EVERY declared parameter (not just the unset
        # ones) if even one coder_parameter is left unsupplied, which hangs
        # forever with no TTY attached. _launch_builder_workspace_generic
        # already supplies these for the generic path.
        ("build_mode", "odoo"),
        ("component_repo_url", ""),
        ("component_repo_ref", ""),
        ("component_dockerfile", ""),
    ]
    ws_name = f"build-{uuid.uuid4().hex[:8]}"
    args = ["create", "-t", BUILDER_TEMPLATE, "-y", "--no-wait", ws_name]
    for k, v in params:
        args += ["--parameter", f"{k}={v}"]
    subprocess.run(["coder", *args], env={**os.environ, **_coder_env()},
                   check=True, capture_output=True, text=True, timeout=120)
    return ws_name


def _launch_builder_workspace_generic(image_uri: str, result_put: str,
                                       component: dict, profile: dict, s: dict) -> str:
    """Multi-repo: launch the SAME odoo-synth-builder template in
    build_mode=generic -- clones `component`'s own repo and builds its own
    Dockerfile directly, no context.tgz/build-args/enterprise handling."""
    import os
    import subprocess

    missing = [k for k in ("ami_id", "security_group_id", "instance_profile", "subnet_id")
               if not s.get(k)]
    if missing:
        raise RuntimeError(
            f"builder launch settings missing from config: {', '.join(missing)}. "
            "These come from deploy/state.env (written by deploy/09_dev_env.sh "
            "and 11_coder_server.sh): ENV_AMI_ID, ENV_SG_ID, ENV_SUBNET_ID, "
            "ENV_INSTANCE_PROFILE. Run the deploy pipeline first (bash deploy/00_setup.sh).")

    docker_cfg = component.get("docker") or {}
    params = [
        ("ami_id", s.get("ami_id") or ""),
        ("instance_profile", s.get("instance_profile") or ""),
        ("subnet_id", s.get("subnet_id") or ""),
        ("security_group_id", s.get("security_group_id") or ""),
        ("region", _region()),
        ("instance_type", s.get("instance_type") or "m5.xlarge"),
        ("image_uri", image_uri),
        ("result_put_url", result_put),
        ("build_mode", "generic"),
        ("component_repo_url", component.get("repo_url") or ""),
        ("component_repo_ref", component.get("repo_ref") or ""),
        ("component_dockerfile", docker_cfg.get("dockerfile") or "Dockerfile"),
        ("git_token_env", profiles.git_token_env_name(profile.get("id") or "")
         if profile.get("git_token_secret") else ""),
        ("issue", f"{profile.get('id') or ''}-{component.get('name') or ''}"),
        # Odoo-path params -- unused in generic mode, but must still be passed
        # explicitly for the same reason _launch_builder_workspace passes the
        # generic-mode params on the odoo path: `coder create` falls back to
        # prompting interactively for EVERY declared parameter if even one is
        # left unsupplied, which hangs forever with no TTY attached.
        ("context_get_url", ""),
        ("odoo_image_base", ""),
        ("odoo_git_url", ""),
        ("odoo_git_ref", ""),
        ("custom_addons_git_url", ""),
        ("custom_addons_git_ref", ""),
        ("python_deps", ""),
    ]
    ws_name = f"build-{component.get('name', 'c')}-{uuid.uuid4().hex[:8]}"
    args = ["create", "-t", BUILDER_TEMPLATE, "-y", "--no-wait", ws_name]
    for k, v in params:
        args += ["--parameter", f"{k}={v}"]
    subprocess.run(["coder", *args], env={**os.environ, **_coder_env()},
                   check=True, capture_output=True, text=True, timeout=120)
    return ws_name


def _resolve_git_sha(repo_url: str, ref: str) -> str:
    """Resolve `ref` (branch/tag/HEAD) on `repo_url` to a concrete commit SHA
    via `git ls-remote`, for image tags (generic docker components) and
    provenance pinning (process/static components) -- no local clone needed."""
    import subprocess

    out = subprocess.run(
        ["git", "ls-remote", repo_url, ref or "HEAD"],
        check=True, capture_output=True, text=True, timeout=30).stdout
    line = out.strip().splitlines()[0] if out.strip() else ""
    sha = line.split("\t")[0].strip() if line else ""
    if not sha:
        raise RuntimeError(f"could not resolve ref {ref!r} on {repo_url!r}")
    return sha


def _ensure_ecr_repo(repo_name: str) -> None:
    """Idempotent: create the ECR repo if it doesn't exist yet. Needed for a
    multi-repo component's own <project>/<component-name> repo, which (unlike
    odoo/masker/discovery) isn't pre-created by deploy/01_ecr.sh."""
    ecr = boto3.client("ecr", region_name=_region())
    try:
        ecr.create_repository(repositoryName=repo_name)
    except ecr.exceptions.RepositoryAlreadyExistsException:
        pass


def _delete_builder_workspace(ws_name: str, emit: LogSink) -> None:
    """Delete the ephemeral builder workspace once its result has been
    collected. The workspace powers itself off on completion; this tears down
    the (now stopped) EC2 instance + Coder record so we don't accumulate idle
    builder VMs. Best-effort: a failure here is logged, not raised."""
    import os
    import subprocess

    try:
        subprocess.run(["coder", "delete", ws_name, "-y"],
                       env={**os.environ, **_coder_env()},
                       check=True, capture_output=True, text=True, timeout=120)
        emit(f"[panel] builder workspace {ws_name} deleted")
    except Exception as exc:  # noqa: BLE001
        emit(f"[panel] builder workspace {ws_name} cleanup failed: {exc}")


def _poll_result(get_url: str, emit: LogSink, timeout_s: int = 45 * 60) -> Optional[dict]:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        time.sleep(20)
        try:
            with urllib.request.urlopen(get_url, timeout=30) as r:  # noqa: S310
                return json.loads(r.read().decode())
        except Exception:  # noqa: BLE001 — 403/404 until the object exists
            emit("[panel] waiting for builder to finish ...")
    return None


def _run_odoo_build(profile_id: str, profile: dict, odoo_component: dict,
                     emit: LogSink) -> dict:
    """The odoo component's build: unchanged from before multi-repo support --
    package odoo/ context, launch the builder in build_mode=odoo, poll, fold
    the immutable image into the profile's top-level image_uri/image_status/
    image_history (same fields a legacy single-repo profile has always used)."""
    dhash = profile.get("discovery_hash")
    if not dhash:
        raise ValueError("run discovery first (no discovery_hash on the profile)")
    registry = _ecr_registry()
    proj = config.require("PROJECT")
    image_uri = f"{registry}/{proj}/odoo:{profile_id}-{dhash}"
    emit(f"[panel] target image: {image_uri}")

    store.update_profile(profile_id, image_status="building", error=None)

    emit("[panel] packaging odoo/ build context ...")
    needs_enterprise = bool((odoo_component.get("odoo") or {}).get("needs_enterprise")
                            or profile.get("needs_enterprise"))
    include_ent = needs_enterprise and _have_enterprise_zip()
    if needs_enterprise and not include_ent:
        emit("[panel] NOTE profile needs enterprise but odoo/enterprise.zip is not "
             "present; the image will build without enterprise addons.")
    context_get, context_uri = _upload_context(profile_id, include_enterprise=include_ent)
    result_put, result_get, _key = _presign_result(profile_id)

    s = _builder_settings()
    emit(f"[panel] launching Coder builder workspace ({s['instance_type']}) ...")
    try:
        iid = _launch_builder_workspace(image_uri, context_get, result_put,
                                        profile, odoo_component, s)
    except Exception as exc:  # noqa: BLE001
        store.update_profile(profile_id, image_status="failed", error=str(exc))
        raise
    emit(f"[panel] builder workspace {iid} launched; waiting for image build+push ...")

    result = _poll_result(result_get, emit)
    # Delete the builder workspace now that its result is collected (success or
    # failure). The workspace already powered itself off; this reclaims the EC2
    # instance + Coder record so idle VMs don't pile up.
    _delete_builder_workspace(iid, emit)
    if not result:
        store.update_profile(profile_id, image_status="failed",
                             error="builder timed out (no result)")
        return {"exit_code": 1, "error": "builder timed out"}

    tail = result.get("log_tail") or ""
    if tail:
        for ln in tail.splitlines()[-40:]:
            emit(ln)

    if result.get("status") != "succeeded":
        err = result.get("error") or "builder reported failure"
        store.update_profile(profile_id, image_status="failed", error=err)
        return {"exit_code": 1, "error": err}

    # success: rotate current image into history, set the new immutable image.
    history = list(profile.get("image_history") or [])
    if profile.get("image_uri"):
        history.append({"uri": profile["image_uri"], "created_at": time.time()})
    store.update_profile(
        profile_id,
        image_uri=image_uri,
        image_status="ready",
        image_history=history,
        error=None,
    )
    emit(f"[panel] image ready: {image_uri}")
    return {"exit_code": 0, "image_uri": image_uri, "context_uri": context_uri}


def _run_generic_docker_build(profile_id: str, profile: dict, component: dict,
                               emit: LogSink) -> dict:
    """Multi-repo, kind=docker (non-odoo): build the component's OWN repo +
    Dockerfile via the builder template's generic mode. Tagged by the
    resolved commit SHA (there's no discovery_hash for a non-odoo component --
    its own repo state IS the provenance)."""
    name = component["name"]
    try:
        sha = _resolve_git_sha(component.get("repo_url", ""), component.get("repo_ref", ""))
    except Exception as exc:  # noqa: BLE001
        return {"exit_code": 1, "error": f"could not resolve {name} ref: {exc}"}

    registry = _ecr_registry()
    proj = config.require("PROJECT")
    repo_name = f"{proj}/{name}"
    _ensure_ecr_repo(repo_name)
    image_uri = f"{registry}/{repo_name}:{profile_id}-{sha[:12]}"
    emit(f"[panel] component {name!r} target image: {image_uri}")

    result_put, result_get, _key = _presign_result(f"{profile_id}-{name}")
    s = _builder_settings()
    emit(f"[panel] launching Coder builder workspace for {name!r} ({s['instance_type']}) ...")
    try:
        iid = _launch_builder_workspace_generic(image_uri, result_put, component, profile, s)
    except Exception as exc:  # noqa: BLE001
        return {"exit_code": 1, "error": str(exc)}
    emit(f"[panel] builder workspace {iid} launched; waiting for {name!r} build+push ...")

    result = _poll_result(result_get, emit)
    _delete_builder_workspace(iid, emit)
    if not result:
        return {"exit_code": 1, "error": "builder timed out (no result)"}
    tail = result.get("log_tail") or ""
    if tail:
        for ln in tail.splitlines()[-40:]:
            emit(ln)
    if result.get("status") != "succeeded":
        return {"exit_code": 1, "error": result.get("error") or "builder reported failure"}
    emit(f"[panel] component {name!r} image ready: {image_uri}")
    return {"exit_code": 0, "image_uri": image_uri, "resolved_ref": sha}


def _pin_component_ref(component: dict, emit: LogSink) -> dict:
    """Multi-repo, kind=process/static: no image to build -- just resolve
    `repo_ref` to a concrete commit SHA so env-create clones the EXACT same
    commit later (the same "profile binds code+data together" guarantee an
    immutable image gives the docker/odoo components)."""
    name = component["name"]
    try:
        sha = _resolve_git_sha(component.get("repo_url", ""), component.get("repo_ref", ""))
    except Exception as exc:  # noqa: BLE001
        return {"exit_code": 1, "error": f"could not resolve {name} ref: {exc}"}
    emit(f"[panel] component {name!r} pinned at {sha[:12]} (kind={component.get('kind')}, no image built)")
    return {"exit_code": 0, "resolved_ref": sha}


def run_build(profile_id: str, emit: LogSink, run_id: str | None = None) -> dict:
    """Blocking: build the odoo component exactly as before (top-level
    image_uri/image_status/image_history, unchanged for a legacy single-repo
    profile), then build/pin every other component. A non-odoo component's
    failure is recorded on that component and surfaced, but does not fail
    the whole run -- the odoo image (if it succeeded) is still usable."""
    profile = store.get_profile(profile_id)
    if not profile:
        raise KeyError(profile_id)

    components = profiles.components_of(profile)
    odoo_component = next((c for c in components if c.get("kind") == "odoo"), None)
    if odoo_component is None:
        raise ValueError("profile has no odoo component")
    odoo_result = _run_odoo_build(profile_id, profile, odoo_component, emit)
    if odoo_result.get("exit_code") != 0:
        return odoo_result

    non_odoo = [c for c in components if c.get("kind") != "odoo"]
    if non_odoo:
        component_results: dict[str, dict] = {}
        for c in non_odoo:
            if c.get("kind") == "docker":
                component_results[c["name"]] = _run_generic_docker_build(profile_id, profile, c, emit)
            else:  # process | static
                component_results[c["name"]] = _pin_component_ref(c, emit)

        # merge each component's build result back onto profile.components,
        # matched by name (mirrors how discovery merges its wiring plan).
        merged = []
        for c in (profile.get("components") or []):
            c = dict(c)
            r = component_results.get(c.get("name"))
            if r:
                c["built"] = {
                    "exit_code": r.get("exit_code"),
                    "image_uri": r.get("image_uri"),
                    "resolved_ref": r.get("resolved_ref"),
                    "error": r.get("error"),
                    "built_at": time.time(),
                }
            merged.append(c)
        store.update_profile(profile_id, components=merged)

        failed = [n for n, r in component_results.items() if r.get("exit_code") != 0]
        if failed:
            emit(f"[panel] WARN: component build/pin failed for: {', '.join(failed)} "
                 f"(odoo image is still ready; see profile show for per-component errors)")
        odoo_result["components"] = component_results

    return odoo_result


# ---------------------------------------------------------------------------
# retention / cleanup (decision 4: immutable images kept; explicit cleanup)
# ---------------------------------------------------------------------------

def _parse_image_uri(uri: str) -> tuple[str, str]:
    """Split '<registry>/<repo>:<tag>' into (repo, tag)."""
    ref, _, tag = uri.rpartition(":")
    repo = ref.split("/", 1)[1] if "/" in ref else ref
    return repo, tag


def list_images(profile_id: str) -> dict:
    """Return the profile's current image + history, enriched with live ECR
    metadata (pushed_at, size, whether the tag still exists)."""
    profile = store.get_profile(profile_id)
    if not profile:
        raise KeyError(profile_id)

    current = profile.get("image_uri")
    history = list(profile.get("image_history") or [])
    entries: list[dict] = []
    seen: set[str] = set()

    def add(uri: str, is_current: bool, created_at=None) -> None:
        if not uri or uri in seen:
            return
        seen.add(uri)
        entries.append({"uri": uri, "current": is_current,
                        "created_at": created_at})

    add(current, True)
    for h in reversed(history):
        add(h.get("uri"), False, h.get("created_at"))

    # enrich from ECR in one batch per repo
    proj = config.get("PROJECT")
    repo = f"{proj}/odoo" if proj else None
    meta: dict[str, dict] = {}
    if repo:
        try:
            ecr = boto3.client("ecr", region_name=_region())
            tags = [_parse_image_uri(e["uri"])[1] for e in entries]
            resp = ecr.describe_images(
                repositoryName=repo,
                imageIds=[{"imageTag": t} for t in tags if t])
            for d in resp.get("imageDetails", []):
                for t in d.get("imageTags", []):
                    meta[t] = {
                        "pushed_at": d.get("imagePushedAt").timestamp()
                        if d.get("imagePushedAt") else None,
                        "size_mb": round(d.get("imageSizeInBytes", 0) / 1e6, 1),
                    }
        except Exception:  # noqa: BLE001 — ECR unreachable or tags gone
            pass

    for e in entries:
        _, tag = _parse_image_uri(e["uri"])
        m = meta.get(tag)
        e["exists"] = m is not None
        e["pushed_at"] = m.get("pushed_at") if m else None
        e["size_mb"] = m.get("size_mb") if m else None

    return {"profile_id": profile_id, "current": current, "images": entries}


def delete_image(profile_id: str, image_uri: str) -> dict:
    """Delete an ECR tag from a profile's history. The *current* image cannot be
    deleted (guards against orphaning the ready image). Removes the entry from
    image_history and the ECR tag itself."""
    profile = store.get_profile(profile_id)
    if not profile:
        raise KeyError(profile_id)
    if image_uri == profile.get("image_uri"):
        raise ValueError("cannot delete the profile's current image")

    history = [h for h in (profile.get("image_history") or [])
               if h.get("uri") != image_uri]

    proj = config.get("PROJECT")
    deleted = False
    if proj:
        repo, tag = _parse_image_uri(image_uri)
        try:
            ecr = boto3.client("ecr", region_name=_region())
            ecr.batch_delete_image(repositoryName=repo,
                                   imageIds=[{"imageTag": tag}])
            deleted = True
        except Exception:  # noqa: BLE001 — already gone / not found
            pass

    store.update_profile(profile_id, image_history=history)
    return {"deleted": deleted, "image_uri": image_uri}

