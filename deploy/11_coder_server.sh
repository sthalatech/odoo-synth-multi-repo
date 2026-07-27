#!/usr/bin/env bash
# 11: Coder server (control plane for developer environments).
#
# Replaces the hand-rolled EC2/Secrets-Manager/SG-ingress lifecycle that used to
# live in lib/backend/environments.py. The Coder server is the only NEW
# long-running AWS artifact this step creates: one t3.small EC2 instance in the
# default VPC running `coder server` + its bundled PostgreSQL. Workspace VMs (the
# actual per-issue dev environments) are launched later by Coder from the existing
# thin golden AMI (ENV_AMI_ID) + the existing env instance profile.
#
# Why one EC2 box and not ECS+ALB+RDS: Coder is a single Go binary with a bundled
# Postgres; running it on one instance reuses the default VPC + a single SG and
# adds zero managed services. Workspace agents reach it over the public internet
# on one port (8943); developers reach the dashboard at http://<ip>:8943.
#
# Writes CODER_URL / CODER_SERVER_IP / CODER_INSTANCE_ID / CODER_SG_ID to
# deploy/state.env. The control panel reads CODER_URL + a CODER_SESSION_TOKEN
# (set by `coder login` once, stored in config.yaml) to drive `coder create`/
# `coder delete`/the API.
#
# Idempotent: re-running reuses the instance + SG. Pass --rebuild to terminate
# and recreate (loses the server's DB). Pass --login to print the login URL.
#
# Usage:
#   deploy/11_coder_server.sh                # create if missing, else no-op
#   deploy/11_coder_server.sh --rebuild       # terminate + recreate
#   deploy/11_coder_server.sh --login        # print the admin login URL
source "$(dirname "$0")/lib.sh"

CODER_NAME="${CODER_NAME:-$PROJECT-coder}"
CODER_PORT="${CODER_PORT:-8943}"
CODER_INSTANCE_TYPE="${CODER_INSTANCE_TYPE:-t3.small}"
CODER_VOLUME_GB="${CODER_VOLUME_GB:-20}"
CODER_VERSION="${CODER_VERSION:-v2.34.6}"
# Browser-facing domain + scheme for the dashboard + every subdomain app tile
# (see deploy/14_caddy_https.sh for the reverse proxy that actually terminates
# TLS). Kept separate from CODER_SERVER_IP/CODER_URL -- which stay the
# server's own bare-IP-http origin, what Coder is told about itself -- so
# switching to a real Cloudflare-managed domain later is JUST changing
# PUBLIC_DOMAIN in deploy/state.env (or re-running this script with it set in
# the environment), no code change anywhere.
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"
PUBLIC_SCHEME="${PUBLIC_SCHEME:-https}"
REBUILD=0; DO_LOGIN=0; NO_SYNC=0
for a in "$@"; do
  case "$a" in
    --rebuild)  REBUILD=1 ;;
    --login)    DO_LOGIN=1 ;;
    --no-sync)  NO_SYNC=1 ;;  # skip pushing coder.env changes to an existing instance
    *) log "unknown arg: $a"; exit 2 ;;
  esac
done

VPC="$(vpc_id)"
SUBNET="$(subnet_ids | awk '{print $1}')"

# ---------------------------------------------------------------------------
# 1. SG: inbound 8943 (workspace agents + dashboard) from anywhere.
# ---------------------------------------------------------------------------
CODER_SG_NAME="$CODER_NAME-sg"
CODER_SG_ID="$(sg_id "$CODER_SG_NAME")"
if [ -z "$CODER_SG_ID" ] || [ "$CODER_SG_ID" = "None" ]; then
  CODER_SG_ID="$(aws ec2 create-security-group --group-name "$CODER_SG_NAME" \
    --description "odoo-synth Coder server (dashboard + workspace agent ingress)" \
    --vpc-id "$VPC" --region "$AWS_REGION" --query GroupId --output text)"
  log "created SG $CODER_SG_NAME = $CODER_SG_ID"
fi
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
  --group-id "$CODER_SG_ID" --protocol tcp --port "$CODER_PORT" --cidr 0.0.0.0/0 \
  >/dev/null 2>&1 || true
