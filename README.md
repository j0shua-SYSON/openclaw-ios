<div align="center">

# 🦞📱 OpenClaw-iOS

### A full Node.js AI-assistant gateway, running **natively on jailbroken iOS**

*A private, always-on AI assistant that lives entirely on your own iPhone, yours to own rather than rented from the cloud.*

<!-- badges -->
[![node-ios build](https://github.com/j0shua-SYSON/openclaw-ios/actions/workflows/node-ios.yml/badge.svg)](https://github.com/j0shua-SYSON/openclaw-ios/actions/workflows/node-ios.yml)
[![deb](https://github.com/j0shua-SYSON/openclaw-ios/actions/workflows/deb.yml/badge.svg)](https://github.com/j0shua-SYSON/openclaw-ios/actions/workflows/deb.yml)
![platform](https://img.shields.io/badge/target-iOS%2015%20·%20arm64%20·%20rootless-black)
![jailbreak](https://img.shields.io/badge/jailbreak-Dopamine%20(Procursus)-6E4AFF)
![node](https://img.shields.io/badge/Node.js-22.19-339933?logo=node.js&logoColor=white)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

---

> **TL;DR** — This repo cross-compiles **Node.js 22 for iOS**, then packages the [OpenClaw](https://github.com/openclaw/openclaw) personal-AI-assistant gateway plus that runtime into a **rootless `.deb`** you can install from **Sileo** on a Dopamine-jailbroken device. Your old iPhone becomes an always-on, on-device AI gateway.

## ✨ Why this is fun

- 🧠 **A real AI assistant, on-device, even on a decade-old iPhone.** OpenClaw is a full Node gateway (multi-channel chat for Telegram/Discord/Slack, tools, cron, sessions) and it runs *on the device itself*, not phoning home to a server.
- 🛠 **A Node 22 build for `iphoneos-arm64`, with full JIT.** Getting V8 to link with Apple's `ld`, dodging the missing `sys/random.h`, guarding macOS-only keychain code, and teaching V8's JIT to use `mprotect` W^X on a chip with no APRR are all solved here as a small, readable patch set.
- ☁️ **You need nothing but a browser.** Every artifact is produced by GitHub Actions: the Node runtime, the JS bundle, and the signed `.deb`. Your low-disk Windows box never compiles a thing.
- 🔓 **Rootless-jailbreak native.** Ships under `/var/jb`, `ldid`-signed with the `dynamic-codesigning` entitlement, wired up as a `launchd` daemon, the way Procursus/Dopamine packages are meant to work.

## 📟 Reference device (what it's built and validated against)

| | |
|---|---|
| **Model** | iPhone 6s Plus (`iPhone8,2`), Apple A9 |
| **CPU** | `arm64` v8, *not* arm64e (no APRR, no PPL) |
| **OS** | iOS **15.8.5** (19H394), Darwin 21.6.0 |
| **Jailbreak** | **Dopamine** (KFD, rootless), Procursus bootstrap |
| **Prefix / arch** | `/var/jb`, `iphoneos-arm64` |
| **RAM** | ~1.9 GB (the real constraint) |

> **Other devices and iOS versions?** Probably, but untested. The `.deb` targets any **rootless
> `iphoneos-arm64`** jailbreak with a **minimum of iOS 15**, so newer iPhones and other iOS 15+
> versions on Dopamine/Procursus are *likely* to work. The above is just the one device it's
> actually been built and validated on. If you try it elsewhere, open an issue with what you find. 🙏

## 🧩 How it fits together

```
        GitHub Actions  (macOS + Linux runners)
        ┌───────────────────────────────────────────────┐
        │  1. cross-compile  Node 22  →  iphoneos-arm64  │
        │  2. npm install openclaw     (pure JS + WASM)  │
        │  3. assemble rootless .deb   (ldid-signed)     │
        └───────────────────────┬───────────────────────┘
                                │   published as a GitHub Release
                                ▼
        iPhone 6s Plus · iOS 15.8 · Dopamine (/var/jb)
        ┌───────────────────────────────────────────────┐
        │  launchd ─▶ run-gateway.sh ─▶ node             │
        │              └─▶ OpenClaw Gateway  :18789      │
        │                 node:sqlite · JIT+WASM · chans │
        └───────────────────────────────────────────────┘
```

Only **one** artifact is iOS-specific: the `node` binary. OpenClaw itself is platform-independent
JavaScript + WASM, and its datastore is Node's **built-in `node:sqlite`**, so there are *zero* native
addons to cross-compile for the gateway to boot.

## 🔬 The interesting part: Node.js 22 on iOS 15

OpenClaw *requires* Node ≥ 22.19 (for `node:sqlite`), and there was no prebuilt Node 22 for iOS, so it
had to be cross-compiled from source. The blockers, and the fixes (see
[`scripts/ios-source-fixups.sh`](scripts/ios-source-fixups.sh)):

| Blocker | Fix |
|---|---|
| gyp emits GNU `ld --start-group/--end-group` for non-mac | strip them; Apple's `ld64` resolves archives globally |
| c-ares includes `<sys/random.h>` (absent on iOS SDK) | undef the macro; fall back to `arc4random_buf` |
| `crypto_context.cc` uses macOS-only `SecTrustSettings*` | guard behind `TARGET_OS_OSX` (bundled CA roots cover TLS) |
| Node `configure` rejects Python 3.14 | pin Python 3.12 |
| host C++ tools need modern std | `-std=gnu++20` for host **and** target |
| **V8 JIT dies on the A9** (no APRR; `MAP_JIT` → `EINVAL`; iOS won't grant RWX) | **patch V8 to use classic `mprotect` W^X** over its registered code ranges (JS **and** WASM) |

The runtime model was validated on-device first (see [`spikes/runtime-probe`](spikes/runtime-probe)):
an `ldid`-signed binary runs directly under Dopamine (auto-trust-cached) and `fork()` works. The A9
has no APRR, so V8's usual `MAP_JIT` + `pthread_jit_write_protect_np` path is a dead end, and iOS
silently downgrades an RWX request to RW even for an entitled binary. So V8 was patched to use the
classic **W^X** sequence (map RW, write, `mprotect` RX, execute) over each registered code range.
With that, **full JIT (JavaScript TurboFan *and* WebAssembly) runs on-device** on the A9, a pre-A11
chip with none of the hardware JIT-hardening (APRR/PKU) V8 normally relies on.

## ✅ Requirements (on the device)

The `.deb` **bundles its own Node.js runtime and every JavaScript/WASM dependency**, so there's very
little to install alongside it: no Node, no npm, no toolchain on the phone.

| Need | Notes |
|---|---|
| **A rootless jailbreak** | Dopamine (or any Procursus-based rootless JB) on **iOS 15+**, `arm64`. Provides `/var/jb`, `launchctl`, and the trust mechanism that lets the signed binary run. |
| **An installer** | **Sileo** (or Zebra/`dpkg`) to install the `.deb`. `dpkg` + APT ship with the bootstrap. |
| **A shell (to configure)** | **OpenSSH** or an on-device terminal (e.g. NewTerm) to run `openclaw onboard` once. Optional but you'll want it. |
| **~1 GB free space** | The bundled runtime + OpenClaw tree. Disk is rarely the constraint; **RAM (~2 GB)** is. |
| **API keys** | Whatever provider/channel you point OpenClaw at (an OpenClaw config step, not a device package). |

There is intentionally **no APT `Depends:`** on extra packages: everything the gateway needs is inside
the package or already part of the jailbreak base. `ldid` is used opportunistically in `postinst` to
re-sign, but the binary is already signed at build time, so it's not required.

## 📦 Install (once a `.deb` is published)

```bash
# Option A — Sileo: add this repo's release as a source, install "OpenClaw Gateway".
# Option B — SSH:
scp ai.openclaw.gateway_*.deb mobile@<iphone-ip>:/var/mobile/
ssh mobile@<iphone-ip> 'sudo dpkg -i /var/mobile/ai.openclaw.gateway_*.deb'
ssh mobile@<iphone-ip> 'openclaw onboard'        # configure keys + channels
```

The daemon starts at boot via `launchd`; logs land in `/var/jb/var/log/openclaw.log`.

> **Heads up on the OpenClaw version.** OpenClaw ships *fast*, so the bundled version may lag upstream;
> I'll try to keep it current. The good news: the tricky patches here are to **Node's own build**, not to
> OpenClaw (which is installed unmodified from npm), so they **don't rot** when OpenClaw updates. Bumping
> the `openclaw-bundle` `version` input to a newer release works **as long as that release still targets
> Node 22.x and stays pure-JS** (the datastore is the built-in `node:sqlite`, so there are normally no
> native addons to worry about). What *would* need more than a version bump: a release that raises the Node
> floor (e.g. to 24 → rebuild Node with the same patch set), adds a **boot-critical native module**
> (→ cross-compile it), or renames the CLI/`OPENCLAW_*` env surface (→ tweak the wrappers). The repo pins a
> **validated** version; newer is *usually* fine, not guaranteed.

## 🚧 Status

> Experimental, actively being built in the open. The cross-compile is done and full JIT (JS + WASM)
> now runs on the A9; wiring the whole gateway up end-to-end on-device is the remaining frontier.

- [x] Probe device + validate the runtime model (exec / JIT / fork) on-device
- [x] Build the platform-independent OpenClaw bundle
- [x] Rootless `.deb` packaging: `launchd` daemon, wrappers, maintainer scripts
- [x] **Cross-compile Node 22 → `iphoneos-arm64`**
- [x] **Full JIT on the A9** (JavaScript TurboFan + WebAssembly) via `mprotect` W^X
- [ ] End-to-end: gateway boots and responds on-device

## 🏗 Build it yourself

Everything runs in Actions; fork and go:

```
node-ios.yml         cross-compile Node → iphoneos-arm64  (macOS runner)
openclaw-bundle.yml  npm --omit=dev tree of OpenClaw       (Linux runner)
deb.yml              assemble + sign the rootless .deb      (Linux runner)
```

## 🙏 Credits

- [**OpenClaw**](https://github.com/openclaw/openclaw) — the assistant gateway being ported (MIT).
- [**Dopamine**](https://github.com/opa334/Dopamine) & [**Procursus**](https://github.com/ProcursusTeam/Procursus) — the rootless jailbreak + bootstrap this targets.
- [**nodejs-mobile**](https://github.com/nodejs-mobile/nodejs-mobile) — prior art for Node on mobile.

## 📄 License

MIT — see [LICENSE](LICENSE). OpenClaw and all third-party components retain their own licenses.

<div align="center">
<sub>Not affiliated with Apple or the OpenClaw project. For your own device, on your own responsibility.</sub>
</div>
