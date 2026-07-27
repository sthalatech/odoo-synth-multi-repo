"""Developer environment lifecycle via Coder (coder/coder).

An *environment* is a Coder workspace: an EC2 instance launched by the Coder
server from the `odoo-synth-workspacer` Terraform template (existing thin golden AMI
+ existing env instance profile, no public IP, no per-env SG rules). The Coder
agent running inside the workspace dials out to the Coder server over the
public internet; the developer reaches the workspace (web terminal, VS Code
Web, port-forwarded Odoo) through Coder's Wireguard tunnel -- so the workspace
needs zero inbound ports and no Secrets Manager secret. This deletes ~5 AWS
artifacts per environment vs. the old hand-rolled EC2/Secrets-Manager/SG-ingress
design.

This module is a thin shim over the `coder` CLI (driven by CODER_URL +
CODER_SESSION_TOKEN). The panel stores the Coder workspace name and proxies
lifecycle to the CLI/API.
"""
from __future__ import annotations
import base64
import json
import os
import re
import secrets
import string
import subprocess
import time
import urllib.request
import uuid
import yaml
from typing import Optional

from . import component_env, config, pipeline, profiles, store

TEMPLATE_NAME = "odoo-synth-workspacer"


def _region() -> str:
    return config.require("AWS_REGION")


def _coder_env() -> dict:
    """Env for the coder CLI: the server URL + a session token, plus AWS creds.

    CODER_SESSION_TOKEN resolves via config.coder_token(), which validates the
    configured token and falls back to "" (keyring) when it is stale. The env
    var is omitted when empty so the coder CLI reads its keyring session."""
    env: dict = {
        "CODER_URL": config.coder_url() or "",
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




def _gen_password(n: int = 24) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(n))




def _env_secret_prefix() -> str:
    e = config.environments_cfg() if hasattr(config, "environments_cfg") else {}
    return (e.get("secret_prefix") or "odoo-synth/env")


def _put_password_secret(env_id: str, password: str) -> str:
    """Create a Secrets Manager secret for the env's Odoo admin password;
    return its ARN."""
    import boto3
    sm = boto3.client("secretsmanager", region_name=_region())
    name = f"{_env_secret_prefix()}/{env_id}/password"
    try:
        resp = sm.create_secret(Name=name, SecretString=password,
                                Description="odoo-synth workspace Odoo admin password")
        return resp["ARN"]
    except sm.exceptions.ResourceExistsException:
        sm.put_secret_value(SecretId=name, SecretString=password)
        return sm.describe_secret(SecretId=name)["ARN"]


def _get_password_secret(arn: str | None) -> str:
    if not arn:
        return ""
    import boto3
    try:
        return boto3.client("secretsmanager", region_name=_region()).get_secret_value(
            SecretId=arn).get("SecretString", "")
    except Exception:  # noqa: BLE001
        return ""


def _delete_password_secret(arn: str | None) -> None:
    if not arn:
        return
    import boto3
    try:
        boto3.client("secretsmanager", region_name=_region()).delete_secret(
            SecretId=arn, ForceDeleteWithoutRecovery=True)
    except Exception:  # noqa: BLE001
        pass

def _subdomain_url(subdomain_name: str) -> str:
    """Build the browser-reachable URL for a subdomain-hosted coder_app.

    CODER_URL is the Coder server origin, e.g. http://13.222.25.98:8943, and
    CODER_WILDCARD_ACCESS_URL on the server is "*.<same host:port>". Coder
    exposes per-app `subdomain_name` = "<app>--<ws>--<owner>". The app origin is
    therefore "<subdomain_name>.<host>:<port>" with the same scheme:port as
    CODER_URL. (nip.io makes *.host resolve to host, so no real DNS needed.)
    """
    base = config.get("CODER_URL", "").rstrip("/")
    if not base or not subdomain_name:
        return ""
    from urllib.parse import urlsplit
    ps = urlsplit(base)
    host, port = ps.hostname, ps.port
    full_host = f"{subdomain_name}.{host}" + (f":{port}" if port else "")
    return f"{ps.scheme}://{full_host}"


