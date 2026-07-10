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

# --- V8: don't use MAP_JIT on iOS ---
# platform-posix.cc requests MAP_JIT pages for all Darwin. On the A9 MAP_JIT returns EINVAL
# (it's an A11+/APRR feature), so we exclude iOS and let V8 fall back to plain anonymous
# pages that our mprotect W^X mechanism (below) can flip. iOS-only.
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
print("fixup: V8 no longer uses MAP_JIT on iOS (falls back to plain pages + mprotect W^X)")
PY

# --- V8: full JIT on pre-APRR iOS (A9/A10) via mprotect W^X ---
# V8 only WRAPS its code-space writes (allocation, free-list, GC, patching) in
# "make-writable-first" scopes when V8_HAS_PTHREAD_JIT_WRITE_PROTECT is set — which
# build_config.h hard-codes OFF for real iOS devices (on only for macOS + iOS simulator).
# With it off, V8 assumes code memory is permanently RWX and writes unguarded; those writes
# then fault the instant a page is RX (observed on-device: EXC_BAD_ACCESS code=2, a WRITE
# fault, in FreeListManyCachedFastPathBase::Allocate during Sparkplug code allocation).
# Fix, 4 files:
#   (A) turn the macro ON for iOS device too -> activates ALL of V8's write wrapping
#       (the machinery is already correct for APRR Macs; it was just switched off).
#   (B/C) reroute the actual flip primitive from pthread_jit_write_protect_np (a no-op on
#       the A9) to mprotect over the registered code range.
#   (D) register that bounded code region, and skip the macOS-only RWX code-range setup on
#       iOS (iOS rejects RWX; committed code pages start RW).
# Run node --predictable so the process-wide mprotect flip has no W^X race with a
# background compiler thread.
python3 - <<'PY'
def patch(path, anchor, inject):
    s = open(path).read()
    if anchor not in s:
        raise SystemExit("anchor NOT found in " + path + " :: " + repr(anchor[:70]))
    open(path, "w").write(s.replace(anchor, inject, 1))

# (A) build_config.h: enable the pthread-JIT-write-protect macro on iOS device too.
patch("deps/v8/src/base/build_config.h",
'''#if defined(V8_HOST_ARCH_ARM64) && \\
    (defined(V8_OS_MACOS) || (defined(V8_OS_IOS) && TARGET_OS_SIMULATOR))
#define V8_HAS_PTHREAD_JIT_WRITE_PROTECT 1''',
'''#if defined(V8_HOST_ARCH_ARM64) && \\
    (defined(V8_OS_MACOS) || defined(V8_OS_IOS))
#define V8_HAS_PTHREAD_JIT_WRITE_PROTECT 1''')

# (B) platform.h: declare RegisterJitRange alongside SetJitWriteProtected.
patch("deps/v8/src/base/platform/platform.h",
'''#if V8_HAS_PTHREAD_JIT_WRITE_PROTECT
V8_BASE_EXPORT void SetJitWriteProtected(int enable);
#endif''',
'''#if V8_HAS_PTHREAD_JIT_WRITE_PROTECT
V8_BASE_EXPORT void SetJitWriteProtected(int enable);
#if defined(V8_OS_IOS)
V8_BASE_EXPORT void RegisterJitRange(void* base, size_t size);
#endif
#endif''')

# (C) platform-darwin.cc: on iOS the flip is done directly with mprotect (exactly
# what the on-device probe validated) over the registered range. The stock definition
# is guarded to NON-iOS; add the iOS one after its #endif.
patch("deps/v8/src/base/platform/platform-darwin.cc",
'''V8_BASE_EXPORT void SetJitWriteProtected(int enable) {
  pthread_jit_write_protect_np(enable);
}

#pragma clang diagnostic pop
#endif''',
'''V8_BASE_EXPORT void SetJitWriteProtected(int enable) {
  pthread_jit_write_protect_np(enable);
}

#pragma clang diagnostic pop
#endif
#if V8_HAS_PTHREAD_JIT_WRITE_PROTECT && defined(V8_OS_IOS)
// Real iOS arm64 (A9/A10) enforces W^X even for dynamic-codesigning processes:
// pthread_jit_write_protect_np is a no-op and an RWX request is silently
// downgraded to RW. So flip each registered code range RW<->RX via mprotect.
// There are SEVERAL such ranges: the JS code range (registered in code-range.cc)
// and every committed WASM code region (registered in wasm-code-manager.cc) --
// WASM has its own code space that the single JS range does not cover, so a
// one-range flip leaves WASM pages RW and their jump table faults on execute.
// Nesting is handled by RwxMemoryWriteScope, which calls this only at the
// outermost level. Run node --predictable --single-threaded so the process-wide
// flip has no W^X race with a background compiler thread.
namespace {
struct JitRange {
  void* base;
  size_t size;
};
constexpr int kMaxJitRanges = 256;
JitRange g_jit_ranges[kMaxJitRanges];
int g_jit_range_count = 0;
}  // namespace
V8_BASE_EXPORT void RegisterJitRange(void* base, size_t size) {
  if (base == nullptr || size == 0) return;
  for (int i = 0; i < g_jit_range_count; i++) {
    if (g_jit_ranges[i].base == base) {
      g_jit_ranges[i].size = size;
      return;
    }
  }
  if (g_jit_range_count < kMaxJitRanges) {
    g_jit_ranges[g_jit_range_count].base = base;
    g_jit_ranges[g_jit_range_count].size = size;
    g_jit_range_count++;
  }
}
V8_BASE_EXPORT void SetJitWriteProtected(int enable) {
  int prot = enable ? (PROT_READ | PROT_EXEC) : (PROT_READ | PROT_WRITE);
  for (int i = 0; i < g_jit_range_count; i++) {
    // Best-effort: a registered range can be unmapped during isolate/heap
    // teardown while still listed here, after which mprotect fails harmlessly
    // (observed on-device: a CHECK_EQ abort in Heap::TearDown *after* the script
    // ran fine). The flip is proven to succeed for live ranges during operation,
    // so on failure just drop the now-freed range instead of aborting.
    if (mprotect(g_jit_ranges[i].base, g_jit_ranges[i].size, prot) != 0) {
      g_jit_ranges[i] = g_jit_ranges[--g_jit_range_count];
      i--;
    }
  }
}
#endif''')

