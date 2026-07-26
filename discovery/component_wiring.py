"""Multi-component wiring discovery: classify a component's env-var *names*
(never persisting a raw value) so the panel can auto-wire the shared DB, peer
components, and declared shared infra, and leave everything else as an
editable per-component placeholder.

Runs inside the discovery container (see discover.py's per-component loop).
Deliberately dependency-free (stdlib only) since this image is a minimal
python:slim with no access to lib/backend/* -- separate build context.
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

# suffix -> what a name-prefix match to another component/dependency means
_HOST_SUFFIXES = ("_HOST", "_HOSTNAME")
_PORT_SUFFIXES = ("_PORT",)
_URL_SUFFIXES = ("_URL", "_DOMAIN", "_BASE_URL", "_ENDPOINT")

# key name -> which field of the shared DB connection it holds. Drives
# env-create's resolution (host/port/dbname/user/password/dsn), not just
# discovery's classification -- this IS the full DB bucket vocabulary, a
# closed set (unlike peer/shared_infra, which are open-ended by component/
# dependency name), so a direct lookup table is clearer than more pattern
# matching.
_DB_FIELD_MAP = {
    "DB_HOST": "host", "POSTGRES_HOST": "host",
    "DB_PORT": "port", "POSTGRES_PORT": "port",
    "DB_NAME": "dbname", "POSTGRES_DB": "dbname",
    "DB_USER": "user", "DB_USERNAME": "user", "POSTGRES_USER": "user",
    "DB_PASSWORD": "password", "DB_PASS": "password", "POSTGRES_PASSWORD": "password",
}
_DB_DSN_RE = re.compile(r"^(DATABASE|POSTGRES|PG)_?(URL|DSN)$")

_LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "0.0.0.0", "::1"}


def _norm(name: str) -> str:
    """Normalize a component/dependency name or an env-var prefix for
    case/separator-insensitive matching (e.g. "prs-frontend" == "PRS_FRONTEND")."""
    return re.sub(r"[-_]+", "_", name).strip("_").upper()


def _strip_suffix(key: str, suffixes: tuple[str, ...]) -> Optional[str]:
    upper = key.upper()
    for suf in suffixes:
        if upper.endswith(suf) and len(upper) > len(suf):
            return upper[: -len(suf)]
    return None


def _parse_url_loopback_port(value: str) -> Optional[int]:
    """If `value` is a URL/DSN pointing at a loopback host, return its port."""
    try:
        u = urlparse(value.strip())
    except ValueError:
        return None
    if not u.hostname or u.hostname.lower() not in _LOOPBACK_HOSTS:
        return None
    return u.port


def _url_scheme(value: str) -> str:
    try:
        return urlparse(value.strip()).scheme.lower()
    except ValueError:
        return ""


def read_env_sample(repo_dir: Path, from_repo: Optional[str]) -> dict[str, str]:
    """Parse a checked-in env file (KEY=value per line) into a dict. Tries
    `from_repo` first if given, else common conventional names -- preferring
    an explicit sample/example/template (the best-practice convention) but
    falling back to an actually-tracked .env/.env.local/.env.development/
    .env.test, since in practice not every repo follows the sample-file
    convention (some check the real thing into git directly, values and
    all). Either way this only ever reads whatever is CHECKED INTO the repo
    at `repo_ref` -- never a developer's untracked local copy, which this
    process has no access to and never sees. Returns {} if none exist."""
    candidates = [from_repo] if from_repo else []
    candidates += [".env.sample", ".env.example", ".env.template", "env.sample",
                   ".env", ".env.local", ".env.development", ".env.test"]
    for name in candidates:
        if not name:
            continue
        p = repo_dir / name
        if p.exists():
            return _parse_env_lines(p.read_text(encoding="utf-8", errors="ignore"))
    return {}


def _parse_env_lines(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        if key:
            out[key] = val
    return out


def clone_repo(url: str, ref: str, dest: Path, git_token: str = "") -> Optional[Path]:
    """Shallow-clone `url`@`ref` into `dest`. Mirrors discover.py's clone_addons
    but generalized to any repo (not just the addons repo)."""
    if not url:
        return None
    clone_url = url
    if git_token and url.startswith("https://"):
        clone_url = url.replace("https://", f"https://x-access-token:{git_token}@", 1)
    subprocess.check_call(
        ["git", "clone", "--depth", "1", "--filter=blob:none", "--quiet",
         "--branch", ref or "HEAD", clone_url, str(dest)])
    return dest


def check_kind_shape(repo_dir: Path, kind: str, kind_cfg: dict) -> tuple[bool, str]:
    """Soft validation that the repo actually looks like the declared `kind`.
    Never hard-fails discovery -- returns a warning string to surface to the
    operator instead, since repo layout conventions vary."""
    if kind == "docker":
        dockerfile = kind_cfg.get("dockerfile") or "Dockerfile"
        if not (repo_dir / dockerfile).exists():
            return False, f"kind=docker but no {dockerfile} found at repo root"
    elif kind in ("process", "static"):
        has_pkg = (repo_dir / "package.json").exists()
        has_reqs = (repo_dir / "requirements.txt").exists()
        has_gomod = (repo_dir / "go.mod").exists()
        if not (has_pkg or has_reqs or has_gomod):
            return False, (f"kind={kind} but no package.json/requirements.txt/"
                            f"go.mod found -- install_cmd/start_cmd may need "
                            f"manual review")
    return True, ""


def find_dockerfile_port(repo_dir: Path, dockerfile: str = "Dockerfile") -> Optional[int]:
    """Best-effort: propose a component's own port from its Dockerfile's
    EXPOSE or a `--port <n>` in its CMD/ENTRYPOINT. None if not found --
    the operator sets `port` explicitly in that case (ports are platform
    configuration, not something to guess when the image doesn't declare one)."""
    p = repo_dir / dockerfile
    if not p.exists():
        return None
    text = p.read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"^\s*EXPOSE\s+(\d+)", text, re.MULTILINE)
    if m:
        return int(m.group(1))
    m = re.search(r"--port[= ]\"?(\d+)\"?", text)
    if m:
        return int(m.group(1))
    return None


