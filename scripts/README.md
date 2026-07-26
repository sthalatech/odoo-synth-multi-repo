# scripts/ — issue -> env + agent

Two pieces that turn a GitHub issue (opened in a **profile's addons repo**)
into a running odoo-synth workspace with an AI agent working on it:

1. `webhook_listener.py` — a Flask app that **runs on the Coder server**
   (the always-on control plane), receives GitHub `issues` webhooks, verifies
   the HMAC signature, and launches the runner.
2. `issue_to_env.py` — the host-agnostic launcher: matches the issue's repo URL
   to an odoo-synth profile (the latest preset for that repo) -> creates a Coder
   env from the profile's latest mask run -> labels it `iss-<n>-<slug>` -> drives
   the agent (opencode/claude-code, driven by superpowers) with the issue
   details + per-profile system prompt.

## Design (why the Coder server, not a dev VM)

```
   GitHub issue opened                Coder server (always-on EC2)
   in the addons repo   ──webhook──▶  webhook_listener.py (port 8080, public)
   (e.g. your-addons-repo)                │
                                          │ issue.opened  -> issue_to_env.py (create + agent)
                                          │ issue.closed  -> issue_to_env.py --teardown (delete ws)
                                          ▼
                                     match repo URL -> profile (S3)   [opened]
                                     latest mask run -> `coder create`
                                     wait -> agent (opencode/claude-code) via superpowers
                                     ── or [closed] ──
                                     match (repo, issue #) -> `coder delete` (frees EC2)
```

- The Coder server is the only always-on box; a dev VM is ephemeral, so a
  webhook must not land on a dev VM.
- The Coder server already holds `CODER_URL` + `CODER_SESSION_TOKEN` and can
  reach `coder create` on localhost.
- Its AWS role has access to the dumps bucket, so it reads the **S3-backed
  profile + run stores** (the preset resolver) without this dev VM being up.
- The "latest preset for that repo" is resolved from the profile store (S3),
  not the Coder preset API — `coder_workspace_preset` is a Terraform-side
  dashboard construct that does not surface as an API resource, so we resolve
  presets ourselves by repo-URL match + newest successful mask run.

## Flow in detail (matches the 6 requirements)

1. **Issue -> env, preset matched from repo URL.** `issue_to_env.py`
   normalizes the issue's repo URL (`git@...` and `https://...` both ->
   `host/org/repo`) and matches it to a profile's `addons_git_url`. It then
   creates the env from that profile's latest successful **mask run** (the
   masked dump). This is the same inputs the Coder dashboard preset carries.
2. **Label with issue # + short name.** Coder workspace name =
   `iss-<number>-<short-title-slug>` (e.g. `iss-42-fix-login-500`).
3. **Invoke opencode in the env with issue details.** `wait_for_env` polls the
   build to `running`, then `run_agent` runs
   `opencode run "<task>"` (or `claude -p "<task>"`) over `coder ssh`, the
   task being the issue title/body/URL **plus a prescriptive workflow** (see
   `_build_task` in `issue_to_env.py`): read `AGENT_CONTEXT.md`/`AGENT.md`
   first, implement, verify with headless Chrome + capture a screenshot, then commit
   on a new branch, push, and `gh pr create --base <pr_base>`. The PR base
   comes from the profile (`pr_base`, default `uat`) so each repo lands on its
   own integration branch. A wall-clock timeout caps cost.
4. **superpowers attached.** superpowers (the agentic-skills plugin baked
   into the golden AMI) loads inside the agent's session and drives it
   autonomously: brainstorm -> plan -> git-worktree -> TDD subagent dev ->
   review -> finish branch (merge/PR). The agent + system prompt come from the
   matched profile (per-preset config), with env-var / global-file fallbacks.
   Note: superpowers' brainstorming checklist ends at "transition to
   implementation" and does NOT itself include commit/push/PR, so the task
   string (step 3) makes the finish step explicit — that was the root cause of
   the agent stopping after "verify changes" with no commit/push/PR.
