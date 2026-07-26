#!/usr/bin/env python3
"""GitHub issue -> odoo-synth environment + AI agent launcher.

Invoked by .github/workflows/issue-env.yml on the `issues` webhook (opened).
It:

  1. Matches the issue's repo URL to an odoo-synth *profile* whose addons repo
     is the same, picks the profile's latest successful mask run (masked dump),
     and creates a Coder environment from it. This matches the env template
     preset the Coder dashboard would offer for that repo.
  2. Labels the env with the issue # + a short slug of the issue title
     (the Coder workspace name, e.g. `iss-42-fix-login-500`).
  3. Waits for the env to reach running, then invokes the agent headlessly
     inside it (opencode run / claude -p), passing the issue details as the
     task and the project system prompt as context. The agent + system prompt
     come from the matched profile (per-preset config), with env-var / global-
     file fallbacks.
  4. superpowers (the agentic-skills plugin baked into the golden AMI) loads
     inside the agent's session and drives it autonomously through the task
     (brainstorm -> plan -> git-worktree -> TDD -> review -> finish branch/PR).
     The env startup script stages the per-profile prompt as AGENT_CONTEXT.md /
     AGENT.md; this launcher overlays the issue/task specifics.

Inputs come from env vars set by the workflow:
  ISSUE_NUMBER, ISSUE_TITLE, ISSUE_BODY, ISSUE_URL, ISSUE_REPO_URL,
  ODOO_SYNTH_AGENT (default opencode; profile.agent_name wins when set),
  ODOO_SYNTH_MAX_ITER (kept for compat; the agent self-drives via superpowers),
  ODOO_SYNTH_AGENT_TIMEOUT (wall-clock cost guard, default 3600s),
  ODOO_SYNTH_BRANCH_HINT (optional repo branch override; else profile ref).

Exit codes: 0 = env created + agent launched; 1 = no matching profile; 2 = env
create failed; 3 = env did not become running; 4 = agent launch failed.
"""
from __future__ import annotations
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "lib"))

from backend import config, environments, store  # noqa: E402


def _log(msg: str) -> None:
    print(f"[issue-to-env] {msg}", flush=True)


def _normalize_repo(url: str) -> str:
    """Normalize a git URL for matching: lowercase, strip scheme/user/token/.git,
    trailing slash. `git@github.com:org/repo.git` and
    `https://github.com/org/repo` both -> `github.com/org/repo`."""
    if not url:
        return ""
    u = url.strip()
    if u.startswith("git@") or u.startswith("ssh://"):
        # git@github.com:org/repo(.git)  ->  github.com/org/repo
        u = re.sub(r"^(git@|ssh://)", "", u)
        u = u.replace(":", "/", 1)
    # strip any embedded creds (https://user:token@host/...)
    parts = urlsplit(u)
    host_path = (parts.netloc + parts.path) if parts.scheme else u
    host_path = host_path.split("@")[-1]  # drop user@ if present
    host_path = host_path.rstrip("/")
    if host_path.endswith(".git"):
        host_path = host_path[:-4]
    return host_path.lower()


def _short_slug(title: str, maxlen: int = 24) -> str:
    """Coerce an issue title into a short url-safe slug for the workspace name."""
    s = (title or "").strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    if not s:
        s = "task"
    if len(s) > maxlen:
        s = s[:maxlen].rstrip("-")
    return s or "task"


def _workspace_label(issue_number: str, title: str) -> str:
    """issue # + short name, e.g. `iss-42-fix-login-500`."""
    n = re.sub(r"[^0-9]", "", issue_number or "")
    return f"iss-{n or 'x'}-{_short_slug(title)}"


def _envs_for_issue(repo_url: str, issue_number: str) -> list[dict]:
    """Find every env record whose repo + issue match `issue_number` in
    `repo_url`. The linkage key is (normalized repo, issue number) -- the same
    pair the launcher wrote when it created the env -- so teardown hits only
    the workspace(s) for THIS issue in THIS repo, never another issue's.

    Returns the env records (newest first). An issue may have more than one if
    it was reopened/re-launched (each launch is a separate env record); each is
    a distinct Coder workspace named iss-<n>-<slug>, all torn down here.
    """
    n = re.sub(r"[^0-9]", "", issue_number or "")
    if not n:
        return []
    target_repo = _normalize_repo(repo_url)
    # the launcher stores issue as "#492" (issue_ref); match the bare number so
    # the comparison is robust to the leading '#'/formatting.
    out = []
    for e in store.list_environments(limit=500):
        e_repo = _normalize_repo(e.get("repo_url") or "")
        e_issue = re.sub(r"[^0-9]", "", str(e.get("issue") or ""))
        # repo match: prefer the stored repo_url; fall back to the matched
        # profile's addons repo when the env record predates repo_url storage.
        if not e_repo:
            pid = e.get("profile_id")
            if pid:
                prof = store.get_profile(pid) or {}
                e_repo = _normalize_repo(prof.get("addons_git_url") or "")
        if target_repo and e_repo and e_repo != target_repo:
            continue
        if e_issue == n:
            out.append(e)
    out.sort(key=lambda x: x.get("created_at", 0), reverse=True)
    return out


