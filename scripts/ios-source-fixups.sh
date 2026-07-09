#!/bin/sh
# iOS cross-compile source fixups for the Node.js tree.
# Applied after clone, before configure. Accumulates targeted deltas for iOS-SDK
# mismatches in Node's bundled deps (cheaper + more version-robust than .patch files).
set -eux
SRC="${1:?usage: ios-source-fixups.sh <node-src-dir>}"
cd "$SRC"

# --- gyp make generator: drop GNU --start-group/--end-group ---
# For flavor=="ios" the make generator uses the Linux link template, which wraps the
# static libs in `-Wl,--start-group ... -Wl,--end-group`. Apple's ld64 (used for BOTH the
# macOS host tools and the iOS target on the runner) rejects those flags AND doesn't need
# them — it resolves archives with a global view, so circular deps are fine without a
# group. Strip them from every link template. This is far less invasive than remapping the
# flavor (which shifts obj.host lib paths and breaks the js2c host link).
python3 - "tools/gyp/pylib/gyp/generator/make.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
orig = s
s = s.replace(" -Wl,--start-group", "").replace(" -Wl,--end-group", "")
if s == orig:
    raise SystemExit("make.py --start-group strip matched nothing — Node layout changed?")
open(p, "w").write(s)
print("fixup: stripped -Wl,--start-group/--end-group from gyp make link templates")
PY

# --- Node crypto: macOS-only keychain CA reader ---
# src/crypto/crypto_context.cc guards its macOS system-keychain cert reader with
# `#ifdef __APPLE__`, but it uses SecTrustSettings* — a macOS-only Security API absent on
# iOS (where __APPLE__ is still defined). Narrow the guard to TARGET_OS_OSX so it's
# excluded on iOS. We don't need it: Node's bundled Mozilla roots handle TLS.
python3 - "src/crypto/crypto_context.cc" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
orig = s
if "TargetConditionals.h" not in s:
    s = "#if defined(__APPLE__)\n#include <TargetConditionals.h>\n#endif\n" + s
s = s.replace("#ifdef __APPLE__", "#if defined(__APPLE__) && TARGET_OS_OSX")
if s == orig:
    raise SystemExit("crypto_context.cc fixup matched nothing — Node layout changed?")
open(f, "w").write(s)
print("fixup: crypto_context.cc macOS keychain code guarded with TARGET_OS_OSX")
PY

# --- link Darwin frameworks on iOS ---
# Frameworks are normally declared via xcode_settings.OTHER_LDFLAGS, which the gyp *make*
# generator only applies for flavor=="mac" — so flavor=="ios" links nothing. Abseil's tz
# lookup (via V8) needs CoreFoundation (_CFRelease/_CFTimeZone* etc.), and other deps want
# CoreServices/Security. Inject them as plain link_settings.libraries in target_defaults
# (honored by any flavor, applied to every linked target). All exist on the iOS SDK.
python3 - "common.gypi" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
anchor = "['OS==\"mac\"', {\n        'defines': ['_DARWIN_USE_64_BIT_INODE=1'],"
inject = ("['OS==\"ios\"', {\n"
          "        'link_settings': { 'libraries': [\n"
          "          '-framework CoreFoundation',\n"
          "          '-framework CoreServices',\n"
          "          '-framework Security',\n"
          "        ] },\n"
          "      }],\n"
          "      ") + anchor
if anchor not in s:
    raise SystemExit("common.gypi anchor not found — Node layout changed?")
if "OS==\"ios\"" not in s:
    s = s.replace(anchor, inject, 1)
open(f, "w").write(s)
print("fixup: common.gypi links CoreFoundation/CoreServices/Security on iOS")
PY

# --- V8: don't use MAP_JIT on iOS (enables real JIT on the A9) ---
# V8 is internally inconsistent about iOS: platform-darwin.cc skips the
# pthread_jit_write_protect_np toggle on iOS (`&& !defined(V8_OS_IOS)`), but
# platform-posix.cc still requests MAP_JIT pages for all Darwin. So on iOS V8 gets a
# MAP_JIT region and never performs the write-protect flip that makes it executable ->
# executing JITed code SIGBUSes (fatal on the A9, which has no APRR). Excluding iOS from
# MAP_JIT makes V8 fall back to plain PROT_NONE + mprotect(RW->RX), which the runtime probe
# proved works on jailbroken iOS 15 with the dynamic-codesigning entitlement.
python3 - "deps/v8/src/base/platform/platform-posix.cc" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
orig = s
s = s.replace(
    "#if V8_OS_DARWIN\n  // MAP_JIT is required to obtain writable and executable pages when the",
    "#if V8_OS_DARWIN && !defined(V8_OS_IOS)\n  // MAP_JIT is required to obtain writable and executable pages when the",
)
if s == orig:
    raise SystemExit("V8 MAP_JIT fixup matched nothing — V8 layout changed?")