def _api(path: str) -> dict:
    """Call the Coder HTTP API (CODER_URL/api/v2/<path>) and return JSON."""
    url = f"{config.coder_url().rstrip('/')}/api/v2/{path.lstrip('/')}"
    tok = config.coder_token()
    req = urllib.request.Request(url, headers={"Coder-Session-Token": tok})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except Exception:  # noqa: BLE001
        return {}


def _api_send(path: str, method: str = "POST", body: dict | None = None) -> dict:
    """Call the Coder HTTP API with a request body (POST/PUT/DELETE). Raises
    RuntimeError with the server's message on a non-2xx so the panel surfaces
    the real error (e.g. 'email already taken')."""
    url = f"{config.coder_url().rstrip('/')}/api/v2/{path.lstrip('/')}"
    tok = config.coder_token()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Coder-Session-Token": tok,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        msg = f"coder {method} {path} -> HTTP {exc.code}"
        try:
            d = json.loads(exc.read().decode())
            msg = d.get("message") or msg
        except Exception:  # noqa: BLE001
            pass
        raise RuntimeError(msg) from exc
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(f"coder {method} {path} failed: {exc}") from exc

def _run(args: list, *, json_out: bool = True, timeout: int = 60, extra_env: dict | None = None):
    """Run a `coder` CLI command, returning parsed JSON (or stdout)."""
    cmd = ["coder"] + args + (["-o", "json"] if json_out else [])
    env = {**os.environ, **_coder_env()}
    if extra_env:
        env.update(extra_env)
    try:
        p = subprocess.run(cmd, env=env,
                           capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError as exc:
        raise RuntimeError("coder CLI not installed on the panel host") from exc
    if p.returncode != 0:
        raise RuntimeError(f"coder {' '.join(args)} failed: {p.stderr.strip() or p.stdout.strip()}")
    if not json_out:
        return p.stdout
    try:
        return json.loads(p.stdout) if p.stdout.strip() else {}
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"coder {args} returned non-JSON: {p.stdout[:200]}") from exc


def _dump_uri_for_run(run_id: Optional[str], explicit: Optional[str]) -> Optional[str]:
    """Resolve the masked-dump S3 URI: explicit wins, else the run's result."""
    if explicit:
        return explicit
    if not run_id:
        return None
    run = store.get_run(run_id)
    if not run:
        return None
    res = run.get("result") or {}
    return res.get("masked_dump_s3_uri")


def _resolve_odoo_image(source_run_id: Optional[str], s: dict) -> Optional[str]:
    """Provenance-baked Odoo image: a run's own image wins, else configured."""
    if source_run_id:
        run = store.get_run(source_run_id)
        if run:
            img = (run.get("result") or {}).get("odoo_image")
            if img:
                return img
    return s.get("odoo_image")


def _workspace_name_from_label(label: Optional[str]) -> Optional[str]:
    """Coerce a human-friendly label (e.g. 'iss-42-fix-login-500') into a
    Coder-safe workspace name. Coder requires lowercase alnum + hyphens,
    start/end alnum, <= 32 chars. Returns None when the label is empty / cannot
    be coerced (caller falls back to the random env id)."""
    if not label:
        return None
    name = label.strip().lower()
    name = re.sub(r"[^a-z0-9-]+", "-", name)
    name = re.sub(r"-+", "-", name).strip("-")
    if not name:
        return None
    if len(name) > 32:
        # keep the leading issue ref intact, truncate the slug tail
        name = name[:32].rstrip("-")
    if len(name) < 2:
        return None
    return name


