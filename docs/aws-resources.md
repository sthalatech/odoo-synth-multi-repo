# AWS Resources Created by This Repo

Reference for the infra/DevOps team: every AWS resource this repo's deploy
scripts (`deploy/*.sh`) and Coder templates (`coder/templates/*/main.tf`)
create, in one place. Resource names below use `<project>` as a placeholder
for the `PROJECT` value in `config.yaml` (e.g. `odoosynth-multi`).

No VPC, subnet, NAT gateway, or internet gateway is created — everything
launches into the AWS account's **existing default VPC** and one of its
default (public) subnets. No RDS, ALB/ELB, Lambda, or CloudWatch resources
are created either.

---

## 1. Coder server (the control plane)

One persistent EC2 instance — the only always-on box this repo manages directly.

| Resource | Value | Created by |
|---|---|---|
| EC2 instance | `t3.small`, 20GB gp3 EBS root volume | `deploy/11_coder_server.sh` |
| Elastic IP | Allocated + associated to the instance (tag `Name=<project>-coder-eip`) | `deploy/11_coder_server.sh` |
| Security group | `<project>-coder-sg` | `deploy/11_coder_server.sh` |
| IAM role + instance profile | `<project>-coder-role` / `<project>-coder-profile` | `deploy/11_coder_server.sh` |

**Security group `<project>-coder-sg` inbound rules:**
| Port | Source | Purpose |
|---|---|---|
| 8943/tcp | `0.0.0.0/0` | Coder dashboard/API + workspace agent tunnel (plain HTTP) |
| 22/tcp | Caller's IP at the time the script last ran (`/32`) | Ops SSH access |
| 80/tcp | `0.0.0.0/0` | Let's Encrypt HTTP-01 challenge (opened by `deploy/14_caddy_https.sh`) |
| 443/tcp | `0.0.0.0/0` | HTTPS — Caddy reverse proxy (opened by `deploy/14_caddy_https.sh`) |

The instance has **no persisted SSH keypair** — access is via EC2 Instance
Connect (`ec2-instance-connect:SendSSHPublicKey`), not a stored `.pem` key.

**IAM role `<project>-coder-role` grants:** EC2 instance lifecycle
(run/stop/start/terminate/describe/tag) so it can launch workspace VMs via
Terraform; `iam:PassRole` on the env + builder instance roles below;
`ssm:GetParameters` (AMI lookups).

**What runs on it:** the `coder server` binary + its bundled PostgreSQL
(all workspace/profile/run state lives in this one Postgres instance — no
managed RDS), and (once `deploy/14_caddy_https.sh` has run) Caddy, terminating
HTTPS for the dashboard and every workspace app tile.

---

## 2. Golden AMI (shared base image for every workspace type)

| Resource | Value | Created by |
|---|---|---|
| Temporary builder EC2 instance | `t3.large`, 30GB gp3 EBS, **terminated** after imaging | `deploy/09_dev_env.sh` |
| AMI | `<project>-devenv-<UTC timestamp>` (Ubuntu 22.04 + Docker + AWS CLI + agent CLIs baked in — **not** Odoo itself) | `deploy/09_dev_env.sh` |

Re-running with `--rebake` produces a **new** AMI + underlying EBS snapshot;
old ones are **not automatically deleted** — worth a periodic cleanup pass
for storage cost.

This one AMI is the base image for all four Coder templates below (Odoo is
installed per-profile at workspace boot, not baked into the AMI).

---

## 3. Shared environment infra (used by workspace/discoverer/masker/builder instances)