open(f, "w").write(s)
print("fixup: V8 no longer uses MAP_JIT on iOS (falls back to mprotect W^X)")
PY

# --- V8: mprotect-based W^X JIT for pre-APRR iOS (A9/A10) ---
# V8 only implements W^X via APRR (pthread_jit) or PKU; on a real iOS arm64 device it has
# NEITHER, so RwxMemoryWriteScope::SetWritable/SetExecutable are empty no-ops and V8 leaves
# code memory RW (iOS drops X) -> JIT SIGBUSes. Implement the empty fallback with mprotect
# over the code range (registered by code-range.cc). Run node --predictable so codegen is
# single-threaded (mprotect is process-wide). iOS-only; other "neither" platforms allow RWX.
python3 - <<'PY'
import io

# 1) code-memory-access.cc: define the extern-C mprotect toggle + range registration.
p = "deps/v8/src/common/code-memory-access.cc"
s = open(p).read(); o = s
anchor = '#include "src/utils/allocation.h"\n\nnamespace v8 {'
inject = '''#include "src/utils/allocation.h"

#if defined(V8_OS_IOS)
#include <sys/mman.h>
namespace {
void* g_ios_jit_base = nullptr;
unsigned long g_ios_jit_size = 0;
int g_ios_jit_nest = 0;
}  // namespace
extern "C" void v8_ios_jit_wx_register_range(void* base, unsigned long size) {
  g_ios_jit_base = base;
  g_ios_jit_size = size;
  mprotect(base, size, PROT_READ | PROT_EXEC);
}
extern "C" void v8_ios_jit_wx_set_writable() {
  if (g_ios_jit_nest++ == 0 && g_ios_jit_base) {
    mprotect(g_ios_jit_base, g_ios_jit_size, PROT_READ | PROT_WRITE);
  }
}
extern "C" void v8_ios_jit_wx_set_executable() {
  if (g_ios_jit_nest > 0 && --g_ios_jit_nest == 0 && g_ios_jit_base) {
    mprotect(g_ios_jit_base, g_ios_jit_size, PROT_READ | PROT_EXEC);
  }
}
#endif

namespace v8 {'''
s = s.replace(anchor, inject, 1)
if s == o: raise SystemExit("cma.cc anchor not found")
open(p, "w").write(s)

# 2) code-memory-access-inl.h: wire the empty fallback to the extern-C toggles.
p = "deps/v8/src/common/code-memory-access-inl.h"
s = open(p).read(); o = s
anchor = '''// static
bool RwxMemoryWriteScope::IsSupported() { return false; }

// static
void RwxMemoryWriteScope::SetWritable() {}

// static
void RwxMemoryWriteScope::SetExecutable() {}'''
inject = '''#if defined(V8_OS_IOS)
extern "C" void v8_ios_jit_wx_set_writable();
extern "C" void v8_ios_jit_wx_set_executable();
// static
bool RwxMemoryWriteScope::IsSupported() { return true; }
// static
void RwxMemoryWriteScope::SetWritable() { v8_ios_jit_wx_set_writable(); }
// static
void RwxMemoryWriteScope::SetExecutable() { v8_ios_jit_wx_set_executable(); }
#else
// static
bool RwxMemoryWriteScope::IsSupported() { return false; }
// static
void RwxMemoryWriteScope::SetWritable() {}
// static
void RwxMemoryWriteScope::SetExecutable() {}
#endif'''
s = s.replace(anchor, inject, 1)
if s == o: raise SystemExit("cma-inl.h anchor not found")
open(p, "w").write(s)

# 3) code-range.cc: register the code range base/size for toggling.
p = "deps/v8/src/heap/code-range.cc"
s = open(p).read(); o = s
anchor = '''    if (!params.page_allocator->DiscardSystemPages(base, size)) return false;
  }
  return true;
}'''
inject = '''    if (!params.page_allocator->DiscardSystemPages(base, size)) return false;
  }
#if defined(V8_OS_IOS)
  {
    extern "C" void v8_ios_jit_wx_register_range(void*, unsigned long);
    v8_ios_jit_wx_register_range(reinterpret_cast<void*>(base()), size());
  }
#endif
  return true;
}'''
s = s.replace(anchor, inject, 1)
if s == o: raise SystemExit("code-range.cc anchor not found")
open(p, "w").write(s)

print("fixup: V8 mprotect W^X JIT patch applied (3 files)")
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