# 22 for ops/first-login (limited to the caller's IP, best-effort).
MYIP="$(curl -fsS https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$MYIP" ]; then
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
    --group-id "$CODER_SG_ID" --protocol tcp --port 22 --cidr "$MYIP/32" \
    >/dev/null 2>&1 || true
fi
put_state CODER_SG_ID "$CODER_SG_ID"

# ---------------------------------------------------------------------------
# 1b. IAM role + instance profile so the Coder server can run Terraform that
#     launches workspace VMs. Minimum perms: ec2 run/stop/start/terminate/
#     describe + create-tags, iam PassRole on the env instance profile. This is
#     the one new IAM artifact (reuses the existing env instance profile for the
#     workspace VMs themselves, created by deploy/09_dev_env.sh).
# ---------------------------------------------------------------------------
CODER_ROLE="$CODER_NAME-role"
CODER_PROFILE="$CODER_NAME-profile"
if ! aws iam get-role --role-name "$CODER_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$CODER_ROLE"     --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
fi
# Env-instance role ARN (for iam:PassRole). Created by deploy/09_dev_env.sh
# --infra-only (run earlier in the provisioning chain). The role + instance
# profile share the name "$PROJECT-env-instance". If 09 hasn't run yet, fall
# back to that standard name so this step doesn't hard-fail on an unbound var.
ENV_ROLE_NAME="${ENV_INSTANCE_PROFILE:-$PROJECT-env-instance}"
ENV_ROLE_ARN="$(aws iam get-role --role-name "$ENV_ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || true)"
# Option E: the Coder server also launches BUILDER workspaces, which assume
# the odoo-synth-builder role (distinct from the env role -- ECR push + S3 +
# Secrets + self-terminate). The server needs iam:PassRole on it too.
BUILDER_ROLE="${BUILDER_ROLE:-$PROJECT-builder}"
BUILDER_ROLE_ARN="$(aws iam get-role --role-name "$BUILDER_ROLE" \
  --query 'Role.Arn' --output text 2>/dev/null || true)"
POLICY_DOC="$(python3 - "$AWS_REGION" "$ACCOUNT_ID" "$ENV_ROLE_ARN" "$BUILDER_ROLE_ARN" <<'PYDOC'
import json, sys
region, acct, env_role_arn, builder_role_arn = sys.argv[1:5]
pass_roles = [r for r in (env_role_arn, builder_role_arn) if r] or ["arn:aws:iam::*:role/*"]
print(json.dumps({
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "Ec2WorkspaceLifecycle", "Effect": "Allow",
     "Action": ["ec2:RunInstances","ec2:TerminateInstances","ec2:StartInstances",
                "ec2:StopInstances","ec2:Describe*",
                "ec2:CreateTags","ec2:DeleteTags"],
     "Resource": "*"},
    # PassRole targets the ROLE the workspace VM assumes (not its instance profile).
    # Covers both the dev-env role (shared by odoo-synth-workspacer,
    # odoo-synth-discoverer, odoo-synth-masker) and the builder role, so the
    # Coder server can provision workspaces from all four templates.
    {"Sid": "PassWorkspaceRoles", "Effect": "Allow",
     "Action": ["iam:PassRole"],
     "Resource": pass_roles},
    {"Sid": "SsmAmiLookup", "Effect": "Allow",
     "Action": ["ssm:GetParameters"],
     "Resource": ["arn:aws:ssm:*:*:parameter/aws/service/canonical/*"]},
  ],
}))
PYDOC
)"
aws iam put-role-policy --role-name "$CODER_ROLE" \
  --policy-name "$CODER_NAME-policy" --policy-document "$POLICY_DOC" >/dev/null 2>&1 || true
if ! aws iam get-instance-profile --instance-profile-name "$CODER_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$CODER_PROFILE" >/dev/null
fi
aws iam add-role-to-instance-profile --instance-profile-name "$CODER_PROFILE"   --role-name "$CODER_ROLE" >/dev/null 2>&1 || true
put_state CODER_INSTANCE_PROFILE "$CODER_PROFILE"
log "Coder server IAM role: $CODER_ROLE (profile $CODER_PROFILE)"