def teardown_for_issue(repo_url: str, issue_number: str) -> int:
    """Tear down the Coder workspace(s) for a closed issue. Idempotent + safe:
    matches envs by (repo, issue number) so only THIS issue's workspace(s) are
    deleted; other issues' envs are untouched. Returns 0 on success (including
    the no-match case, which is a benign "nothing to do")."""
    envs = _envs_for_issue(repo_url, issue_number)
    if not envs:
        _log(f"close #{issue_number}: no env found for repo {_normalize_repo(repo_url)}; nothing to tear down")
        return 0
    _log(f"close #{issue_number}: tearing down {len(envs)} env(s) for repo {_normalize_repo(repo_url)}")
    rc = 0
    for e in envs:
        env_id = e["id"]
        name = e.get("workspace_name") or env_id
        st = e.get("status") or ""
        # already-terminated envs have no live Coder workspace; skip the API
        # call (it would 404) but still drop the stale store record.
        if st in ("terminated", "deleted"):
            _log(f"  env {env_id} ({name}) already {st}; dropping stale record")
            store.delete_environment(env_id)
            continue
        try:
            _log(f"  tearing down env {env_id} (workspace {name}, status={st})")
            environments.teardown(env_id)
            _log(f"  torn down env {env_id} (workspace {name})")
        except Exception as exc:  # noqa: BLE001
            _log(f"  ERROR tearing down env {env_id} ({name}): {exc!r}")
            rc = 5
    return rc


