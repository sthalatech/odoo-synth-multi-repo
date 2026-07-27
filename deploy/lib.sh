#!/usr/bin/env bash
# Shared helpers for deploy scripts. `source` this.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Config: config.yaml is the single source of truth (see config.example.yaml).
# deploy/_yaml_to_env.py loads it and exports the KEY=VALUE env vars the
# pipeline scripts expect (with `ref:` secret resolution for env/SSM). The
# python3 dependency is installed by deploy/00_install_prereqs.sh.
_load_config() {
  if [ ! -f "$HERE/config.yaml" ]; then
    echo "== ERROR: $HERE/config.yaml not found ==" >&2
    echo "       copy config.example.yaml to config.yaml and fill it in, then" >&2
    echo "       run bash deploy/00_validate_config.sh." >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "== ERROR: python3 not found on PATH (needed to load config.yaml) ==" >&2
    echo "       run bash deploy/00_install_prereqs.sh first." >&2
    return 1
  fi
  eval "$(python3 "$HERE/deploy/_yaml_to_env.py" "$HERE/config.yaml")"
  return $?
}
_load_config

# ACCOUNT_ID requires live AWS auth. Resolve it best-effort so that sourcing
# lib.sh does not abort (under `set -e`) before a caller can report a friendly
# "not authenticated" error -- e.g. 00_validate_config.sh sources this to read
# config values but must not die on missing creds. Scripts that actually need
# ACCOUNT_ID (09_dev_env/10_builder/11_coder_server) re-check it explicitly.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
ECR="${ACCOUNT_ID:+${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com}"
export HERE ACCOUNT_ID ECR
export AWS_PAGER=""

log(){ echo "== $* ==" >&2; }

STATE="$HERE/deploy/state.env"
touch "$STATE"
set -a; source "$STATE"; set +a
put_state(){ # key value
  # ensure the file ends with a newline so appends never glue onto the last line
  [ -s "$STATE" ] && [ -n "$(tail -c1 "$STATE")" ] && echo >> "$STATE"
  grep -v "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null || true
  echo "$1=$2" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"
  export "$1=$2"
}

# Ephemeral SSH via EC2 Instance Connect -- works even with no persisted
# keypair on the target instance (the Coder server launches with KeyName
# unset). Re-pushes the key right before each call since EIC keys are only
# valid ~60s for the initial handshake; the key itself is reused across calls
# within one script run. Requires ec2-instance-connect:SendSSHPublicKey.
EIC_KEY="$HERE/deploy/.eic_key"
eic_ssh(){ # instance-id az ip -- remote-cmd...
  local iid="$1" az="$2" ip="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  [ -f "$EIC_KEY" ] || ssh-keygen -t ed25519 -f "$EIC_KEY" -N "" -q -C odoo-synth-eic >&2
  aws ec2-instance-connect send-ssh-public-key --region "$AWS_REGION" \
    --instance-id "$iid" --availability-zone "$az" --instance-os-user ubuntu \
    --ssh-public-key "file://${EIC_KEY}.pub" >/dev/null
  ssh -i "$EIC_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
    "ubuntu@$ip" "$@"
}
instance_az(){ aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text; }

# Ensures instance $1 has an Elastic IP associated -- a plain
# --associate-public-ip-address instance gets a DYNAMIC public IP that
# changes on stop/start (this exact drift broke the HTTPS/nip.io setup once
# already: an unpinned IP invalidates every cert + bookmarked URL tied to it).
# Reuses a previously-allocated-but-now-unassociated EIP tagged $2 first
# (e.g. left over from a --rebuild, so the address -- and every cert/DNS
# record pinned to it -- survives instance replacement too), before
# allocating a brand new one. Echoes the resulting public IP on stdout.
ensure_eip(){ # instance-id  name-tag
  local iid="$1" name="$2" ip alloc
  ip="$(aws ec2 describe-addresses --region "$AWS_REGION" \
    --filters "Name=instance-id,Values=$iid" \
    --query 'Addresses[0].PublicIp' --output text 2>/dev/null)"
  if [ -n "$ip" ] && [ "$ip" != "None" ]; then
    echo "$ip"
    return
  fi
  alloc="$(aws ec2 describe-addresses --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$name" \
    --query 'Addresses[].[AllocationId,AssociationId]' --output text 2>/dev/null \
    | awk '$2=="None" || $2=="" {print $1; exit}')"
  if [ -z "$alloc" ]; then
    log "allocating a new Elastic IP ($name) ..."
    alloc="$(aws ec2 allocate-address --region "$AWS_REGION" --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$name},{Key=odoo-synth:managed,Value=true}]" \
      --query AllocationId --output text)"
  else
    log "reusing previously-allocated Elastic IP ($name, $alloc) ..."
  fi
  aws ec2 associate-address --region "$AWS_REGION" \
    --instance-id "$iid" --allocation-id "$alloc" >/dev/null
  aws ec2 describe-addresses --region "$AWS_REGION" --allocation-ids "$alloc" \
    --query 'Addresses[0].PublicIp' --output text
}

vpc_id(){ aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION"; }

subnet_ids(){ aws ec2 describe-subnets --filters Name=vpc-id,Values=$(vpc_id) \
    Name=default-for-az,Values=true --query 'Subnets[].SubnetId' \
    --output text --region "$AWS_REGION"; }

sg_id(){ aws ec2 describe-security-groups \
    --filters Name=group-name,Values="$1" Name=vpc-id,Values=$(vpc_id) \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null; }

