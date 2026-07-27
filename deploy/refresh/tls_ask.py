#!/usr/bin/env python3
"""Caddy on_demand_tls "ask" endpoint (see deploy/14_caddy_https.sh).

Caddy calls GET /?domain=<requested-hostname> before requesting a Let's
Encrypt certificate for any hostname not already in its static Caddyfile
config. The wildcard app-tile site (*.PUBLIC_DOMAIN) can't list its hostnames
ahead of time -- a new one appears every time a workspace is created -- so
Caddy has to ask at request time. Without this gate, Caddy would attempt (and
burn Let's Encrypt's per-domain rate limit on) a certificate for ANY hostname
a scanner points at this box. This only allows the dashboard host and the
"<slug>--<workspace>--<owner>" app-tile pattern odoo-synth-workspacer
actually uses, both under PUBLIC_DOMAIN.

Stdlib only (no Flask/deps) -- this is a single tiny always-on check, run as
its own systemd service on the Coder server, independent of whether the
(separate, optional) GitHub webhook listener is deployed.

Usage: PUBLIC_DOMAIN=<domain> ASK_PORT=<port> python3 tls_ask.py
"""
from __future__ import annotations
import os
import re
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs

PUBLIC_DOMAIN = os.environ.get("PUBLIC_DOMAIN", "")
PORT = int(os.environ.get("ASK_PORT", "8081"))
_escaped = re.escape(PUBLIC_DOMAIN)
PATTERN = re.compile(rf"^(coder\.{_escaped}|[a-z0-9-]+--[a-z0-9-]+--[a-z0-9-]+\.{_escaped})$")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # noqa: A003 - quiet by default
        pass

    def do_GET(self):  # noqa: N802 - stdlib method name
        qs = parse_qs(urlsplit(self.path).query)
        domain = (qs.get("domain", [""])[0] or "").lower()
        ok = bool(PUBLIC_DOMAIN) and bool(domain) and bool(PATTERN.match(domain))
        self.send_response(200 if ok else 403)
        self.end_headers()
        self.wfile.write(b"ok\n" if ok else b"denied\n")


if __name__ == "__main__":
    if not PUBLIC_DOMAIN:
        raise SystemExit("PUBLIC_DOMAIN env var is required")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
