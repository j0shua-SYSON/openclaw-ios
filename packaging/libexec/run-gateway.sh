#!/bin/sh
# OpenClaw gateway daemon launcher (run by launchd). Bounds memory for a 2GB device and
# pins a fixed writable state dir. Bypasses OpenClaw's macOS daemon installer entirely.
PREFIX=/var/jb
APP="$PREFIX/usr/libexec/openclaw"

export HOME="${OPENCLAW_HOME:-$PREFIX/var/lib/openclaw}"
export OPENCLAW_STATE_DIR="$HOME"
export OPENCLAW_NO_RESPAWN=1
export UV_THREADPOOL_SIZE=2
export PATH="$PREFIX/usr/bin:$PREFIX/bin:$PREFIX/usr/sbin:$PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$HOME" 2>/dev/null || true
cd "$HOME" 2>/dev/null || true

exec "$APP/node" \
  --max-old-space-size=512 \
  --max-semi-space-size=16 \
  --disable-warning=ExperimentalWarning \
  "$APP/node_modules/openclaw/openclaw.mjs" gateway --port 18789
