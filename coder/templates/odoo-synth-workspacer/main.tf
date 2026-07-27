# Coder template: an odoo-synth developer environment.
#
# One EC2 instance (existing thin golden AMI + existing env instance profile) in
# a default-VPC subnet, NO public IP — the Coder agent dials OUT to the Coder
# server over the public internet; the developer reaches the workspace via
# Coder's Wireguard tunnel (web terminal / VS Code Web / port-forward / ssh),
# so the workspace needs zero inbound ports and no per-env SG rules. This is
# what deletes ~5 AWS artifacts per environment vs. the old hand-rolled design.
#
# The agent's startup_script is the existing Odoo boot logic (dump restore + ECR
# pull + addons bind-mount + admin reset) verbatim from user-data.sh.tmpl, with
# startup_script_behavior="blocking" so the workspace is not "ready" until Odoo
# answers HTTP. No nginx TLS sidecar (Coder proxies the web UI), no per-env
# Secrets Manager secret (the password is generated + stored as a Coder env var
# the agent reads), no EC2-tag readiness polling (Coder tracks agent lifecycle).

terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.2"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "coder_parameter" "instance_type" {
  name         = "instance_type"
  display_name = "EC2 instance type for the workspace."
  type         = "string"
  default      = "t3.large"
  order        = 0
}

# Infra defaults: the panel used to pass these per-create, which made a bare
# `coder create -t odoo-synth-workspacer <name>` fail (aws_instance needs a non-empty
# ImageId/instance-profile/subnet/SG). They are now first-class defaults derived
# from the shared infra (deploy/state.env: ENV_AMI_ID/ENV_INSTANCE_PROFILE/
# ENV_SUBNET_ID/ENV_SG_ID). They can still be overridden per-workspace.
#
# AMI: resolved dynamically from the latest Ubuntu 22.04 AMI in the current
# region (see the aws_ami data source below). The deploy script
# (deploy/12_publish_template.sh) overrides this with the golden AMI ID from
# ENV_AMI_ID when available. Users can also override per-workspace.
data "coder_parameter" "ami_id" {
  name         = "ami_id"
  display_name = "Thin golden AMI (ubuntu + docker + awscli). Empty = auto-resolve latest Ubuntu 22.04."
  type         = "string"
  default      = ""
  order        = 1
}

# Dynamically resolve the latest Ubuntu 22.04 AMI for the current region.
# Used as a fallback when no explicit ami_id is provided (parameter or
# deploy-time override). This keeps the template portable across AWS accounts
# and regions without hardcoding account-specific AMI IDs.
data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "coder_parameter" "instance_profile" {
  name         = "instance_profile"
  display_name = "IAM instance profile (S3 dump read + ECR pull). Empty = resolve by name."
  type         = "string"
  default      = ""
  order        = 2
}

data "coder_parameter" "subnet_id" {
  name         = "subnet_id"
  display_name = "Default-VPC subnet to launch in. Empty = first default-VPC subnet."
  type         = "string"
  default      = ""
  order        = 3
}

data "coder_parameter" "security_group_id" {
  name         = "security_group_id"
  display_name = "Env SG (egress only is sufficient; Coder tunnel carries access). Empty = resolve by name."
  type         = "string"
  default      = ""
  order        = 4
}

data "coder_parameter" "region" {
  name         = "region"
  display_name = "AWS region."
  type         = "string"
  default      = "us-east-1"
  order        = 5
}

data "coder_parameter" "odoo_image" {
  name         = "odoo_image"
  display_name = "Provenance-baked Odoo ECR image to run against the masked DB."
  type         = "string"
  default      = ""
  order        = 6
}

data "coder_parameter" "dump_s3_uri" {
  name         = "dump_s3_uri"
  display_name = "s3://bucket/key of the masked pg_dump seeding the env's DB."
  type         = "string"
  default      = ""
  order        = 7
}

data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Addons repo cloned + live-mounted into Odoo."
  type         = "string"
  # No default: the user must supply their own addons repo URL at workspace
  # creation time (or use a preset that pre-fills it). Preset-provided values
  # are locked by Coder; a parameter default is not, so presets use the
  # parameter mechanism instead of a hardcoded default here.
  default = ""
  order   = 8
}

data "coder_parameter" "repo_branch" {
  name         = "repo_branch"
  display_name = "Branch/tag/commit of the addons repo."
  type         = "string"
  # No default: the user must supply their own branch/commit (or use a preset).
  default      = ""
  order        = 9
}

data "coder_parameter" "git_token_env" {
  name         = "git_token_env"
  display_name = "Env var name holding the GitHub token (Coder user secret, profile-specific)"
  type         = "string"
  default      = ""
  order        = 10
}

data "coder_parameter" "issue" {
  name         = "issue"
  display_name = "GitHub issue ref (provenance only)."
  type         = "string"
  default      = ""
  order        = 11
}

data "coder_parameter" "db_name" {
  name         = "db_name"
  display_name = "Local Postgres DB name seeded from the dump."
  type         = "string"
  default      = "odoo"
  order        = 12
}

data "coder_parameter" "odoo_master_password" {
  name         = "odoo_master_password"
  display_name = "Odoo database master password."
  type         = "string"
  default      = "change_me_master"
  order        = 13
}

data "coder_parameter" "odoo_conf_extra_b64" {
  name         = "odoo_conf_extra_b64"
  display_name = "Base64 of extra odoo.conf lines appended by the profile."
  type         = "string"
  default      = ""
  order        = 14
}

data "coder_parameter" "admin_password" {
  name         = "admin_password"
  display_name = "Per-workspace Odoo admin password. Generated by the control panel."
  type         = "string"
  default      = "change-me"
  order        = 15
}

# Agent the launcher drives for this profile's issues (opencode|claude-code).
# Surfaced as a preset parameter so a profile author picks it once per repo.
data "coder_parameter" "agent_name" {
  name         = "agent_name"
  display_name = "AI agent the launcher drives (opencode|claude-code)."
  type         = "string"
  default      = "opencode"
  order        = 16
}

# Per-project system prompt (base64). The startup script decodes + stages it
# as AGENT_CONTEXT.md / AGENT.md so the agent follows the project context.
# Empty = the launcher/template falls back to the built-in agent-system-prompt.md.
data "coder_parameter" "agent_system_prompt_b64" {
  name         = "agent_system_prompt_b64"
  display_name = "Base64 of the per-project agent system prompt (empty = built-in)."
  type         = "string"
  default      = ""
  order        = 17
}

# Multi-repo: base64 JSON {"components": [...], "dependencies": [...]} for
# every component OTHER than odoo (already booted above via odoo_image/
# dump_s3_uri/repo_url). Each component carries its own resolved env-file URL
# (lib/backend/component_env.py already resolved DB/peer/shared-infra wiring
# on the panel side -- the workspace just downloads, sources, and runs).
# {"components": [], "dependencies": []} (base64) for a legacy single-repo
# profile -- the loop below then does nothing and only the single Odoo
# container this template has always booted comes up.
data "coder_parameter" "components_json" {
  name         = "components_json"
  display_name = "Base64 JSON: non-odoo components + shared-infra dependencies"
  type         = "string"
  default      = ""
  order        = 18
}

