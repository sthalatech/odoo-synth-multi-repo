# odoo-synth

Production-masked Odoo dev environments on AWS. Takes a source Odoo DB, masks
the PII, bakes a provenance-tagged Odoo image, and launches isolated Coder
workspaces (one per GitHub issue) seeded from the masked dump.

```
prod DB ──mask──▶ masked pg_dump in S3 ──build──▶ ECR image ──env──▶ Coder workspace
```

## What's in this repo

| Path | Purpose |
|------|---------|
| `cli/odoo-synth` | The CLI. Calls the backend library directly (no HTTP). |
| `lib/backend/` | Python backend: profiles, runs, builds, environments, config loader. |
| `masker/` | Greenmask-based masking rules + profile YAMLs baked into the masker image. |
| `coder/templates/odoo-synth-workspacer/` | Coder template for developer workspaces. |
| `coder/templates/odoo-synth-builder/` | Coder template for ephemeral image-builder workspaces. |
| `coder/templates/odoo-synth-discoverer/` | Coder template for provenance discovery workspaces. |
| `coder/templates/odoo-synth-masker/` | Coder template for DB masking workspaces. |
| `odoo/` | Odoo image build context (Dockerfile, odoo.conf, entrypoint) + `enterprise.zip` (gitignored). |
| `deploy/` | Infra + provisioning scripts (ECR, base images, builder IAM, Coder server, templates). |
| `config.example.yaml` | Annotated config template. **Copy to `config.yaml` and fill in.** |
| `config.yaml` | The single source of truth for infra/defaults (gitignored — secrets). |
| `profiles/*.yaml` | One YAML file per profile (source binding + provenance + masking rules + image/S3 refs). Created by `profile create`. Gitignored — contains source hostnames + secret ARNs. |
| `deploy/state.env` | AWS resource ids/endpoints resolved by the deploy scripts (gitignored). |

## Quick start: run the CLI locally

You want this if the AWS stack is **already deployed** and you just want to run
`./cli/odoo-synth` from your machine against it. This installs local tools and
config only — it does **not** provision or modify any AWS infrastructure.

### Guided setup (recommended for first run)

`deploy/00_setup.sh` is an interactive wizard that walks you through every step:
installs prerequisites, sets up AWS auth, collects the values `config.yaml`
needs, generates the DB/Odoo passwords, writes `config.yaml` +
a gitignored `deploy/secrets.env`, then validates and smoke-tests the CLI.

```bash
bash deploy/00_setup.sh
```

Idempotent — re-run anytime; it keeps your existing config unless you choose to
overwrite. The manual steps below are the same flow spelled out in detail (use
them if you prefer to control each step, or to understand what the wizard does).

### Manual setup

#### 1. Install prerequisites

```bash
bash deploy/00_install_prereqs.sh
```

Idempotent. Installs only what's missing: AWS CLI v2, python3 + `pyyaml`/`boto3`,
and the Coder CLI. Docker is optional (only to pull/inspect built images locally).

### 2. Authenticate to AWS

```bash
aws configure          # interactive; writes ~/.aws/credentials
# OR
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_REGION=us-east-1
```

Verify: `aws sts get-caller-identity`

### 3. Create your config

```bash
cp config.example.yaml config.yaml
$EDITOR config.yaml      # fill in: aws.region, odoo.git_ref, addons.*,
                         # database passwords, odoo admin/master passwords,
                         # mask.dumps_bucket, coder.session_token
```

`config.yaml` is the single source of truth and is **gitignored** — never commit
real secrets. Any value can be delegated to an env var or SSM Parameter Store
via `{ ref: env:VAR }` or `{ ref: ssm:/path }` instead of inlining it.

### 4. Point at the existing deployment

Copy `deploy/state.env` from the deploy host. It carries the resolved AWS
resource ids (AMI, subnets, SGs, Coder URL, ECR repo, etc.) the CLI overlays on
`config.yaml`. **The CLI needs this to find the deployed resources.**
(`deploy/run_all.sh` writes it during a fresh deploy — see the next section.)

### 5. Log into Coder (for build / env / run commands)