# ---------------------------------------------------------------------------
# 2. instance: reuse if present (unless --rebuild). The instance reads its own
#    public IP from IMDS at boot and bakes CODER_ACCESS_URL, so no SSH needed.
# ---------------------------------------------------------------------------
get_coder_instance(){
  aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$CODER_NAME" \
             "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[0].[InstanceId,State.Name,PublicIpAddress]' \
    --output text 2>/dev/null | head -1
}
EXISTING="$(get_coder_instance)"
WAS_REUSED=0
if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  I_ID="$(awk '{print $1}' <<<"$EXISTING")"
  if [ "$REBUILD" = 1 ]; then
    log "--rebuild: terminating $I_ID"
    aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$I_ID" >/dev/null
    aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$I_ID" 2>/dev/null || true
    EXISTING=""
  else
    WAS_REUSED=1
  fi
fi

if [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then
  log "launching Coder server ($CODER_INSTANCE_TYPE) ..."
  UD="$(mktemp)"; trap 'rm -f "$UD"' EXIT
  cat > "$UD" <<'UD_EOF'
#!/usr/bin/env bash
set -euo pipefail
export HOME=/root
# Port the Coder server listens on (SG already opens it). Defined here because
# the host-side CODER_PORT isn't available inside cloud-init.
CODER_PORT=8943
if ! command -v coder >/dev/null 2>&1; then
  cd /tmp
  curl -fsSL -o coder.tar.gz "https://github.com/coder/coder/releases/download/v2.34.6/coder_2.34.6_linux_amd64.tar.gz"
  tar xzf coder.tar.gz && install -m 0755 coder /usr/local/bin/coder && rm -f coder coder.tar.gz
fi
# Fetch our own public IP from IMDSv2 and bake CODER_ACCESS_URL so workspace
# agents phone home to the right address (needed before `coder server` starts).
TOK="$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')"
MYIP="$(curl -s -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/public-ipv4)"
install -d -m 700 /etc/coder
# Coder's built-in PostgreSQL refuses to run as root, so create a dedicated
# user and run the systemd unit as it.
if ! id coder >/dev/null 2>&1; then useradd -m -s /bin/bash coder; fi
install -d -m 700 -o coder -g coder /home/coder/.config/coderv2
install -d -m 700 -o coder -g coder /etc/coder
# Subdomain app hosting: each coder_app gets its own origin
# (<app>--<ws>--<owner>.<wildcard>). REQUIRED for Odoo, whose login form/assets
# use absolute server-root paths (/web/login, /web/session/authenticate,
# /web/static/...) that would otherwise resolve against the Coder dashboard
# origin and 404. The Coder flag is --wildcard-access-url /
# CODER_WILDCARD_ACCESS_URL (NOT CODER_APP_HOSTNAME, which is ignored).
#
# PUBLIC_SCHEME/PUBLIC_DOMAIN_OVERRIDE below are the only two lines this
# LOCAL script substitutes into an otherwise fully self-contained remote
# script (see the sed call right after this heredoc is written) -- everything
# else here runs purely with values this remote instance resolves itself.
# https: PUBLIC_DOMAIN_OVERRIDE must already be known (a real domain decided
# ahead of time; a bare-IP nip.io domain can't be known before this instance
# has an IP). http (no Caddy yet): falls back to the historical bare-IP
# origin, nip.io wildcard DNS with no real domain needed.
PUBLIC_SCHEME="__PUBLIC_SCHEME__"
PUBLIC_DOMAIN_OVERRIDE="__PUBLIC_DOMAIN_OR_EMPTY__"
if [ "$PUBLIC_SCHEME" = "https" ] && [ -n "$PUBLIC_DOMAIN_OVERRIDE" ]; then
  ACCESS_URL="https://coder.${PUBLIC_DOMAIN_OVERRIDE}"
  WILDCARD_URL="*.${PUBLIC_DOMAIN_OVERRIDE}"
else
  ACCESS_URL="http://${MYIP}:8943"
  WILDCARD_URL="*.${MYIP}.nip.io:8943"
fi
cat > /etc/coder/coder.env <<EENV
CODER_ACCESS_URL=${ACCESS_URL}
CODER_HTTP_ADDRESS=0.0.0.0:8943
# NOTE: for the plain-http fallback (no PUBLIC_SCHEME=https / no Caddy yet),
# the wildcard host MUST include the port (:8943); without it, Coder builds
# app subdomain URLs on the default port 80, which the SG blocks (only
# 8943 + 22 are open) -> the auth-redirect Location header sends browsers to
# port 80 and they time out. Once Caddy fronts 443/80 (PUBLIC_SCHEME=https),
# no port is needed -- see deploy/14_caddy_https.sh.
CODER_WILDCARD_ACCESS_URL=${WILDCARD_URL}
CODER_LOG_FILTER=debug
EENV
cat > /etc/systemd/system/coder-server.service <<'UNIT'
[Unit]
Description=Coder server (odoo-synth dev-env control plane)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=coder
Group=coder
Environment=HOME=/home/coder
EnvironmentFile=/etc/coder/coder.env
ExecStart=/usr/local/bin/coder server
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now coder-server
echo "coder-server started; access_url=${MYIP}:8943"
UD_EOF
  # Inject the two LOCAL-known values the remote script above needs (its own
  # heredoc stayed single-quoted, so nothing else leaked in by accident).
  sed -i "s/__PUBLIC_SCHEME__/${PUBLIC_SCHEME}/; s/__PUBLIC_DOMAIN_OR_EMPTY__/${PUBLIC_DOMAIN}/" "$UD"
  # AMI id (Ubuntu 24.04 LTS via SSM public parameter).
  CODER_AMI="$(aws ssm get-parameters --region "$AWS_REGION" \
    --names /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
    --query 'Parameters[0].Value' --output text)"
  # RunInstances can fail with "Invalid IAM Instance Profile name" for ~10-30s
  # after create-instance-profile -- IAM -> EC2 control-plane propagation lag.
  # Retry a few times with a short sleep on that specific error.
  I_ID=""
  for _try in 1 2 3 4 5; do
    # `|| true` keeps set -e from aborting on a failed run-instances WITHOUT
    # wiping the captured stderr (which carries the error text we surface below).
    I_ID="$(aws ec2 run-instances --region "$AWS_REGION" \
      --image-id "$CODER_AMI" \
      --instance-type "$CODER_INSTANCE_TYPE" \
      --subnet-id "$SUBNET" --associate-public-ip-address \
      --security-group-ids "$CODER_SG_ID" \
      --iam-instance-profile "Name=$CODER_PROFILE" \
      --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$CODER_VOLUME_GB,VolumeType=gp3}" \
      --user-data "file://$UD" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$CODER_NAME},{Key=odoo-synth:managed,Value=true},{Key=odoo-synth:control-plane,Value=true}]" \
      --query 'Instances[0].InstanceId' --output text 2>&1)" || true
    case "$I_ID" in
      i-*) break ;;                       # got an instance id -> success
      *InvalidParameterValue*|*Invalid*IAM*Instance*Profile*) sleep 10 ;;
      *) break ;;                          # a real error -- stop, surface below
    esac
  done
  if ! printf '%s' "$I_ID" | grep -qi '^i-'; then
    log "ERROR: RunInstances failed: $I_ID"
    exit 1
  fi
  log "instance $I_ID launching; waiting for running + public IP ..."
  aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$I_ID" 2>/dev/null || true