def create(source_run_id: Optional[str], issue: Optional[str],
           dump_s3_uri: Optional[str], repo_url: Optional[str] = None,
           repo_branch: Optional[str] = None,
           profile_id: Optional[str] = None,
           name: Optional[str] = None) -> str:
    """Create a Coder workspace for the env. Runs `coder create` with the
    template parameters; the Coder server provisions the EC2 instance and the
    agent's startup_script boots Odoo.

    The env id (random hex) is the internal store key. The Coder *workspace
    name* defaults to that id, but an optional human-friendly ``name`` (e.g.
    ``iss-42-fix-login-500``) overrides it so the env is labelled on the Coder
    dashboard with the issue # + a short slug.

    The masked DB is already schema-matched to the provenance-baked Odoo image
    (same git refs at build + mask time), so the env boots Odoo directly against
    it with no ``-u all`` module upgrade."""
    if not config.environments_configured():
        raise RuntimeError(
            "developer environments are not configured (set CODER_URL and "
            "CODER_SESSION_TOKEN, and ensure the odoo-synth-workspacer template is "
            "published to the Coder server)")
    s = config.environments_settings()
    profile = store.get_profile(profile_id) if profile_id else None
    dump = _dump_uri_for_run(source_run_id, dump_s3_uri)
    if profile:
        odoo_img = profile.get("image_uri") or _resolve_odoo_image(source_run_id, s)
        r_url = repo_url or profile.get("addons_git_url") or s.get("repo_url")
        r_branch = repo_branch or profile.get("addons_git_ref") or s.get("repo_branch")
        # The git token is a Coder user secret injected as $GH_PAT_<UPPER_ID>;
        # pass the env-var NAME to the template (the value is write-only in
        # Coder, so we never hold it). Empty when the profile has no token.
        git_token_env = (profiles.git_token_env_name(profile.get("id") or "")
                         if profile.get("git_token_secret") else "") or s.get("git_token_env", "")
        conf_extra = profile.get("odoo_conf_extra") or ""
        agent_name = (profile.get("agent_name") or "").strip()
        agent_system_prompt = profile.get("agent_system_prompt") or ""
    else:
        odoo_img = _resolve_odoo_image(source_run_id, s)
        r_url = repo_url or s.get("repo_url")
        r_branch = repo_branch or s.get("repo_branch")
        git_token_env = s.get("git_token_env", "")
        conf_extra = ""
        agent_name = ""
        agent_system_prompt = ""
    conf_extra_b64 = base64.b64encode((conf_extra or "").encode()).decode()
    agent_system_prompt_b64 = base64.b64encode(
        (agent_system_prompt or "").encode()).decode()

    # Multi-repo: resolve + upload each non-odoo component's env, so the
    # workspace can boot them alongside odoo. {"components": [], ...} for a
    # legacy profile or a profile-less inline env -- the workspace then boots
    # exactly the single Odoo container it always has, unchanged.
    components_json = base64.b64encode(
        json.dumps({"components": [], "dependencies": []}).encode()).decode()
    if profile:
        all_components = profiles.components_of(profile)
        dependencies = profiles.dependencies_of(profile)
        non_odoo = [c for c in all_components if c.get("kind") != "odoo"]
        if non_odoo:
            port_table = component_env.build_port_table(all_components)
            dependency_conn = component_env.build_dependency_conn(dependencies)
            # The shared masked DB, as env-db (this same template's local
            # postgres, hydrated from `dump`) already exposes it: published to
            # 127.0.0.1:5432 with fixed odoo/odoo creds -- see the "envnet"
            # section of this template's startup_script. Every other
            # component's DB-bucket vars point at these same values.
            dest_conn = {"host": "127.0.0.1", "port": 5432,
                         "dbname": s.get("db_name") or "odoo",
                         "user": "odoo", "password": "odoo"}
            # This workspace's own local Odoo -- a fixed target (like
            # dest_conn above), not per-profile discovered: every workspace
            # runs Odoo on 127.0.0.1:18069 with the masker's admin/admin
            # login reset, against this same dest_conn database.
            odoo_conn = {"host": "127.0.0.1", "port": 18069, "scheme": "http",
                         "dbname": dest_conn["dbname"], "login": "admin",
                         "password": config.get("ODOO_ADMIN_PASSWORD", "admin")}
            resolved_components = []
            for c in non_odoo:
                env_pairs = list(component_env.resolve_component_env(
                    c, dest_conn, port_table, dependency_conn, odoo_conn).items())
                env_get_url, env_keys = (
                    pipeline._upload_env_file(env_pairs) if env_pairs else ("", []))
                built = c.get("built") or {}
                resolved_components.append({
                    "name": c["name"], "kind": c.get("kind"), "port": c.get("port"),
                    "image_uri": built.get("image_uri"),
                    "resolved_ref": built.get("resolved_ref"),
                    "repo_url": c.get("repo_url"), "repo_ref": c.get("repo_ref"),
                    "docker": c.get("docker") or {}, "process": c.get("process") or {},
                    "static": c.get("static") or {},
                    "env_get_url": env_get_url, "env_keys": env_keys,
                    # Explicit opt-in to Coder-tunnel exposure (see
                    # profiles._validate_components) -- deliberately NOT
                    # derived from "port" above, since a component can need
                    # a port for internal peer-wiring without wanting a
                    # dashboard app tile (an internal-only API, say).
                    "expose": c.get("expose"),
                })
            components_json = base64.b64encode(json.dumps({
                "components": resolved_components, "dependencies": dependencies,
            }).encode()).decode()

    env_id = uuid.uuid4().hex[:10]
    # Coder workspace name: a human-friendly label when given, else the env id.
    ws_name = _workspace_name_from_label(name) or env_id
    store.create_environment(env_id, source_run_id, issue, dump,
                             repo_url=r_url, repo_branch=r_branch,
                             odoo_image=odoo_img, profile_id=profile_id)
    store.update_environment(env_id, status="provisioning",
                             odoo_image=odoo_img, repo_url=r_url, repo_branch=r_branch)

    admin_password = _gen_password()
    params = [
        ("ami_id", s["ami_id"]),
        ("instance_profile", s["instance_profile"]),
        ("subnet_id", s["subnet_id"]),
        ("security_group_id", s["security_group_id"]),
        ("region", _region()),
        ("instance_type", s["instance_type"]),
        ("odoo_image", odoo_img or ""),
        ("dump_s3_uri", dump or ""),
        ("repo_url", r_url or ""),
        ("repo_branch", r_branch or ""),
        ("git_token_env", git_token_env or ""),
        ("issue", issue or ""),
        ("db_name", s.get("db_name") or "odoo"),
        ("odoo_master_password",
         config.get("ODOO_MASTER_PASSWORD", "change_me_master") or "change_me_master"),
        ("odoo_conf_extra_b64", conf_extra_b64),
        ("admin_password", admin_password),
        # Per-preset agent config (profile.agent_name / agent_system_prompt).
        # Empty agent_name => the template default (opencode); empty prompt =>
        # the built-in agent-system-prompt.md shipped on the AMI.
        ("agent_name", agent_name),
        ("agent_system_prompt_b64", agent_system_prompt_b64),
        ("components_json", components_json),
    ]
    # --preset none disables any auto-applied template preset (one per
    # built+masked profile, generated by deploy/_gen_presets.py). Without this
    # Coder applies the *default* preset, which LOCKS odoo_image + dump_s3_uri
    # to that preset's profile and silently ignores our CODER_RICH_PARAMETER_FILE
    # values -- so an env requested for profile A would boot with profile B's
    # image + dump. Passing `none` forces every parameter to come from our param
    # file, which is exactly what env create needs (it already resolves the
    # provenance-correct image + dump for the requested profile/run).
    args = ["create", "-t", TEMPLATE_NAME, "-y", "--no-wait",
            "--preset", "none", ws_name]
    # Pass rich parameters via a YAML map file (CODER_RICH_PARAMETER_FILE)
    # rather than `--parameter name=value` flags: Coder's --parameter is a
    # string-array flag that splits each value on commas, which breaks
    # comma-separated values (e.g. a,b,c -> "got b"). The YAML map file keeps
    # values intact and is not split, so multi-value params reach the agent
    # startup script unmodified.
    import tempfile, os as _os
    params_doc = {k: str(v) for k, v in params}
    fd, param_path = tempfile.mkstemp(prefix="coder_params_", suffix=".yaml")
    try:
        with _os.fdopen(fd, "w") as fh:
            yaml.safe_dump(params_doc, fh, default_flow_style=False, sort_keys=False)
        _run(args, json_out=False, timeout=120,
             extra_env={"CODER_RICH_PARAMETER_FILE": param_path,
                        "CODER_PRESET_NAME": "none"})
    finally:
        try: _os.unlink(param_path)
        except OSError: pass
    pw_arn = _put_password_secret(env_id, admin_password)
    store.update_environment(env_id, workspace_name=ws_name, status="provisioning",
                            password_secret=pw_arn)
    return env_id


