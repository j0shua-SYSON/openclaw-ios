# Contributing / Build it yourself

Everything is built in **GitHub Actions** — you don't need a Mac, Xcode, or a fast machine.
You just need a GitHub account (fork) and, to install it, a rootless‑jailbroken `arm64` device.

## The pipeline (3 workflows)

```
node-ios.yml        macOS runner   →  cross-compile Node → iphoneos-arm64   →  Release: node-ios
openclaw-bundle.yml Linux  runner   →  npm --omit=dev tree of OpenClaw       →  Release: openclaw-bundle
deb.yml             Linux  runner   →  stitch node + bundle + packaging      →  Release: deb  (the .deb)
```

Only `node` is iOS‑specific; OpenClaw itself is platform‑independent JS + WASM (its datastore is Node's
built‑in `node:sqlite`), so there are normally **no native addons** to worry about.

## Build steps

1. **Fork** this repo (Actions run in your fork, on your free minutes — public repos are unlimited).
2. In your fork's **Actions** tab, run the workflows (▶ *Run workflow*):
   1. **`node-ios-arm64`** — builds the Node runtime. ⏳ The *first* run is slow (~80 min: a full V8
      compile) but it warms a ccache, so re‑runs are ~5 min. Produces the `node-ios` release.
   2. **`openclaw-bundle`** — set the `version` input to the OpenClaw npm version you want (default is a
      known‑good pin). Produces the `openclaw-bundle` release. Fast (~2 min).
   3. **`deb`** — assembles and signs the installable package. Produces the `deb` release. Fast (~1 min).
3. Grab the `.deb` from your fork's **`deb`** release.

## Install on device

```bash
scp ai.openclaw.gateway_*.deb mobile@<iphone-ip>:/var/mobile/
ssh mobile@<iphone-ip> 'sudo dpkg -i /var/mobile/ai.openclaw.gateway_*.deb'
ssh mobile@<iphone-ip> 'openclaw onboard'     # add your LLM key + a channel (Telegram is easiest)
```

Logs: `/var/jb/var/log/openclaw.log`. The daemon (`ai.openclaw.gateway`) starts at boot via `launchd`.

## How the iOS Node port works (the interesting bit)

`scripts/ios-source-fixups.sh` is the whole patch set — small, readable deltas applied to Node's source
before `configure`:

- strip GNU `ld --start-group/--end-group` (Apple's `ld64` doesn't take them)
- undef c‑ares `HAVE_SYS_RANDOM_H` (iOS SDK lacks the header; falls back to `arc4random_buf`)
- guard `crypto_context.cc`'s macOS‑only keychain code behind `TARGET_OS_OSX`
- link `-framework CoreFoundation/CoreServices/Security` (Abseil/V8 need them; gyp only added them for `mac`)

The build (`.github/workflows/node-ios.yml`) pins Python 3.12, uses `-std=gnu++20` for host+target, and
signs the result with `ldid` + the `dynamic-codesigning` entitlement so V8's JIT works under Dopamine.
The device runtime model (exec / JIT / fork) is validated first by `spikes/runtime-probe`.

## Ways to help

- **Test on other devices / iOS versions** and report back (open an issue with model + iOS + what happened).
- **Bump the Node target** (`node_ref` input) as OpenClaw's requirement moves.
- **Cross‑compile the optional native bits** (e.g. `@lydell/node-pty`) if you want the terminal feature.
- **On‑device polish** — jetsam/memory tuning, battery, launchd behavior.

PRs and issues welcome. Keep patches small and commented; each fix in `ios-source-fixups.sh` explains *why*.