| Resource | Value | Created by |
|---|---|---|
| Security group | `<project>-env-sg` — **egress-only, zero inbound rules** (Coder's own tunnel brokers all access; instances need no public ingress) | `deploy/09_dev_env.sh` |
| IAM role + instance profile | `<project>-env-instance` | `deploy/09_dev_env.sh` |
| IAM role + instance profile | `<project>-builder-instance` (`<project>-builder` role) | `deploy/10_builder.sh` |

**`<project>-env-instance` grants:** S3 read on the dumps bucket's
`masked-dumps/*` prefix, Secrets Manager read on `<project>/env/*` and
`<project>/profile/*`, ECR pull on `<project>/*` repos.

**`<project>-builder-instance` grants:** S3 read/write on the whole dumps
bucket, Secrets Manager read (same paths), ECR push/pull on `<project>/*`,
and `ec2:TerminateInstances` scoped to `odoo-synth:managed=true`-tagged
instances (used for the builder's own self-terminate).

---

## 4. Coder-launched workspace instances (per Terraform template)

Each of the 4 Coder templates launches **one EC2 instance per workspace**,
using the shared golden AMI above, with a dynamic (non-Elastic) public IP —
these are meant to be short-lived/disposable, so no EIP is allocated for
them.

| Template | Purpose | Default instance type | IAM profile | Lifetime |
|---|---|---|---|---|
| `odoo-synth-workspacer` | The actual developer workspace (Odoo + all multi-repo components) | `t3.large` | `<project>-env-instance` | Persistent — runs until the developer/Coder stops or deletes it |
| `odoo-synth-builder` | Builds the per-profile Odoo image, pushes to ECR | `m5.xlarge` | `<project>-builder-instance` | Transient — self-terminates when the build finishes |
| `odoo-synth-discoverer` | Scans the source DB schema, proposes a masking plan | `m5.large` | `<project>-env-instance` | Transient — self-terminates when discovery finishes |
| `odoo-synth-masker` | Runs greenmask, produces the masked dump | `m5.large` | `<project>-env-instance` | Transient — self-terminates when the mask run finishes |

All four use the same `<project>-env-sg` (egress-only) and the same golden
AMI (~30GB gp3 root volume, inherited from the AMI). Every instance type
above is a `coder_parameter`, overridable per workspace/run at create time.

---

## 5. Inside a workspacer instance: the multi-repo components

**One EC2 instance runs everything below** — these are Docker containers
and OS processes on that single box, not separate AWS resources. No
per-container CPU/memory limits are configured anywhere in this repo — all
containers share the instance's full capacity (default `t3.large` = 2 vCPU /
8GB RAM), gated only by the instance type chosen above.

| Component | Runs as | Image / runtime | Approx. size | Notes |
|---|---|---|---|---|
| Odoo | Docker container (`env-odoo`) | `<project>/odoo:<profile>-<hash>` — custom-built per profile from the pinned Odoo git ref + custom addons | Varies per profile/addon set (not fixed) | Built by `odoo-synth-builder`, pushed to ECR |
| Postgres | Docker container (`env-db`) | `postgres:16` (official image) | ~400MB | Odoo's database; seeded from the masked dump |
| Redis | Docker container (`dep-redis`) | `redis:7-alpine` (official image) | ~40MB | Current profile config; dependency kind is config-driven, not fixed |
| facade | Docker container | `<project>/facade:<profile>-<hash>` — built from that repo's own `Dockerfile` | Varies (not fixed) | `uvicorn`-served Python app |
| worker | Docker container | `<project>/worker:<profile>-<hash>` — built from that repo's own `Dockerfile` | Varies (not fixed) | Celery worker + beat + flower in one container |
| frontend | **Not a container** — a `yarn`/Vite process running directly on the VM | N/A | N/A | `process`-kind component; no Docker image at all |
| admin-frontend | **Not a container** — a `pnpm`/Next.js process running directly on the VM | N/A | N/A | Same as above |

Image sizes for the custom-built components (odoo/facade/worker) aren't
fixed values — each is rebuilt per profile from that repo's own
dependencies, so size varies with whatever the source repos pull in.

---

## 6. Storage, images, and secrets

| Resource | Naming | Created by |
|---|---|---|
| S3 bucket | Operator-chosen name (e.g. `<project>-dumps-<account-id>`) | `deploy/00_setup.sh` (guided) |
| ECR repo | `<project>/masker` | `deploy/01_ecr.sh` |
| ECR repo | `<project>/discovery` | `deploy/01_ecr.sh` |
| ECR repo | `<project>/odoo` | `deploy/01_ecr.sh` |
| ECR repo | `<project>/<component-name>` — one per `docker`-kind multi-repo component, e.g. `<project>/facade`, `<project>/worker` | Created on-the-fly on first build (`lib/backend/build.py`) |
| Secrets Manager secret | `<project>/profile/<profile_id>/source-password` | `lib/backend/profiles.py` (profile create/update, if a source DB password is set) |
| Secrets Manager secret | `<project>/profile/<profile_id>/ssh-key` | Same (if an SSH bastion key is set) |
| Secrets Manager secret | `<project>/env/<env_id>/password` | `lib/backend/environments.py` (per workspace, the Odoo admin password) |

The S3 bucket holds: source dump uploads, masked dump artifacts
(`masked-dumps/` prefix), discovery-plan JSON output, and per-profile build
artifacts (a sibling prefix). Deleting a profile or workspace deletes its
associated secret(s); it does **not** delete S3 objects.

A GitHub personal-access token for private addons repos is **not** an AWS
Secrets Manager secret — it's a Coder-native user secret, stored in Coder's
own Postgres on the control-plane instance, not a separate AWS resource.

---

## 7. DNS / TLS

**No Route 53 hosted zone or AWS Certificate Manager certificate is created
by this repo.** By default, HTTPS uses [nip.io](https://nip.io) (a
third-party wildcard-DNS service, not an AWS resource) plus Caddy's
automatic/on-demand Let's Encrypt issuance, running as a systemd service on
the Coder server instance itself (see §1). See `deploy/14_caddy_https.sh`
and the `PUBLIC_DOMAIN`/`PUBLIC_SCHEME` values in `deploy/state.env` if/when
this moves to a real domain (Cloudflare or otherwise).

---

## Resource-tag conventions

Everything this repo creates in EC2 is tagged `odoo-synth:managed=true`
(the Coder server additionally gets `odoo-synth:control-plane=true`) — a
useful filter for a cost/cleanup audit:

```bash
aws ec2 describe-instances --filters "Name=tag:odoo-synth:managed,Values=true"
aws ec2 describe-images --owners self --filters "Name=tag:odoo-synth:managed,Values=true"
aws ec2 describe-addresses --filters "Name=tag:odoo-synth:managed,Values=true"
```
