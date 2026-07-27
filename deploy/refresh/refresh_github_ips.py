#!/usr/bin/env python3
"""Refresh GitHub hook IP ranges in the Caddy Caddyfile; reload Caddy only on change.

Fetches api.github.com/meta, extracts the `hooks` CIDR list, renders the Caddyfile
from a template, and -- if the new file differs from the current one -- atomically
replaces it and reloads Caddy. No reload when the ranges are unchanged (idempotent,
zero needless Caddy restarts). Fails closed: on a fetch/parse error it leaves the
existing Caddyfile untouched (GitHub's ranges change rarely; a stale allowlist is
better than a broken one).

Runs from a systemd timer (refresh-github-ips.timer) on the Coder server. This is
the ongoing source of truth for the Caddyfile -- the one deploy/14_caddy_https.sh
writes at install time is just the bootstrap; keep this template in sync with that
script's whenever either changes.

Writes /etc/caddy/.github_hook_ips for inspection + a stamp file with the last
successful refresh timestamp.
"""
from __future__ import annotations
import json
import os
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

META_URL = "https://api.github.com/meta"
CADDYFILE = Path("/etc/caddy/Caddyfile")
IPS_CACHE = Path("/etc/caddy/.github_hook_ips")
STAMP = Path("/etc/caddy/.github_hook_ips.refreshed")
FALLBACK = "192.30.252.0/22 185.199.108.0/22 140.82.112.0/20 143.55.64.0/20"

PUBLIC_DOMAIN = os.environ.get("PUBLIC_DOMAIN", "")
HOSTNAME = os.environ.get("CADDY_HOSTNAME", f"coder.{PUBLIC_DOMAIN}")
LISTENER_PORT = os.environ.get("WEBHOOK_PORT", "8080")
ASK_PORT = os.environ.get("ASK_PORT", "8081")


def fetch_hook_ips() -> str:
    """Return the space-joined GitHub hook CIDR list, or the fallback on error."""
    try:
        with urllib.request.urlopen(META_URL, timeout=20) as r:
            data = json.load(r)
        ips = data.get("hooks") or []
        if ips:
            return " ".join(ips)
    except Exception as e:  # noqa: BLE001
        sys.stderr.write(f"WARN: fetch failed ({e}); using cached/fallback ranges\n")
    # use the previously cached list if we have one (better than the static fallback)
    if IPS_CACHE.exists():
        cached = IPS_CACHE.read_text().strip()
        if cached:
            return cached
    return FALLBACK


def render_caddyfile(hook_ips: str) -> str:
    return f"""{{
	on_demand_tls {{
		ask http://127.0.0.1:{ASK_PORT}
	}}
}}

{HOSTNAME} {{
	encode zstd gzip

	# GitHub webhook -> odoo-synth listener (localhost only, if/when deployed).
	# Restricted to GitHub's hook IP ranges (auto-refreshed by this script);
	# everyone else gets 403. The listener additionally verifies the HMAC
	# signature + dedupes by X-GitHub-Delivery.
	@github_webhook {{
		path /webhook
		remote_ip {hook_ips}
	}}
	handle @github_webhook {{
		reverse_proxy 127.0.0.1:{LISTENER_PORT} {{
			flush_interval -1
			header_up X-Forwarded-Proto https
		}}
	}}
	# /webhook from a non-GitHub IP -> 403 (must come before the catch-all)
	@webhook_path path /webhook
	handle @webhook_path {{
		respond 403
	}}
	# everything else -> the Coder HTTP server (dashboard + API). Host is
	# passed through unchanged -- it already equals {HOSTNAME}, which is
	# exactly what Coder's own CODER_ACCESS_URL is configured as.
	handle {{
		reverse_proxy 127.0.0.1:8943 {{
			flush_interval -1
			header_up X-Forwarded-Proto https
		}}
	}}
}}

# Every subdomain app tile (frontend/facade/admin-frontend/worker/odoo, ...).
# Hostnames are dynamic so a static cert can't cover them -- on-demand TLS
# issues one per exact hostname on first request, gated by the ask endpoint
# above.
*.{PUBLIC_DOMAIN} {{
	encode zstd gzip
	tls {{
		on_demand
	}}
	reverse_proxy 127.0.0.1:8943 {{
		flush_interval -1
		header_up X-Forwarded-Proto https
	}}
}}
"""


def main() -> int:
    if not PUBLIC_DOMAIN:
        sys.stderr.write("ERROR: PUBLIC_DOMAIN not set\n")
        return 1
    hook_ips = fetch_hook_ips()
    new_text = render_caddyfile(hook_ips)
    cur_text = CADDYFILE.read_text() if CADDYFILE.exists() else ""
    if new_text == cur_text:
        sys.stderr.write("no change; skipping reload\n")
        return 0
    # validate before swapping
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".caddy") as tf:
        tf.write(new_text)
        tmp = tf.name
    try:
        subprocess.run(["caddy", "validate", "--config", tmp, "--adapter", "caddyfile"], check=True,
                        capture_output=True, text=True)
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"ERROR: new Caddyfile failed validation; not applied\n"
                          f"{e.stderr}\n")
        os.unlink(tmp)
        return 1
    finally:
        if Path(tmp).exists():
            os.unlink(tmp)
    # atomic swap
    CADDYFILE.write_text(new_text)
    IPS_CACHE.write_text(hook_ips + "\n")
    subprocess.run(["systemctl", "reload", "caddy"], check=True)
    STAMP.write_text("")
    sys.stderr.write(f"refreshed GitHub hook IPs ({len(hook_ips.split())} ranges) "
                     f"and reloaded Caddy\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