# ---------------------------------------------------------------------------
# Post-launch hooks (GitHub Actions -> env -> agent)
# ---------------------------------------------------------------------------
# After `create` returns the env is provisioning on the Coder server. The
# GitHub Actions hook waits for the workspace build to finish (so the EC2 agent
# is up) then runs the boot/startup script to readiness before driving the AI
# agent (opencode / claude-code, driven by superpowers) inside it over `coder ssh`.
# These helpers wrap the
# `coder` CLI; they do NOT mutate infra, so they are safe to run alongside the
# discover/build/mask pipeline in another process.

def _workspace_status(name: str) -> str:
    """Latest build status for a workspace name, via the Coder API. Returns
    'unknown' on any error so the caller can decide whether to keep waiting."""
    try:
        ws = _run(["list", "-a", "--search", f"name={name}"], timeout=30)
    except Exception:  # noqa: BLE001
        return "unknown"
    for w in ws if isinstance(ws, list) else []:
        if w.get("name") == name:
            return ((w.get("latest_build") or {}).get("status") or "unknown")
    return "unknown"


def wait_for_env(env_id: str, timeout: int = 1200, poll: int = 10) -> bool:
    """Block until the Coder workspace for ``env_id`` reaches a terminal build
    state (running / failed / deleted). The env's EC2 instance + Coder agent
    are up once 'running'; the agent's blocking startup_script (Odoo boot) then
    continues server-side. Returns True when running, False on timeout or a
    failed/deleted build. Idempotent + read-only: safe to retry."""
    env = store.get_environment(env_id)
    if not env:
        raise ValueError(f"environment not found: {env_id}")
    name = env.get("workspace_name") or env_id
    deadline = time.time() + timeout
    while True:
        st = _workspace_status(name)
        if st in ("running", "failed", "deleted", "canceled", "canceling"):
            store.update_environment(env_id, status=_STATUS_MAP.get(st, st))
            return st == "running"
        if time.time() > deadline:
            return False
        time.sleep(poll)


