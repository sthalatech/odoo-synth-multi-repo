#!/usr/bin/env bash
# Launch a synthetic "source DB" for testing profile discover/build/mask when
# the real customer DB is unreachable. Restores a masked dump from the dev
# account's S3 bucket into a Postgres 16 container on a t3.medium EC2 in the
# default VPC, opens 5432 to the VPC CIDR (so Coder runner workspaces in the
# same VPC can reach it via private IP), and prints a ready-to-use --source-dsn.
#
# Usage:
#   scripts/launch_synthetic_source_db.sh                       # smallest dump
#   scripts/launch_synthetic_source_db.sh <s3://bucket/path>    # specific dump
#
# Tears down with: scripts/launch_synthetic_source_db.sh --teardown
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-odoo-synth}"
AMI="${ENV_AMI_ID:-ami-020f580da88780fd1}"      # golden AMI (docker+awscli baked in)
INSTANCE_TYPE="t3.medium"
DUMP_BUCKET="odoo-synth-dumps-676206949426"
DEFAULT_DUMP="s3://${DUMP_BUCKET}/masked-dumps/40e095c4fca3/masked.dump"  # 69 MB, smallest
NAME="odoo-synth-synthdb"
TAG="Resource=odoo-synth-synthdb"

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ "${1:-}" == "--teardown" ]]; then
  IID=$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || true)
  if [[ -z "$IID" || "$IID" == "None" ]]; then echo "no running $NAME instance"; exit 0; fi
  # --query ... --output text tab-separates MULTIPLE matches on one line --
  # passing that as a single quoted --instance-ids value is malformed (AWS
  # CLI wants each id as its own argument). Word-split into an array instead
  # (tabs/newlines/spaces are all IFS whitespace), so a teardown after
  # several launches terminates every one of them, not just fail outright.
  read -ra IID_ARR <<< "$IID"
  echo "terminating ${IID_ARR[*]} ..."
  aws ec2 terminate-instances --region "$REGION" --instance-ids "${IID_ARR[@]}" --query "TerminatingInstances[].InstanceId" --output table
  # SG
  SG_ID=$(aws ec2 describe-security-groups --region "$REGION" --group-names "${NAME}-sg" \
          --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
  if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
    aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null && echo "deleted SG $SG_ID" || echo "(SG $SG_ID left; may be in use)"
  fi
  echo "teardown done."
  exit 0
fi

DUMP_S3="${1:-$DEFAULT_DUMP}"
echo "==> synthetic source DB"
echo "    region: $REGION | ami: $AMI | type: $INSTANCE_TYPE"
echo "    dump:   $DUMP_S3"

# --- VPC / subnet / SG ---
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
VPC_CIDR=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=isDefault,Values=true" --query "Vpcs[0].CidrBlock" --output text)
SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" "Name=defaultForAz,Values=true" --query "Subnets[0].SubnetId" --output text)
echo "    vpc: $VPC_ID ($VPC_CIDR) | subnet: $SUBNET_ID"

SG_ID=$(aws ec2 describe-security-groups --region "$REGION" --group-names "${NAME}-sg" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  SG_ID=$(aws ec2 create-security-group --region "$REGION" \
          --group-name "${NAME}-sg" --description "synthetic source DB for odoo-synth testing" \
          --vpc-id "$VPC_ID" --query "GroupId" --output text)
  # 5432 from the VPC (runner workspaces live here) + SSH from anywhere (for debugging)
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=$VPC_CIDR}]" >/dev/null
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}]" >/dev/null
fi
echo "    sg: $SG_ID (5432 from $VPC_CIDR, 22 from anywhere)"

# --- keypair (reuse existing or create) ---
KEY_NAME="${NAME}-key"
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
if ! aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
    --query "KeyMaterial" --output text > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
fi

# --- launch ---
IID=$(aws ec2 run-instances --region "$REGION" \
      --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
      --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" \
      --security-group-ids "$SG_ID" --associate-public-ip-address \
      --iam-instance-profile "Name=odoo-synth-env-instance" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
      --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3}" \
      --query "Instances[0].InstanceId" --output text)
echo "    instance: $IID (launching ...)"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"

PRIV_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
          --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
PUB_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
         --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
echo "    private ip: $PRIV_IP | public ip: $PUB_IP"

# --- wait for SSH ---
echo "==> waiting for SSH ..."
for i in $(seq 1 60); do
  if ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
       "ubuntu@$PUB_IP" "true" 2>/dev/null; then break; fi
  sleep 5
done
SSH=(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "ubuntu@$PUB_IP")

# --- provision: postgres 16 in docker, create DB+user, restore dump ---
echo "==> provisioning Postgres 16 + restoring dump (this takes a few minutes) ..."
"${SSH[@]}" "DUMP_S3='$DUMP_S3' bash -s" <<'REMOTE'
set -euo pipefail
echo "[remote] waiting for docker ..."
for i in $(seq 1 60); do command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1 && break; sleep 3; done
echo "[remote] starting postgres:16 container ..."
sudo docker rm -f synthdb >/dev/null 2>&1 || true
sudo docker run -d --name synthdb -p 5432:5432 \
  -e POSTGRES_PASSWORD=runner -e POSTGRES_USER=runner -e POSTGRES_DB=postgres \
  -v /var/lib/synthdb:/var/lib/postgresql/data \
  postgres:16 >/dev/null
echo "[remote] waiting for postgres ready ..."
for i in $(seq 1 60); do sudo docker exec synthdb pg_isready -U runner >/dev/null 2>&1 && break; sleep 2; done
echo "[remote] creating masked DB ..."
sudo docker exec -e PGPASSWORD=runner synthdb psql -U runner -d postgres -c "CREATE DATABASE masked OWNER runner;" >/dev/null
echo "[remote] downloading masked dump from S3: $DUMP_S3 ..."
aws s3 cp "$DUMP_S3" /tmp/masked.dump --region us-east-1 >/dev/null
echo "[remote] restoring (pg_restore) ..."
sudo docker exec -i -e PGPASSWORD=runner synthdb pg_restore -U runner -d masked --no-owner --no-acl < /tmp/masked.dump || true
sudo docker exec -e PGPASSWORD=runner synthdb psql -U runner -d masked -c "SELECT count(*) AS partners FROM res_partner;" 2>/dev/null || \
  sudo docker exec -e PGPASSWORD=runner synthdb psql -U runner -d masked -c "\dt" | head -20
echo "[remote] done."
REMOTE

echo ""
echo "=============================================================="
echo " SYNTHETIC SOURCE DB READY"
echo "=============================================================="
echo " private ip : $PRIV_IP   (use this in --source-dsn; runner EC2 reaches it)"
echo " public ip  : $PUB_IP    (for SSH debugging: ssh -i $KEY_FILE ubuntu@$PUB_IP)"
echo " credentials: user=runner password=runner db=masked port=5432"
echo ""
echo " Create a profile on the test VM pointing at it:"
echo "   odoo-synth profile create \\"
echo "     --label 'Synthetic Source' \\"
echo "     --odoo-series 17.0 --odoo-git-ref 17.0 \\"
echo "     --addons-git-url https://github.com/odoo/odoo --addons-git-ref 17.0 \\"
echo "     --no-ssh \\"
echo "     --source-dsn postgresql://runner:runner@$PRIV_IP:5432/masked \\"
echo "     --git-token ghp_..."
echo ""
echo " Then:  odoo-synth profile discover <profile_id>"
echo ""
echo " Tear down when done:"
echo "   scripts/launch_synthetic_source_db.sh --teardown"