# --- Template presets --------------------------------------------------------
# Presets are auto-generated from the profile store by deploy/_gen_presets.py
# into presets.tf (one preset per profile that has a built image + a successful
# mask run). `deploy/12_publish_template.sh` regenerates them before each push.
# A new repo+DB becomes a one-click preset after: build + mask via the CLI,
# then re-publish the template.

provider "aws" {
  region = data.coder_parameter.region.value
}

data "coder_workspace" "me" {}

# --- infra defaults via data sources (Phase 1 of Option E) --------------------
# When the user leaves instance_profile / security_group_id / subnet_id empty,
# resolve them by name (SG) or as the first default-VPC subnet, so
# `coder create -t odoo-synth-workspacer <name>` works with no infra params. The panel
# can still pass explicit values to override.

# Env SG is a single named SG (odoo-synth-env-sg); look it up by name.
data "aws_security_groups" "env_sg" {
  filter {
    name   = "group-name"
    values = ["odoo-synth-env-sg"]
  }
}

# First default-VPC subnet (used only when subnet_id is empty).
data "aws_subnets" "default_vpc" {
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  # Resolve infra: explicit parameter wins, else data-source / known-name fallback.
  # ami_id: an explicitly-passed "" must NOT become the AMI (=> MissingParameter:
  # ImageId), so fall back to the dynamically-resolved Ubuntu 22.04 AMI.
  ami_id           = length(data.coder_parameter.ami_id.value) > 0 ? data.coder_parameter.ami_id.value : data.aws_ami.ubuntu_2204.id
  sg_id            = length(data.coder_parameter.security_group_id.value) > 0 ? data.coder_parameter.security_group_id.value : (length(data.aws_security_groups.env_sg.ids) > 0 ? data.aws_security_groups.env_sg.ids[0] : "")
  instance_profile = length(data.coder_parameter.instance_profile.value) > 0 ? data.coder_parameter.instance_profile.value : "odoo-synth-env-instance"
  subnet_id        = length(data.coder_parameter.subnet_id.value) > 0 ? data.coder_parameter.subnet_id.value : (length(data.aws_subnets.default_vpc.ids) > 0 ? data.aws_subnets.default_vpc.ids[0] : "")

  # one password per workspace for the Odoo admin user (matches the
  # old design where both shared the per-env secret). Set by the control panel as
  # a template parameter so it knows the value for the /password endpoint.
  admin_password = data.coder_parameter.admin_password.value

  # Multi-repo components to expose through the Coder tunnel: same
  # components_json the boot script already decodes, read here in Terraform
  # itself. Exposure is an explicit opt-in per component (profile's
  # component.expose = {port: N}), deliberately NOT implied by merely
  # having a port -- a component can need a port for internal peer-wiring
  # (--network host binding, another component's PEER_HOST/PEER_PORT)
  # without wanting a dashboard app tile, e.g. an internal-only API.
  components_decoded = try(jsondecode(base64decode(data.coder_parameter.components_json.value)), { components = [] })
  exposed_components = {
    for c in try(local.components_decoded.components, []) : c.name => c
    if try(c.expose.port, null) != null
  }
}

