#!/bin/sh
# iOS cross-compile source fixups for a JITLESS Node.js tree with DrumBrake (V8's
# WebAssembly interpreter). Applied after clone, before configure.
#
# Why this exists: the A9 (no APRR/PKU) can only do JIT single-threaded (process-global
# W^X), but OpenClaw uses worker_threads -> JIT SIGBUSes. So the runtime is JITLESS.
# But jitless disables WASM, and undici/fetch's llhttp IS WASM. DrumBrake is V8's jitless
# WASM interpreter (--jitless --wasm-jitless). It exists in Node 24's V8 but is GN-only —
# Node's GYP build doesn't wire it — so we hand-wire it here.
#
# Contains ONLY: the shared iOS build fixups + DrumBrake GYP wiring + the WASM guard-region
# patch. NO JIT W^X patch set (that lives in the JIT build, scripts/ios-source-fixups.sh).
set -eux
SRC="${1:?usage: ios-source-fixups-drumbrake.sh <node-src-dir>}"
cd "$SRC"

# --- gyp make generator: drop GNU --start-group/--end-group ---
# Apple's ld64 (host tools + iOS target) rejects those flags and resolves archives globally.
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
# crypto_context.cc uses SecTrustSettings* (macOS-only) under `#ifdef __APPLE__`. Narrow to
# TARGET_OS_OSX so it's excluded on iOS. Bundled Mozilla roots handle TLS.
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
# The gyp make generator only applies xcode_settings.OTHER_LDFLAGS for flavor=="mac". Inject
# CoreFoundation/CoreServices/Security as plain link_settings.libraries for OS=="ios".
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

# --- DrumBrake WASM interpreter wiring + iOS WASM guard-region off ---
# Node's GYP build does NOT know about DrumBrake. Wire it in: declare the feature vars +
# emit the defines in features.gypi (so BOTH host mksnapshot and target libv8 agree on the
# builtin set — else snapshot/runtime mismatch = boot crash), add the interpreter
# source/header/builtin files to v8.gyp, and force WASM guard regions off on iOS. On arm64
# V8_DRUMBRAKE_BOUNDS_CHECKS is always on, so only the C++ interpreter + 4 wrapper builtins
# compile (the ~192 asm instruction-handlers are x64-only). Anchors validated vs v24.18.0.
python3 - <<'PY'
def patch(path, anchor, inject):
    s = open(path).read()
    n = s.count(anchor)
    if n != 1:
        raise SystemExit("anchor count=%d (need 1) in %s :: %r" % (n, path, anchor[:70]))
    open(path, "w").write(s.replace(anchor, inject, 1))
    print("fixup drumbrake: patched", path)

# (1a) features.gypi: declare the DrumBrake feature variables.
patch("tools/v8_gypfiles/features.gypi",
"""    # Sets -dV8_ENABLE_WEBASSEMBLY.
    'v8_enable_webassembly%': 1,""",
"""    # Sets -dV8_ENABLE_WEBASSEMBLY.
    'v8_enable_webassembly%': 1,

    # WebAssembly interpreter (DrumBrake). Sets -dV8_ENABLE_DRUMBRAKE.
    'v8_enable_drumbrake%': 1,
    'v8_enable_drumbrake_tracing%': 0,
    # Explicit in-handler bounds checks (mandatory on iOS: guard regions are off).
    'v8_drumbrake_bounds_checks%': 1,""")

# (1b) features.gypi: map the vars -> defines (applies to every V8 target, both toolsets).
patch("tools/v8_gypfiles/features.gypi",
"""      ['v8_enable_webassembly==1', {
        'defines': ['V8_ENABLE_WEBASSEMBLY',],
      }],""",
"""      ['v8_enable_webassembly==1', {
        'defines': ['V8_ENABLE_WEBASSEMBLY',],
      }],
      ['v8_enable_drumbrake==1', {
        'defines': ['V8_ENABLE_DRUMBRAKE',],
      }],
      ['v8_enable_drumbrake_tracing==1', {
        'defines': ['V8_ENABLE_DRUMBRAKE_TRACING',],
      }],
      ['v8_drumbrake_bounds_checks==1', {
        'defines': ['V8_DRUMBRAKE_BOUNDS_CHECKS',],
      }],""")

