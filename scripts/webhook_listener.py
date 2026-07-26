#!/usr/bin/env python3
"""GitHub webhook listener -> odoo-synth workspace + opencode agent launcher.

Runs ON THE CODER SERVER (the always-on control plane at CODER_SERVER_IP), NOT
on a dev VM. GitHub POSTs `issues` events from the *profile's addons repo*
(e.g. your-org/your-addons-repo) to this listener; it verifies the
HMAC-SHA256 signature with a shared webhook secret, dedupes by
X-GitHub-Delivery (replay protection), and:
  * on `issue.opened`  -> runs scripts/issue_to_env.py in a background thread
    (GitHub gets a fast 200 while the env boots + agent runs, which takes many
    minutes).
  * on `issue.closed`  -> runs scripts/issue_to_env.py --teardown in a
    background thread to delete the Coder workspace for that issue, freeing its
    EC2 instance. Teardown is scoped by (repo, issue number) so ONLY the closed
    issue's workspace is deleted -- never another issue's (see
    issue_to_env.teardown_for_issue).

Why the Coder server host:
  - It is the only always-on box in the stack; a dev VM is ephemeral.
  - It already has CODER_URL + CODER_SESSION_TOKEN (it runs `coder server`).
  - It has AWS creds for the dumps bucket, so it can read the S3-backed profile
    + run stores (the "latest preset for that repo" resolver) without this dev
    VM being up.
  - `coder create` talks to the Coder API on localhost.

The launcher (scripts/issue_to_env.py) is host-agnostic: it matches the issue's
repo URL -> profile (from S3) -> latest successful mask run -> `coder create`
with the profile's params (= the same preset the Coder dashboard offers), then
labels the env `iss-<n>-<slug>` and drives the agent (opencode/claude-code)
via superpowers inside the env.

FOLDED BEHIND CADDY (deploy/13 + deploy/14): the listener binds 127.0.0.1 ONLY
-- it has NO public port. Caddy on :443 routes /webhook -> 127.0.0.1:8080
(restricted to GitHub's hook IPs via remote_ip) and /* -> the Coder HTTP
server. So GitHub reaches it at one HTTPS endpoint, same as the Coder dashboard:
  - GitHub repo -> Settings -> Webhooks -> Add webhook:
      Payload URL: https://coder.<CODER_SERVER_IP>.nip.io/webhook
      Content type: application/json
      Events: Issues
      Secret: <GITHUB_WEBHOOK_SECRET>  (must match the systemd unit's env)

Defense in depth: (1) Caddy terminates TLS, (2) Caddy restricts /webhook to
GitHub's published hook IP ranges, (3) HMAC-SHA256 signature verification,
(4) X-GitHub-Delivery dedupe (replay protection).

Env vars (systemd unit / EnvironmentFile):
  GITHUB_WEBHOOK_SECRET  REQUIRED -- shared secret for HMAC verification.
  WEBHOOK_PORT           default 8080 (localhost only; Caddy fronts it).
  WEBHOOK_BIND           default 127.0.0.1 -- do NOT expose this directly;
                         Caddy's /webhook route is the public entry point.
  CODER_URL, CODER_SESSION_TOKEN, AWS_*  inherited so the launcher can drive
                         Coder + read the S3 profile/run stores.
"""
from __future__ import annotations
import hashlib
import hmac
import json
import os
import subprocess
import threading
import time
from collections import deque
from pathlib import Path

from flask import Flask, request, abort

REPO_ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = REPO_ROOT / "scripts" / "issue_to_env.py"
# On the Coder server the launcher's deps (boto3, pyyaml) live in a venv at
# $REPO_ROOT/.venv (Ubuntu 24.04 PEP 668 blocks system-wide pip). Prefer it if
# present, else fall back to the system interpreter.
_VENV_PY = REPO_ROOT / ".venv" / "bin" / "python3"
PY = str(_VENV_PY) if _VENV_PY.exists() else "python3"

app = Flask(__name__)

# Replay protection: GitHub sends a unique X-GitHub-Delivery id per event. We
# remember the last N deliveries (sliding window) and reject a duplicate -- so a
# captured-and-replayed webhook (even though it carries a valid HMAC) cannot
# spin up a second env for the same issue. In-process + lock-guarded; a restart
# clears the window (acceptable: replays within one process lifetime are what we
# guard against; GitHub itself retries with the SAME delivery id on non-2xx, so
# dedupe also prevents a legit retry from double-launching if the first run was
# slow but succeeded).
_DELIVERY_WINDOW = 4096
_DELIVERIES: deque[str] = deque(maxlen=_DELIVERY_WINDOW)
_DELIVERY_LOCK = threading.Lock()


def _seen_delivery(delivery_id: str) -> bool:
    """True if this delivery id was already accepted (and not evicted)."""
    if not delivery_id:
        return False
    with _DELIVERY_LOCK:
        if delivery_id in _DELIVERIES:
            return True
        _DELIVERIES.append(delivery_id)
        return False