# Per-workspace password generated by Coder and exposed to the agent as an env
# var — replaces the old per-env AWS Secrets Manager secret.
resource "coder_agent" "main" {
  os                      = "linux"
  arch                    = "amd64"
  startup_script_behavior = "blocking"
  startup_script          = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    exec > >(tee -a /var/log/odoo-synth-workspacer.log) 2>&1
    echo "[workspacer ${data.coder_workspace.me.id}] boot $(date -u +%FT%TZ) issue=${data.coder_parameter.issue.value}"

    REGION="${data.coder_parameter.region.value}"
    if [ -z "$REGION" ]; then
      REGION="$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo us-east-1)"
    fi
    DUMP_S3_URI="${data.coder_parameter.dump_s3_uri.value}"
    ODOO_IMAGE="${data.coder_parameter.odoo_image.value}"
    REPO_URL="${data.coder_parameter.repo_url.value}"
    REPO_BRANCH="${data.coder_parameter.repo_branch.value}"
    GIT_TOKEN_ENV="${data.coder_parameter.git_token_env.value}"
    DB_NAME="${data.coder_parameter.db_name.value}"
    ODOO_MASTER_PASSWORD="${data.coder_parameter.odoo_master_password.value}"
    ODOO_CONF_EXTRA_B64="${data.coder_parameter.odoo_conf_extra_b64.value}"
    AGENT_NAME="${data.coder_parameter.agent_name.value}"
    AGENT_SYSTEM_PROMPT_B64="${data.coder_parameter.agent_system_prompt_b64.value}"
    COMPONENTS_JSON="${data.coder_parameter.components_json.value}"
    ADMIN_PASS="${local.admin_password}"
    WORKSPACE="/home/dev/workspace"
    REPO_DIR="$WORKSPACE/repo"
    PGPASS="odoo"
    NET="envnet"

    mkdir -p "$WORKSPACE"
    chown -R dev:dev /home/dev
    docker network create "$NET" >/dev/null 2>&1 || true

    # --- 1. local postgres holding the masked data ---
    docker rm -f env-db >/dev/null 2>&1 || true
    docker run -d --name env-db --network "$NET" \
      -e POSTGRES_PASSWORD="$PGPASS" -e POSTGRES_USER=odoo \
      -e POSTGRES_DB="$DB_NAME" -p 127.0.0.1:5432:5432 \
      -v /var/lib/env-db:/var/lib/postgresql/data postgres:16
    # Wait for the *database* (not just the server) to accept connections.
    # pg_isready returns OK once postgres accepts any connection, but the
    # POSTGRES_DB is still being created by the entrypoint; a psql -d $DB_NAME
    # at that instant fails ("database ... does not exist"), and under
    # `set -euo pipefail` that kills the whole startup script (race that
    # intermittently broke workspace creation).
    for _ in $(seq 1 60); do
      docker exec env-db psql -U odoo -d "$DB_NAME" -tAc "select 1" >/dev/null 2>&1 && break
      sleep 2
    done

    # --- 2. seed from the masked dump (first boot only; idempotent) ---
    # The env-db volume PERSISTS across workspace stop/start, and the
    # startup_script re-runs on every agent boot. Re-running pg_restore into a
    # DB that already holds the dump corrupts it (pg_restore --clean drops a
    # table but its composite TYPE survives, then CREATE TABLE collides on the
    # type -> already-exists / duplicate-key errors -> half-dropped DB ->
    # Odoo 500s). So only restore when the target DB is empty (first boot);
    # on restart we keep the developer in-progress data untouched.
    if [ -n "$DUMP_S3_URI" ]; then
      TBL_COUNT=$(docker exec env-db psql -U odoo -d "$DB_NAME" -tAc "select count(*) from pg_tables where schemaname = current_schema()" 2>/dev/null || echo 0)
      TBL_COUNT=$${TBL_COUNT:-0}
      if [ "$TBL_COUNT" -gt 0 ] 2>/dev/null; then
        echo "[env] target DB already seeded -- keeping existing data"
      else
        echo "[env] downloading masked dump from S3 ..."
        aws s3 cp "$DUMP_S3_URI" /tmp/masked.dump --region "$REGION"
        echo "[env] restoring masked dump into local postgres ..."
        docker exec -i env-db pg_restore -U odoo -d "$DB_NAME" \
          --no-owner --no-privileges --disable-triggers \
          < /tmp/masked.dump || true
        rm -f /tmp/masked.dump
        echo "[env] dump restore complete"
      fi
    fi

    # --- 3. resolve git credentials ---
    # Two auth paths for private addons:
    #   (a) SSH (git@github.com:... / ssh://) -- uses the workspace user's
    #       per-user Coder SSH key, injected by the agent as $GIT_SSH_COMMAND
    #       ("coder gitssh --"). No static token needed; each user's own key
    #       grants access, so add the user's Coder public key to the repo's
    #       deploy/user keys on the Git host. Requires HOME for the gitssh
    #       wrapper and accept-new host-key handling (no known_hosts baked in).
    #   (b) HTTPS -- fall back to a GitHub token injected into the URL by
    #       Coder (a per-profile user secret named git-token-<profile_id>,
    #       injected as $GH_PAT_<UPPER_ID>; the name arrives in
    #       GIT_TOKEN_ENV). For users without a registered SSH key.
    GIT_TOKEN=""
    GIT_TOKEN_RC="n/a"
    if [ -n "$GIT_TOKEN_ENV" ]; then
      GIT_TOKEN="$${!GIT_TOKEN_ENV:-}"
      if [ -n "$GIT_TOKEN" ]; then GIT_TOKEN_RC="ok"; else GIT_TOKEN_RC="EMPTY"; fi
    fi
    SSH_MODE=0
    case "$REPO_URL" in
      git@*|ssh://*) SSH_MODE=1 ;;
    esac
    _M=$([ "$SSH_MODE" = 1 ] && echo ssh || echo https)
    echo "[env] repo: url=$REPO_URL branch=$REPO_BRANCH mode=$_M git_token_env=$GIT_TOKEN_ENV git_token=$GIT_TOKEN_RC"

    # --- 4. clone the addons repo ---
    if [ -n "$REPO_URL" ]; then
      CLONE_OK=0
      if [ "$SSH_MODE" = 1 ]; then
        # Use the Coder-injected per-user SSH key. $GIT_SSH_COMMAND points at
        # "<tmp>/coder gitssh --"; the agent injects the user's Coder SSH key
        # and a token the wrapper uses to sign SSH challenges, so private repos
        # the user has access to clone with NO stored/static token.
        # The gitssh binary lives in a root-owned 0700 tmp dir, so the clone
        # runs as root with HOME=/root; the result is chowned to dev below.
        ROOT_GIT_SSH="$(printf '%s' "$GIT_SSH_COMMAND") -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/known_hosts"
        if HOME=/root GIT_SSH_COMMAND="$ROOT_GIT_SSH" git clone "$REPO_URL" "$REPO_DIR" 2>&1; then
          CLONE_OK=1
        else
          echo "[env] WARN: ssh clone failed (need the user's Coder SSH key registered as a deploy key on the repo?)"
        fi
        if [ -d "$REPO_DIR/.git" ] && [ -n "$REPO_BRANCH" ]; then
          HOME=/root git -C "$REPO_DIR" checkout "$REPO_BRANCH" 2>/dev/null \
            || { HOME=/root GIT_SSH_COMMAND="$ROOT_GIT_SSH" git -C "$REPO_DIR" fetch --depth 1 origin "$REPO_BRANCH" \
                 && HOME=/root git -C "$REPO_DIR" checkout FETCH_HEAD; } \
            || true
        fi
        [ -d "$REPO_DIR/.git" ] && HOME=/root git -C "$REPO_DIR" remote set-url origin "$REPO_URL" 2>/dev/null || true
      else
        # HTTPS: inject a token from Secrets Manager. A private repo with no
        # token -> git prompts for a username, which hangs/fails non-interactively
        # with "could not read Username". Surface that clearly instead of a
        # silent bare-URL clone.
        if [ -z "$GIT_TOKEN" ]; then
          echo "[env] WARN: https repo but no git token (GIT_TOKEN_ENV empty or Coder user secret unset); clone will fail for a private repo"
        fi
        CLONE_URL="$REPO_URL"
        if [ -n "$GIT_TOKEN" ]; then
          CLONE_URL="$(printf '%s' "$REPO_URL" | sed -E "s#https://#https://x-access-token:$GIT_TOKEN@#")"
        fi
        if sudo -u dev git clone "$CLONE_URL" "$REPO_DIR" 2>&1; then
          CLONE_OK=1
        else
          echo "[env] WARN: https clone failed (token=$${GIT_TOKEN_RC}) -- check the profile's Coder user secret (git-token-<profile_id>) is set"
        fi
        if [ -n "$REPO_BRANCH" ] && [ -d "$REPO_DIR/.git" ]; then
          sudo -u dev git -C "$REPO_DIR" checkout "$REPO_BRANCH" 2>/dev/null \
            || { sudo -u dev git -C "$REPO_DIR" fetch --depth 1 origin "$REPO_BRANCH" \
                 && sudo -u dev git -C "$REPO_DIR" checkout FETCH_HEAD; } \
            || true
        fi
        if [ -n "$GIT_TOKEN" ] && [ -d "$REPO_DIR/.git" ]; then
          sudo -u dev git -C "$REPO_DIR" remote set-url origin "$REPO_URL" || true
        fi
      fi
      [ "$CLONE_OK" = 1 ] && echo "[env] repo cloned -> $REPO_DIR" || echo "[env] repo NOT cloned (addons won't be live-mounted)"
    fi
    chown -R dev:dev /home/dev

    # --- 5. pull + run the provenance-baked odoo image ---
    if [ -n "$ODOO_IMAGE" ]; then
      REG="$${ODOO_IMAGE%%/*}"
      aws ecr get-login-password --region "$REGION" \
        | docker login --username AWS --password-stdin "$REG" || true
      docker pull "$ODOO_IMAGE" || true
      MOUNT_ARGS=""
      if [ -d "$REPO_DIR" ]; then
        ADDON_DIRS="$(cd "$REPO_DIR" && find . -maxdepth 3 -name __manifest__.py -printf '%h\n' 2>/dev/null \
          | sed 's#/[^/]*$##' | sed 's#^\./\{0,1\}##' | sort -u)"
        EXTRA=""
        if [ -n "$ADDON_DIRS" ]; then
          while IFS= read -r rel; do
            [ -z "$rel" ] && cpath="/mnt/live" || cpath="/mnt/live/$rel"
            EXTRA="$${EXTRA:+$EXTRA,}$cpath"
          done <<< "$ADDON_DIRS"
        else
          EXTRA="/mnt/live"
        fi
        MOUNT_ARGS="-v $${REPO_DIR}:/mnt/live:rw -e EXTRA_ADDONS_PATH=$EXTRA"
      fi
      docker rm -f env-odoo >/dev/null 2>&1 || true
      docker run -d --name env-odoo --network "$NET" \
        -p 127.0.0.1:18069:8069 \
        -e TARGET_DB_HOST=env-db -e TARGET_DB_PORT=5432 -e TARGET_DB_NAME="$DB_NAME" \
        -e TARGET_DB_USER=odoo -e TARGET_DB_PASSWORD="$PGPASS" \
        -e ODOO_MASTER_PASSWORD="$ODOO_MASTER_PASSWORD" \
        -e ODOO_CONF_EXTRA_B64="$ODOO_CONF_EXTRA_B64" \
        $MOUNT_ARGS "$ODOO_IMAGE" || true

      # install addons' python deps into the odoo container, then restart
      if [ -d "$REPO_DIR" ]; then
        DEPS="$(docker exec env-odoo python3 - <<'PY' 2>/dev/null || true
import ast, glob
MAP = {"dateutil":"python-dateutil","ldap":"python-ldap","Crypto":"pycryptodome",
       "jwt":"pyjwt","OpenSSL":"pyOpenSSL","PIL":"Pillow","yaml":"PyYAML",
       "bs4":"beautifulsoup4","magic":"python-magic","wand":"Wand"}
pkgs = set()
for m in glob.glob('/mnt/live/**/__manifest__.py', recursive=True):
    try: d = ast.literal_eval(open(m).read())
    except Exception: continue
    for p in ((d.get('external_dependencies') or {}).get('python') or []):
        pkgs.add(MAP.get(p, p))
print(' '.join(sorted(pkgs)))
PY
)"
        REQS="$(find "$REPO_DIR" -maxdepth 3 -name requirements.txt 2>/dev/null | head -5)"
        if [ -n "$DEPS" ] || [ -n "$REQS" ]; then
          REQ_ARGS=""
          for r in $REQS; do REQ_ARGS="$REQ_ARGS -r /mnt/live/$${r#$REPO_DIR/}"; done
          docker exec env-odoo pip install --no-cache-dir $DEPS $REQ_ARGS \
            >/home/dev/workspace/pip-addons.log 2>&1 || true
          chown dev:dev /home/dev/workspace/pip-addons.log 2>/dev/null || true
          docker restart env-odoo >/dev/null 2>&1 || true
        fi
      fi

      # restore a usable admin login (masked DB has no passwords)
      if [ -n "$ADMIN_PASS" ]; then
        for _ in $(seq 1 30); do
          docker exec env-db pg_isready -U odoo -d "$DB_NAME" >/dev/null 2>&1 && break
          sleep 2
        done
        ADMIN_HASH="$(docker exec env-odoo python3 -c \
          "from passlib.context import CryptContext; print(CryptContext(['pbkdf2_sha512']).hash('$ADMIN_PASS'))" \
          2>/dev/null || echo '')"
        if [ -n "$ADMIN_HASH" ]; then
          docker exec env-db psql -U odoo -d "$DB_NAME" -c \
            "UPDATE res_users SET login='admin', password='$ADMIN_HASH', active=true WHERE id=2;" \
            >/dev/null 2>&1 || true
        fi
      fi
    fi

    # --- 5b. multi-repo: boot every other component + shared-infra deps -----
    # {"components": [], "dependencies": []} (base64) for a legacy single-repo
    # profile -- the python3 step below then writes zero manifest lines and
    # this whole block is a no-op, same as before multi-repo support existed.
    # All components here run --network host (like every other odoo-synth
    # Coder template) so they reach env-db (published at 127.0.0.1:5432) and
    # each other via plain localhost:<port> -- lib/backend/component_env.py
    # already resolved every wired env var to that same convention.
    COMPDIR="/tmp/components"; mkdir -p "$COMPDIR"
    echo "$COMPONENTS_JSON" | base64 -d > "$COMPDIR/components.json" 2>/dev/null || true
    python3 - "$COMPDIR" <<'PYEOF' || echo "[env] WARN: components_json processing failed; no extra components will start"
