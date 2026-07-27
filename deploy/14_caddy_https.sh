#!/usr/bin/env bash
# 14: Caddy HTTPS reverse proxy in front of the existing Coder HTTP server --
# covers BOTH the dashboard/API/webhook path AND every subdomain app tile
# (frontend/facade/admin-frontend/worker/odoo, etc.).
#
# Two Caddy site blocks, both reverse-proxying to the already-running Coder
# server at 127.0.0.1:8943 (never touched directly -- no restart, no config
# change to coder-server.service from THIS script; see deploy/11_coder_server.sh
# for the separate step that points Coder's own CODER_ACCESS_URL/
# CODER_WILDCARD_ACCESS_URL at these same HTTPS hostnames):
#
#   1. coder.$PUBLIC_DOMAIN       -- dashboard + API + webhook. A fixed
#      hostname, so Caddy's normal automatic HTTPS (one Let's Encrypt cert,
#      issued once) is enough.
#   2. *.$PUBLIC_DOMAIN            -- every "<slug>--<workspace>--<owner>"
#      app tile. These can't be enumerated ahead of time (a new one appears
#      every time a workspace is created), so this uses Caddy's on-demand TLS
#      (issues a real Let's Encrypt cert for each exact hostname the first
#      time it's requested) gated by an "ask" endpoint
#      (deploy/refresh/tls_ask.py) that only allows hostnames matching our
#      own naming pattern -- otherwise Caddy would attempt a certificate for
#      ANY hostname a scanner points at this box, burning Let's Encrypt's
#      per-domain rate limit.
#
# Domain: PUBLIC_DOMAIN (deploy/state.env, set by deploy/11_coder_server.sh --
# defaults to "<coder-ip>.nip.io", nip.io wildcard DNS needing no purchased
# domain). Moving to a real Cloudflare-managed domain later is just setting
# PUBLIC_DOMAIN to that domain (with its own wildcard DNS record pointed at
# this box) and re-running this script -- nothing else in here is IP/nip.io
# specific.
#
# Prereqs: deploy/11_coder_server.sh (CODER_SERVER_IP/CODER_SG_ID/
# CODER_INSTANCE_ID/PUBLIC_DOMAIN in deploy/state.env). SSH access is via EC2
# Instance Connect (deploy/lib.sh eic_ssh) -- no persisted keypair needed.
#
# Usage:
#   deploy/14_caddy_https.sh                # install + enable
#   deploy/14_caddy_https.sh --status       # show caddy + cert status
source "$(dirname "$0")/lib.sh"

PORT=8080
ASK_PORT=8081
DOSTATUS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --status) DOSTATUS=1; shift ;;
    *) log "unknown arg: $1"; exit 2 ;;
  esac
done

: "${CODER_SERVER_IP:?CODER_SERVER_IP not in deploy/state.env -- run deploy/11_coder_server.sh first}"
: "${CODER_SG_ID:?CODER_SG_ID not in deploy/state.env -- run deploy/11_coder_server.sh first}"
: "${CODER_INSTANCE_ID:?CODER_INSTANCE_ID not in deploy/state.env -- run deploy/11_coder_server.sh first}"
: "${PUBLIC_DOMAIN:?PUBLIC_DOMAIN not in deploy/state.env -- run deploy/11_coder_server.sh first}"

# 1. open SG 80/443 for Let's Encrypt HTTP-01 + HTTPS
log "opening inbound tcp/80 + tcp/443 on Coder SG $CODER_SG_ID ..."
for p in 80 443; do
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
    --group-id "$CODER_SG_ID" --protocol tcp --port "$p" --cidr 0.0.0.0/0 \
    >/dev/null 2>&1 || true
done

HOSTNAME="coder.${PUBLIC_DOMAIN}"
AZ="$(instance_az "$CODER_INSTANCE_ID")"

# GitHub hook IP ranges (from api.github.com/meta) -- only these may POST
# /webhook. Everyone else gets 403 on that path; the rest of the site is open.
# Fetched locally so the heredoc below can expand ${GITHUB_HOOK_IPS}.
GITHUB_HOOK_IPS="$(curl -fsS --max-time 15 https://api.github.com/meta 2>/dev/null \
  | python3 -c "import sys,json; print(' '.join(json.load(sys.stdin).get('hooks',[])))" 2>/dev/null \
  || true)"
if [ -z "$GITHUB_HOOK_IPS" ]; then
  GITHUB_HOOK_IPS="192.30.252.0/22 185.199.108.0/22 140.82.112.0/20 143.55.64.0/20"