# (2) v8.gyp v8_base_without_compiler: the 4 interpreter .cc (explicit paths). RAW anchor.
patch("tools/v8_gypfiles/v8.gyp",
r'''        ['v8_enable_webassembly==1', {
          'sources': [
            '<!@pymod_do_main(GN-scraper "<(V8_ROOT)/BUILD.gn"  "\\"v8_base_without_compiler.*?v8_enable_webassembly.*?sources \\+= ")',
          ],
        }],''',
r'''        ['v8_enable_webassembly==1', {
          'sources': [
            '<!@pymod_do_main(GN-scraper "<(V8_ROOT)/BUILD.gn"  "\\"v8_base_without_compiler.*?v8_enable_webassembly.*?sources \\+= ")',
          ],
        }],
        ['v8_enable_drumbrake==1', {
          'sources': [
            '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter-objects.cc',
            '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter-runtime.cc',
            '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter-simd.cc',
            '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter.cc',
          ],
        }],''')

# (3) v8.gyp v8_internal_headers: the 7 interpreter headers. RAW anchor.
patch("tools/v8_gypfiles/v8.gyp",
r'''          ['v8_enable_webassembly==1', {
            'sources': [
              '<!@pymod_do_main(GN-scraper "<(V8_ROOT)/BUILD.gn"  "v8_header_set.\\"v8_internal_headers\\".*?v8_enable_webassembly.*?sources \\+= ")',
            ],
          }],''',
r'''          ['v8_enable_webassembly==1', {
            'sources': [
              '<!@pymod_do_main(GN-scraper "<(V8_ROOT)/BUILD.gn"  "v8_header_set.\\"v8_internal_headers\\".*?v8_enable_webassembly.*?sources \\+= ")',
            ],
          }],
          ['v8_enable_drumbrake==1', {
            'sources': [
              '<(V8_ROOT)/src/wasm/interpreter/instruction-handlers.h',
              '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter-inl.h',
              '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter-objects-inl.h',
              '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter-objects.h',
              '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter-runtime-inl.h',
              '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter-runtime.h',
              '<(V8_ROOT)/src/wasm/interpreter/wasm-interpreter.h',
            ],
          }],''')

# (4) v8.gyp v8_initializers: the arm64 interpreter builtin trampoline. Insert BEFORE the
# webassembly dependencies block (arm64-gated; host==target==arm64 on macos-14).
patch("tools/v8_gypfiles/v8.gyp",
"""        ['v8_enable_webassembly==1', {
          'dependencies': [
            'v8_initializers_slow',
          ],""",
"""        ['v8_enable_drumbrake==1 and v8_target_arch=="arm64"', {
          'sources': [
            '<(V8_ROOT)/src/wasm/interpreter/arm64/interpreter-builtins-arm64.cc',
          ],
        }],
        ['v8_enable_webassembly==1', {
          'dependencies': [
            'v8_initializers_slow',
          ],""")

# (F) backing-store.cc: force WASM guard regions OFF on iOS (var 'has_guard_regions' in V8 13.6).
# iOS refuses the multi-GB guard reservation; with guards off the reservation shrinks to byte
# capacity and V8_DRUMBRAKE_BOUNDS_CHECKS makes the interpreter self-bounds-check.
patch("deps/v8/src/objects/backing-store.cc",
"""  bool has_guard_regions =
      trap_handler::IsTrapHandlerEnabled() &&
      (wasm_memory == WasmMemoryFlag::kWasmMemory32 ||
       (is_wasm_memory64 && v8_flags.wasm_memory64_trap_handling));""",
"""#if defined(V8_OS_IOS)
  // iOS refuses the multi-GB guard-region reservation; disable guard regions so a WASM
  // memory reserves only its byte capacity. V8_DRUMBRAKE_BOUNDS_CHECKS makes the interpreter
  // do explicit in-handler bounds checks instead of relying on the (absent) guard.
  bool has_guard_regions = false;
#else
  bool has_guard_regions =
      trap_handler::IsTrapHandlerEnabled() &&
      (wasm_memory == WasmMemoryFlag::kWasmMemory32 ||
       (is_wasm_memory64 && v8_flags.wasm_memory64_trap_handling));
#endif""")

print("fixup: DrumBrake wired into GYP (features.gypi defines + v8.gyp sources) + iOS WASM guard-region off")
PY

# --- c-ares ---
# iOS SDK lacks <sys/random.h>; undef the header macro so ares_rand.c uses arc4random_buf.
if grep -q '#define HAVE_SYS_RANDOM_H 1' deps/cares/config/darwin/ares_config.h; then
  sed -i.bak 's|#define HAVE_SYS_RANDOM_H 1|/* undef HAVE_SYS_RANDOM_H (iOS SDK lacks it) */|' \
    deps/cares/config/darwin/ares_config.h
  echo "fixup: c-ares HAVE_SYS_RANDOM_H undef'd"
fi

echo "ios-source-fixups-drumbrake: done"
