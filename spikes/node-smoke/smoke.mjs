// Strict on-device smoke test for the iOS cross-build.
// Answers the make-or-break questions in one run:
//   1. does the binary report the pinned version, arch, and platform
//   2. does node:sqlite load (OpenClaw's boot-critical datastore)
//   3. does WebAssembly instantiate (boot-critical in OpenClaw)
//   4. is JIT codegen stable under a hot loop
//   5. are bundled TLS roots present
//
// Run as:
//   ./node --predictable --single-threaded smoke.mjs
//
// A --jitless run is useful for diagnosis, but correctly exits nonzero because
// Node 22 disables WebAssembly in that mode and OpenClaw needs WASM.

import assert from "node:assert/strict";

const failures = [];

function recordFailure(check, error) {
  const detail = error instanceof Error
    ? error.name + ": " + error.message
    : String(error);
  failures.push(check + ": " + detail);
  console.error(check + "_FAIL", detail);
}

console.log("NODE_VERSION", process.version);
console.log("ARCH", process.arch, "PLATFORM", process.platform);
console.log("EXEC_FLAGS", process.execArgv.join(" ") || "(none)");

try {
  assert.equal(process.version, "v22.19.0");
  assert.equal(process.arch, "arm64");
  // NOTE: a Node built with --dest-os=ios reports process.platform === "ios"
  // (non-standard; NOT "darwin"). Verified on-device. Do not "correct" this.
  assert.equal(process.platform, "ios");
  assert.ok(process.execArgv.includes("--predictable"), "missing --predictable");
  assert.ok(process.execArgv.includes("--single-threaded"), "missing --single-threaded");
  assert.ok(!process.execArgv.includes("--jitless"), "OpenClaw cannot boot with --jitless");
  console.log("RUNTIME_OK");
} catch (error) {
  recordFailure("RUNTIME", error);
}

// 1) node:sqlite - boot-critical for OpenClaw.
try {
  const { DatabaseSync } = await import("node:sqlite");
  const db = new DatabaseSync(":memory:");
  db.exec("CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (42);");
  const row = db.prepare("SELECT x AS x FROM t").get();
  db.close();
  assert.equal(row.x, 42);
  console.log("SQLITE_OK", row.x);
} catch (error) {
  recordFailure("SQLITE", error);
}

// 2) WebAssembly - minimal exported i32 add function.
try {
  const hex = "0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b";
  const bytes = Uint8Array.from(hex.match(/../g).map((h) => parseInt(h, 16)));
  const { instance } = await WebAssembly.instantiate(bytes);
  const result = instance.exports.add(1, 2);
  assert.equal(result, 3);
  console.log("WASM_OK", result);
} catch (error) {
  recordFailure("WASM", error);
}

// 3) JIT codegen stability under a hot loop.
try {
  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) sum += i % 7;
  assert.equal(sum, 14_999_995);
  console.log("LOOP_OK", sum);
} catch (error) {
  recordFailure("LOOP", error);
}

// 4) TLS/crypto sanity: bundled CA roots, with no /etc/ssl dependency.
try {
  const tls = await import("node:tls");
  assert.ok((tls.rootCertificates?.length ?? 0) > 0, "bundled root certificates missing");
  console.log("TLS_ROOTS", "present");
} catch (error) {
  recordFailure("TLS", error);
}

if (failures.length > 0) {
  console.error("SMOKE_FAILED", failures.length);
  for (const failure of failures) console.error("-", failure);
  process.exitCode = 1;
} else {
  console.log("SMOKE_DONE");
}
