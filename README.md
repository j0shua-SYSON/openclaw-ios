# openclaw-ios

Port of **OpenClaw** (the Node.js personal-AI-assistant *gateway*, not the companion app) to run
natively on a **jailbroken iOS 15 arm64** device, delivered as a **rootless `.deb`** installable via
Sileo. All building happens in **GitHub Actions** (no local PC builds).

## Target device (ground truth, probed over SSH)

| Fact | Value |
|------|-------|
| Model | iPhone 6s Plus (`iPhone8,2`) |
| CPU | Apple A9, **arm64** (v8, *not* arm64e) |
| OS | iOS **15.8.5** (build 19H394), Darwin 21.6.0 |
| Jailbreak | **Dopamine** (KFD, rootless), Procursus bootstrap |
| Prefix | `/var/jb` → `/private/preboot/.../procursus/` |
| dpkg arch | `iphoneos-arm64` |
| RAM | ~1.94 GB (the real runtime constraint) |
| Disk free | ~59 GiB |
| Root | `sudo` works (password) |
| On-device tools | `dpkg-deb`, `ldid`/`ldid2`, `jbctl`, `launchctl`, `uicache`, `opainject`, `make` (no clang/cc) |
| JIT levers | `jbctl proc_set_debugged <pid>`, `jbctl trustcache add <cdhash>`, `dynamic-codesigning` entitlement |
| Node in repos? | **No** — Procursus has no `nodejs` candidate → we ship our own Node ≥22.19 |

## The three hard problems

1. **Node ≥22.19 runtime for iOS 15 arm64** — cross-compiled in CI (biggest risk).
2. **V8 JIT under Dopamine** — validated by `spikes/runtime-probe` before investing in the Node build;
   fallback is `--jitless` (but that may disable WASM, which OpenClaw needs — hence we validate JIT first).
3. **Rootless packaging** — `/var/jb` layout, `iphoneos-arm64` control, `ldid` signing + trustcache, a
   `LaunchDaemon` under `/var/jb/Library/LaunchDaemons`.

## Layout

```
spikes/runtime-probe/   Spike A: exec + JIT + fork validation (tiny arm64 iOS binary)
.github/workflows/      CI that builds each piece on macOS/Linux runners
```

Deploy path for testing: CI builds artifact → PC downloads (`gh run download`) → PC `scp`s to the phone
over the LAN → install/run. (The GitHub cloud runner cannot reach the phone directly.)