fi

# fetch the public IP (may take a few seconds after running)
CODER_IP=""
for i in $(seq 1 30); do
  CODER_IP="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$I_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || true)"
  [ -n "$CODER_IP" ] && [ "$CODER_IP" != "None" ] && break
  sleep 3
done
[ -n "$CODER_IP" ] && [ "$CODER_IP" != "None" ] || { log "could not get Coder server public IP"; exit 1; }

CODER_URL="http://$CODER_IP:$CODER_PORT"
put_state CODER_SERVER_IP "$CODER_IP"
put_state CODER_INSTANCE_ID "$I_ID"
put_state CODER_URL "$CODER_URL"
log "Coder server: id=$I_ID  url=$CODER_URL"

# PUBLIC_DOMAIN default: bare-IP nip.io, same convention the fresh-launch
# path falls back to. An operator who later points this at a real
# Cloudflare-managed domain sets PUBLIC_DOMAIN in deploy/state.env once, and
# every subsequent run (this script + 14_caddy_https.sh) just picks it up.
[ -n "$PUBLIC_DOMAIN" ] || PUBLIC_DOMAIN="${CODER_IP}.nip.io"
put_state PUBLIC_DOMAIN "$PUBLIC_DOMAIN"
put_state PUBLIC_SCHEME "$PUBLIC_SCHEME"