fi
log "GitHub hook IP ranges: $GITHUB_HOOK_IPS"

log "installing Caddy on $CODER_SERVER_IP and writing Caddyfile (domain=$PUBLIC_DOMAIN) ..."
eic_ssh "$CODER_INSTANCE_ID" "$AZ" "$CODER_SERVER_IP" -- "bash -s" -- \
  "$HOSTNAME" "$PUBLIC_DOMAIN" "$PORT" "$ASK_PORT" "$GITHUB_HOOK_IPS" <<'REMOTE'
set -euo pipefail
HOSTNAME="$1"; PUBLIC_DOMAIN="$2"; PORT="$3"; ASK_PORT="$4"; GITHUB_HOOK_IPS="$5"
export DEBIAN_FRONTEND=noninteractive
sudo install -d -m 0755 /usr/share/keyrings
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key 2>/dev/null \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
sudo apt-get update -qq 2>/dev/null
sudo apt-get install -y -qq caddy >/dev/null 2>&1 || sudo apt-get install -y -qq caddy

sudo tee /etc/caddy/Caddyfile >/dev/null <<CADDY
{
	on_demand_tls {
		ask http://127.0.0.1:${ASK_PORT}
	}
}

${HOSTNAME} {
	encode zstd gzip

	# GitHub webhook -> odoo-synth listener (localhost only, if/when deployed
	# by deploy/13_webhook_listener.sh). Restricted to GitHub's hook IP
	# ranges; everyone else gets 403. The listener additionally verifies the
	# HMAC signature + dedupes by X-GitHub-Delivery.
	@github_webhook {
		path /webhook
		remote_ip ${GITHUB_HOOK_IPS}
	}
	handle @github_webhook {
		reverse_proxy 127.0.0.1:${PORT} {
			flush_interval -1
			header_up X-Forwarded-Proto https
		}
	}
	# /webhook from a non-GitHub IP -> 403 (must come before the catch-all)
	@webhook_path path /webhook
	handle @webhook_path {
		respond 403
	}
	# everything else -> the Coder HTTP server (dashboard + API). Host is
	# passed through unchanged -- it already equals ${HOSTNAME}, which is
	# exactly what Coder's own CODER_ACCESS_URL is configured as (see
	# deploy/11_coder_server.sh), so no rewrite is needed.
	handle {
		reverse_proxy 127.0.0.1:8943 {
			flush_interval -1
			header_up X-Forwarded-Proto https
		}
	}
}

# Every subdomain app tile (frontend/facade/admin-frontend/worker/odoo, ...).
# Hostnames are dynamic ("<slug>--<workspace>--<owner>.${PUBLIC_DOMAIN}", a
# new one per workspace) so a normal static cert can't cover them -- on-demand
# TLS issues one per exact hostname on first request, gated by the ask
# endpoint above so only our own naming pattern can trigger an issuance.
*.${PUBLIC_DOMAIN} {
	encode zstd gzip
	tls {
		on_demand
	}
	reverse_proxy 127.0.0.1:8943 {
		flush_interval -1
		header_up X-Forwarded-Proto https
	}
}
CADDY
sudo caddy validate --config /etc/caddy/Caddyfile 2>&1 | grep -qi "valid" && echo "caddy config valid"

# tls_ask.py: the on_demand_tls "ask" endpoint. Stdlib-only, no deps beyond
# python3 (already present on the AMI).
sudo install -d -m 755 /opt/odoo-synth-tls-ask
sudo tee /etc/default/odoo-synth-tls-ask >/dev/null <<EENV
PUBLIC_DOMAIN=${PUBLIC_DOMAIN}
ASK_PORT=${ASK_PORT}
EENV
sudo tee /etc/systemd/system/odoo-synth-tls-ask.service >/dev/null <<UNIT
[Unit]
Description=Caddy on_demand_tls ask endpoint (odoo-synth)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
EnvironmentFile=/etc/default/odoo-synth-tls-ask
ExecStart=/usr/bin/python3 /opt/odoo-synth-tls-ask/tls_ask.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
# NOT enable --now here -- tls_ask.py itself isn't on disk yet (shipped by a
# separate scp right after this heredoc, since it needs a local file, not
# heredoc content); starting now would crash-loop on a missing file. `enable`
# only (boot persistence); the scp step below does the first actual start.
sudo systemctl enable odoo-synth-tls-ask >/dev/null 2>&1

sudo systemctl enable --now caddy >/dev/null 2>&1
sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
echo "caddy active: $(sudo systemctl is-active caddy)"
REMOTE