5. **System prompt provision (Phase 1).**
   `coder/templates/odoo-synth-workspacer/agent-system-prompt.md` is the placeholder,
   staged into the env as `AGENT_CONTEXT.md` and (if the repo ships none)
   `AGENT.md` in the repo cwd so the agent follows the project context.
6. **Post-launch module upgrade, generic for any repo.** The template's
   `odoo-bin -u all` is now `-u $UPGRADE_MODULES` (defaults to `all`). The
   hook passes the profile's discovered `installed_modules`, so the
   schema-reconcile is scoped per repo, not hardcoded to one.

## Deploy (one-time, from a host with AWS access)

```bash
deploy/13_webhook_listener.sh --secret <GITHUB_WEBHOOK_SECRET> [--port 8080]
```

This opens a 2nd inbound port on the Coder SG, ships the repo to the Coder
server over SSH, installs `webhook_listener.py` as a systemd service, and writes
`GITHUB_WEBHOOK_SECRET` to `/etc/odoo-synth/webhook.env`.

Then in the **addons repo** (the profile repo, e.g. `your-addons-repo`):
Settings -> Webhooks -> Add webhook:
- Payload URL: `http://<CODER_SERVER_IP>:8080/webhook`
- Content type: `application/json`
- Events: **Issues**
- Secret: the same `GITHUB_WEBHOOK_SECRET`

Manage on the Coder server:
```bash
ssh ubuntu@<CODER_SERVER_IP>
systemctl status odoo-synth-webhook
journalctl -u odoo-synth-webhook -f
```

## Config (`config.yaml`, optional)

```yaml
github:
  webhook_secret: { ref: env:GITHUB_WEBHOOK_SECRET }  # or a literal
  # webhook_secret_env: GITHUB_WEBHOOK_SECRET  # alt: name an env var
```

If unset, `deploy/13_webhook_listener.sh --secret ...` sets it directly on the
server; the service is fail-closed (rejects all POSTs) until a secret exists.

## Teardown on issue close

The same webhook also handles `issues.closed`: it runs
`issue_to_env.py --teardown`, which matches the env record(s) by **(repo, issue
number)** and deletes the Coder workspace for that issue — freeing the EC2
instance so closed issues don't keep a dev env running. The linkage is exact:
the launcher wrote the env record with the issue's repo URL + `#N`, so
teardown only ever deletes the workspace created for *that* issue in *that*
repo, never another issue's. It's idempotent (no-match = benign no-op;
already-terminated envs just drop their stale store record). Manual form:

```bash
ISSUE_NUMBER=492 ISSUE_REPO_URL=https://github.com/your-org/your-addons-repo \
  .venv/bin/python3 scripts/issue_to_env.py --teardown
```

## Manual / CLI use (same primitives, ad-hoc)

```bash
# set the PR base branch once per profile (default uat); the issue launcher
# tells the agent to `gh pr create --base <pr_base>` against it
odoo-synth profile update <profile_id> --pr-base uat

odoo-synth workspace create --profile-id <id> --source-run-id <run> \
  --issue "#42" --name iss-42-fix-login --upgrade-modules "module_a,module_b"
odoo-synth workspace wait <workspace_id> --timeout 1200
odoo-synth workspace agent <workspace_id> "Resolve #42: fix the login 500" --agent opencode --issue "#42"
```

`scripts/issue_to_env.py` is also runnable standalone with env vars
(`ISSUE_NUMBER`, `ISSUE_TITLE`, `ISSUE_BODY`, `ISSUE_URL`, `ISSUE_REPO_URL`,
`ODOO_SYNTH_AGENT`, `ODOO_SYNTH_MAX_ITER`, `ODOO_SYNTH_UPGRADE_MODULES`,
`ODOO_SYNTH_BRANCH_HINT`) — that's exactly what the listener spawns.

## Exit codes (issue_to_env.py)

`0` env + agent launched (or teardown OK / nothing to tear down) · `1` no
matching profile/dump (open) / missing `ISSUE_REPO_URL`+`ISSUE_NUMBER`
(teardown) · `2` env create failed · `3` env not running in time · `4` agent
launch failed · `5` teardown of at least one env failed (others may have
succeeded).
