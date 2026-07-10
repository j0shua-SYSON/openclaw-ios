// Proves the V8 mprotect-W^X patch actually executes JIT-generated code.
//
// Plain 6*7 runs in Ignition using embedded builtins (RX in the binary) and
// never exercises dynamically generated code, so it would not test the patch.
// This forces TurboFan to compile a hot function and then executes that code.
//
// Run without --jitless and with both safety flags. This experimental patch
// flips process-wide page permissions and is not safe with background compiler
// threads or worker_threads:
//   ./node --predictable --single-threaded jit-test.mjs
// Optionally hammer tier-up harder:
//   ./node --predictable --single-threaded --no-lazy jit-test.mjs

import assert from "node:assert/strict";

for (const flag of ["--predictable", "--single-threaded"]) {
  assert.ok(process.execArgv.includes(flag), "required test flag missing: " + flag);
}
assert.ok(!process.execArgv.includes("--jitless"), "JIT test must not use --jitless");

function hot(n) {
  // Enough arithmetic to be worth compiling; result is deterministic.
  let acc = 0;
  for (let i = 0; i < 64; i++) acc = (acc + n * 7 + (i ^ n)) | 0;
  return acc | 0;
}

// Warm it well past the tier-up threshold so TurboFan compiles and installs
// code, then keep calling the compiled version.
let sum = 0;
for (let i = 0; i < 5_000_000; i++) sum = (sum + hot(i)) | 0;

assert.equal(sum | 0, -767_246_336, "hot-loop result changed");
console.log("JIT_HOTLOOP_OK", sum | 0);
assert.equal(6 * 7, 42);
console.log("ANSWER", 42);

// WASM comes back once JIT works (Node 22 / V8 12.4 disables it under --jitless).
// (module (func (export "add") (param i32 i32) (result i32)
//   local.get 0 local.get 1 i32.add))
const bytes = new Uint8Array([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
  0x03, 0x02, 0x01, 0x00,
  0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00,
  0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
]);
const mod = new WebAssembly.Module(bytes);
const inst = new WebAssembly.Instance(mod);
const wasmResult = inst.exports.add(19, 23);
assert.equal(wasmResult, 42, "WebAssembly returned the wrong result");
console.log("WASM_OK", wasmResult);

console.log("JIT_TEST_DONE");
