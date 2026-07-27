# odoo-synth-workspacer

A developer environment running Odoo against a masked copy of a production
database, with an addons repo live-mounted for development.

## What you get

- **Odoo** (image-baked addons) on `127.0.0.1:8069`, hydrated from a masked
  dump into a **local Postgres 16** container (`env-db`).
- **Your addons repo** cloned to `/home/dev/workspace/repo` and bind-mounted
  into Odoo at `/mnt/live` (read-write). Edit on the host; restart Odoo to
  reload.
- An **Env Guide** app on the workspace page with all commands and locations.
- **AI coding agents** baked into the AMI and exposed as workspace apps:
  - **Claude Code** — `claude` (Anthropic). Served as a web terminal app.
    Set your Coder user secret `anthropic-api-key` (env `ANTHROPIC_API_KEY`)
    and it's auto-injected into every workspace you own.
  - **OpenCode** — `opencode` (open-source agent). Served as a web terminal
    app; configure a provider with `opencode auth`.
  - **Ralph Wiggum** — `ralph`, an autonomous agentic loop over any of the
    agents above: e.g. `ralph "fix the login 500" --agent claude-code
    --max-iterations 10`.

## Create with the preset

The default preset **"Latest masked profile"** pre-fills the Odoo image, the
masked dump URI, and the addons repo + ref from your profile store. Click
**Create** and the env hydrates and serves Odoo automatically.

## Parameters you must supply

- `repo_url` *(required)* — git URL of your addons repo. Use an **SSH URL**
  (`git@github.com:org/repo.git`) to authenticate with **your own Coder SSH
  key** — the workspace agent injects `$GIT_SSH_COMMAND` so private repos you
  have access to clone with no stored token. (Add your Coder public key to
  GitHub as a deploy/user key — see your Coder user settings -> "Git
  authentication".) An HTTPS URL also works but then needs a GitHub token.
- `repo_branch` *(required)* — branch / tag / commit to check out.
- `git_token_env` *(optional)* — only used when `repo_url` is HTTPS. The name
  of the Coder user secret env var holding a GitHub token for cloning a private
  HTTPS repo (e.g. `GH_PAT_PROF_749C8A90`). Set on the profile via
  `odoo-synth profile create --git-token <PAT>`; Coder injects it into the
  workspace. SSH URLs ignore this and use your Coder key instead.
- `odoo_image`, `dump_s3_uri` — the preset fills these; override only if you
  know what you're doing.

## Once it's running

Open the **Env Guide** app on the workspace page — it documents containers,
repo mount, how to start/stop Odoo, how to reach Postgres, where the logs are,
and how to retrieve your passwords from env vars (passwords are never printed
in the guide). Quick reference:

```bash
docker logs -f env-odoo                      # Odoo logs
docker exec -it env-db psql -U odoo -d odoo  # Postgres shell
docker restart env-odoo                      # reload addons
echo "$CODER_ENV_ADMIN_PASSWORD"             # Odoo admin pw
```

Odoo admin login is `admin`. The DB volume persists across workspace
stop/start; the masked dump is restored only on first boot, so your in-progress
data is kept on restart.