# (D0) code-range.cc: pull in platform.h so ::v8::base::RegisterJitRange is
# declared (allocation.h, already included, does not transitively provide it).
patch("deps/v8/src/heap/code-range.cc",
'''#include "src/utils/allocation.h"''',
'''#include "src/utils/allocation.h"
#include "src/base/platform/platform.h"''')

# (D) code-range.cc: on iOS skip the macOS-only RWX code-range setup (iOS rejects
# RWX and CHECK_EQ(reserved_area,0) may not hold) and instead register the bounded
# code region for the mprotect flip. Committed code pages start RW.
patch("deps/v8/src/heap/code-range.cc",
'''  if (V8_HEAP_USE_PTHREAD_JIT_WRITE_PROTECT &&
      params.jit == JitPermission::kMapAsJittable) {''',
'''#if !defined(V8_OS_IOS)
  if (V8_HEAP_USE_PTHREAD_JIT_WRITE_PROTECT &&
      params.jit == JitPermission::kMapAsJittable) {''')

patch("deps/v8/src/heap/code-range.cc",
'''    if (!params.page_allocator->DiscardSystemPages(base, size)) return false;
  }
  return true;
}''',
'''    if (!params.page_allocator->DiscardSystemPages(base, size)) return false;
  }
#else
  ::v8::base::RegisterJitRange(
      reinterpret_cast<void*>(page_allocator_->begin()),
      page_allocator_->size());
#endif
  return true;
}''')

# (E) wasm-code-manager.cc: WASM has its OWN code space (separate from the JS
# code range), committed via WasmCodeManager::Commit with kReadWriteExecute. On
# iOS that RWX request is silently downgraded to RW, so WASM code is never
# executable -> its jump table faults on the first call (observed on-device:
# EXC_BAD_ACCESS code=2 executing a RW WASM jump-table page, right after
# WebAssembly.Module compiles). WASM code writes already go through
# RwxMemoryWriteScope -> base::SetJitWriteProtected (same chain the JS JIT uses),
# so the ONLY missing piece is that the WASM region isn't in the flip's range
# set. Fix: commit the WASM region RW (not the downgraded RWX) and register it,
# so the same mprotect W^X flip toggles it RW<->RX exactly like the JS range.
#
# (E1) request kReadWrite on iOS instead of kReadWriteExecute.
patch("deps/v8/src/wasm/wasm-code-manager.cc",
'''  // Allocate with RWX permissions; this will be restricted via PKU if
  // available and enabled.
  PageAllocator::Permission permission = PageAllocator::kReadWriteExecute;''',
'''  // Allocate with RWX permissions; this will be restricted via PKU if
  // available and enabled.
#if defined(V8_OS_IOS)
  // iOS enforces W^X even for dynamic-codesigning processes: an RWX request is
  // silently downgraded to RW, so WASM code would never become executable.
  // Commit RW and register the region (below) with the same mprotect W^X flip
  // the JS code range uses.
  PageAllocator::Permission permission = PageAllocator::kReadWrite;
#else
  PageAllocator::Permission permission = PageAllocator::kReadWriteExecute;
#endif''')

# (E2) after the (non-PKU) commit succeeds, register the WASM region for the flip.
patch("deps/v8/src/wasm/wasm-code-manager.cc",
'''    success = SetPermissions(GetPlatformPageAllocator(), region.begin(),
                             region.size(), permission);
  }

  if (V8_UNLIKELY(!success)) {''',
'''    success = SetPermissions(GetPlatformPageAllocator(), region.begin(),
                             region.size(), permission);
#if defined(V8_OS_IOS)
    if (success) {
      ::v8::base::RegisterJitRange(reinterpret_cast<void*>(region.begin()),
                                   region.size());
    }
#endif
  }

  if (V8_UNLIKELY(!success)) {''')

print("fixup: iOS full-JIT via mprotect W^X (multi-range flip; JS code range + WASM code regions; build_config/platform.h/platform-darwin/code-range/wasm-code-manager)")
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
