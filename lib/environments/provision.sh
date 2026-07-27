#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Golden-AMI provisioner for odoo-synth developer environments.
#
# Run this ONCE on a fresh Ubuntu 22.04/24.04 instance, then bake an AMI from
# it (aws ec2 create-image). The AMI id goes into config.yaml (environments.
# ami_id / ami_id_env). Per-environment boot work (seed DB, start the odoo
# container) is done by user-data.sh.tmpl at launch time, so this only installs
# the static toolchain that every environment shares: docker + buildx, awscli,
# postgres-client, ttyd (web terminal served via the Coder app), the Claude
# Code + OpenCode agent CLIs, and headless Chrome for agent UI verification.
# (NOTE: "code-server" is NOT installed -- the developer reaches the workspace
# through Coder's tunnel, not a code-server editor. A prior design used
# code-server; this comment previously referenced it.)
# ---------------------------------------------------------------------------
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git jq unzip \
    postgresql-client python3 python3-venv python3-pip \
    build-essential

# --- Docker (for the per-env local postgres that holds the masked data) -----
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
systemctl enable --now docker

# --- AWS CLI v2 (used by user-data to pull the dump + secret) ---------------
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip
  unzip -q /tmp/awscli.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/awscli.zip /tmp/aws
fi

# --- Node.js LTS + corepack (for multi-repo `static`/`process` components --
# each repo pins its own package manager via package.json's "packageManager"
# field, e.g. yarn@4.5.0 or pnpm@10.30.1; corepack shims whichever one a
# given repo actually needs rather than assuming npm everywhere).
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y --no-install-recommends nodejs
corepack enable

# --- ttyd (web terminal that serves Claude Code via the Coder app) -------
apt-get install -y --no-install-recommends ttyd

# --- Claude Code (prebuilt binary; no node required) -----------------------
# Installed into /opt/claude-code so it's available to every user (the env
# startup script symlinks /home/dev/.local/bin/claude -> here). Pinning the
# version keeps the AMI deterministic; bump VERSION to refresh.
CLAUDE_VERSION="2.1.211"
CLAUDE_DIR="/opt/claude-code"
mkdir -p "$CLAUDE_DIR"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  CLAUDE_ARCH="x64" ;;
  aarch64) CLAUDE_ARCH="arm64" ;;
  *) echo "unsupported arch $ARCH" >&2; exit 1 ;;
esac
curl -fsSL "https://github.com/anthropics/claude-code/releases/download/v${CLAUDE_VERSION}/claude-linux-${CLAUDE_ARCH}.tar.gz" \
  -o /tmp/claude.tar.gz
tar -xzf /tmp/claude.tar.gz -C "$CLAUDE_DIR"
rm -f /tmp/claude.tar.gz
# the tarball ships a single `claude` binary at its root
ln -sf "$CLAUDE_DIR/claude" /usr/local/bin/claude
chmod +x "$CLAUDE_DIR/claude" /usr/local/bin/claude

# --- Bun (JS runtime for OpenCode + superpowers plugin install) -----------
# Installed system-wide: binary at /opt/bun/bin/bun, symlinked on PATH.
BUN_DIR="/opt/bun"
curl -fsSL https://bun.sh/install | BUN_INSTALL="$BUN_DIR" bash
ln -sf "$BUN_DIR/bin/bun" /usr/local/bin/bun
ln -sf "$BUN_DIR/bin/bunx" /usr/local/bin/bunx 2>/dev/null || true

# --- OpenCode (open-source coding agent; TUI + web + headless) -------------
# Its installer hardcodes $HOME/.opencode/bin, so install under HOME=/opt to
# get a system-wide binary, then symlink. --no-modify-path avoids editing
# shell rc files during the bake.
mkdir -p /opt
# HOME=/opt must be on the bash (the consumer of the pipe), not curl,
# so the installer writes to /opt/.opencode/bin rather than /root/.opencode/bin.
curl -fsSL https://opencode.ai/install | HOME=/opt bash -s -- --no-modify-path
ln -sf /opt/.opencode/bin/opencode /usr/local/bin/opencode

# --- Superpowers (agentic-skills plugin for claude-code + opencode) --------
# https://github.com/obra/superpowers  -- TDD, planning, git-worktrees, code
# review, subagent-driven-development. Loaded inside the agent's session (not
# an external loop), so it drives the agent autonomously through a task in one
# continuous session. Pre-cloned to /opt/superpowers so envs load it with no
# runtime network dependency (local-path plugin install for both harnesses).
SUPERPOWERS_DIR="/opt/superpowers"
if [ ! -d "$SUPERPOWERS_DIR/.git" ]; then
  git clone --depth 1 https://github.com/obra/superpowers.git "$SUPERPOWERS_DIR"