def _coerce_out(v) -> str:
    """subprocess output is str under text=True, but TimeoutExpired may yield
    bytes on some Python versions; normalize so concatenation never raises."""
    if v is None:
        return ""
    if isinstance(v, bytes):
        try:
            return v.decode("utf-8", "replace")
        except Exception:
            return ""
    return v


def ssh_exec(env_id: str, command: str, timeout: int = 600) -> tuple[int, str]:
    """Run a single non-interactive command inside the workspace over
    `coder ssh <ws> -- <cmd>`. Returns (exit_code, combined_output). The
    workspace is auto-started by the Coder SSH gateway if stopped. The command
    runs as the agent user (root at boot; the dev user's shell for login cmds)."""
    env = store.get_environment(env_id)
    if not env:
        raise ValueError(f"environment not found: {env_id}")
    name = env.get("workspace_name") or env_id
    # NOTE: do NOT use `-- bash -lc <command>` here. Coder v2.34 ssh splits
    # the argv after `--` on whitespace and only passes the first token to
    # `bash -lc`, silently truncating multi-word commands to their first word
    # (e.g. `echo hi > f` runs just `echo`). Passing the command directly
    # (no `--`, no `bash -lc`) lets coder ssh run it via the user's login
    # shell, which preserves the full command. --wait=yes auto-starts a
    # stopped workspace.
    cmd = ["coder", "ssh", "--wait=yes", name, command]
    try:
        p = subprocess.run(cmd, env={**os.environ, **_coder_env()},
                           capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        return 124, _coerce_out(exc.stdout) + _coerce_out(exc.stderr)
    except FileNotFoundError as exc:
        raise RuntimeError("coder CLI not installed on the panel host") from exc
    return p.returncode, _coerce_out(p.stdout) + _coerce_out(p.stderr)


# Where the project-level system prompt for the AI agent lives. The hook writes
# the first-phase placeholder here; contents are filled in later. Shipped in
# the repo so every env loads the same project context.
AGENT_SYSTEM_PROMPT_PATH = "coder/templates/odoo-synth-workspacer/agent-system-prompt.md"


def _stage_agent_context(env_id: str, issue: str, task: str, system_prompt: str) -> str:
    """Stage the project system prompt + issue/task context into the workspace
    so the agent reads it on start. Best-effort: the env's startup script
    already stages the per-profile prompt as AGENT_CONTEXT.md / AGENT.md at
    boot; this overlays the issue/task specifics for the webhook path (so the
    agent sees the GitHub issue body, not just the bare task). Returns the
    remote path written (empty on failure)."""
    import textwrap
    body = textwrap.dedent(f"""\
        # odoo-synth agent context (env {env_id})

        > ⚠️ READ THIS FILE FIRST. Before you do anything else, read this whole
        > file (and `AGENT.md` in your cwd if present). It carries the GitHub
        > issue, your task, the commit/push/PR mandate, and the browser guidance. Do NOT rely solely on the superpowers brainstorming
        > checklist — that checklist ends at "transition to implementation"
        > and does NOT include finishing the branch. Committing, pushing, and
        > opening a PR (`gh pr create --base <branch>`) are part of YOUR task,
        > and you must also capture a headless-Chrome screenshot of the changed
        > view as evidence for the PR. Do not stop until the PR is created.

        ## GitHub issue
        {issue or '(none)'}

        ## Task
        {task or '(see the issue above)'}

        ## Project system prompt
        {system_prompt or '(staged by the env startup script from the profile)'}
        """)
    b64 = base64.b64encode(body.encode()).decode()
    remote = "/home/dev/workspace/AGENT_CONTEXT.md"
    cmd = (
        "install -d /home/dev/workspace /home/dev/workspace/repo && "
        f"echo '{b64}' | base64 -d > {remote} && "
        f"chown dev:dev {remote} 2>/dev/null; "
        f"if [ ! -f /home/dev/workspace/repo/AGENT.md ]; then "
        f"cp {remote} /home/dev/workspace/repo/AGENT.md && "
        "chown dev:dev /home/dev/workspace/repo/AGENT.md 2>/dev/null; fi; true"
    )
    rc, out = ssh_exec(env_id, cmd, timeout=900)
    return remote if rc == 0 else ""


def _ensure_agent_launcher(env_id: str) -> None:
    """Write /home/dev/workspace/run-agent.sh on the env (idempotent). The
    launcher sources the per-env agent-env file (GH_TOKEN for `gh` PR creation)
    and execs the agent with the task decoded from a base64 argv. Kept as a
    file so run_agent can invoke it without nested shell quoting (ssh_exec
    runs `bash -lc <cmd>`, so any single quotes in the command break)."""
    script = r"""#!/usr/bin/env bash
set -a
. /home/dev/.config/agent-env 2>/dev/null || true
set +a
cd /home/dev/workspace/repo 2>/dev/null || cd /home/dev/workspace
AGENT="$1"; TASK_B64="$2"
TASK="$(printf %s "$TASK_B64" | base64 -d)"
case "$AGENT" in
  claude-code) exec claude -p "$TASK" ;;
  *)           exec opencode run --auto "$TASK" ;;
esac
"""
    b64 = base64.b64encode(script.encode()).decode()
    cmd = (
        f"echo {b64} | base64 -d > /home/dev/workspace/run-agent.sh && "
        f"chmod 755 /home/dev/workspace/run-agent.sh && "
        f"chown dev:dev /home/dev/workspace/run-agent.sh 2>/dev/null; true"
    )
    ssh_exec(env_id, cmd, timeout=120)


def run_agent(env_id: str, task: str, *, agent: str = "opencode",
               max_iterations: int = 15, issue: Optional[str] = None,
               system_prompt: Optional[str] = None,
               timeout: int = 3600) -> dict:
    """Invoke the AI agent headlessly inside the launched env. The agent runs
    once in a single session; superpowers (the agentic-skills plugin baked into
    the golden AMI) drives it autonomously through the task -- brainstorm ->
    plan -> git-worktree -> TDD subagent dev -> review -> finish branch (merge
    /PR) -- so no external loop (the former ralph-wiggum) is needed. A wall-clock
    ``timeout`` caps cost (default 1h). Returns {exit_code, output, command,
    workspace, agent}.

    - ``agent``: opencode (default, no per-user API key) or claude-code.
    - ``max_iterations``: kept for API compatibility; no longer used (the agent
      self-drives via superpowers; the wall-clock timeout is the cost guard).
    - ``issue``/``system_prompt``: staged as AGENT_CONTEXT.md / AGENT.md so the
      agent follows the project context. The env startup script already stages
      the per-profile prompt; this overlays the issue/task specifics.
    """
    env = store.get_environment(env_id)
    if not env:
        raise ValueError(f"environment not found: {env_id}")
    name = env.get("workspace_name") or env_id
    _stage_agent_context(env_id, issue or "", task, system_prompt or "")
    # Run via the staged launcher script (avoids nested-shell quoting --
    # ssh_exec runs `bash -lc <cmd>`, so single quotes in the command break).
    # The task is base64-encoded and passed as argv to the launcher, which
    # sources GH_TOKEN (for `gh` PR creation) and execs the agent.
    _ensure_agent_launcher(env_id)
    task_b64 = base64.b64encode((task or "").encode()).decode()
    cmd = f"sudo -u dev HOME=/home/dev /home/dev/workspace/run-agent.sh {agent} {task_b64}"
    rc, out = ssh_exec(env_id, cmd, timeout=timeout)
    return {"exit_code": rc, "output": out, "command": cmd,
            "workspace": name, "agent": agent}


# Coder workspace build status -> our env status.
_STATUS_MAP = {
    "pending": "provisioning", "starting": "provisioning", "building": "provisioning",
    "running": "running", "stopped": "stopped", "stopping": "stopping",
    "deleting": "terminated", "deleted": "terminated", "failed": "failed",
    "canceling": "failed", "canceled": "failed",
}


def reconcile() -> None:
    """Refresh env statuses from the Coder API. Called when the UI lists envs
    so a panel restart recovers the true state -- the Coder server owns
    lifecycle now, so this is a single API call, not per-env EC2 polling."""
    try:
        ws = _run(["list", "-a"], json_out=True, timeout=30)
    except Exception:  # noqa: BLE001
        return
    by_name = {w.get("name"): w for w in (ws if isinstance(ws, list) else [])}
    for e in store.list_environments():
        name = e.get("workspace_name") or e.get("id")
        w = by_name.get(name)
        if not w:
            if e.get("status") not in ("terminated", "failed"):
                store.update_environment(e["id"], status="terminated",
                                        error="workspace not found in Coder")
            continue
        latest = (w.get("latest_build") or {})
        cs = _STATUS_MAP.get(latest.get("status", ""), e.get("status"))
        if cs != e.get("status"):
            store.update_environment(e["id"], status=cs)
        # app URLs: Coder serves each app on its OWN origin (subdomain app
        # hosting, CODER_WILDCARD_ACCESS_URL=*.host). This is REQUIRED for Odoo:
        # its login form / assets use absolute server-root paths
        # (/web/login, /web/session/authenticate, /web/static/...) that resolve
        # against the app's own origin. With the old path proxy
        # (@owner/ws/apps/slug) those hit the Coder dashboard origin and 404.
        # The API exposes subdomain_name = "<app>--<ws>--<owner>"; the full host
        # is "<subdomain_name>.<wildcard-base>" where wildcard-base is the
        # CODER_URL host (the server's wildcard is "*.<that host>", so we
        # prefix the subdomain name to the same host:port).
        odoo = None
        wuuid = w.get("id")
        if wuuid:
            d = _api(f"workspaces/{wuuid}?include_agents=true")
            for r in (d.get("latest_build") or {}).get("resources", []):
                for a in r.get("agents", []):
                    for app in a.get("apps", []) or []:
                        if not app.get("subdomain"):
                            continue  # only subdomain apps are reachable for Odoo
                        sd = app.get("subdomain_name")
                        if not sd:
                            continue
                        u = _subdomain_url(sd)
                        if app.get("slug") == "odoo": odoo = u
        # VS Code is no longer surfaced as a panel url -- users open it via the
        # Coder dashboard's native vscode:// deeplink (session-authenticated).
        store.update_environment(e["id"], odoo_url=odoo)


def get_password(env_id: str) -> Optional[str]:
    """The per-workspace Odoo admin password. The value lives in
    Secrets Manager (ARN on the env record); only the ARN is on disk so the
    password isn't sitting in envs.yaml in plaintext."""
    env = store.get_environment(env_id)
    if not env:
        return None
    pw = _get_password_secret(env.get("password_secret"))
    return pw or None


def teardown(env_id: str) -> None:
    """Delete the Coder workspace (Coder terminates the EC2 instance + cleans
    up the Terraform state). No per-env SG rule or secret to revoke -- those no
    longer exist."""
    env = store.get_environment(env_id)
    if not env:
        raise ValueError("environment not found")
    name = env.get("workspace_name") or env_id
    try:
        _run(["delete", "-y", name], json_out=False, timeout=120)
    except Exception as exc:  # noqa: BLE001
        # A workspace build may already be active (e.g. a prior delete in
        # flight), or the workspace is already gone. Either way the workspace
        # is being/has been removed by Coder -- still clean up our linkage +
        # the password secret so `env delete` is idempotent.
        msg = str(exc)
        if "already active" not in msg and "not found" not in msg.lower():
            store.update_environment(env_id, status="failed", error=msg)
    _delete_password_secret(env.get("password_secret"))
    store.delete_environment(env_id)


# Back-compat: the panel used to call `environments.reconcile_booting`.
reconcile_booting = reconcile


# ---------------------------------------------------------------------------
# Coder users (multi-user: create/list via the coder CLI)
# ---------------------------------------------------------------------------

def _default_org_id() -> str:
    """The default org id (the panel creates users in the default org)."""
    orgs = _api("organizations")
    if isinstance(orgs, list) and orgs:
        return orgs[0].get("id", "")
    if isinstance(orgs, dict) and orgs.get("organizations"):
        return orgs["organizations"][0].get("id", "")
    return ""


def list_users() -> list:
    """List Coder users via the HTTP API (admin sees all)."""
    d = _api("users")
    if isinstance(d, list):
        return d
    if isinstance(d, dict) and "users" in d:
        return d["users"]
    return []


def create_user(email: str, password: str = "") -> dict:
    """Create a Coder user (member, default org) via the HTTP API. The new
    user can immediately log in and create their own workspaces; their apps
    are owner-private by default (sharing_level=owner)."""
    if not email or "@" not in email:
        raise ValueError("a valid email is required")
    if not password:
        raise ValueError("a password is required (SMTP reset is not configured)")
    org_id = _default_org_id()
    if not org_id:
        raise RuntimeError("no Coder organization found to add the user to")
    # Coder requires a username; derive one from the email local-part, made
    # Coder-username-safe (lowercase alnum, max 32 chars).
    username = re.sub(r"[^a-z0-9]", "", email.split("@", 1)[0].lower())[:32] or "user"
    body = {
        "email": email,
        "password": password,
        "username": username,
        "organization_ids": [org_id],
    }
    return _api_send("users", method="POST", body=body)
