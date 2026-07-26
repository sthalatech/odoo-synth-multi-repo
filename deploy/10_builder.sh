#!/usr/bin/env bash
# 10: ephemeral image-builder IAM (decision 1b).
#
# Provisions the IAM role + instance profile the control panel attaches to the
# throwaway EC2 instances that build per-profile provenance Odoo images:
#   * ECR push + pull (build & publish odoo:<profile>-<hash>)
#   * S3 get/put on the dumps bucket (download build context, upload result)
#   * ec2:TerminateInstances on self (the builder self-terminates when done)
# (The GitHub token for private addons clone is no longer an AWS secret -- it's
# a Coder user secret injected into the builder workspace env, so no Secrets
# Manager grant is needed for the git token.)
#
# The builder reuses the developer-environment AMI (docker preinstalled); no new
# AMI is baked. Writes BUILD_INSTANCE_PROFILE (+ reuses ENV_AMI_ID/SG/SUBNET) to
# deploy/state.env for the panel's build.* / environments.* config.
#
# Idempotent: re-running reuses the existing role + profile.
source "$(dirname "$0")/lib.sh"

BUILD_ROLE="${BUILD_ROLE:-$PROJECT-builder}"
BUILD_PROFILE="${BUILD_PROFILE:-$PROJECT-builder-instance}"
BUCKET="${DUMP_S3_BUCKET:-odoo-synth-dumps-$ACCOUNT_ID}"
PREFIX="${DUMP_S3_PREFIX:-masked-dumps}"
# build artifacts live in a sibling prefix under the same bucket
BUILD_PREFIX="$(dirname "$PREFIX")"; [ "$BUILD_PREFIX" = "." ] && BUILD_PREFIX="" || BUILD_PREFIX="$BUILD_PREFIX/"
ASSUME='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "$BUILD_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$BUILD_ROLE" \
    --assume-role-policy-document "$ASSUME" >/dev/null
  log "created role $BUILD_ROLE"
fi

POLICY_JSON="$(python3 - "$AWS_REGION" "$ACCOUNT_ID" "$BUCKET" "$PROJECT" <<'PY'
import json, sys
region, acct, bucket, project = sys.argv[1:5]
# Builder reads no AWS secrets: the git token is a Coder user secret. (Kept
# broad profile/env read in case future build-time secrets are added.)
secret_arns = [f"arn:aws:secretsmanager:{region}:{acct}:secret:{project}/profile/*",
               f"arn:aws:secretsmanager:{region}:{acct}:secret:{project}/env/*"]
doc = {
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "BuildArtifacts", "Effect": "Allow",
     "Action": ["s3:GetObject", "s3:PutObject"],
     "Resource": [f"arn:aws:s3:::{bucket}/*"]},
    {"Sid": "BuildSecrets", "Effect": "Allow",
     "Action": ["secretsmanager:GetSecretValue"],
     "Resource": secret_arns},
    {"Sid": "EcrAuth", "Effect": "Allow",
     "Action": ["ecr:GetAuthorizationToken"], "Resource": "*"},
    {"Sid": "EcrPushPull", "Effect": "Allow",
     "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
                "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload",
                "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
                "ecr:PutImage"],
     # Wildcarded to the whole project prefix, not just "<project>/odoo" --
     # multi-repo builds push to per-component repos created on the fly
     # (<project>/<component-name>, see build.py's _ensure_ecr_repo), so a
     # single fixed repo ARN here 403s on every one of those.
     "Resource": [f"arn:aws:ecr:{region}:{acct}:repository/{project}/*"]},
    {"Sid": "SelfTerminate", "Effect": "Allow",
     "Action": ["ec2:TerminateInstances"], "Resource": "*",
     "Condition": {"StringEquals": {"aws:ResourceTag/odoo-synth:managed": "true"}}},
  ],
}
print(json.dumps(doc))
PY
)"
aws iam put-role-policy --role-name "$BUILD_ROLE" \
  --policy-name "$PROJECT-builder-policy" \
  --policy-document "$POLICY_JSON" >/dev/null

if ! aws iam get-instance-profile --instance-profile-name "$BUILD_PROFILE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$BUILD_PROFILE" >/dev/null
fi
aws iam add-role-to-instance-profile --instance-profile-name "$BUILD_PROFILE" \
  --role-name "$BUILD_ROLE" >/dev/null 2>&1 || true

put_state BUILD_INSTANCE_PROFILE "$BUILD_PROFILE"
log "builder instance profile: $BUILD_PROFILE (role $BUILD_ROLE)"
log "done. The panel launches builders with this profile + the env AMI/SG/subnet."