def classify_component_env(
    component_name: str,
    env_keys: dict[str, str],
    port_table: dict[str, int],
    dependency_names: dict[str, str],
) -> dict[str, dict]:
    """Classify each env-var NAME into a wiring bucket. `env_keys` values are
    used only transiently (to read a port number or URL scheme) -- the
    returned plan never includes the original value, only {bucket, target}.

    port_table: {component_name: port} for every OTHER component (self
      excluded) -- the platform's own port assignments, not discovered from
      any developer's local env.
    dependency_names: {dependency_name: dependency_kind}, e.g. {"redis": "redis"}.

    Buckets: db | peer | shared_infra | own_port | external.
    """
    plan: dict[str, dict] = {}
    own_port = port_table.get(component_name)
    peers = {name: port for name, port in port_table.items() if name != component_name}
    norm_peers = {_norm(name): name for name in peers}
    norm_deps = {_norm(name): (name, kind) for name, kind in dependency_names.items()}

    for key, value in env_keys.items():
        upper = key.upper()
        loop_port = _parse_url_loopback_port(value)

        # 1. DB bucket -- exact well-known DB var names, or a single DSN var.
        # `field` says which part of the connection this key holds (env-create
        # needs this to resolve a concrete value; "dsn" means the whole
        # postgresql://... URL rather than one field).
        if upper in _DB_FIELD_MAP:
            plan[key] = {"bucket": "db", "field": _DB_FIELD_MAP[upper]}
            continue
        if _DB_DSN_RE.match(upper):
            plan[key] = {"bucket": "db", "field": "dsn"}
            continue

        # 2. peer bucket via STRICT name-prefix match (HOST/PORT/URL-style
        # suffix, e.g. ODOO_HOST/ODOO_PORT). Deliberately no "name appears
        # anywhere in the key" fallback -- that over-matched sibling keys
        # like ODOO_LOGIN/ODOO_PASSWORD/ODOO_PROTOCOL (same "ODOO" prefix,
        # but application credentials, not connection wiring) when tested
        # against the real sample data. Name-agnostic peer refs (e.g.
        # API_BASE_URL with no component-name hint) are caught by bucket 3.
        matched_peer = None
        suffix_kind = None
        for suffixes, kind_label in ((_HOST_SUFFIXES, "host"),
                                      (_PORT_SUFFIXES, "port"),
                                      (_URL_SUFFIXES, "url")):
            prefix = _strip_suffix(upper, suffixes)
            if prefix and prefix in norm_peers:
                matched_peer, suffix_kind = norm_peers[prefix], kind_label
                break
        if matched_peer:
            plan[key] = {"bucket": "peer", "target": matched_peer, "as": suffix_kind}
            continue

        # 3. peer bucket via VALUE port-match (e.g. API_BASE_URL with no name hint).
        if loop_port is not None:
            matched = next((name for name, port in peers.items() if port == loop_port), None)
            if matched:
                plan[key] = {"bucket": "peer", "target": matched, "as": "url"}
                continue

        # 4. shared-infra bucket: strict name-prefix match, or value scheme
        # match (e.g. BROKER_URL=redis://... has no "redis" in the key name
        # at all -- only the value's scheme identifies it). `as` mirrors the
        # peer bucket's tag (host/port/url) so env-create resolves the same
        # way; a scheme-only match (no suffix hint) defaults to "url" since
        # that's what a scheme implies (a whole connection URL).
        matched_dep = None
        dep_as = "url"
        for suffixes, kind_label in ((_HOST_SUFFIXES, "host"),
                                      (_PORT_SUFFIXES, "port"),
                                      (_URL_SUFFIXES, "url")):
            prefix = _strip_suffix(upper, suffixes)
            if prefix and prefix in norm_deps:
                matched_dep, dep_as = norm_deps[prefix][0], kind_label
                break
        if not matched_dep:
            scheme = _url_scheme(value)
            if scheme:
                matched_dep = next((name for name, kind in dependency_names.items()
                                     if kind.lower() == scheme), None)
        if matched_dep:
            plan[key] = {"bucket": "shared_infra", "target": matched_dep, "as": dep_as}
            continue

        # 5. own-port: informational only, not wired -- confirms the port table.
        if own_port is not None and (upper.endswith("_PORT") or upper == "PORT") \
                and loop_port == own_port:
            plan[key] = {"bucket": "own_port"}
            continue

        # 6. everything else: external, operator fills in (or keeps the
        # sample's own default for non-secret tuning knobs) -- same
        # never-auto-fill posture as required_config_keys/odoo_conf_extra
        # today. Deliberately no secret-vs-benign guessing here either --
        # matching that existing precedent rather than inventing a new one.
        plan[key] = {"bucket": "external"}

    return plan
