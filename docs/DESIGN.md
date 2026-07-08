# OpenClaw on Jailbroken iOS 15 (arm64, Dopamine rootless) — Native Node Gateway Porting Plan

Target device: iPhone 6s Plus (Apple A9, arm64 / ARMv8.0-A, **not** arm64e), iOS 15.8.x, Dopamine (KFD, rootless, `/var/jb`, dpkg arch `iphoneos-arm64`), ~2 GB RAM. Delivery: `.deb` via Sileo. Build: GitHub Actions only, no local builds.

---

## 1. Feasibility verdict + the single biggest risk

**Verdict: Feasible, but this is an R&D port, not an integration task.** Nothing here is a solved, off-the-shelf path — you are building the first known Node ≥22 `iphoneos-arm64` binary and the first OpenClaw iOS service adapter. Every load-bearing dependency question, however, resolves in your favor:

- OpenClaw's datastore is Node's **built-in `node:sqlite`**, not a native addon (no `better-sqlite3`, no `sql.js`). A stock Node build with SQLite compiled in (the default) satisfies the single boot-critical requirement — **zero native addons to cross-compile for the gateway to boot.**
- The only *mandatory-looking* native addon (`@lydell/node-pty`) is lazy-loaded and degrades gracefully; the gateway boots without it.
- The build tree ships as a plain `npm install --omit=dev` layout (the repo's own `portable-windows-build.yml` does exactly this), and packaging a rootless daemon `.deb` for Dopamine is a well-documented, adhoc-signed (`ldid`) flow with automatic trust-caching — no manual trustcache step.

**The single biggest risk is the Node runtime itself, at the intersection of three unsolved facts:**

1. **No fork or repo ships Node ≥20 for iOS.** The ceiling is nodejs-mobile **18.20.4** (an *embeddable framework*, not a CLI) and the jailbreak-oriented `1Conan/node` fork **17.6.0** (frozen Oct 2022). OpenClaw hard-requires **Node ≥22.19** (enforced as a string check in `openclaw.mjs:11-61`; it `process.exit(1)`s otherwise) because that is the `node:sqlite`-unflagged floor. So you must forward-port a fork's V8/iOS patch set from 18 → 24 — mainline's `--dest-os=ios` scaffolding exists but no known-good ≥22 patch set does.
2. **The WASM-vs-jitless collision.** OpenClaw loads three WASM modules (`quickjs-wasi` for code-mode, `tree-sitter-bash` for command-explainer, `photon` for image fallback). iOS forbids JIT/RWX without the `dynamic-codesigning` entitlement, so the "safe" build is `--jitless` — **but `--jitless` disables WebAssembly entirely on Node 22 (V8 12.4), which has no DrumBrake WASM interpreter.** You cannot have both jitless *and* WASM on Node 22.
3. **JIT on the A9 is unverified.** The A9 is pre-APRR and pre-PPL. On a jailbreak you *can* grant `dynamic-codesigning` and get plain RWX (easier than on a modern arm64e device), but V8's Apple arm64 codegen path assumes APRR hardware the A9 lacks. Whether an unmodified V8 initializes code space correctly on A9 is the make-or-break empirical unknown.

**The concrete failure mode this creates:** you ship a Node binary, it passes the version gate, the gateway boots on `node:sqlite` — and then code-mode / command-explainer throw at runtime because WASM won't instantiate, *or* the JIT build won't allocate executable memory on the A9 and V8 aborts on startup.

**The resolution (see §2) is to target Node 24, not 22** — Node 24's V8 (13.6) contains DrumBrake, which restores interpreted WASM under jitless via a custom build flag. This is the pivotal decision in this plan. Mitigating this one risk cluster is 70% of the project; the daemon/packaging work is comparatively routine.

---

## 2. Node runtime strategy

### 2.1 Exact target

| Property | Decision |
|---|---|
| Version | **Node 24.x (latest LTS)**, not 22. Rationale below. |
| Satisfies OpenClaw gate | Yes — `>=22.19 <23 \|\| >=23.11`; Node 24 clears `>=23.11`, and `openclaw.mjs` recommends 24 explicitly. |
| Arch / OS | `iphoneos-arm64`, `--dest-cpu=arm64 --dest-os=ios`, `IPHONEOS_DEPLOYMENT_TARGET=15.0` |
| Verify minos | `otool -l node \| grep -A3 LC_BUILD_VERSION` → platform iOS, minos 15.0 |
| ABI | Single binary; **all WASM is core-portable, and there are no runtime native addons to ABI-match** (node:sqlite is built-in). node-pty is the only addon and it is dropped. |

**Why 24 over 22:** Node 22 = V8 12.4, which predates the DrumBrake WASM interpreter. Under `--jitless`, Node 22 has *no* way to run WebAssembly. Node 24 = V8 13.6, which contains DrumBrake; built with `v8_enable_drumbrake=true` and launched `--jitless --wasm-jitless`, it runs WASM in an interpreter with **no JIT and no entitlement**. This is the only way to get all of {satisfies OpenClaw's version floor} ∧ {runs jitless / no risky entitlement} ∧ {WASM works}. Choosing 22 would force you into the JIT path (unverified on A9) to keep WASM.

### 2.2 Build approach — GitHub Actions macOS runner

Runner: `macos-14` (arm64, full Xcode + iPhoneOS SDK). Do **not** attempt to bump straight to 24 from mainline cold. Sequence: **start from the proven nodejs-mobile 18.20.4 patch series, confirm it builds/links/runs jitless, then forward-port to 20 → 24**, resolving V8 `OS=="ios"` codegen and `src/` posix/spawn diffs at each step.

Canonical configure (adapted from nodejs-mobile's `tools/ios_framework_prepare.sh`, with OpenClaw's corrections applied):

```bash
export IPHONEOS_DEPLOYMENT_TARGET=15.0
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
export GYP_DEFINES="target_arch=arm64 host_os=mac target_os=ios"
export CC_host=clang CXX_host="clang++ -std=gnu++17"
export CC="clang -arch arm64 -isysroot $SDK -miphoneos-version-min=15.0"
export CXX="clang++ -std=gnu++17 -arch arm64 -isysroot $SDK -miphoneos-version-min=15.0"
export LDFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0 -undefined dynamic_lookup"
./configure \
  --dest-os=ios --dest-cpu=arm64 --cross-compiling \
  --with-intl=small-icu \        # NOT none — OpenClaw uses Intl.DateTimeFormat/tz at runtime
  --without-npm \
  --without-node-snapshot \      # avoids host-runs-target mksnapshot pain
  --without-node-code-cache \
  --without-inspector \
  --openssl-no-asm               # keep OpenSSL + bundled CA; do NOT --without-ssl / --without-bundled-ca
make -j$(sysctl -n hw.ncpu)
ldid -Sentitlements.plist out/Release/node
```

**Non-negotiable build inclusions (from the node-features audit):**
- **SQLite compiled in** (default; never `--without-sqlite`). Keep extension loading (do **not** set `SQLITE_OMIT_LOAD_EXTENSION`) so sqlite-vec has a chance later.
- **Intl with ICU** — `--with-intl=small-icu` minimum (English + full IANA tz DB, sufficient because runtime only formats `en-US`/`en-CA`), `full-icu --download=all` if non-English host-default locale formatting matters. **Never `--with-intl=none`** — nodejs-mobile's recipe uses `none`, but that would break `src/agents/date-time.ts` tz formatting. `--download=all` sidesteps cross-building ICU host tools.
- **OpenSSL + bundled Mozilla CA store** — iOS has no `/etc/ssl/cert.pem` and no Node-visible system trust; without bundled CAs all outbound TLS to model providers fails.
- **worker_threads enabled** (default) — code-mode, audit writer, compaction planner all use it.
- **WebStreams / structuredClone / undici / ESM** — all standard, no flags.

### 2.3 JIT vs jitless decision — and the WASM resolution

Run **jitless as the primary/shipping mode**, with DrumBrake for WASM. Reasoning:

- Jitless is **guaranteed to run** on the A9 with no entitlement gymnastics (no APRR dependency, no RWX). This is the same path that first made Node-on-iOS work in 2019.
- Performance cost is acceptable for OpenClaw's profile: V8 measures ~40% slower on Speedometer, but this is an **I/O-bound personal gateway** (mostly awaiting LLM network calls). Steady-state latency is network-dominated. The one hazard is the **RegExp interpreter** (no JIT'd regexp) — a pathological regex becomes a self-DoS; audit config/user regexes.
- **WASM resolution — the key move:** build Node 24 with `v8_enable_drumbrake=true` (a V8 GN/gyp flag — wire it through `common.gypi` / `GYP_DEFINES`, since the default Node build does **not** set it) and launch `node --jitless --wasm-jitless`. This gives interpreted WASM with no JIT. Verify each of the three modules loads (DrumBrake is experimental and may not implement SIMD/threads/GC — see open questions).

**Critical mitigating fact: none of the three WASM modules is boot-critical.** All are lazy/optional (`code-mode.worker.ts`, `command-explainer/tree-sitter-runtime.ts`, `media/photon.runtime.ts`). So even a *plain jitless build with WASM entirely broken still boots the full gateway* — only code-mode, shell-command explanation, and one image-conversion fallback degrade. This lets you ship an MVP before DrumBrake is proven.

**Secondary/fallback path — real JIT:** omit `--jitless`, sign the binary with `dynamic-codesigning` (+ `platform-application`, `get-task-allow`) via `ldid -S`. On the A9 (no `pmap_cs`/PPL) the `jb.pmap_cs.custom_trust` entitlement is irrelevant — `dynamic-codesigning` alone should suffice once Dopamine's `systemhook`/`launchdhook` trust-caches the cdhash. If this works, you keep TurboFan **and** full-speed WASM with zero build customization. **But V8's A9-without-APRR behavior is unverified — treat JIT as a spike, not the plan.**

**Decision, ranked:** (1) jitless + DrumBrake (Node 24) — primary. (2) real JIT via `dynamic-codesigning` — attempt in a spike; if it works on-device it is strictly better (full speed + WASM free). (3) plain jitless, WASM features disabled — guaranteed-shippable MVP. (4) native N-API replacements for the 3 WASM modules — last resort (native `tree-sitter`, native QuickJS, drop photon), viable because unsigned dylibs load freely under jailbreak, but each needs its own iOS arm64 cross-build.

Set at launch (env or NODE_OPTIONS, since the self-respawn that normally injects these is disabled — see §5): `--disable-warning=ExperimentalWarning` (node:sqlite emits a suppressed ExperimentalWarning), `--max-old-space-size=512`, `--max-semi-space-size=16`.

---

## 3. Dependency plan

OpenClaw externalizes nearly all deps at build time (tsdown `platform:"node"`), so **the full production `node_modules` must ship** — `dist/` is not self-contained. WASM `.wasm` blobs live inside `node_modules` and are resolved via `require.resolve`; ship those packages whole (never prune to JS-only).

| Dependency | Type | Verdict | How |
|---|---|---|---|
| **`node:sqlite` (DatabaseSync)** | **Node core builtin** (compiled against `deps/sqlite`) | **SHIP-NATIVE (in the node binary)** | Boot-critical. **Not an addon** — no `better-sqlite3`/`sql.js` anywhere. Build node with SQLite (default). Verify `node -e "new (require('node:sqlite').DatabaseSync)(':memory:')"`. No `--experimental-sqlite` flag needed on ≥22.19. **This is the whole ballgame and it costs zero addon work.** |
| **`@lydell/node-pty`** | Native N-API addon (no iOS prebuild) | **STUB / disable-feature** | Lazy-loaded (`src/gateway/terminal/pty.ts:46`); gateway boots without it. Leave uninstalled → loader throws "PTY unavailable" only when a shell is spawned. If interactive terminal is needed, write a `child_process` pipe adapter behind the same `PtyAdapter` contract (spawn *does* work under the jailbreak — see §5), sacrificing tty resize/echo. |
| `sqlite-vec` | Native SQLite loadable ext (`.dylib`, no iOS variant) | **disable-feature** | `dlopen` of arbitrary dylibs is loader-restricted; vector memory search degrades gracefully (`memory-host-sdk/src/host/sqlite-vec.ts`). Keep extension-loading compiled in; optionally cross-compile `vec0` for ios-arm64 later and set `memorySearch.store.vector.extensionPath`. |
| `playwright-core` | Pure JS + needs Chromium binary | **disable-feature** (or remote CDP) | Optional browser extension. No iOS Chromium. Either leave the extension off, or point it at a remote browser via `connectOverCDP`. Package itself installs fine. |
| `web-tree-sitter` + `tree-sitter-bash` | **WASM** | **OK (needs WASM engine)** | Ship `.wasm` grammar; runs under DrumBrake/JIT. Lazy (command-explainer). |
| `quickjs-wasi` | **WASM/WASI** | **OK (needs WASM engine)** | Ship `quickjs.wasm`. Lazy (code-mode worker). Uses Node WASI → also needs WASM instantiation. |
| `@silvia-odwyer/photon-node` | **WASM** | **OK** | Ship wasm; lazy image conversion. |
| `rastermill` | Pure JS + WASM (photon) | **OK** | Statically imported in `image-ops.ts` but has **no** native prebuild — boot-safe. `execution:'auto'` degrades cleanly (no `sips`/`magick` on iOS). |
| `clawpdf` | Self-contained WASM/JS (no addon) | **OK / disable** | Optional document-extract extension; lazy `createEngine()`. |
| `file-type` | Pure JS | **OK** | — |
| `web-push` | Pure JS (needs `crypto`) | **OK** | Needs OpenSSL EC P-256 (present). Lazy. |
| `node-edge-tts` | Pure JS (cloud) | **OK** | Optional Microsoft TTS; needs network. |
| `@homebridge/ciao` | Pure JS mDNS/UDP | **disable-feature / verify** | Imports fine; needs multicast UDP `dgram` — verify jailbreak sandbox permits it, else disable bonjour (non-essential). |
| `@matrix-org/matrix-sdk-crypto-nodejs` | Native (Rust N-API, node≥24, no iOS) | **disable / use WASM sibling** | Matrix extension only. Force `@matrix-org/matrix-sdk-crypto-wasm`, or disable Matrix. |
| esbuild / oxc / tsdown / tsx | Native, dev-only | **OK (build off-device)** | Never runs on device. Build `dist/` on the macOS runner. No iOS binaries exist; on-device build is not viable. |

**Explicit `node:sqlite` vs native sqlite call-out:** OpenClaw uses the *Node-core builtin* `node:sqlite`, loaded via `createRequire()('node:sqlite')` in `src/infra/node-sqlite.ts:11-14` and `packages/memory-host-sdk/src/host/sqlite.ts:17-20`. There is **no** `better-sqlite3` and **no** `sql.js`/wasm sqlite in runtime code. Consequence: you do **not** cross-compile any sqlite addon — you only ensure the node binary bundles SQLite. This is the biggest single de-risking fact in the whole port.

**Explicit `node-pty` call-out:** it is the *only* genuine runtime native N-API addon OpenClaw depends on, ships prebuilds for darwin/linux/win only, and is lazy. Ship without it; terminal/PTY-exec features are the only casualties, and they are not on the boot path.

---

## 4. Runtime file tree shipped in the `.deb` (under `/var/jb`)

All payload under `/var/jb`; binaries adhoc-signed with `ldid`; daemon plist `root:wheel 0644`; node binary `0755`. State dir is set explicitly to a stable, writable, uid-consistent path so the app UI and daemon never diverge.

```
/var/jb/
├── usr/
│   ├── bin/
│   │   └── openclaw                      # wrapper script -> exec node openclaw.mjs "$@"   (0755)
│   └── lib/openclaw/
│       ├── node                          # our Node 24 iphoneos-arm64 binary, ldid-signed (0755)
│       └── app/
│           └── node_modules/
│               ├── openclaw/
│               │   ├── openclaw.mjs       # launcher (bin) — invoked directly, not via symlink
│               │   ├── package.json       # read for version/entry; version must be present
│               │   ├── npm-shrinkwrap.json
│               │   ├── dist/              # tsdown output: entry.js + hashed chunks +
│               │   │   │                  #   channel-catalog.json, build-info.json,
│               │   │   │                  #   cli-startup-metadata.json, postinstall-inventory.json
│               │   │   ├── extensions/    # bundled lightweight plugins (telegram compiled in)
│               │   │   └── plugin-sdk/
│               │   │   # dist/control-ui/  OMITTED (headless; build:docker excludes ui:build)
│               │   ├── scripts/*.mjs      # runtime helpers whitelisted by package.json files[]
│               │   └── src/agents/templates/  # scaffolding only (NO src/entry.ts, NO .git)
│               ├── quickjs-wasi/quickjs.wasm            # WASM assets — ship WHOLE packages
│               ├── web-tree-sitter/…                    #   (require.resolve walks node_modules)
│               ├── tree-sitter-bash/tree-sitter-bash.wasm
│               ├── @silvia-odwyer/photon-node/…
│               └── <all other production deps>          # express, ws, grammy, undici, openai,
│                                                        #   @anthropic-ai/sdk, MCP sdk, kysely,
│                                                        #   web-push, file-type, rastermill, …
│                                                        #   (NO @lydell/node-pty, NO sqlite-vec,
│                                                        #    NO playwright browser, NO control-ui)
├── etc/openclaw/
│   └── openclaw.env                       # sourced by wrapper / referenced by plist (0600)
├── var/
│   ├── mobile/openclaw/                   # OPENCLAW_STATE_DIR — state DB, config, secrets, tmp/
│   └── log/openclaw/
│       ├── gateway.log
│       └── gateway.err.log
└── Library/LaunchDaemons/
    └── ai.openclaw.gateway.plist          # root:wheel 0644
```

**`/var/jb/usr/bin/openclaw` (wrapper, 0755):**
```sh
#!/bin/sh
set -eu
[ -f /var/jb/etc/openclaw/openclaw.env ] && . /var/jb/etc/openclaw/openclaw.env
exec /var/jb/usr/lib/openclaw/node \
  /var/jb/usr/lib/openclaw/app/node_modules/openclaw/openclaw.mjs "$@"
```

**`/var/jb/etc/openclaw/openclaw.env` (0600):**
```sh
export HOME=/var/root
export OPENCLAW_STATE_DIR=/var/jb/var/mobile/openclaw
export OPENCLAW_CONFIG_PATH=/var/jb/var/mobile/openclaw/openclaw.json
export TMPDIR=/var/jb/var/mobile/openclaw/tmp
export NODE_EXTRA_CA_CERTS=/var/jb/etc/ssl/cert.pem   # verify this path exists on device
export PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/var/jb/usr/sbin:/sbin
export OPENCLAW_NO_RESPAWN=1                            # keep single predictable process under launchd
export NODE_DISABLE_COMPILE_CACHE=1                     # avoid compile-cache respawn branch
export UV_THREADPOOL_SIZE=3
export OPENCLAW_MAX_WORKERS=1                           # honored by patched worker call-sites (§5)
export NODE_OPTIONS=--disable-warning=ExperimentalWarning
export OPENCLAW_GATEWAY_PORT=18789
export OPENCLAW_SERVICE_MARKER=openclaw
export OPENCLAW_SERVICE_KIND=gateway
# gateway auth token injected here (0600 file keeps it non-world-readable)
export OPENCLAW_GATEWAY_TOKEN=__TOKEN__
```

**`/var/jb/Library/LaunchDaemons/ai.openclaw.gateway.plist` (root:wheel 0644):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>ai.openclaw.gateway</string>
  <key>ProgramArguments</key>
  <array>
    <string>/var/jb/usr/lib/openclaw/node</string>
    <string>--jitless</string>
    <string>--wasm-jitless</string>
    <string>--max-old-space-size=512</string>
    <string>--max-semi-space-size=16</string>
    <string>/var/jb/usr/lib/openclaw/app/node_modules/openclaw/openclaw.mjs</string>
    <string>gateway</string>
    <string>--port</string><string>18789</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>/var/root</string>
    <key>OPENCLAW_STATE_DIR</key><string>/var/jb/var/mobile/openclaw</string>
    <key>OPENCLAW_CONFIG_PATH</key><string>/var/jb/var/mobile/openclaw/openclaw.json</string>
    <key>TMPDIR</key><string>/var/jb/var/mobile/openclaw/tmp</string>
    <key>NODE_EXTRA_CA_CERTS</key><string>/var/jb/etc/ssl/cert.pem</string>
    <key>PATH</key><string>/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin</string>
    <key>OPENCLAW_NO_RESPAWN</key><string>1</string>
    <key>NODE_DISABLE_COMPILE_CACHE</key><string>1</string>
    <key>UV_THREADPOOL_SIZE</key><string>3</string>
    <key>OPENCLAW_MAX_WORKERS</key><string>1</string>
    <key>NODE_OPTIONS</key><string>--disable-warning=ExperimentalWarning</string>
    <key>OPENCLAW_GATEWAY_TOKEN</key><string>__TOKEN__</string>
  </dict>
  <key>UserName</key><string>root</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ExitTimeOut</key><integer>20</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardInPath</key><string>/dev/null</string>
  <key>StandardOutPath</key><string>/var/jb/var/log/openclaw/gateway.log</string>
  <key>StandardErrorPath</key><string>/var/jb/var/log/openclaw/gateway.err.log</string>
  <key>WorkingDirectory</key><string>/var/jb/var/mobile/openclaw</string>
  <!-- Consider JetsamPriority / JetsamMemoryLimit keys once measured (§7) -->
</dict></plist>
```
Notes vs the macOS installer's plist: `system` domain not `gui/<uid>`; `ProcessType=Background` not `Interactive`; stderr to a real log not `/dev/null` (so you can debug boot); `KeepAlive` as a dict so a clean stop doesn't respawn; env inlined (token acceptable only because the daemon is root and the plist is `0644` — if that's unacceptable, keep env in the `0600` `openclaw.env` and set `ProgramArguments` to run the wrapper).

**`DEBIAN/control`:**
```
Package: ai.openclaw.gateway
Name: OpenClaw Gateway
Version: <openclaw-ver>+ios1
Architecture: iphoneos-arm64
Maintainer: <you>
Section: System
Depends: firmware (>= 15.0)
Description: OpenClaw AI gateway (bundled Node 24 runtime) running as a system LaunchDaemon.
```
(No `Depends` on a repo `node` — we ship our own. No `ellekit`/`mobilesubstrate` — this is a daemon, not a tweak.)

**`DEBIAN/postinst`:**
```sh
#!/bin/sh
set -e
PLIST=/var/jb/Library/LaunchDaemons/ai.openclaw.gateway.plist
case "$1" in configure|"")
  mkdir -p /var/jb/var/mobile/openclaw/tmp /var/jb/var/log/openclaw
  chown root:wheel "$PLIST"; chmod 0644 "$PLIST"
  chmod 0755 /var/jb/usr/lib/openclaw/node /var/jb/usr/bin/openclaw
  chmod 0600 /var/jb/etc/openclaw/openclaw.env 2>/dev/null || true
  launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null || true
  launchctl kickstart -k system/ai.openclaw.gateway 2>/dev/null || true
  ;;