fi
# OpenCode: register the local checkout as a plugin in the global opencode.json.
# (Written to /opt so it applies to every user; the env startup symlinks it
# into /home/dev/.config/opencode/ for the dev user.)
mkdir -p /opt/.opencode
cat > /opt/.opencode/opencode.json <<'OCJSON'
{
  "plugin": ["/opt/superpowers"]
}
OCJSON
# Claude Code: plugins live under ~/.claude/plugins. Symlink the checkout so
# Claude Code's plugin loader discovers it (the plugin ships its own
# hooks/hooks.json SessionStart entry, so it bootstraps on every session).
mkdir -p /opt/.claude/plugins
ln -sfn "$SUPERPOWERS_DIR" /opt/.claude/plugins/superpowers

# --- Headless Chrome for Testing (the agent's browser: scrape + screenshot) --
# https://googlechromelabs.github.io/chrome-for-testing/  -- Google publishes
# pinned, headless-capable Chrome for Testing builds as plain zips (no npm/
# puppeteer needed). The agent uses this for BOTH legs of web verification:
#   - scrape/verify a page:  chrome --headless=new --dump-dom <url>     (rendered HTML)
#   - capture a PNG evidence: chrome --headless=new --screenshot=out.png <url>
# One tool does both. (We previously shipped obscura here, but obscura has no
# layout/paint engine -- Page.captureScreenshot is unimplemented, see upstream
# issues #52/#121/#123 -- so it cannot take screenshots at all. Chrome for
# Testing does both jobs, so we use it instead of maintaining two browsers.)
# System shared libs headless Chrome needs (X11/cairo/pango/nss/alsa/...).
# --no-install-recommends keeps the image lean.
#
# IMPORTANT: the base AMI is Ubuntu 22.04 (jammy). On jammy the ALSA lib is
# `libasound2`; `libasound2t64` is a 24.04-only (time64 transition) package
# that does NOT exist on jammy. apt does NOT "skip" an unresolvable name in a
# single install command -- it ABORTS the whole transaction, so listing both
# (as we once did) installed *none* of the libs and Chrome failed with
# "libasound.so.2 => not found" (and 12 others). `libasound2` is the right name
# on both 22.04 (real) and 24.04 (transitional -> libasound2t64).
#
# Install one package per apt call so a single missing name can never block the
# rest; tolerate (but log) any that won't resolve. (Verified on jammy: every
# name below resolves.)
for p in \
    libx11-6 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxi6 \
    libxrandr2 libxrender1 libxtst6 libxss1 libxkbcommon0 \
    libnss3 libcups2 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 \
    libatspi2.0-0 libgbm1 libpango-1.0-0 libcairo2 libfontconfig1 \
    libfreetype6 libasound2 \
    fonts-liberation fonts-dejavu-core ; do
    apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 \
        || echo "  provision:WARN could not install $p (skipping)" >&2
done
CHROME_DIR="/opt/chrome-for-testing"
mkdir -p "$CHROME_DIR"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  CFT_ARCH="linux64"   ; CFT_BIN="chrome-linux64/chrome" ;;
  aarch64) echo "chrome-for-testing has no arm64 build for the pinned version; skipping" >&2; CFT_ARCH="" ;;
  *) echo "unsupported arch $ARCH for chrome-for-testing" >&2; CFT_ARCH="" ;;
esac
if [ -n "$CFT_ARCH" ]; then
  # Pin a known-good version (Google's last-known-good JSON). Pinned so a bake
  # is reproducible; bump deliberately. URL shape:
  #   .../chrome-for-testing-public/<ver>/$CFT_ARCH/chrome-linux64.zip
  CFT_VERSION="131.0.6778.204"
  CFT_URL="https://storage.googleapis.com/chrome-for-testing-public/${CFT_VERSION}/${CFT_ARCH}/chrome-linux64.zip"
  curl -fsSL "$CFT_URL" -o /tmp/chrome-cft.zip && \
    unzip -q /tmp/chrome-cft.zip -d "$CHROME_DIR" && rm -f /tmp/chrome-cft.zip
  # chrome-linux64/chrome is the binary; symlink it onto PATH as `chrome`.
  ln -sf "$CHROME_DIR/$CFT_BIN" /usr/local/bin/chrome
  chmod +x "$CHROME_DIR/$CFT_BIN"
  # Convenience alias `headless-chrome` for docs that say that.
  ln -sf /usr/local/bin/chrome /usr/local/bin/headless-chrome