def _build_task(issue_ref: str, title: str, url: str, body: str,
                pr_base: str) -> str:
    """Build the task string sent to the agent.

    This is the single source of truth for what the agent is told to do, so it
    is deliberately prescriptive about the FULL workflow -- not just the
    feature -- to fix the failure mode where the agent stopped after
    "verify changes" and never committed/pushed/PR'd:

      A. Read the operating instructions first. The env stages the project
         system prompt + this task as /home/dev/workspace/AGENT_CONTEXT.md
         (and AGENT.md in the repo cwd when the repo ships none). The agent
         MUST read AGENT_CONTEXT.md / AGENT.md before doing anything else --
         they carry the commit/push/PR mandate, the browser guidance,
         and the env layout. superpowers' brainstorming skill checklist ends
         at "transition to implementation" and does NOT include finishing the
         branch, so the mandate has to be in the task itself, not just the
         skill or a file the agent may skip.
      B. Make the finish step an explicit, final, non-optional part of the
         task: commit on a new branch, push, and `gh pr create --base <pr_base>`
         with "Resolves #N". Do not stop until the PR is created.
      +  Verify the change visually with headless Chrome for Testing (the
         headless browser on the AMI) and save a screenshot, so the PR has
         evidence the UI works.

    The PR base branch is per-profile (profile.pr_base, default uat) so each
    repo lands on its own integration branch without the agent guessing.
    """
    import textwrap
    pr_base = (pr_base or "uat").strip() or "uat"
    parts: list[str] = []
    parts.append(f"Resolve GitHub issue {issue_ref}: {title}")
    if url:
        parts.append(f"Issue URL: {url}")
    if body:
        parts.append(f"\nIssue body:\n{body[:8000]}")

    parts.append(textwrap.dedent(f"""\

        ── READ THIS BEFORE YOU START ──
        First, read your operating instructions: open and read
        /home/dev/workspace/AGENT_CONTEXT.md and /home/dev/workspace/repo/AGENT.md
        (if it exists) in your cwd. They contain the project system prompt, the
        commit/push/PR mandate, the browser guidance, and the env layout
        (Odoo on 127.0.0.1:18069, repo at /home/dev/workspace/repo). Do NOT skip
        this and do NOT rely solely on the superpowers brainstorming checklist --
        that checklist ends at "transition to implementation" and does NOT include
        finishing the branch, so the finish steps below are part of YOUR task.

        ── WORKFLOW (do every step; do not stop early) ──
        1. Understand the issue and explore the codebase (read before you write).
        2. Make the smallest correct change in the addons repo.
        3. Reload + upgrade Odoo: `docker restart env-odoo` then
           `docker exec env-odoo odoo -d odoo -u <addon> --stop-after-init`.
        4. VERIFY VISUALLY with headless Chrome for Testing (do NOT launch a
           GUI browser). Two wrappers are on PATH and you MUST use them (raw
           `chrome --headless=new ...` hangs forever in this workspace: an empty
           DBUS_SESSION_BUS_ADDRESS makes Chrome block on a D-Bus connection,
           and Odoo's /web/login redirect chain never fires a load event so
           Chrome waits indefinitely). The wrappers fix both:
             chrome-dom http://127.0.0.1:18069/web/login        # render page -> HTML on stdout
             chrome-shot /home/dev/workspace/repo/docs/issue-{issue_ref}-after.png \
               http://127.0.0.1:18069/<your-route>              # capture a PNG screenshot
           (full-page/tall: append `--window-size=1280,2400` as a trailing flag.)
           Save the screenshot under the repo (e.g.
           /home/dev/workspace/repo/docs/issue-{issue_ref}-after.png) and
           reference its path in the PR body. If the change has no UI surface
           (pure model/data change), say so explicitly in your final summary
           instead of silently skipping the screenshot.
        5. FINISH — commit, push, and open a PR. This is mandatory and is the
           last step; do not stop after verifying:
             a. Commit on a NEW branch (do not commit directly to {pr_base}).
             b. Push the branch: `git push -u origin <branch>`.
             c. Open a pull request:
                  gh pr create --base {pr_base} \\
                    --title "<short summary>" \\
                    --body "<summary of the change + Resolves {issue_ref} + note the screenshot path>"
             The `gh` CLI is installed and GH_TOKEN is in your environment. Push
             FIRST, then create the PR. Do NOT stop until the PR is created. Do
             NOT submit/merge the PR yourself.
        If you cannot push or create the PR (auth failure, gh missing, etc.),
        say so EXPLICITLY in your final summary — do NOT silently leave changes
        uncommitted or unpushed."""))
    return "\n".join(parts)


def match_profile(repo_url: str) -> tuple[str | None, dict | None]:
    """Find the profile whose addons repo matches `repo_url` (normalized host+path
    equality). Prefer one with a built image (image_status == ready). Returns
    (profile_id, profile) or (None, None) when nothing matches."""
    target = _normalize_repo(repo_url)
    if not target:
        return None, None
    profiles = store.list_profiles(limit=200)
    ready, other = None, None
    for p in profiles:
        pa = _normalize_repo(p.get("addons_git_url") or "")
        if pa and pa == target:
            if p.get("image_status") == "ready" and p.get("image_uri"):
                if ready is None:
                    ready = p
            elif other is None:
                other = p
    chosen = ready or other
    return (chosen["id"], chosen) if chosen else (None, None)


def latest_successful_mask_run(profile_id: str) -> str | None:
    """Newest succeeded mask run for the profile that produced a masked dump."""
    for r in store.list_runs(limit=200):
        if (r.get("operation") == "mask" and r.get("status") == "succeeded"
                and r.get("profile_id") == profile_id):
            full = store.get_run(r["id"]) or {}
            if (full.get("result") or {}).get("masked_dump_s3_uri"):
                return r["id"]
    return None