import json, shlex, sys

compdir = sys.argv[1]
try:
    doc = json.load(open(f"{compdir}/components.json"))
except Exception:
    doc = {}  # empty/invalid (e.g. a legacy profile's unset default) -> no-op

def sh(v) -> str:
    """shlex.quote, not repr() -- these lines are SOURCED BY BASH, and
    Python's string-repr quoting is a different grammar than POSIX shell
    quoting (mismatched escaping of embedded quotes/backslashes/$ would be a
    real shell-injection risk for arbitrary values like install/start
    commands)."""
    return shlex.quote(str(v) if v is not None else "")

names = []
for c in doc.get("components") or []:
    name = c["name"]
    names.append(name)
    proc = c.get("process") or {}
    stat = c.get("static") or {}
    with open(f"{compdir}/{name}.env", "w") as f:
        f.write(f'NAME={sh(name)}\n')
        f.write(f'KIND={sh(c.get("kind"))}\n')
        f.write(f'PORT={sh(c.get("port"))}\n')
        f.write(f'IMAGE_URI={sh(c.get("image_uri"))}\n')
        f.write(f'RESOLVED_REF={sh(c.get("resolved_ref"))}\n')
        f.write(f'REPO_URL={sh(c.get("repo_url"))}\n')
        f.write(f'REPO_REF={sh(c.get("repo_ref"))}\n')
        f.write(f'ENV_GET_URL={sh(c.get("env_get_url"))}\n')
        f.write(f'INSTALL_CMD={sh(proc.get("install_cmd") or stat.get("install_cmd"))}\n')
        f.write(f'BUILD_CMD={sh(proc.get("build_cmd") or stat.get("build_cmd"))}\n')
        f.write(f'START_CMD={sh(proc.get("start_cmd"))}\n')
        f.write(f'PUBLISH_DIR={sh(stat.get("publish_dir") or "dist")}\n')
with open(f"{compdir}/manifest.txt", "w") as f:
    # Trailing newline matters: `while read -r NAME; do ...; done < manifest.txt`
    # below silently drops the LAST entry without it (bash's `read` returns
    # failure on a final line with no newline, which fails the loop condition
    # before the body runs for it).
    for n in names:
        f.write(n + "\n")
with open(f"{compdir}/dependencies.txt", "w") as f:
    for d in (doc.get("dependencies") or []):
        f.write(f'{shlex.quote(d["name"])} {shlex.quote(d.get("kind", d["name"]))}\n')

# Env Guide fragment: entirely generated from this profile's actual
# components/dependencies (whatever they are) -- never a fixed list of
# names, so it reflects any profile from a legacy odoo-only one up to
# however many repos/services a given operator wired in.
import html as _html

