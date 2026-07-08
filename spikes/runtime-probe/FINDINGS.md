# Spike A findings — iOS 15 runtime model (iPhone 6s Plus, Dopamine rootless)

Ran the arm64 probe on-device (signed with `ldid -Sents.plist`, entitlements =
`dynamic-codesigning`, `get-task-allow`, `platform-application`, `no-container`).

```
kernel: Darwin 21.6.0 (iPhone8,2)
uid=501 euid=501
[exec] basic execution PASS
[jit ] pthread_jit_write_protect_np present=0 supported=-1
[fork] PASS
JIT strategies (each isolated in a child):
  [rwx-mmap   ] KILLED by signal 10 (SIGBUS)
  [map-jit    ] FAIL — mmap MAP_JIT -> EINVAL
  [wx-mprotect] PASS (exit 42)
```

## What this establishes

| Question | Answer |
|----------|--------|
| Does an ldid ad-hoc + entitled arm64 binary run as `mobile`? | **Yes**, directly. No `jbctl trustcache add` needed — Dopamine `systemhook` trusts it. |
| `fork()` / `child_process`? | **Works** (Dopamine `forkfix.dylib`). |
| JIT possible at all? | **Yes**, via classic **W^X**: `mmap(RW)` → write → `mprotect(R+X)` → exec. |
| Apple hardened-JIT (`MAP_JIT` + `pthread_jit_write_protect_np`)? | **No** — symbol absent on iOS 15, `MAP_JIT` → EINVAL. |
| Simultaneous RWX page? | **No** — SIGBUS on execute. |

## Consequence for the Node/V8 build (Spike B)

V8 on Apple arm64 (`V8_OS_DARWIN && V8_HOST_ARCH_ARM64`) defaults to the
`MAP_JIT` + `pthread_jit_write_protect_np` write-protect scheme — **which is unavailable here**.
So we must either:

1. **Build V8 to use the mprotect W^X model** (the path that PASSED), i.e. disable the Apple
   hardened-JIT code path so V8 toggles page perms with `mprotect` — OR
2. **Build/run Node `--jitless`** (Ignition interpreter only). Must then confirm WASM still works
   (OpenClaw uses several WASM modules); recent V8 has a Wasm interpreter, but this needs verifying.

Option 1 preferred (keeps JS + WASM fast). The A9 has **no APRR/hardware W^X** (that's A12+), so
plain `mprotect` toggling is the correct model and is confirmed working.

Signing recipe that works on-device:
```
ldid -Sents.plist <binary>     # ents.plist includes dynamic-codesigning
./<binary>                      # runs as mobile, no trustcache step
```