def main() -> int:
    # --teardown: invoked by the webhook listener on issue close. Tearing down
    # the env for a closed issue frees its EC2 instance. Linkage is by
    # (repo, issue number); see teardown_for_issue.
    if "--teardown" in sys.argv[1:]:
        issue_number = os.environ.get("ISSUE_NUMBER", "").strip()
        issue_repo = os.environ.get("ISSUE_REPO_URL", "").strip()
        if not issue_repo or not issue_number:
            _log("ERROR: --teardown requires ISSUE_REPO_URL + ISSUE_NUMBER")
            return 1
        return teardown_for_issue(issue_repo, issue_number)

    issue_number = os.environ.get("ISSUE_NUMBER", "").strip()
    issue_title = os.environ.get("ISSUE_TITLE", "").strip()
    issue_body = os.environ.get("ISSUE_BODY", "").strip()
    issue_url = os.environ.get("ISSUE_URL", "").strip()
    issue_repo = os.environ.get("ISSUE_REPO_URL", "").strip()
    agent = os.environ.get("ODOO_SYNTH_AGENT", "opencode").strip() or "opencode"
    max_iter = int(os.environ.get("ODOO_SYNTH_MAX_ITER", "15") or "15")
    branch_hint = os.environ.get("ODOO_SYNTH_BRANCH_HINT", "").strip()

    if not issue_repo:
        _log("ERROR: ISSUE_REPO_URL not set")
        return 1
    if not config.environments_configured():
        _log("ERROR: developer environments are not configured "
             "(CODER_URL + CODER_SESSION_TOKEN + odoo-synth-workspacer template)")
        return 1

    _log(f"issue #{issue_number}: {issue_title!r}")
    _log(f"repo: {issue_repo}  -> normalized {_normalize_repo(issue_repo)}")

    pid, profile = match_profile(issue_repo)
    if not pid:
        _log(f"ERROR: no odoo-synth profile matches repo {issue_repo}; "
             "create+build+mask a profile for it first (odoo-synth profile create)")
        return 1
    _log(f"matched profile {pid} ({profile.get('label')}) "
         f"image_status={profile.get('image_status')}")

    run_id = latest_successful_mask_run(pid)
    if not run_id:
        _log(f"ERROR: profile {pid} has no succeeded mask run with a dump; "
             "run `odoo-synth profile mask <id>` first")
        return 1
    _log(f"using masked dump from mask run {run_id}")

    repo_branch = branch_hint or profile.get("addons_git_ref") or ""
    label = _workspace_label(issue_number, issue_title)
    issue_ref = f"#{issue_number}" if issue_number else issue_url

    # The PR base branch the agent must target with `gh pr create --base`.
    # Per-profile (profile.pr_base) so each repo lands on its own integration
    # branch; default is the repo's main branch. The issue
    # launcher passes this explicitly so the agent doesn't have to guess.
    pr_base = (profile.get("pr_base") or "").strip() or "main"

    _log(f"creating env: name={label} issue={issue_ref} branch={repo_branch} "
         f"pr_base={pr_base}")
    try:
        env_id = environments.create(
            source_run_id=run_id, issue=issue_ref, dump_s3_uri=None,
            repo_url=profile.get("addons_git_url"), repo_branch=repo_branch,
            profile_id=pid, name=label)
    except Exception as exc:  # noqa: BLE001
        _log(f"ERROR: env create failed: {exc}")
        return 2
    _log(f"env created: env_id={env_id} workspace={label}")

    _log("waiting for the workspace to reach running ...")
    wait_timeout = int(os.environ.get("ODOO_SYNTH_WAIT_TIMEOUT", "1200") or "1200")
    if not environments.wait_for_env(env_id, timeout=wait_timeout):
        _log("ERROR: env did not reach running in time")
        return 3
    _log("env is running; staging agent context + launching agent")

    task = _build_task(issue_ref, issue_title, issue_url, issue_body, pr_base)

    # The agent + system prompt come from the matched profile (per-preset
    # config), with env-var / global-file fallbacks so the defaults still work
    # for profiles that haven't set them.
    agent = (profile.get("agent_name") or agent).strip() or "opencode"
    system_prompt = (profile.get("agent_system_prompt") or "").strip()
    if not system_prompt:
        sp_path = REPO_ROOT / environments.AGENT_SYSTEM_PROMPT_PATH
        try:
            if sp_path.exists():
                system_prompt = sp_path.read_text()
        except Exception:  # noqa: BLE001
            pass
    # Wall-clock cost guard (replaces ralph's --max-iterations cap).
    agent_timeout = int(os.environ.get("ODOO_SYNTH_AGENT_TIMEOUT", "3600") or "3600")

    try:
        res = environments.run_agent(
            env_id, task, agent=agent, max_iterations=max_iter,
            issue=issue_ref, system_prompt=system_prompt,
            timeout=agent_timeout)
    except Exception as exc:  # noqa: BLE001
        _log(f"ERROR: agent launch failed: {exc}")
        return 4
    _log(f"agent finished: exit={res['exit_code']} workspace={res['workspace']}")
    if res["output"]:
        _log("agent output (head):\n" + "\n".join(res["output"].splitlines()[:40]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