DEFAULT_DEP_PORTS = {"redis": 6379}  # kept in sync with component_env.py's
CONTROL_HINTS = {
    "docker": "docker start|stop|restart {name}",
    "static": "served by a background python http.server; re-open this workspace's startup log or restart the workspace to rebuild/reserve it",
    "process": "background process (no systemd unit); find it with pgrep -fa '{name}' or inspect /tmp/components/{name}.run.log",
}
LOG_HINTS = {
    "docker": "docker logs -f {name}",
    "static": "/tmp/components/{name}.buildlog (build), /tmp/components/{name}.serve.log (serve)",
    "process": "/tmp/components/{name}.buildlog (build), /tmp/components/{name}.run.log (run)",
}

rows = []
for c in (doc.get("components") or []):
    name = c["name"]
    kind = c.get("kind") or "?"
    port = c.get("port")
    port_cell = f"127.0.0.1:{port}" if port else "&mdash;"
    repo_cell = (f'{_html.escape(str(c.get("repo_url") or ""))}<br><code>{_html.escape(str(c.get("resolved_ref") or c.get("repo_ref") or ""))}</code>'
                 if c.get("repo_url") else "&mdash;")
    control = CONTROL_HINTS.get(kind, "no default control hint for kind '{kind}'").format(name=name, kind=kind)
    logs = LOG_HINTS.get(kind, "&mdash;").format(name=name)
    rows.append(
        f"<tr><td><code>{_html.escape(name)}</code></td><td>{_html.escape(kind)}</td>"
        f"<td>{port_cell}</td><td>{repo_cell}</td>"
        f"<td><code>{_html.escape(control)}</code></td><td><code>{_html.escape(logs)}</code></td></tr>"
    )
components_table = (
    "<table><tr><th>name</th><th>kind</th><th>host port</th><th>repo @ ref</th>"
    "<th>control</th><th>logs</th></tr>" + "".join(rows) + "</table>"
    if rows else "<p>No additional components on this profile -- single-repo (Odoo-only).</p>"
)

dep_rows = []
for d in (doc.get("dependencies") or []):
    name = d["name"]
    kind = (d.get("kind") or name).lower()
    port = DEFAULT_DEP_PORTS.get(kind)
    conn = f"127.0.0.1:{port}" if port else "no default port for kind '{}' -- wire it manually".format(kind)
    dep_rows.append(
        f"<tr><td><code>{_html.escape(name)}</code></td><td>{_html.escape(kind)}</td>"
        f"<td><code>dep-{_html.escape(name)}</code></td><td><code>{_html.escape(conn)}</code></td></tr>"
    )
dependencies_table = (
    "<table><tr><th>name</th><th>kind</th><th>container</th><th>connect</th></tr>" + "".join(dep_rows) + "</table>"
    if dep_rows else "<p>No shared-infra dependencies on this profile.</p>"
)

with open(f"{compdir}/components_guide.html", "w") as f:
    f.write("<h2>Multi-repo components</h2>\n" + components_table + "\n")
    f.write("<h2>Shared dependencies</h2>\n" + dependencies_table + "\n")
PYEOF

    # --- boot declared shared-infra dependencies first (components may need
    # them ready before their own start_cmd/entrypoint runs) -----------------
    if [ -s "$COMPDIR/dependencies.txt" ]; then
      while read -r DEP_NAME DEP_KIND; do
        [ -z "$DEP_NAME" ] && continue
        echo "[env] starting shared dependency $DEP_NAME (kind=$DEP_KIND) ..."
        case "$DEP_KIND" in
          redis)
            docker rm -f "dep-$DEP_NAME" >/dev/null 2>&1 || true
            docker run -d --name "dep-$DEP_NAME" --network host redis:7-alpine \
              >/dev/null 2>&1 || echo "[env] WARN: failed to start dependency $DEP_NAME"
            ;;
          *)
            echo "[env] WARN: no default image for dependency kind '$DEP_KIND' ($DEP_NAME) -- skipped, wire it manually"
            ;;
        esac
      done < "$COMPDIR/dependencies.txt"
    fi

    # --- boot each component per its kind ------------------------------------
    if [ -s "$COMPDIR/manifest.txt" ]; then
      while read -r CNAME; do
        [ -z "$CNAME" ] && continue
        # Every var this iteration sources/sets (NAME, KIND, PORT, REPO_URL,
        # ...) is confined to this subshell. Without it, `. $CNAME.env`
        # leaks straight into the top-level script scope (a `while read; do
        # ...; done < file` loop does NOT fork a subshell in bash) and the
        # LAST component processed clobbers vars of the same name used
        # elsewhere -- e.g. the Odoo addons-repo $REPO_URL/$RESOLVED_REF
        # referenced later in the Env Guide page. `continue` inside a
        # subshell doesn't reach the outer loop, so each early-exit below
        # uses `exit 0` instead (which only ends this subshell/iteration).
        (
        # shellcheck disable=SC1090
        . "$COMPDIR/$CNAME.env"
        echo "[env] starting component $NAME (kind=$KIND) ..."
        CENV_ARGS=(); CENV_KEYS=""
        if [ -n "$ENV_GET_URL" ]; then
          if curl -fsSL "$ENV_GET_URL" -o "$COMPDIR/$NAME.envsh" 2>/dev/null; then
            . "$COMPDIR/$NAME.envsh"
            CENV_KEYS="$(grep -oE '^export [A-Za-z_][A-Za-z0-9_]*' "$COMPDIR/$NAME.envsh" | awk '{print $2}')"
          else
            echo "[env] WARN: could not download env for $NAME; it will start with no resolved env vars"
          fi
          for _k in $CENV_KEYS; do CENV_ARGS+=("-e" "$_k"); done
        fi
        case "$KIND" in
          docker)
            [ -z "$IMAGE_URI" ] && { echo "[env] WARN: component $NAME has no built image; skipped"; exit 0; }
            aws ecr get-login-password --region "$REGION" 2>/dev/null \
              | docker login --username AWS --password-stdin "$(echo "$IMAGE_URI" | cut -d/ -f1)" >/dev/null 2>&1 || true
            docker pull "$IMAGE_URI" >/dev/null 2>&1 || { echo "[env] WARN: docker pull failed for $NAME"; exit 0; }
            docker rm -f "$NAME" >/dev/null 2>&1 || true
            docker run -d --name "$NAME" --network host "$${CENV_ARGS[@]}" "$IMAGE_URI" \
              >/dev/null 2>&1 || echo "[env] WARN: failed to start component $NAME"
            ;;
          static)
            CDIR="$WORKSPACE/components/$NAME"; mkdir -p "$CDIR"
            # Same token-embedding as the primary addons clone above -- a
            # bare $REPO_URL clone hangs/fails non-interactively for a
            # private repo (git prompts for a username with no token).
            CCLONE_URL="$REPO_URL"
            [ -n "$GIT_TOKEN" ] && CCLONE_URL="$(printf '%s' "$REPO_URL" | sed -E "s#https://#https://x-access-token:$GIT_TOKEN@#")"
            git clone --quiet "$CCLONE_URL" "$CDIR" >/dev/null 2>&1 || echo "[env] WARN: clone failed for $NAME"
            [ -n "$RESOLVED_REF" ] && { git -C "$CDIR" checkout --quiet "$RESOLVED_REF" 2>/dev/null || echo "[env] WARN: checkout $RESOLVED_REF failed for $NAME"; }
            (
              cd "$CDIR"
              [ -f "$COMPDIR/$NAME.envsh" ] && . "$COMPDIR/$NAME.envsh"
              [ -n "$INSTALL_CMD" ] && eval "$INSTALL_CMD"
              [ -n "$BUILD_CMD" ] && eval "$BUILD_CMD"
            ) >"$COMPDIR/$NAME.buildlog" 2>&1 || echo "[env] WARN: build failed for $NAME (see $COMPDIR/$NAME.buildlog)"
            SPORT="$${PORT:-8080}"
            ( cd "$CDIR/$PUBLISH_DIR" 2>/dev/null && nohup python3 -m http.server "$SPORT" --bind 127.0.0.1 \
              >"$COMPDIR/$NAME.serve.log" 2>&1 & )
            ;;
          process)
            CDIR="$WORKSPACE/components/$NAME"; mkdir -p "$CDIR"
            CCLONE_URL="$REPO_URL"
            [ -n "$GIT_TOKEN" ] && CCLONE_URL="$(printf '%s' "$REPO_URL" | sed -E "s#https://#https://x-access-token:$GIT_TOKEN@#")"
            git clone --quiet "$CCLONE_URL" "$CDIR" >/dev/null 2>&1 || echo "[env] WARN: clone failed for $NAME"
            [ -n "$RESOLVED_REF" ] && { git -C "$CDIR" checkout --quiet "$RESOLVED_REF" 2>/dev/null || echo "[env] WARN: checkout $RESOLVED_REF failed for $NAME"; }
            (
              cd "$CDIR"
              [ -f "$COMPDIR/$NAME.envsh" ] && . "$COMPDIR/$NAME.envsh"
              # nohup spawns a NEW process, which only inherits exported
              # (environment) vars, not plain shell vars -- PORT was only a
              # plain var sourced from $NAME.env until now, so a process kind
              # component's own server always saw its framework's built-in
              # default port instead of its actual platform-assigned one.
              export PORT="$${PORT:-8080}"
              [ -n "$INSTALL_CMD" ] && eval "$INSTALL_CMD"
              [ -n "$BUILD_CMD" ] && eval "$BUILD_CMD"
              [ -n "$START_CMD" ] && nohup bash -c "$START_CMD" >"$COMPDIR/$NAME.run.log" 2>&1 &
            ) >"$COMPDIR/$NAME.buildlog" 2>&1 || echo "[env] WARN: setup failed for $NAME (see $COMPDIR/$NAME.buildlog)"
            ;;
          *)
            echo "[env] WARN: unknown component kind '$KIND' for $NAME -- skipped"
            ;;
        esac
        ) || echo "[env] WARN: component $CNAME failed unexpectedly"
      done < "$COMPDIR/manifest.txt"
    fi

    # --- 6. in-env info page (Env Guide app) ---------------------------------
    # A secret-free, generated HTML page the dev opens from the workspace page
    # ("Env Guide" app). Documents where the repo lives, how to control the
    # Odoo/postgres containers, where logs are, and how to retrieve passwords
    # from env vars -- it NEVER prints the passwords themselves. Served by a
    # tiny python http.server bound to 127.0.0.1:8090; Coder proxies it through
    # the authenticated tunnel (owner-only by default).
    cat > /home/dev/workspace/index.html <<HTML
