#!/usr/bin/env bash
# 00_setup.sh -- guided first-time setup for a community user.
#
# Walks you through the full first-run, in order:
#   1. install prerequisites (incl. the coder CLI)
#   2. collect + configure AWS credentials
#   3. config.yaml (create/overwrite?)
#   4. collect BASIC-INFRA config values (region, project, S3 dumps bucket)
#      -- Odoo git_ref + custom addons + DB/Odoo passwords are NOT here;
#      they're profile/mask/env-time concerns (set per-profile / in
#      deploy/secrets.env before the first mask run)
#   5. validate config + CLI smoke test
#   6. provision BASIC infrastructure (ECR, masker+discovery images, builder
#      IAM, Coder server, Coder templates) -- with an interactive `coder login`
#      seam (the server must be up before you can log in, and templates need
#      the login token to publish)
#   7. hand off to profile creation + secrets + mask + dev envs (on-demand CLI)
#
# Safe to re-run: it offers to keep or overwrite your existing config, and every
# provisioning step is idempotent. It never commits anything (config.yaml +
# secrets.env are gitignored).
#
# Usage:
#   bash deploy/00_setup.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

# --- pretty helpers --------------------------------------------------------
BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'; OFF=$'\033[0m'
if [ ! -t 1 ]; then BOLD=""; DIM=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; OFF=""; fi
# All UI helpers write to stderr so prompt functions can safely capture only
# the final answer from stdout (fixes a bug where `warn`/`ok` text leaked into
# `$(prompt_required ...)` values and corrupted config.yaml).
say(){ echo "${BOLD}$*${OFF}" >&2; }
step(){ echo; echo "${CYAN}${BOLD}[$1]${OFF} ${BOLD}$2${OFF}" >&2; }
note(){ echo "${DIM}$*${OFF}" >&2; }
ok(){ echo "${GREEN}✓${OFF} $*" >&2; }
warn(){ echo "${YELLOW}!${OFF} $*" >&2; }
die(){ echo "${RED}✗${OFF} $*" >&2; exit 1; }
# prompt_default  "question" "default"  -> echoes answer (default if empty)
prompt_default(){
  local q="$1" d="$2" v
  printf '%s%s%s [%s]: ' "${BOLD}" "$q" "${OFF}" "$d" >&2
  read -r v
  echo "${v:-$d}"
}
prompt_required(){  # question
  local q="$1" v
  while true; do
    printf '%s%s%s: ' "${BOLD}" "$q" "${OFF}" >&2
    read -r v
    [ -n "$v" ] && { echo "$v"; return; }
    warn "a value is required"
  done
}
prompt_secret(){  # question  (no echo, optional confirm for generated)
  local q="$1" v
  printf '%s%s%s: ' "${BOLD}" "$q" "${OFF}" >&2
  read -rs v; echo >&2
  echo "$v"
}
confirm(){  # question  -> 0=yes 1=no  (default no)
  local q="$1" v
  printf '%s%s%s [y/N]: ' "${BOLD}" "$q" "${OFF}" >&2
  read -r v
  case "$v" in y|Y|yes|YES) return 0;; *) return 1;; esac
}
have(){ command -v "$1" >/dev/null 2>&1; }

say "${BOLD}odoo-synth guided setup${OFF}"
note "This walks you through a first-time install: prerequisites, AWS auth,"
note "config.yaml, secrets, and a smoke test. Re-run anytime; existing config"
note "is kept unless you choose to overwrite."

# ===========================================================================
# 1. PREREQUISITES
# ===========================================================================
step 1/7 "Install prerequisites (AWS CLI, python deps, Coder CLI, odoo-synth on PATH)"
if confirm "Run deploy/00_install_prereqs.sh now?"; then
  bash deploy/00_install_prereqs.sh --quiet
else
  warn "skipped -- make sure aws, python3, coder, and odoo-synth are on PATH."
fi
have aws     || die "aws CLI missing -- run deploy/00_install_prereqs.sh"
have python3 || die "python3 missing -- run deploy/00_install_prereqs.sh"
have odoo-synth || die "odoo-synth not on PATH -- run deploy/00_install_prereqs.sh"
ok "prerequisites present"

