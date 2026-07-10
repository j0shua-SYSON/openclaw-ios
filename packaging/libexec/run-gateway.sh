#!/var/jb/bin/sh
# OpenClaw gateway daemon launcher (run by launchd). Runs as user `mobile` so the
# state dir and the `openclaw` CLI share one owner (no root/mobile permission split).
# Bounds memory for a 2GB device and pins a fixed writable state dir.
PREFIX=/var/jb
APP="$PREFIX/usr/libexec/openclaw"

export HOME="${OPENCLAW_HOME:-$PREFIX/var/lib/openclaw}"
export OPENCLAW_STATE_DIR="$HOME"
export OPENCLAW_NO_RESPAWN=1
# iOS has no scutil/dns-sd; skip Bonjour/mDNS to avoid failed spawns + ~5s boot latency.
export OPENCLAW_DISABLE_BONJOUR=1
export SHELL="${SHELL:-$PREFIX/bin/sh}"
export UV_THREADPOOL_SIZE=2
export PATH="$PREFIX/usr/bin:$PREFIX/bin:$PREFIX/usr/sbin:$PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"

# Memory caps only (NODE_OPTIONS rejects --single-threaded / --wasm-*; those go as
# direct args below). Child node procs inherit these caps via NODE_OPTIONS.
export NODE_OPTIONS="--max-old-space-size=512 --max-semi-space-size=16 --disable-warning=ExperimentalWarning"

# Default fd limit on-device is only 256 — too low for a Node server (EMFILE). Raise it.
ulimit -n 8192 2>/dev/null || ulimit -n 4096 2>/dev/null || ulimit -n 1024 2>/dev/null || true

mkdir -p "$HOME" "$TMPDIR" 2>/dev/null || true
cd "$HOME" 2>/dev/null || true

ENTRY="$APP/node_modules/openclaw/openclaw.mjs"
if [ ! -f "$ENTRY" ]; then
  echo "[run-gateway] FATAL: OpenClaw entry not found at $ENTRY" >&2
  exit 1
fi

# Runtime mode (see the V8 patch set): full JIT + WebAssembly work on the A9 via
# mprotect W^X, but ONLY single-threaded (the flip is process-wide) and with WASM
# guard regions disabled (iOS refuses the 32GB reservation). --jitless is NOT an
# option: it disables WebAssembly, which undici/fetch needs, so the gateway can't
# reach any API. worker_threads still work under --single-threaded.
#   --single-threaded            : no background V8 threads racing the W^X flip
#   --wasm-enforce-bounds-checks : explicit WASM bounds checks (guard regions are off)
#   --wasm-max-mem-pages=4096    : cap WASM memory reservation at 256MB (not 4GB)
exec "$APP/node" \
  --single-threaded \
  --wasm-enforce-bounds-checks \
  --wasm-max-mem-pages=4096 \
  "$ENTRY" gateway --port 18789
