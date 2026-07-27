"""Multi-repo: resolve each component's final env vars for env-create.

Turns a component's discovered wiring_plan (see discovery/component_wiring.py
-- {var_name: {bucket, field/target/as}}) into concrete {KEY: VALUE} pairs,
using the workspace's own port assignments and the shared local DB -- never
re-reading a developer's local env. Operator overrides (component.env.
overrides) always win over anything auto-wired.

All new (non-odoo) components run `--network host` in the workspace, same as
every other odoo-synth Coder template (discoverer/masker/builder) -- env-db
is reachable at 127.0.0.1:5432 regardless (it's published there for exactly
this reason), so plain localhost:<port> resolution works uniformly whether a
peer is a docker container or a native process/static server.
"""
from __future__ import annotations

import re
from typing import Any

# An override value of exactly this shape ("$EXTERNAL_URL(facade)") is
# resolved to that peer's actual browser-reachable subdomain URL, not a
# literal string. Distinct from the "peer" wiring bucket (component.
# discovered.wiring_plan), which always resolves to an internal
# localhost:<port> -- server-side wiring is workspace-invariant, but a
# browser-facing var (NEXT_PUBLIC_*, VITE_*, ...) needs a URL that's only
# known once a specific workspace exists (its subdomain encodes the
# workspace name), so it can't be a fixed literal in components.yaml.
_EXTERNAL_URL_RE = re.compile(r"^\$EXTERNAL_URL\(([a-z0-9-]+)\)$")

# dependency kind -> the port it's booted on when the workspace provisions it
# itself (see environments.py's dependency-boot step). Only kinds with a
# known default are auto-wireable; an unrecognized kind's shared_infra vars
# simply won't resolve (same "never guess" posture as everywhere else).
DEFAULT_DEPENDENCY_PORTS = {
    "redis": 6379,
}


def build_port_table(components: list[dict[str, Any]]) -> dict[str, int]:
    """{component_name: port} for every component that has one assigned
    (operator-declared, or discovery's proposed_port already folded onto
    component["port"] -- see discovery.py's merge). Components with no port
    (e.g. a pure worker) are simply absent -- nothing should reference them
    by port anyway."""
    return {c["name"]: int(c["port"]) for c in components if c.get("port")}


def build_dependency_conn(dependencies: list[dict[str, Any]]) -> dict[str, dict]:
    """{dependency_name: {host, port}} for every declared dependency this
    workspace will provision on a well-known port. An unrecognized kind is
    included with no port (host-only) -- see _resolve_url_shaped, which
    leaves the value unresolved rather than emitting a bogus port."""
    out: dict[str, dict] = {}
    for d in dependencies:
        kind = (d.get("kind") or d["name"]).lower()
        port = DEFAULT_DEPENDENCY_PORTS.get(kind)
        out[d["name"]] = {"host": "localhost", "port": port, "kind": kind}
    return out


def _resolve_db_value(field: str, dest_conn: dict) -> str:
    if field == "host":
        return dest_conn.get("host", "localhost")
    if field == "port":
        return str(dest_conn.get("port", 5432))
    if field == "dbname":
        return dest_conn.get("dbname", "")
    if field == "user":
        return dest_conn.get("user", "")
    if field == "password":
        return dest_conn.get("password", "")
    if field == "dsn":
        return (f"postgresql://{dest_conn.get('user', '')}:{dest_conn.get('password', '')}"
                f"@{dest_conn.get('host', 'localhost')}:{dest_conn.get('port', 5432)}"
                f"/{dest_conn.get('dbname', '')}")
    return ""


def _resolve_odoo_value(field: str, odoo_conn: dict) -> str:
    if field == "host":
        return odoo_conn.get("host", "localhost")
    if field == "port":
        return str(odoo_conn.get("port", ""))
    if field == "scheme":
        return odoo_conn.get("scheme", "http")
    if field == "dbname":
        return odoo_conn.get("dbname", "")
    if field == "login":
        return odoo_conn.get("login", "admin")
    if field == "password":
        return odoo_conn.get("password", "")
    return ""


def _resolve_url_shaped(as_kind: str, host: str, port, scheme: str = "http") -> str:
    if as_kind == "host":
        return host
    if as_kind == "port":
        return str(port) if port is not None else ""
    if port is None:
        return ""
    return f"{scheme}://{host}:{port}"


def resolve_component_env(component: dict[str, Any], dest_conn: dict,
                          port_table: dict[str, int],
                          dependency_conn: dict[str, dict],
                          odoo_conn: dict | None = None,
                          external_url_table: dict[str, str] | None = None) -> dict[str, str]:
    """A component's fully-resolved env vars: db-bucket vars point at the
    shared local DB, odoo-bucket vars point at this workspace's own local
    Odoo (a fixed target, like the db bucket -- not discovered per-profile),
    peer-bucket vars point at another component's assigned port,
    shared_infra-bucket vars point at a provisioned dependency, own_port
    confirms the component's own port. "external" vars are never auto-filled
    -- only present if the operator supplied env.overrides for them.
    overrides always win, for every bucket (an operator can force any value,
    including one auto-wiring would have produced differently).

    An override value of "$EXTERNAL_URL(<name>)" is a third case, resolved
    against external_url_table (built by environments.create(), which knows
    this workspace's own name) -- for browser-facing vars like Next.js's
    NEXT_PUBLIC_* or Vite's VITE_* that need a peer's actual subdomain URL,
    not its internal localhost:<port> (the browser runs on the developer's
    own machine, not inside the workspace's network namespace)."""
    wiring_plan = ((component.get("discovered") or {}).get("wiring_plan")) or {}
    overrides = ((component.get("env") or {}).get("overrides")) or {}
    odoo_conn = odoo_conn or {}
    external_url_table = external_url_table or {}

    resolved: dict[str, str] = {}
    for key, info in wiring_plan.items():
        bucket = info.get("bucket")
        if bucket == "db":
            resolved[key] = _resolve_db_value(info.get("field", ""), dest_conn)
        elif bucket == "odoo":
            resolved[key] = _resolve_odoo_value(info.get("field", ""), odoo_conn)
        elif bucket == "peer":
            target_port = port_table.get(info.get("target"))
            if target_port is not None:
                resolved[key] = _resolve_url_shaped(info.get("as", "url"), "localhost", target_port)
        elif bucket == "shared_infra":
            conn = dependency_conn.get(info.get("target")) or {}
            if conn:
                # e.g. redis -> "redis://host:port", not "http://" -- the
                # dependency's own kind IS its URL scheme.
                scheme = conn.get("kind") or info.get("target") or "http"
                resolved[key] = _resolve_url_shaped(info.get("as", "url"),
                                                    conn.get("host", "localhost"),
                                                    conn.get("port"), scheme=scheme)
        elif bucket == "own_port":
            own_port = port_table.get(component.get("name"))
            if own_port is not None:
                resolved[key] = str(own_port)
        # "external": never auto-filled -- only env.overrides (applied below)
        # or nothing at all, same as required_config_keys/odoo_conf_extra.

    for k, v in overrides.items():
        m = _EXTERNAL_URL_RE.match(str(v))
        resolved[k] = external_url_table.get(m.group(1), "") if m else str(v)

    # drop keys that resolved to "" (unresolvable -- e.g. peer/dependency with
    # no port, or $EXTERNAL_URL(x) where x has no expose.port set) so the
    # workspace doesn't export an empty, misleading value.
    return {k: v for k, v in resolved.items() if v != ""}