# ===========================================================================
# 2. AWS AUTHENTICATION
# ===========================================================================
step 2/7 "Configure AWS credentials"
echo "  Your access key is the CONTROL-PLANE key -- it creates the AWS resources"
echo "  + the builder/Coder IAM roles (those roles get the data-plane perms). The"
echo "  quickest path is to attach the AWS-managed ${BOLD}PowerUserAccess${OFF} policy to"
echo "  your IAM user. For a locked-down key, these actions are enough:"
echo
echo "  ${DIM}ec2:*                 SG, run/terminate/describe instances, create-image${OFF}"
echo "  ${DIM}ecr:CreateRepository, DescribeRepositories, GetAuthorizationToken,${OFF}"
echo "  ${DIM}    BatchGetImage, PutImage, *LayerUpload${OFF}"
echo "  ${DIM}iam:CreateRole, GetRole, PutRolePolicy, CreateInstanceProfile,${OFF}"
echo "  ${DIM}    GetInstanceProfile, AddRoleToInstanceProfile${OFF}"
echo "  ${DIM}s3:CreateBucket, ListBucket, GetObject, PutObject, DeleteObject, HeadBucket${OFF}"
echo "  ${DIM}ssm:GetParameters, secretsmanager:Create*/Get/Put/Delete/DescribeSecret,${OFF}"
echo "  ${DIM}sts:GetCallerIdentity${OFF}"
echo
echo "  ${DIM}Create the key in the AWS console: IAM -> Users -> your user -> Security${OFF}"
echo "  ${DIM}credentials -> Create access key. The wizard writes it to the standard${OFF}"
echo "  ${DIM}shared-credentials file (~/.aws/credentials + ~/.aws/config) -- nothing is${OFF}"
echo "  ${DIM}committed to this repo."
echo

aws_ok=false
aws_account=""
# Detect existing credentials first (shared file OR env vars).
if aws sts get-caller-identity >/dev/null 2>&1; then
  aws_account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '')"
  aws_region_cur="$(aws configure get region 2>/dev/null || aws configure get region 2>/dev/null || echo '')"
  ok "AWS credentials already configured (account ${aws_account:-?}, region ${aws_region_cur:-?})."
  if confirm "Re-enter different credentials?"; then
    aws_ok=false        # fall through to the guided collection below
  else
    aws_ok=true
  fi
fi

if [ "$aws_ok" = false ]; then
  if ! have aws; then
    die "aws CLI missing -- run step 1 (deploy/00_install_prereqs.sh) first."
  fi
  echo
  say "Enter your AWS access key"
  echo "  ${DIM}Access key id  : 20-char, starts with AKIA (e.g. AKIAIOSFODNN7EXAMPLE)${OFF}"
  echo "  ${DIM}Secret access key: 40-char. Both are shown once when you create the key.${OFF}"
  echo "  ${DIM}Type is hidden; paste carefully. Press Ctrl-C to abort.${OFF}"
  echo
  AKID="$(prompt_required "AWS Access Key ID")"
  SAK="$(prompt_secret  "AWS Secret Access Key")"
  [ -n "$AKID" ] && [ -n "$SAK" ] || die "both access key id and secret are required"
  # Region: the wizard asks again in step 4 as the config.yaml region, but we
  # need it now for sts to pick the right partition. Default from any existing
  # shared config, else us-east-1.
  REGION_DEFAULT="$(aws configure get region 2>/dev/null || echo us-east-1)"
  AWS_REGION_Q="$(prompt_default "AWS region for these credentials" "$REGION_DEFAULT")"

  # Write to the shared credentials/config files non-interactively.
  # `aws configure set` is idempotent and writes the right file per key.
  aws configure set aws_access_key_id     "$AKID"       # -> ~/.aws/credentials
  aws configure set aws_secret_access_key "$SAK"        # -> ~/.aws/credentials
  aws configure set region                "$AWS_REGION_Q"  # -> ~/.aws/config
  # scrub the values from this shell's variables + history so they don't linger
  unset AKID SAK
  export AWS_REGION="$AWS_REGION_Q"

  echo
  say "Verifying credentials..."
  if cid="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
    aws_ok=true
    aws_account="$cid"
    ok "authenticated -- AWS account $cid, region $AWS_REGION_Q"
    arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
    [ -n "$arn" ] && note "identity: $arn"
  else
    warn "AWS could not authenticate with those credentials. Common causes:"
    warn "  - wrong secret key (re-create the access key in IAM and re-run)"
    warn "  - key belongs to a different region/partition (check the region)"
    warn "  - the IAM user lacks sts:GetCallerIdentity (very unlikely)."
    warn "You can continue filling config.yaml now and fix AWS auth before the"
    warn "deploy step. The validate + smoke steps below will report 'AWS: not'."
    aws_ok=false
  fi
  REGION_DEFAULT="$AWS_REGION_Q"