<!doctype html><html><head><meta charset="utf-8">
<title>odoo-synth env guide</title>
<style>
  body{font:15px/1.55 -apple-system,Segoe UI,sans-serif;max-width:880px;margin:2em auto;padding:0 1.5em;color:#222;background:#fafafa}
  h1{font-size:1.5em;border-bottom:2px solid #777;padding-bottom:.2em}
  h2{font-size:1.15em;margin-top:1.6em;color:#335}
  pre,code{background:#eee;border:1px solid #ddd;border-radius:3px}
  pre{padding:.8em;overflow:auto;font-size:13px}
  code{padding:.1em .3em}
  .k{display:inline-block;min-width:11em;font-weight:600}
  table{border-collapse:collapse;width:100%}
  td,th{border:1px solid #ddd;padding:.3em .6em;text-align:left;vertical-align:top}
  th{background:#eee}
</style></head><body>
<h1>odoo-synth environment guide</h1>
<p>Everything running in this workspace, where it lives, and how to drive it.</p>

<h2>Containers (docker)</h2>
<table>
<tr><th>name</th><th>purpose</th><th>host port</th></tr>
<tr><td><code>env-odoo</code></td><td>Odoo server (image-baked addons)</td><td>127.0.0.1:18069 &rarr; 8069</td></tr>
<tr><td><code>env-db</code></td><td>local Postgres 16 (hydrated from masked dump)</td><td>127.0.0.1:5432</td></tr>
</table>

$(cat "$COMPDIR/components_guide.html" 2>/dev/null)

<h2>Addons repo (live-mounted)</h2>
<p>
  <span class="k">repo:</span> <code>$${REPO_URL:-&lt;not set&gt;}</code><br>
  <span class="k">ref:</span> <code>$${REPO_BRANCH:-&lt;not set&gt;}</code><br>
  <span class="k">host path:</span> <code>/home/dev/workspace/repo</code><br>
  <span class="k">inside odoo:</span> <code>/mnt/live</code> (bind-mount, read-write)
</p>
<p>Edit addons on the host under <code>/home/dev/workspace/repo/&lt;addon&gt;</code>;
Odoo sees them at <code>/mnt/live/&lt;addon&gt;</code>. Restart Odoo to pick up
manifest or Python changes:</p>
<pre>docker restart env-odoo</pre>

<h2>Control the Odoo service</h2>
<pre># start / stop / restart
docker start  env-odoo
docker stop   env-odoo
docker restart env-odoo

# tail Odoo logs (live)
docker logs -f env-odoo

# last 100 lines / errors only
docker logs --tail 100 env-odoo
docker logs env-odoo 2&gt;&amp;1 | grep ERROR

# run odoo CLI (e.g. install an addon into the current DB)
docker exec -it env-odoo odoo -d $${DB_NAME} -i my_addon --stop-after-init
</pre>

<h2>Postgres access</h2>
<pre># psql inside the DB container
docker exec -it env-db psql -U odoo -d $${DB_NAME}

# from the host (port forwarded to 127.0.0.1:5432)
PGPASSWORD=odoo psql -h 127.0.0.1 -U odoo -d $${DB_NAME}

# quick counts
docker exec env-db psql -U odoo -d $${DB_NAME} -tAc \
  "select count(*) from res_partner"
</pre>

<h2>Logs</h2>
<table>
<tr><th>what</th><th>where</th></tr>
<tr><td>Odoo runtime log</td><td><code>docker logs env-odoo</code> (stdout, no file)</td></tr>
<tr><td>workspace boot / dump restore / clone</td><td><code>/var/log/odoo-synth-workspacer.log</code></td></tr>
<tr><td>addon pip install</td><td><code>/home/dev/workspace/pip-addons.log</code> (if a repo was cloned)</td></tr>
</table>

<h2>Passwords &amp; credentials</h2>
<p>Passwords are <strong>not</strong> printed here. Retrieve them from the
workspace environment, in a terminal on this host:</p>
<pre># Odoo admin password (login: admin)
echo "\$CODER_ENV_ADMIN_PASSWORD"

# Odoo DB master password (admin_passwd in odoo.conf)
echo "\$ODOO_MASTER_PASSWORD"
</pre>
<p>Odoo admin login is <code>admin</code>. The admin password
(<code>CODER_ENV_ADMIN_PASSWORD</code>) is what you enter at
<code>/web/login</code>. The DB master password
(<code>ODOO_MASTER_PASSWORD</code>) protects the database manager at
<code>/web/database/manager</code>.</p>

<h2>Notes</h2>
<ul>
  <li>The DB volume (<code>/var/lib/env-db</code>) persists across workspace
      stop/start; the masked dump is restored only on first boot.</li>
  <li>If the addons repo is private, set a GitHub token on the profile via
  <code>odoo-synth profile create --git-token &lt;PAT&gt;</code> (stored as a
      Secrets Manager GitHub token) at create time; otherwise the clone is
      skipped and Odoo runs from image-baked addons only.</li>
</ul>
</body></html>
HTML
    chown dev:dev /home/dev/workspace/index.html 2>/dev/null || true

    cat > /etc/systemd/system/env-info.service <<EISVC
[Unit]
Description=odoo-synth env info page (localhost)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=dev
WorkingDirectory=/home/dev/workspace
ExecStart=/usr/bin/python3 -m http.server 8090 --bind 127.0.0.1
Restart=always
[Install]
WantedBy=multi-user.target
EISVC
    systemctl daemon-reload
    systemctl enable --now env-info

    # --- 7. Claude Code (preinstalled in the golden AMI at /opt/claude-code) -
    # Served over a web terminal (ttyd) as the "Claude Code" Coder app so the
    # dev can drive it from the workspace page. The Anthropic API key is NOT
    # stored here -- it comes from the user's Coder user secret named
    # `anthropic-api-key` (env ANTHROPIC_API_KEY), which Coder injects into the
    # agent env automatically. If the user hasn't created that secret, the env
    # still boots; Claude will simply error at first use with a clear message.
    # The Claude setup is wrapped in a subshell with set +e + || true so a
    # failure here (bad flag, missing binary on an old AMI, etc.) can NEVER
    # abort the startup script -- the Odoo readiness loop below must still run.
    ( set +e
    if [ -x /usr/local/bin/claude ]; then
      install -d -o dev -g dev /home/dev/.local/bin
      ln -sf /usr/local/bin/claude /home/dev/.local/bin/claude 2>/dev/null
      cat > /home/dev/workspace/CLAUDE.md <<'CMDOC'
# odoo-synth environment (Claude Code project guide)

## Where things are
- Addons repo (your working copy): /home/dev/workspace/repo , bind-mounted into Odoo at /mnt/live .
- Odoo runs in the env-odoo docker container (host port 127.0.0.1:18069).
- Postgres runs in the env-db container (host 127.0.0.1:5432, user/db odoo, password odoo).
- Boot log: /var/log/odoo-synth-workspacer.log .
- Env Guide page: http://localhost:8090/ (the Env Guide app on the workspace page).

## Running / restarting Odoo
- Restart after changing addons: docker restart env-odoo
- Install/upgrade an addon: docker exec env-odoo odoo -d odoo -u <addon> --stop-after-init
- Tail logs: docker logs -f env-odoo

## Notes
- The DB is seeded from a masked production dump -- data is fake/masked, safe to mutate.
- Your git pushes use your Coder SSH key; no token needed for SSH URLs.

## AI agents installed (on the AMI)
- claude   -- Claude Code (Anthropic). API key from your Coder user secret `anthropic-api-key`.
- opencode -- open-source agent. Web app on the workspace page; add a provider with: opencode auth
- ralph    -- autonomous loop over an agent. e.g. ralph "fix the login 500" --agent claude-code --max-iterations 10
              (agents: opencode, claude-code, codex, copilot, cursor-agent, qwen-code)
CMDOC
      chown dev:dev /home/dev/workspace/CLAUDE.md 2>/dev/null || true

      # ttyd serves a login shell for dev that drops into the repo and launches
      # claude. Bound to 127.0.0.1; the Coder app proxies it through the tunnel.
      cat > /etc/systemd/system/claude-code.service <<CCSVC
[Unit]
Description=Claude Code web terminal (ttyd)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
Environment=HOME=/root
ExecStart=/usr/bin/ttyd -i 127.0.0.1 -p 8091 -t fontSize=14 sudo -u dev HOME=/home/dev bash -lc 'cd /home/dev/workspace && claude'
Restart=always
[Install]
WantedBy=multi-user.target
CCSVC
      systemctl daemon-reload
      systemctl enable --now claude-code

      # OpenCode: same ttyd-served-TUI pattern as Claude Code, on a separate
      # port (8092) so both apps can run side by side. OpenCode is a TUI by
      # default; `ralph` can drive it (or Claude) in an autonomous loop.
      ln -sf /usr/local/bin/opencode /home/dev/.local/bin/opencode 2>/dev/null
      cat > /etc/systemd/system/opencode.service <<OCSVC
[Unit]
Description=OpenCode web terminal (ttyd)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
Environment=HOME=/root
ExecStart=/usr/bin/ttyd -i 127.0.0.1 -p 8092 -t fontSize=14 sudo -u dev HOME=/home/dev bash -lc 'cd /home/dev/workspace && opencode'
Restart=always
[Install]
WantedBy=multi-user.target
OCSVC
      systemctl daemon-reload
      systemctl enable --now opencode
    else
      echo "[env] agent CLIs not found on AMI -- skipping Claude Code / OpenCode apps"
    fi
    ) || echo "[env] agent-app setup failed; continuing (Claude/OpenCode apps may be unavailable)"

    # --- 7b. stage the per-project agent system prompt ---
    # The profile's agent_system_prompt (base64) is decoded into
    # AGENT_CONTEXT.md (a stable sibling of the repo) and AGENT.md (in the
    # repo cwd, only if the repo ships none) so the agent reads it on start.
    # opencode reads AGENT.md / opencode.json from cwd; Claude Code reads
    # CLAUDE.md. Empty prompt = the launcher supplies the built-in default.
    if [ -n "$AGENT_SYSTEM_PROMPT_B64" ]; then
      prompt="$(printf '%s' "$AGENT_SYSTEM_PROMPT_B64" | base64 -d 2>/dev/null || true)"
      if [ -n "$prompt" ]; then
        printf '%s\n' "$prompt" > "$WORKSPACE/AGENT_CONTEXT.md"
        chown dev:dev "$WORKSPACE/AGENT_CONTEXT.md" 2>/dev/null || true
        if [ -d "$REPO_DIR" ] && [ ! -f "$REPO_DIR/AGENT.md" ]; then
          cp "$WORKSPACE/AGENT_CONTEXT.md" "$REPO_DIR/AGENT.md"
          chown dev:dev "$REPO_DIR/AGENT.md" 2>/dev/null || true
        fi
        echo "[env] staged per-project agent system prompt -> AGENT_CONTEXT.md"
      fi
    fi

    # --- 8. port-forwards Coder opens so the dev reaches odoo ---
    # `coder_port` resources below tell Coder to proxy these through the tunnel.

    # --- 9. readiness: block startup until Odoo answers HTTP ---
    if [ -n "$ODOO_IMAGE" ]; then
      for _ in $(seq 1 72); do
        code="$(curl -s -o /dev/null -w '%%{http_code}' --max-time 5 http://127.0.0.1:18069/web/login 2>/dev/null || echo 000)"
        case "$code" in 200|301|302|303) echo "[env] odoo ready (http $code)"; exit 0 ;; esac
        sleep 10
      done
      echo "[env] WARN: odoo did not answer within 12m; marking ready anyway"
    fi
  EOT
  env = {
    # expose the per-workspace passwords to the agent so the startup_script
    # can read them AND so a user shell / the Env Guide page can surface them
    # via `echo "$CODER_ENV_ADMIN_PASSWORD"`. CODER_ENV_ADMIN_PASSWORD is the
    # Odoo admin login password; ODOO_MASTER_PASSWORD is the Odoo DB master
    # password (admin_passwd in odoo.conf). Both are also sent to the Coder
    # API so the panel can surface them in the /password endpoint.
    CODER_ENV_ADMIN_PASSWORD = local.admin_password
    ODOO_MASTER_PASSWORD     = data.coder_parameter.odoo_master_password.value
  }
}





# workspace VM: existing AMI + profile + subnet, no public IP, no per-env SG.
resource "aws_instance" "workspace" {
  ami                         = local.ami_id
  instance_type               = data.coder_parameter.instance_type.value
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [local.sg_id]
  iam_instance_profile        = local.instance_profile
  associate_public_ip_address = true
  # cloud-init runs the Coder agent bootstrap. We inline the script (rather than
  # using coder_agent.main.init_script) so we can inject CODER_AGENT_TOKEN -- the
  # default init_script sets CODER_AGENT_AUTH=token but not the token itself, which
  # the agent requires to authenticate. The agent's startup_script (Odoo boot) runs
  # after the agent connects to the server.
  user_data                   = <<-EOT
    #!/usr/bin/env sh
    set -eux
    export CODER_AGENT_TOKEN="${coder_agent.main.token}"
    export CODER_AGENT_URL="${data.coder_workspace.me.access_url}"
    export CODER_AGENT_AUTH=token
    B="$(mktemp -d -t coder.XXXXXX)"; cd "$B"
    curl -fsSL --compressed "$${CODER_AGENT_URL}/bin/coder-linux-amd64" -o coder || \
      wget -q "$${CODER_AGENT_URL}/bin/coder-linux-amd64" -O coder
    chmod +x coder
    exec ./coder agent
  EOT
  user_data_replace_on_change = true
  tags = {
    Name                 = "odoo-synth-workspacer-${data.coder_workspace.me.name}"
    "odoo-synth:workspacer" = data.coder_workspace.me.id
    "odoo-synth:managed" = "true"
    "odoo-synth:issue"   = data.coder_parameter.issue.value
  }
}

# start/stop the instance with the workspace (Coder auto-stop).
resource "aws_ec2_instance_state" "workspace" {
  instance_id = aws_instance.workspace.id
  state       = data.coder_workspace.me.transition == "start" ? "running" : "stopped"
}

# port-forwards through the Coder tunnel so the dev reaches odoo
# without any inbound SG rule or public IP.
# subdomain = true => Coder serves each app on its own origin
# (<app>--<owner>--<ws>.apps.<access_host>). This is REQUIRED for Odoo,
# whose login form/assets use absolute server-root paths (/web/login,
# /web/session/authenticate, /web/static/...). With path-based proxying
# those resolve against the Coder dashboard origin and 404. Subdomain
# proxying gives Odoo a real origin so its absolute paths work natively.
# Requires CODER_APP_HOSTNAME=*.<host> on the server (set in 11_coder_server.sh).
resource "coder_app" "odoo" {
  agent_id     = coder_agent.main.id
  slug         = "odoo"
  display_name = "Odoo (masked)"
  icon         = "/icon/odoo.svg"
  url          = "http://localhost:18069"
  subdomain    = true
  healthcheck {
    url       = "http://localhost:18069/web/health"
    interval  = 10
    threshold = 3
  }
}

# One app per multi-repo component with expose.port set (whatever this
# profile actually declares) -- same subdomain-proxied, tunnel-only exposure
# as Odoo above, so nothing needs an inbound SG rule or public IP. No
# healthcheck: unlike Odoo's dedicated /web/health endpoint, a component's
# own root path may legitimately answer with a non-2xx (an API requiring
# auth, a redirect to a login page, ...), so asserting health here would
# just be guessing at semantics this template doesn't know.
resource "coder_app" "component" {
  for_each     = local.exposed_components
  agent_id     = coder_agent.main.id
  slug         = each.key
  display_name = each.key
  url          = "http://localhost:${each.value.expose.port}"
  subdomain    = true
}

# Env Guide: a secret-free HTML page served from inside the workspace
# (127.0.0.1:8090 by python http.server) documenting containers, repo mount,
# odoo/postgres control, logs, and how to retrieve passwords. Owner-only.
resource "coder_app" "env_info" {
  agent_id     = coder_agent.main.id
  slug         = "env-guide"
  display_name = "Env Guide"
  icon         = "/icon/info.svg"
  url          = "http://localhost:8090/"
  subdomain    = true
  share        = "owner"
  healthcheck {
    url       = "http://localhost:8090/"
    interval  = 10
    threshold = 3
  }
}

# Claude Code: a web terminal (ttyd) serving the `claude` CLI for the dev.
# The Anthropic API key is the user's Coder user secret `anthropic-api-key`
# (env ANTHROPIC_API_KEY), injected by Coder -- nothing in the template.
resource "coder_app" "claude_code" {
  agent_id     = coder_agent.main.id
  slug         = "claude-code"
  display_name = "Claude Code"
  icon         = "/icon/terminal.svg"
  url          = "http://localhost:8091"
  subdomain    = true
  share        = "owner"
  healthcheck {
    url       = "http://localhost:8091"
    interval  = 10
    threshold = 5
  }
}

# OpenCode: an open-source coding agent served over a web terminal (ttyd) on
# :8092. Like Claude Code, it's owner-only and health-checked.
resource "coder_app" "opencode" {
  agent_id     = coder_agent.main.id
  slug         = "opencode"
  display_name = "OpenCode"
  icon         = "/icon/terminal.svg"
  url          = "http://localhost:8092"
  subdomain    = true
  share        = "owner"
  healthcheck {
    url       = "http://localhost:8092"
    interval  = 10
    threshold = 5
  }
}