def _webhook_secret() -> bytes:
    s = os.environ.get("GITHUB_WEBHOOK_SECRET", "")
    return s.encode() if s else b""


def _verify_signature(payload: bytes, sig_header: str | None) -> bool:
    """GitHub signs the raw body with HMAC-SHA256 using the webhook secret and
    sends `X-Hub-Signature-256: sha256=<hex>`. Constant-time compare. Fails
    closed: no secret / no header -> reject (never run the env launcher on an
    unauthenticated POST)."""
    secret = _webhook_secret()
    if not secret or not sig_header or not sig_header.startswith("sha256="):
        return False
    expected = hmac.new(secret, payload, hashlib.sha256).hexdigest()
    got = sig_header.split("=", 1)[1].strip()
    return hmac.compare_digest(expected, got)


def _run_launcher(env: dict) -> None:
    """Run the launcher in the background; output goes to the journal."""
    import sys
    issue = env.get("ISSUE_NUMBER", "?")
    print(f"[launcher] issue #{issue} starting ({PY} {LAUNCHER})", flush=True)
    try:
        proc = subprocess.run(
            [PY, str(LAUNCHER)],
            env={**os.environ, **env},
            cwd=str(REPO_ROOT),
            capture_output=True, text=True, timeout=90 * 60, check=False,
        )
        out = (proc.stdout or "").rstrip()
        err = (proc.stderr or "").rstrip()
        print(f"[launcher] issue #{issue} rc={proc.returncode}", flush=True)
        if out:
            print(out, flush=True)
        if err:
            print(err, file=sys.stderr, flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"[launcher] issue #{issue} EXCEPTION: {exc!r}", file=sys.stderr, flush=True)


def _run_tearer(env: dict) -> None:
    """Tear down the env for a closed issue. Same launcher, --teardown mode:
    it matches envs by (repo, issue number) so only the closed issue's
    workspace(s) are deleted -- never another issue's. Runs in the background
    (Coder `coder delete` is fast, but GitHub must not wait on it)."""
    import sys
    issue = env.get("ISSUE_NUMBER", "?")
    print(f"[teardown] issue #{issue} starting ({PY} {LAUNCHER} --teardown)",
          flush=True)
    try:
        proc = subprocess.run(
            [PY, str(LAUNCHER), "--teardown"],
            env={**os.environ, **env},
            cwd=str(REPO_ROOT),
            capture_output=True, text=True, timeout=10 * 60, check=False,
        )
        out = (proc.stdout or "").rstrip()
        err = (proc.stderr or "").rstrip()
        print(f"[teardown] issue #{issue} rc={proc.returncode}", flush=True)
        if out:
            print(out, flush=True)
        if err:
            print(err, file=sys.stderr, flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"[teardown] issue #{issue} EXCEPTION: {exc!r}", file=sys.stderr,
              flush=True)


@app.post("/webhook")
def webhook():
    payload = request.get_data()
    if not _verify_signature(payload, request.headers.get("X-Hub-Signature-256")):
        abort(401)
    event = request.headers.get("X-GitHub-Event", "")
    if event != "issues":
        return ("ignored: not an issues event\n", 200)
    delivery_id = request.headers.get("X-GitHub-Delivery", "")
    if _seen_delivery(delivery_id):
        # legit GitHub retry or a malicious replay -- either way don't relaunch
        return (f"ignored: duplicate delivery {delivery_id}\n", 200)
    try:
        data = json.loads(payload.decode() if isinstance(payload, bytes) else payload)
    except Exception:  # noqa: BLE001
        abort(400)
    action = data.get("action")
    if action not in ("opened", "reopened", "closed"):
        return (f"ignored: action={action}\n", 200)
    issue = data.get("issue") or {}
    repo = data.get("repository") or {}
    env = {
        "ISSUE_NUMBER": str(issue.get("number") or ""),
        "ISSUE_TITLE": issue.get("title") or "",
        "ISSUE_BODY": issue.get("body") or "",
        "ISSUE_URL": issue.get("html_url") or "",
        # the addons repo the issue belongs to -> matches an odoo-synth profile
        # (and on close, scopes teardown to THIS repo's env for this issue).
        "ISSUE_REPO_URL": repo.get("clone_url") or "",
    }
    # fire-and-forget: env boot takes minutes; GitHub must not wait for it.
    # On close, the env is torn down (EC2 freed) -- the linkage is (repo,
    # issue number) so only the closed issue's workspace is deleted.
    target = _run_tearer if action == "closed" else _run_launcher
    threading.Thread(target=target, args=(env,), daemon=True).start()
    return (json.dumps({"accepted": True, "action": action,
                        "issue": env["ISSUE_NUMBER"]}), 200,
            {"Content-Type": "application/json"})


@app.get("/healthz")
def healthz():
    return ("ok\n", 200)


if __name__ == "__main__":
    port = int(os.environ.get("WEBHOOK_PORT", "8080"))
    host = os.environ.get("WEBHOOK_BIND", "127.0.0.1")
    app.run(host=host, port=port, debug=False)