```bash
coder login "$CODER_URL"     # sets CODER_URL + CODER_SESSION_TOKEN
```

Only needed for commands that talk to the Coder control plane
(`profile build`, `env *`, `run mask` via the Coder runner). `profile list`,
`run list`, `config` work without it.

### 6. (Optional) Enterprise addons

If a profile has `needs_enterprise: 1`, drop the Odoo Enterprise 17.0 addons
zip at `odoo/enterprise.zip` (gitignored, ~88MB). Without it, enterprise builds
proceed without enterprise and emit a NOTE.

### 7. Validate + run

```bash
bash deploy/00_validate_config.sh    # checks config + AWS auth + CLI tools
odoo-synth config                    # prints resolved infra summary
odoo-synth profile list              # smoke test
```

---

## Deploy the full pipeline to fresh AWS

You want this **only** if you're standing the stack up in an AWS account for the
first time (or rebuilding it). It provisions real infrastructure — ECR, VPC
security groups, the Coder server, etc. **Do not run this just to
use the CLI locally** — for that, use the Quick start above.

```bash
bash deploy/run_all.sh
```

Runs, in order: install prereqs → validate config → ECR → build+push base
Odoo image → builder IAM → Coder server →
publish the Coder templates (`odoo-synth-workspacer`, `odoo-synth-builder`,
`odoo-synth-discoverer`, `odoo-synth-masker`). It
writes `deploy/state.env` along the way, so afterwards you can run the CLI
locally using the Quick-start steps (skipping step 4 — state.env already
exists).

Requires `coder login` once (interactive) before the publish step.

## CLI overview

```bash
./cli/odoo-synth --help
./cli/odoo-synth profile --help        # source-binding profiles
./cli/odoo-synth run --help            # mask + build runs
./cli/odoo-synth workspace --help      # Coder workspaces
./cli/odoo-synth config                # resolved infra summary
```

### Install as a package (optional)

The CLI can also be installed as an editable package, which puts `odoo-synth`
on PATH and makes the `backend` library importable without a `sys.path` hack:

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -e .            # installs boto3/PyYAML + the odoo-synth console script
odoo-synth --help           # now on PATH
python -c "from backend import config"   # importable directly
```

The thin launcher at `cli/odoo-synth` and the `deploy/00_install_prereqs.sh`
symlink path keep working unchanged.

Long-running ops (`run mask`, `profile build`) run in the foreground and stream
logs to stdout. Bastion/SSH settings on a profile can be overridden per-run with
`--ssh-bastion` / `--ssh-key` / `--ssh-enabled` / `--no-ssh`.

## Config & secrets

- `config.yaml` — structured, the single source of truth. Documented in
  `config.example.yaml`.
- `deploy/state.env` — resolved AWS resource ids; written by the deploy scripts,
  gitignored.
- OS env vars override `config.yaml`/`state.env` (useful for CI or switching AWS
  profiles without editing files): `AWS_REGION`, `AWS_PROFILE`,
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `CODER_URL`,
  `CODER_SESSION_TOKEN`, `TARGET_DB_*`, `SOURCE_DB_*`.

Because this tool routinely handles production dumps and cloud credentials,
run a secret scanner (e.g. `gitleaks detect` or `git secrets --scan`) over your
working tree before your first commit in a new clone — see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Repository layout for builds

The Odoo Dockerfile (`odoo/Dockerfile`) bakes:
- Odoo core from `odoo.git_url` @ `odoo.git_ref`
- custom addons from `addons.custom_git_url` @ `custom_git_ref`
- enterprise addons from `odoo/enterprise.zip` (when `needs_enterprise=1`)

The builder workspace unzips `enterprise.zip` into `enterprise/` before
`docker build` (mirroring the legacy `deploy/02_build_push.sh`). The
`odoo-synth-builder` Coder template must be republished whenever
`coder/templates/odoo-synth-builder` changes — `deploy/12_publish_template.sh`
does this for both templates.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE). This repo orchestrates
third-party tooling (Odoo, Greenmask, Coder) under their own licenses; none of
it is redistributed here.
