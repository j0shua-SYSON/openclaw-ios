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

# TMPDIR is empty for the launchd/root context on this device; give Node a writable one.
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"

# Put the memory caps in NODE_OPTIONS so any child node process OpenClaw spawns
# (workers, or a self-respawn) also stays bounded on a ~2 GB device.
export NODE_OPTIONS="--max-old-space-size=512 --max-semi-space-size=16 --disable-warning=ExperimentalWarning"

# Default fd limit on-device is only 256 — too low for a Node server (EMFILE). Raise it.
ulimit -n 8192 2>/dev/null || ulimit -n 4096 2>/dev/null || ulimit -n 1024 2>/dev/null || true

mkdir -p "$HOME" "$TMPDIR" 2>/dev/null || true
cd "$HOME" 2>/dev/null || true

exec "$APP/node" "$APP/node_modules/openclaw/openclaw.mjs" gateway --port 18789