fi

if [ "$aws_ok" = false ] && [ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}" ]; then
  # only warn if we genuinely have nothing
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    warn "AWS auth not confirmed. You can continue filling config.yaml now and"
    warn "re-run this wizard (or 'aws configure') before the deploy step."
    warn "The validate + smoke steps below will report 'AWS: not authenticated'."
  fi
fi
[ -z "${REGION_DEFAULT:-}" ] && REGION_DEFAULT="$(aws configure get region 2>/dev/null || echo us-east-1)"

# ===========================================================================
# 3. EXISTING CONFIG?
# ===========================================================================
step 3/7 "config.yaml"
CFG="$HERE/config.yaml"
if [ -f "$CFG" ]; then
  ok "config.yaml already exists."
  if ! confirm "Overwrite it with a fresh guided config?"; then
    note "keeping your existing config.yaml -- skipping to validation."
    SKIP_CONFIG=1
  else
    SKIP_CONFIG=0
  fi
else
  SKIP_CONFIG=0
fi

if [ "${SKIP_CONFIG:-0}" = 0 ]; then
# ---- collect values -------------------------------------------------------
step 4/7 "Collect configuration values"
echo "  ${DIM}Press Enter to accept the [default].${OFF}"
echo

REGION="$(prompt_default "AWS region" "$REGION_DEFAULT")"
PROJECT="$(prompt_default "Project name (AWS resources are named <project>-*)" "odoo-synth")"

echo
say "S3 bucket for masked dumps"
echo "  ${DIM}A bucket in your AWS account to hold masked pg_dump artifacts + uploaded${OFF}"
echo "  ${DIM}source dumps. S3 bucket names are GLOBAL across all AWS accounts, so pick${OFF}"
echo "  ${DIM}something unique (e.g. <project>-dumps-<account-id>). We create it if it doesn't${OFF}"
echo "  ${DIM}exist; if the name is taken by another account, you'll be asked for another.${OFF}"
# Resolve the bucket: re-prompt until it either exists (and you own it) or we
# create it. Surfaces the real AWS error so a 'BucketAlreadyExists' collision
# is explained, not swallowed.
if [ "$aws_ok" = true ]; then
  while true; do
    BUCKET="$(prompt_required "Dumps S3 bucket name")"
    [ -z "$BUCKET" ] && continue
    if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
      ok "bucket s3://$BUCKET already exists (yours) -- using it"
      break
    fi
    # Try to create. us-east-1 rejects LocationConstraint.
    if [ "$REGION" = "us-east-1" ]; then
      ERR="$(aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" 2>&1 >/dev/null || true)"
    else
      ERR="$(aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=$REGION" 2>&1 >/dev/null || true)"
    fi
    if [ -z "$ERR" ]; then
      ok "created bucket s3://$BUCKET"
      break
    fi
    warn "could not create bucket s3://$BUCKET:"
    printf '  %s\n' "$(echo "$ERR" | sed -e '/^$/d' -e 's/^[[:space:]]*//')" >&2
    case "$ERR" in
      *BucketAlreadyExists*|"*not available*")
        warn "that name is taken by another AWS account (S3 names are global). Pick a more unique name." ;;
      *AccessDenied*|*Forbidden*)
        warn "your IAM user lacks s3:CreateBucket permission. Use an existing bucket you own, or grant the permission." ;;
    esac
    warn "try again, or Ctrl-C to exit."
  done