# Sync coder.env on an EXISTING instance: cloud-init/user-data only ever runs
# once, at first boot, so a config change here (PUBLIC_DOMAIN/PUBLIC_SCHEME,
# or picking up drift like an EIP swap) needs to be pushed by hand to a
# server that already exists. Skipped for a instance just freshly launched
# above (its user-data already wrote the right file) and for --no-sync.
if [ "$WAS_REUSED" = 1 ] && [ "$NO_SYNC" != 1 ]; then
  log "syncing coder.env on existing instance $I_ID ($CODER_IP) ..."
  AZ="$(instance_az "$I_ID")"
  if [ "$PUBLIC_SCHEME" = "https" ]; then
    WANT_ACCESS_URL="https://coder.${PUBLIC_DOMAIN}"
    # NO scheme here -- CODER_WILDCARD_ACCESS_URL is a bare hostname pattern;
    # Coder rejects one with "hostname pattern must not contain a scheme" and
    # crash-loops. Scheme comes from CODER_ACCESS_URL alone.
    WANT_WILDCARD_URL="*.${PUBLIC_DOMAIN}"
  else
    WANT_ACCESS_URL="http://${CODER_IP}:${CODER_PORT}"
    WANT_WILDCARD_URL="*.${PUBLIC_DOMAIN}:${CODER_PORT}"
  fi
  CUR="$(eic_ssh "$I_ID" "$AZ" "$CODER_IP" -- "sudo cat /etc/coder/coder.env 2>/dev/null" || true)"
  if grep -qF "CODER_ACCESS_URL=$WANT_ACCESS_URL" <<<"$CUR" \
     && grep -qF "CODER_WILDCARD_ACCESS_URL=$WANT_WILDCARD_URL" <<<"$CUR"; then
    log "coder.env already up to date, no restart needed"
  else
    log "coder.env changed (access_url=$WANT_ACCESS_URL wildcard=$WANT_WILDCARD_URL) -- pushing + restarting coder-server"
    eic_ssh "$I_ID" "$AZ" "$CODER_IP" -- "bash -s" -- "$WANT_ACCESS_URL" "$WANT_WILDCARD_URL" <<'REMOTE'
set -euo pipefail
ACCESS_URL="$1"; WILDCARD_URL="$2"
sudo tee /etc/coder/coder.env >/dev/null <<EENV
CODER_ACCESS_URL=${ACCESS_URL}
CODER_HTTP_ADDRESS=0.0.0.0:8943
CODER_WILDCARD_ACCESS_URL=${WILDCARD_URL}
CODER_LOG_FILTER=debug
EENV
sudo systemctl restart coder-server
echo "coder-server restarted with access_url=${ACCESS_URL}"
REMOTE
  fi
fi

# wait for the HTTP endpoint to answer (user-data + service start ~1-2 min)
log "waiting for Coder dashboard at $CODER_URL ..."
for i in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$CODER_URL" 2>/dev/null || echo 000)"
  case "$code" in 200|301|302|303) log "Coder is up (http $code)"; break ;; esac
  sleep 5
done

if [ "$DO_LOGIN" = 1 ]; then
  echo "  open the dashboard and create the first admin: $CODER_URL"
  echo "  then on a host with the coder CLI:"
  echo "    coder login $CODER_URL"
  echo "    coder tokens create   # paste the token into config.yaml (coder.session_token)"
fi
log "done. Developer-environment control plane is ready at $CODER_URL"