# ship tls_ask.py itself (kept as a real file on disk here, not baked into
# the heredoc above, so it's one `scp` away from being edited/redeployed).
# This is also the first actual start of the service (see the `enable` note
# above -- restart starts it fine even if it was never running).
scp -i "$EIC_KEY" -o StrictHostKeyChecking=accept-new \
  "$HERE/deploy/refresh/tls_ask.py" "ubuntu@$CODER_SERVER_IP:/tmp/tls_ask.py"
eic_ssh "$CODER_INSTANCE_ID" "$AZ" "$CODER_SERVER_IP" -- \
  "sudo install -m 0755 /tmp/tls_ask.py /opt/odoo-synth-tls-ask/tls_ask.py && sudo systemctl restart odoo-synth-tls-ask && echo tls-ask active: \$(systemctl is-active odoo-synth-tls-ask)"

log "HTTPS is live at https://$HOSTNAME/ (dashboard) and https://<slug>--<ws>--<owner>.$PUBLIC_DOMAIN/ (app tiles)."
log "Point config.yaml / webhooks at: https://$HOSTNAME"
log "NOTE: run deploy/11_coder_server.sh next (if not already) to point Coder's"
log "own CODER_ACCESS_URL/CODER_WILDCARD_ACCESS_URL at these HTTPS hostnames --"
log "without that, Coder still generates http:// links even though Caddy can"
log "serve https:// for them."

# ---------------------------------------------------------------------------
# 2. install the GitHub-IP auto-refresh renderer + a systemd timer (every 6h +
#    2min after boot). The renderer fetches api.github.com/meta, re-renders the
#    Caddyfile, and reloads Caddy ONLY when the ranges changed (idempotent). On
#    a fetch failure it keeps the existing allowlist (fail-closed/stale > broken).
#    The renderer becomes the source of truth for the Caddyfile, so the inline
#    one above is just the bootstrap. NOTE: today's renderer only re-renders
#    the renderer's own Caddyfile template mirrors the bootstrap one above
#    (both blocks, on_demand_tls + ask) -- keep them in sync if either changes.
# ---------------------------------------------------------------------------
log "installing GitHub-IP auto-refresh (refresh-github-ips.timer, every 6h) ..."
scp -i "$EIC_KEY" -o StrictHostKeyChecking=accept-new \
  "$HERE/deploy/refresh/refresh_github_ips.py" "ubuntu@$CODER_SERVER_IP:/tmp/refresh_github_ips.py"
eic_ssh "$CODER_INSTANCE_ID" "$AZ" "$CODER_SERVER_IP" -- "bash -s" -- \
  "$HOSTNAME" "$PUBLIC_DOMAIN" "$PORT" "$ASK_PORT" <<'REMOTE'
set -euo pipefail
HOSTNAME="$1"; PUBLIC_DOMAIN="$2"; PORT="$3"; ASK_PORT="$4"
sudo install -m 0755 /tmp/refresh_github_ips.py /usr/local/sbin/refresh_github_ips.py
sudo tee /etc/caddy/refresh.env >/dev/null <<EOF
CADDY_HOSTNAME=$HOSTNAME
PUBLIC_DOMAIN=$PUBLIC_DOMAIN
WEBHOOK_PORT=$PORT
ASK_PORT=$ASK_PORT
EOF
sudo tee /etc/systemd/system/refresh-github-ips.service >/dev/null <<UNIT
[Unit]
Description=Refresh GitHub hook IP ranges in the Caddy Caddyfile
After=network-online.target caddy.service
Wants=network-online.target
[Service]
Type=oneshot
EnvironmentFile=/etc/caddy/refresh.env
ExecStart=/usr/local/sbin/refresh_github_ips.py
UNIT
sudo tee /etc/systemd/system/refresh-github-ips.timer >/dev/null <<TIMER
[Unit]
Description=Refresh GitHub hook IP ranges every 6h
[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
Persistent=true
[Install]
WantedBy=timers.target
TIMER
sudo systemctl daemon-reload
sudo systemctl enable --now refresh-github-ips.timer >/dev/null 2>&1
sudo systemctl start refresh-github-ips.service || true
echo "refresh timer: $(systemctl is-active refresh-github-ips.timer)"
REMOTE

if [ "$DOSTATUS" = 1 ]; then
  eic_ssh "$CODER_INSTANCE_ID" "$AZ" "$CODER_SERVER_IP" -- \
    "systemctl --no-pager status caddy odoo-synth-tls-ask 2>&1; echo ---; sudo caddy version"
fi
log "done."