else
  BUCKET="$(prompt_required "Dumps S3 bucket name")"
  warn "AWS not authenticated -- skipped bucket check. Ensure s3://$BUCKET exists before running run_all.sh."
fi

# ---- write config.yaml ----------------------------------------------------
# Build it from the example, substituting only the collected non-secret values.
# Secrets stay as ref:env: (already in the example).
EXAMPLE="$HERE/config.example.yaml"
# Only the basic-infra values are filled here. The Odoo core git_ref +
# custom addons repo are profile-level concerns (tied to a specific source DB),
# so they're blanked here and set per-profile via
# `odoo-synth profile create --odoo-git-ref ... --addons-git-url ...`.
python3 - "$EXAMPLE" "$CFG" "$REGION" "$PROJECT" "$BUCKET" <<'PY'
import sys, re
ex, out, region, project, bucket = sys.argv[1:6]
s = open(ex).read()
# Only install-time / control-plane values are filled here. Odoo provenance,
# addons, and DB credentials are downstream (profile/mask/env-time) and are NOT
# in config.example.yaml anymore, so there's nothing else to substitute.
s = re.sub(r'(?m)^(\s*region:\s*).*',       r'\g<1>'+region,  s, count=1)
s = re.sub(r'(?m)^(\s*project:\s*).*',      r'\g<1>'+project, s, count=1)
s = re.sub(r'(?m)^(\s*dumps_bucket:\s*).*', r'\g<1>'+bucket,  s, count=1)
open(out,'w').write(s)
print("wrote", out)
PY
ok "wrote $CFG"

# (bucket creation/re-prompt handled above, before config.yaml was written)
else  # SKIP_CONFIG
  BUCKET="$(python3 -c "import sys;sys.path.insert(0,'lib');from backend import config;print(config.get('DUMP_S3_BUCKET',''))" 2>/dev/null || echo '')"
  REGION="$(python3 -c "import sys;sys.path.insert(0,'lib');from backend import config;print(config.get('AWS_REGION',''))" 2>/dev/null || echo '')"
  step 4/7 "Collect configuration values (skipped -- keeping existing config.yaml)"
fi

# ===========================================================================
# 6. VALIDATE CONFIG
# ===========================================================================
step 5/7 "Validate config"
# Source secrets.env if it exists (the CLI auto-loads it, but
# deploy/00_validate_config.sh runs _yaml_to_env.py which resolves ref:env:
# from the current shell's env). It may not exist yet -- passwords are deferred
# to mask/env time, so this is best-effort.
if [ -f "$HERE/deploy/secrets.env" ]; then
  set -a; . "$HERE/deploy/secrets.env"; set +a
fi
VALID_OK=0
if bash deploy/00_validate_config.sh; then
  ok "config valid"
  VALID_OK=1
else
  warn "config validation reported issues (see above)."
  warn "Fix them (edit config.yaml / source secrets) and re-run this wizard."
  warn "You can skip provisioning for now and come back to it."
fi

echo
say "CLI smoke test:"
odoo-synth --help >/dev/null 2>&1 && ok "odoo-synth --help" || die "odoo-synth --help failed"
odoo-synth config  >/dev/null 2>&1 && ok "odoo-synth config"  || warn "odoo-synth config emitted warnings"
odoo-synth profile list >/dev/null 2>&1 && ok "odoo-synth profile list" || warn "profile list had issues"

