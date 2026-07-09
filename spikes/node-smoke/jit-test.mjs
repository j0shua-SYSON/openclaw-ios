// jit-test.mjs — proves the V8 mprotect-W^X patch actually executes JIT'd code.
//
// Plain `6*7` runs in Ignition using *embedded* builtins (RX in the binary) and
// never exercises dynamically-generated code — so it would NOT test the patch.
// This forces TurboFan to compile a hot function and then EXECUTES the compiled
// code. If the mprotect W^X flip works, we get the right number + exit 0.
// If the code page is left non-executable, execution SIGBUSes (exit 138).
//
// Run WITHOUT --jitless (we want JIT) and WITH --predictable (single-threaded,
// so process-wide mprotect has no W^X race with a background compiler thread):
//   ./node --predictable jit-test.mjs
// Optionally hammer tier-up harder:
//   ./node --predictable --no-lazy jit-test.mjs

function hot(n) {
  // enough arithmetic to be worth compiling; result is deterministic
  let acc = 0;
  for (let i = 0; i < 64; i++) acc = (acc + n * 7 + (i ^ n)) | 0;
  return acc | 0;
}

// Warm it well past the tier-up threshold so TurboFan compiles + installs code,
// then the loop keeps calling the COMPILED version.
let sum = 0;
for (let i = 0; i < 5_000_000; i++) sum = (sum + hot(i)) | 0;

console.log("JIT_HOTLOOP_OK", sum | 0);
console.log("ANSWER", 6 * 7);

// WASM comes back once JIT works (Node 22 / V8 12.4 disables it under --jitless).
try {
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
  console.log("WASM_OK", inst.exports.add(19, 23)); // -> 42
} catch (e) {
  console.log("WASM_FAIL", e && e.message ? e.message : String(e));
}

console.log("JIT_TEST_DONE");