fi

# --- headless-Chrome wrappers (chrome-shot / chrome-dom) -------------------
# The agent drives headless Chrome for UI verification + PR-evidence screenshots.
# Two environment quirks make a bare `chrome --headless=new ...` hang forever in
# this workspace, so we wrap them here and the agent calls the wrappers instead
# of raw chrome:
#
#   1. DBUS_SESSION_BUS_ADDRESS is *set but empty* in the dev login shell. Chrome
#      (new headless) treats an empty bus address as an unparseable D-Bus address
#      and blocks retrying bus.cc connections ("Could not parse server address"),
#      never reaching page load. Unsetting it lets Chrome autolaunch/fall back.
#   2. Odoo's /web/login 303-redirects to /website_sso, and the redirect target
#      (/) returns 500, so the page's `load` event never fires. Chrome's new
#      headless mode then waits INDEFINITELY for load completion (it has no
#      default nav timeout). --timeout=<ms> caps navigation so Chrome captures
#      whatever rendered and exits instead of hanging. (Verified: exit 0,
#      1280x800 PNG of the login page produced.)
#
# --disable-dev-shm-usage avoids /dev/shm exhaustion crashes in containers.
install -m 0755 /dev/stdin /usr/local/bin/chrome-shot <<'SHOT'
#!/usr/bin/env bash
# chrome-shot <out.png> <url> [extra chrome flags...]  -- capture a PNG screenshot.
set -euo pipefail
out="${1:?usage: chrome-shot <out.png> <url> [flags...]}"; url="${2:?need url}"; shift 2
exec env -u DBUS_SESSION_BUS_ADDRESS /usr/local/bin/chrome \
    --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --hide-scrollbars --window-size=1280,800 --timeout=15000 \
    --screenshot="$out" "$@" "$url"
SHOT
install -m 0755 /dev/stdin /usr/local/bin/chrome-dom <<'DOM'
#!/usr/bin/env bash
# chrome-dom <url> [extra chrome flags...]  -- print rendered (post-JS) HTML to stdout.
set -euo pipefail
url="${1:?usage: chrome-dom <url> [flags...]}"; shift
exec env -u DBUS_SESSION_BUS_ADDRESS /usr/local/bin/chrome \
    --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --timeout=15000 --dump-dom "$@" "$url"
DOM
ln -sf /usr/local/bin/chrome-shot /usr/local/bin/headless-chrome-shot
ln -sf /usr/local/bin/chrome-dom   /usr/local/bin/headless-chrome-dom

# A dedicated unprivileged developer user owns the workspace and runs Odoo.
if ! id dev >/dev/null 2>&1; then
  useradd -m -s /bin/bash dev
  usermod -aG docker dev
fi
# Make the agent CLIs discoverable for the dev user's login shells.
install -d -o dev -g dev /home/dev/.local/bin
ln -sf /usr/local/bin/claude   /home/dev/.local/bin/claude
ln -sf /usr/local/bin/opencode /home/dev/.local/bin/opencode
ln -sf /usr/local/bin/bun      /home/dev/.local/bin/bun
ln -sf /usr/local/bin/chrome   /home/dev/.local/bin/chrome 2>/dev/null || true
ln -sf /usr/local/bin/chrome-shot /home/dev/.local/bin/chrome-shot 2>/dev/null || true
ln -sf /usr/local/bin/chrome-dom   /home/dev/.local/bin/chrome-dom 2>/dev/null || true
# Make the global opencode.json (superpowers plugin) + Claude plugin symlink
# visible to the dev user's home so both agents load superpowers at session start.
install -d -o dev -g dev /home/dev/.config/opencode /home/dev/.claude/plugins
ln -sfn /opt/.opencode/opencode.json /home/dev/.config/opencode/opencode.json
ln -sfn /opt/superpowers /home/dev/.claude/plugins/superpowers 2>/dev/null || true
printf 'export PATH="$HOME/.local/bin:$PATH"\n' >> /home/dev/.bashrc

# Pre-pull the postgres image so first boot is fast. The provenance-baked odoo
# image is pulled per-environment from ECR at boot (the instance profile needs
# ecr:GetAuthorizationToken + pull) so the AMI stays thin and never goes stale.
docker pull postgres:16 || true

mkdir -p /opt/odoo-synth-env
echo "provisioned $(date -u +%FT%TZ)" > /opt/odoo-synth-env/PROVISIONED
echo "[provision] golden AMI toolchain installed."