# ===========================================================================
# 7. PROVISION BASIC INFRASTRUCTURE
# ===========================================================================
# Basic infra = ECR + the provenance-baked base Odoo image + the builder IAM
# role + the Coder server + the Coder templates. This is the one-time AWS
# provisioning that must exist before you can build/mask/env. Profiles (source
# bindings) are created AFTER this, on demand via the CLI.
step 6/7 "Provision basic infrastructure (ECR, base images, builder IAM, Coder server, templates)"
PROVISIONED=0
if [ "$VALID_OK" = 0 ]; then
  warn "config not valid -- skipping provisioning. Fix config and re-run."
else
  # Load any existing provisioning state so the handoff + coder-login step
  # can detect a prior deploy (even if the user skips re-provisioning here).
  [ -f "$HERE/deploy/state.env" ] && { set -a; . "$HERE/deploy/state.env"; set +a; }
  echo "  ${DIM}This provisions real AWS resources in your account (costs a few cents for${OFF}"
  echo "  ${DIM}the build + a t3.large Coder server while it runs). It takes ~10-20 min for${OFF}"
  echo "  ${DIM}the base Odoo image build. You can re-run it safely -- each step is idempotent.${OFF}"
  echo
  if confirm "Provision the basic infrastructure now?"; then
    # --- 7a. ECR + base images + golden AMI + IAM + Coder server ---
    say "7a/7c: ECR, base images, golden AMI, builder IAM, Coder server ..."
    # Order: ECR repos -> masker+discovery images -> builder IAM ->
    #        env-instance IAM + golden AMI (09, full bake: docker+buildx+
    #        awscli baked in so profile-time workspaces do zero provisioning) ->
    #        Coder server (needs ENV_INSTANCE_PROFILE for iam:PassRole) ->
    #        coder login -> publish templates.
    # The golden AMI bake is a one-time ~10-15 min install cost; it moves all
    # provisioning (docker, awscli, agent CLIs) out of per-workspace startup.
    INFRA_OK=0
    if bash deploy/01_ecr.sh            && bash deploy/02_build_push.sh --quiet            && bash deploy/10_builder.sh            && bash deploy/09_dev_env.sh            && bash deploy/11_coder_server.sh; then
      ok "basic infra provisioned (ECR, IAM, Coder server, templates)"
      set -a; . "$HERE/deploy/state.env"; set +a
      INFRA_OK=1
    else
      warn "a provisioning step failed (see logs above)."
      warn "fix it and re-run -- completed steps are idempotent."
      warn "skipping Coder login + template publish for now."
    fi

    # --- 7b. Coder login (headless first-admin + token persistence) ---
    # Only attempt Coder login + template publish if 7a succeeded. If the
    # chain failed (e.g. the golden AMI bake in 09_dev_env.sh died), CODER_URL
    # may still be in state.env from a prior run -- but the infra is not
    # complete, so publishing templates would give a false sense of success.
    # The user should fix the failed step and re-run.
    if [ "$INFRA_OK" = 1 ]; then
    echo
    say "7b/7c: Log into Coder"
    if [ -n "${CODER_URL:-}" ]; then
      echo "  The Coder server is up at ${BOLD}${CODER_URL}${OFF}."
      # The login logic lives in 11b_coder_login.sh so the wizard and run_all
      # share one implementation. On success it persists CODER_SESSION_TOKEN to
      # state.env; we re-source it so 7c sees the token.
      if bash deploy/11b_coder_login.sh; then
        set -a; . "$HERE/deploy/state.env"; set +a
      else
        warn "coder login did not complete (see above). You can run it manually later:"
        warn "    bash deploy/11b_coder_login.sh   ${DIM}# or: coder login $CODER_URL${OFF}"
      fi
    else
      warn "CODER_URL not in deploy/state.env -- did 11_coder_server.sh run? Skipping Coder login."
    fi

    # --- 7c. Publish the Coder templates (needs coder login) ---
    # This MUST run -- profile discover/build/mask shell out to `coder create
    # -t odoo-synth-discoverer` / `-t odoo-synth-masker` / `-t odoo-synth-builder`,
    # which 404 with "template not found" if that template was never published.
    # Never silently skip: if login produced no token, tell the operator
    # explicitly (and how to recover) instead of dropping the step.
    if [ -n "${CODER_URL:-}" ]; then
      echo
      say "7c/7c: Publish Coder templates"
      if [ -z "${CODER_SESSION_TOKEN:-}" ]; then
        warn "CODER_SESSION_TOKEN is not set -- coder login did not persist a token."
        warn "The workspacer/builder/discoverer/masker templates will NOT be"
        warn "published, so 'odoo-synth profile discover/build/mask' and"
        warn "'odoo-synth workspace create' will fail with 'template not found' until"
        warn "you publish them. To fix:"
        warn "    coder login $CODER_URL   ${DIM}# or set CODER_SESSION_TOKEN in deploy/state.env${OFF}"
        warn "    bash deploy/12_publish_template.sh"
      elif bash deploy/12_publish_template.sh --quiet; then
        ok "Coder templates published (odoo-synth-workspacer, odoo-synth-builder, odoo-synth-discoverer, odoo-synth-masker)"
        PROVISIONED=1
      else
        warn "template publish failed (see above). Run 'coder login $CODER_URL' then"
        warn "    bash deploy/12_publish_template.sh"
      fi
    else
      warn "CODER_URL not in deploy/state.env -- did 11_coder_server.sh run? Skipping template publish."
    fi
    fi  # INFRA_OK
  else
    warn "skipped provisioning. Run it later with:"
    warn "    bash deploy/run_all.sh   ${DIM}# or re-run this wizard${OFF}"
  fi