esac
exit 0
```

**`DEBIAN/prerm`:**
```sh
#!/bin/sh
set -e
PLIST=/var/jb/Library/LaunchDaemons/ai.openclaw.gateway.plist
case "$1" in remove|upgrade|deconfigure)
  launchctl bootout system "$PLIST" 2>/dev/null \
    || launchctl bootout system/ai.openclaw.gateway 2>/dev/null \
    || launchctl unload -w "$PLIST" 2>/dev/null || true
  ;;
esac
exit 0
```

Build the `.deb` on the runner root-owned: `dpkg-deb -Zzstd --root-owner-group -b pkgroot …` (use `-Zxz` or `dm.pl -Zlzma` for older front-end compatibility). `ldid -S` every binary before packing; Dopamine's `systemhook`/`launchdhook` trust-caches adhoc-signed binaries at spawn automatically — no manual trustcache step, and `uicache` does not apply to a headless daemon.

---

## 5. Platform patches needed in OpenClaw source

Two categories: **must-patch** (daemon path is fundamentally broken on `darwin`-reported iOS) and **can-avoid-with-env** (state/respawn — overridable, patch only if you want `openclaw gateway install` to work on-device). For an MVP you can hand-author the daemon (§4) and skip the daemon-adapter patches; the env overrides handle the rest. Listed with file:line targets.

**Must-patch to make the in-tree installer work on-device (optional if hand-authoring the plist):**
- `src/daemon/service.ts:302-315, 372-383` (and `SupportedGatewayServicePlatform` at `:273`): `process.platform==='darwin'` maps unconditionally to the macOS LaunchAgent adapter. Add an iOS discriminator (detect `/var/jb`, or honor `OPENCLAW_SERVICE_KIND=launchdaemon` / `OPENCLAW_PLATFORM=ios`) and register an `ios-launchdaemon` adapter.
- `src/daemon/launchd.ts:455-460` `resolveGuiDomain()` → return `system` on iOS (not `gui/<uid>`). Fan-out: `:507-508, 663` (bootstrap), `:591-596` (print), `:662-663/1190` (kickstart/enable), `:1173-1185` (reload).
- `src/daemon/launchd.ts:128-134, 960-965, 986-987`: plist path → `/var/jb/Library/LaunchDaemons/ai.openclaw.gateway.plist`, mode `0644` root:wheel (not sandbox `~/Library/LaunchAgents` `0600`).
- `src/daemon/launchd.ts:342-349` `execLaunchctl` and `:702-729` uninstall: use `/var/jb/usr/bin/launchctl`, `system` domain; replace `~/.Trash` rename with `rm`.
- `src/daemon/launchd-plist.ts:288-316, 8-14`: emit `ProcessType=Background`, real `StandardErrorPath`, `KeepAlive` dict.

**Must-patch for correctness even with a hand-authored plist (env can cover these, but patch is cleaner):**
- `src/bootstrap/node-startup-env.ts:25-37`: on `darwin` it forces `NODE_EXTRA_CA_CERTS=/etc/ssl/cert.pem` + `NODE_USE_SYSTEM_CA=1`. On iOS the bundle is `/var/jb/etc/ssl/cert.pem` and `NODE_USE_SYSTEM_CA` relies on SecTrust semantics that are unreliable. Add iOS branch (or override via `openclaw.env`, which we do). Wired into service env at `src/daemon/service-env.ts:488-489, 523-531, 543-544`.
- `src/daemon/service-env.ts:229-244, 353-362`: hardcoded Homebrew/usr PATH — none of those dirs exist on iOS; child processes spawned by name (`git`, `which`, `launchctl`) won't resolve. Add `/var/jb` PATH branch (or override via env, which we do).

**Env-overridable, no patch strictly required:**
- State/config/HOME divergence: `src/daemon/paths.ts:10-16, 38-49`, `src/config/paths.ts:41-87, 152-161`. Pin `OPENCLAW_STATE_DIR` / `OPENCLAW_CONFIG_PATH` (honored at `paths.ts:39-43`, `home-dir.ts:44-54`) to the same value in daemon and any app UI — done in §4.
- Self-respawn: `openclaw.mjs:118-213, 240-269` (compile-cache respawn) and `src/entry.respawn.ts:38-48, 104-159`. Set `OPENCLAW_NO_RESPAWN=1` + `NODE_DISABLE_COMPILE_CACHE=1` so `buildCliRespawnPlan` returns null and the launcher takes the single-process path. **Reconciliation note:** the node-features audit assumes `child_process.spawn(process.execPath)` *fails* on iOS — that is true for sandboxed App Store apps, but on **jailbroken Dopamine the daemon runs in real Darwin userland and spawn works** (Dopamine's `systemhook` trust-caches spawned binaries). So respawn would likely function; we still disable it to keep a predictable single PID under launchd `KeepAlive`. This same fact means a `child_process`-pipe PTY replacement and external-CLI tools are viable on-device (verify per §7).

**Should-patch for stability on 2 GB / 2 cores:**
- Unbounded `worker_threads`: `src/agents/code-mode.ts:714`, `src/audit/audit-event-writer.ts:54`, `src/agents/compaction-planning-worker.ts:75`, `src/agents/model-provider-auth.ts:513`. Add a concurrency limiter sized by `os.availableParallelism()` (fall back to 1 on ≤2 cores) honoring `OPENCLAW_MAX_WORKERS`; consider running audit/compaction inline on low-mem devices. Each Worker is a full V8 isolate (~30-60 MB) — concurrent workers can trip jetsam.

**Cosmetic (low priority):** `src/infra/machine-name.ts:13-24`, `src/infra/os-summary.ts:24-28` (`scutil`/`sw_vers` fail-soft, report wrong "macOS" label), `src/infra/advertised-lan-host.ts:209-216` (`route`). Fail gracefully; just don't trust the reported OS label.

---

## 6. Phased execution plan (spikes first)

Each phase gates the next and has a concrete on-device SSH validation. Nothing after Phase 0 matters if Phase 0 fails.

### Phase 0 — Prove Node-on-device (THE gate)
Build a **jitless Node 24** (start from nodejs-mobile 18, forward-port) in GHA, `ldid`-sign, `scp` the bare binary to the device.
- **Validate over SSH:**
  ```
  ./node -e "console.log(process.versions.node, process.arch)"        # ≥22.19, arm64
  ./node -e "const s=require('node:sqlite'); const d=new s.DatabaseSync(':memory:'); \
             d.exec('create table t(x)'); d.prepare('insert into t values (1)').run(); \
             console.log(d.prepare('select count(*) c from t').get())"
  ./node -e "require('https').get('https://api.anthropic.com',r=>console.log('TLS',r.statusCode)).on('error',e=>console.log('ERR',e.code))"
  otool -l ./node | grep -A3 LC_BUILD_VERSION                          # platform iOS, minos 15.0
  ```
- **Pass = version gate clears, `node:sqlite` opens+writes, TLS handshakes.** Fail here ⇒ stop and fix the build; nothing else is worth doing.

### Phase 1 — WASM mode decision spike
On the Phase-0 binary, and on a JIT variant (built without `--jitless`, signed with `dynamic-codesigning`).
- **Validate over SSH:**
  ```
  # jitless + DrumBrake build:
  ./node --jitless --wasm-jitless -e "WebAssembly.instantiate(new Uint8Array([0,97,115,109,1,0,0,0]))\
      .then(()=>console.log('WASM ok')).catch(e=>console.log('WASM fail',e.message))"
  # JIT build (real):
  ./node-jit -e "WebAssembly.instantiate(new Uint8Array([0,97,115,109,1,0,0,0]))\
      .then(()=>console.log('JIT+WASM ok')).catch(e=>console.log(e.message))"
  ```
  Then load the *actual* modules: `require.resolve('quickjs-wasi/quickjs.wasm')` + instantiate; `tree-sitter-bash.wasm`; photon.
- **Pass = a mode where all three real modules instantiate.** Records the shipping mode (jitless+DrumBrake vs JIT). If neither, fall back to WASM-disabled MVP and schedule native-addon swaps.

### Phase 2 — Bundle & boot the gateway (foreground)
On the macOS runner: `npm install openclaw@<ver> --omit=dev` (or `pnpm build:docker` from source), drop `dist/control-ui`, `scp` the whole `node_modules/openclaw` + `node_modules` tree next to the binary.
- **Validate over SSH:**
  ```
  export OPENCLAW_STATE_DIR=/var/jb/var/mobile/openclaw OPENCLAW_NO_RESPAWN=1 …
  ./node openclaw.mjs --version
  ./node --jitless --wasm-jitless openclaw.mjs gateway --port 18789 &    # foreground first
  sleep 5
  curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18789/…   # gateway responds
  ls -la $OPENCLAW_STATE_DIR                                             # state DB created
  ```
- **Pass = gateway boots, opens its state DB, serves the API port.** Confirms no hidden native addon or unresolved WASM path breaks boot.

### Phase 3 — Daemon + `.deb` packaging
Hand-author the plist (§4), install manually, then wrap into a `.deb`.
- **Validate over SSH:**
  ```
  launchctl bootstrap system /var/jb/Library/LaunchDaemons/ai.openclaw.gateway.plist
  launchctl print system/ai.openclaw.gateway | grep -E 'state|pid'      # running
  # reboot the device, reconnect:
  launchctl print system/ai.openclaw.gateway                            # RunAtLoad survived reboot
  kill <pid>; sleep 15; launchctl print system/ai.openclaw.gateway      # KeepAlive respawned it
  dpkg -i ai.openclaw.gateway_*.deb ; curl … ; dpkg -r ai.openclaw.gateway  # clean install/remove
  ```
- **Pass = starts at boot, auto-restarts on crash, installs/uninstalls cleanly via dpkg (and Sileo).**

### Phase 4 — Feature validation & memory hardening
- **Validate over SSH:** exercise a real channel (Telegram bundled) end-to-end; trigger code-mode (WASM) and command-explainer; run cron; then load-test and watch memory:
  ```
  while true; do ps -o rss= -p $(launchctl print system/ai.openclaw.gateway|awk '/pid =/{print $3}'); sleep 5; done
  ```
  Measure steady-state and peak RSS under concurrent agents; tune `--max-old-space-size`, `OPENCLAW_MAX_WORKERS`, and the jetsam limit (§7) so jetsam sits comfortably above real RSS.
- **Pass = the daemon runs a real conversation for hours without jetsam kills or crash-loops.**

---

## 7. Open questions to settle empirically (device or CI)

1. **[GATE] Does our Node 24 iOS build include working `node:sqlite`?** Some builds gate it; a stripped build makes the gateway non-functional at first state access. Verify in Phase 0 before anything else.
2. **Does a clean Node ≥22 iOS build even link and run?** No known-good ≥22 patch set exists; the forward-port from nodejs-mobile 18 is the largest unquantified effort. Budget real debugging (mksnapshot host/target split, V8 `OS_IOS` codegen, libuv/posix diffs).
3. **JIT on the A9:** does V8 initialize/execute code space on a pre-APRR, pre-PPL core with only `dynamic-codesigning`? If yes, JIT mode is strictly better (full speed + free WASM). If no, jitless is mandatory. (Phase 1.)
4. **DrumBrake feature coverage:** the default Node build does **not** set `v8_enable_drumbrake=true` — confirm you can wire it in, and that interpreted WASM supports what `quickjs-wasi`, `tree-sitter-bash`, and `photon` actually use (SIMD/threads/GC may be unimplemented). (Phase 1.)
5. **Does `child_process.spawn` work under the daemon?** Determines whether a `node-pty` pipe replacement, external CLI tools, and (if you *don't* disable it) the self-respawn function. Likely yes on Dopamine; verify with `spawn('/var/jb/usr/bin/true')` from within the daemon context.
6. **jetsam on iOS 15.8:** which lever raises a *daemon's* memory limit — `jetsamctl`/`memorystatus_control` (documented only 12–14; needs Torrekie's fork or a direct call), LaunchDaemon `JetsamPriority`/`JetsamMemoryLimit` keys, or the system `jetsamproperties.<Model>.plist`? Measure real RSS (Phase 4) and size both the V8 heap and the jetsam limit around it.
7. **Daemon UID / state consistency:** run as `root` (HOME `/var/root`) — confirm this is what you want, and that `OPENCLAW_STATE_DIR=/var/jb/var/mobile/openclaw` is writable and consistent between daemon and any app-side UI. (If you ever add an app UI, both must point at the same dir.)
8. **CA bundle path:** does `/var/jb/etc/ssl/cert.pem` exist on the target Procursus bootstrap, or must you ship a bundled `cacert.pem` and point `NODE_EXTRA_CA_CERTS` at it? (Phase 0 TLS smoke.)
9. **`launchctl` verbs:** does the on-device `launchctl` support modern `bootstrap`/`kickstart`, or only legacy `load -w`/`unload -w`? The postinst/prerm already fall back, but confirm which path fires.
10. **Multicast UDP:** does the jailbreak sandbox permit `dgram` multicast for `@homebridge/ciao` mDNS? If not, disable the bonjour extension (non-essential).
11. **RegExp DoS surface (jitless-specific):** with no JIT'd regexp, audit user/config regexes for catastrophic backtracking — under the interpreter a bad pattern can wedge the single event loop.

---

**One-line implementation directive:** Build **jitless Node 24 with `v8_enable_drumbrake=true` and `--with-intl=small-icu`**, prove `node:sqlite` + WASM on-device (Phases 0-1) before touching packaging, ship the plain `npm install --omit=dev` tree plus that binary under `/var/jb` as a `system`-domain LaunchDaemon `.deb`, override all daemon paths/CA/PATH/state via env, and patch OpenClaw's `darwin`→launchd assumptions (`service.ts`, `launchd.ts`, `node-startup-env.ts`, `service-env.ts`) only if you want the in-tree `openclaw gateway install` to work on-device.