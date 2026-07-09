#!/bin/sh
# iOS cross-compile source fixups for the Node.js tree.
# Applied after clone, before configure. Accumulates targeted deltas for iOS-SDK
# mismatches in Node's bundled deps (cheaper + more version-robust than .patch files).
set -eux
SRC="${1:?usage: ios-source-fixups.sh <node-src-dir>}"
cd "$SRC"

# --- gyp make generator: treat iOS as a Darwin/Mach-O platform ---
# Node's gyp make generator only emits Mach-O link commands (and frameworks,
# install_name, -arch, .dylib, objc) for flavor=="mac"; flavor=="ios" falls through to
# the Linux template, which uses `ld --start-group/--end-group` — flags Apple's ld
# rejects ("ld: unknown options: --start-group --end-group"). Make the *generator* treat
# ios like mac, but keep the gyp OS variable = "ios" so V8's iOS codegen and OS=="ios"
# gyp conditions remain correct.
python3 - "tools/gyp/pylib/gyp/generator/make.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
orig = s
# CalculateVariables: give ios the mac branch, but OS stays "ios" (not "mac").
s = s.replace(
    'default_variables.setdefault("OS", "mac")',
    'default_variables.setdefault("OS", "ios" if flavor == "ios" else "mac")',
)
# All the per-target mac behaviors (frameworks, install_name, -arch, bundles...).
s = s.replace('self.flavor == "mac"', 'self.flavor in ("mac", "ios")')
# Module-level flavor checks: CalculateVariables branch + LINK_COMMANDS_MAC selection.
s = s.replace('if flavor == "mac":', 'if flavor in ("mac", "ios"):')
if s == orig:
    raise SystemExit("make.py fixup matched nothing — Node layout changed?")
open(p, "w").write(s)
print("fixup: gyp make.py now treats flavor 'ios' as Mach-O/mac (OS stays ios)")
PY

# --- c-ares ---
# Node's cares.gyp uses config/darwin for both mac and ios, but the iOS SDK does NOT
# ship <sys/random.h> (it has arc4random_buf instead). Undef the header macro so
# ares_rand.c falls back to arc4random_buf (HAVE_ARC4RANDOM_BUF is already defined).
if grep -q '#define HAVE_SYS_RANDOM_H 1' deps/cares/config/darwin/ares_config.h; then
  sed -i.bak 's|#define HAVE_SYS_RANDOM_H 1|/* undef HAVE_SYS_RANDOM_H (iOS SDK lacks it) */|' \
    deps/cares/config/darwin/ares_config.h
  echo "fixup: c-ares HAVE_SYS_RANDOM_H undef'd"
fi

echo "ios-source-fixups: done"