fi

# ===========================================================================
# 8. NEXT STEPS (profiles + on-demand ops)
# ===========================================================================
step 7/7 "What's left: create profiles and run"
# Detect existing provisioning from state.env (so a re-run that skips the
# provision prompt still reports the real state, not "not yet provisioned").
if [ "$PROVISIONED" = 0 ] && [ -n "${CODER_URL:-}" ]; then PROVISIONED=1; fi
cat <<NEXT

${BOLD}Basic infra:${OFF} $([ "$PROVISIONED" = 1 ] && echo "${GREEN}provisioned${OFF}" || echo "${YELLOW}not yet provisioned${OFF}").
The rest is on-demand via the odoo-synth CLI -- one profile per source Odoo DB,
then mask + launch dev environments from it.

${BOLD}1. Create a profile${OFF} (binds a source Odoo DB + its addons repo):
    odoo-synth profile create --label 'my-profile'
        --source-dsn 'postgresql://user:pass@host:5432/db'
        --odoo-series 17.0 --addons-git-url <url> --addons-git-ref <ref>
    odoo-synth profile list

${BOLD}2. Set DB/Odoo passwords${OFF} before your first mask/env run. Create
   ${DIM}deploy/secrets.env${OFF} (gitignored; auto-loaded by the CLI):
    ODOO_ADMIN_PASSWORD=...        # admin login on the masked DB
    ODOO_MASTER_PASSWORD=...       # Odoo DB manager pw in dev envs
    TARGET_DB_PASSWORD=...         # the ephemeral masked (target) DB
   (the source DB's password is supplied via --source-dsn on `profile
   create`/`update`, not a secrets.env var)

${BOLD}3. Mask${OFF} the source DB -> masked pg_dump in S3:
    odoo-synth profile mask <id> ...

${BOLD}4. Launch a dev workspace${OFF} (one Coder workspace per GitHub issue):
    odoo-synth workspace create --profile-id <id> --issue <num> --repo-url <url>

${BOLD}5. Pulled new discovery/masker code (e.g. discovery/*.py, masker/entrypoint.sh)?${OFF}
   \`git pull\` alone does NOT update what's running -- \`profile discover\`/
   \`profile mask\` pull a prebuilt image from ECR (tagged :latest), so a code
   change has no effect until you rebuild + push it:
    bash deploy/02_build_push.sh
   (odoo-synth-builder/-workspacer Coder templates are separate; republish
   those with deploy/12_publish_template.sh after changing their main.tf)

Re-run ${BOLD}bash deploy/00_setup.sh${OFF} anytime to reconfigure or re-provision.
NEXT
ok "done."
