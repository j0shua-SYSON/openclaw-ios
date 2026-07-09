// On-device Node smoke test for the iOS cross-build.
// Answers the make-or-break questions in one run:
//   1. does the binary execute + report the right version/arch/platform
//   2. does node:sqlite load (OpenClaw's boot-critical datastore)
//   3. does WebAssembly instantiate (the real JIT proof — fails under --jitless on Node 22)
//   4. is JIT codegen stable under a hot loop
// Run both `./node smoke.mjs` (JIT) and `./node --jitless smoke.mjs` to compare.

console.log('NODE_VERSION', process.version);
console.log('ARCH', process.arch, 'PLATFORM', process.platform);
console.log('JITLESS_FLAG', process.execArgv.join(' ') || '(none)');

// 1) node:sqlite — boot-critical for OpenClaw
try {
  const { DatabaseSync } = await import('node:sqlite');
  const db = new DatabaseSync(':memory:');
  db.exec('CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (42);');
  const row = db.prepare('SELECT x AS x FROM t').get();
  db.close();
  console.log('SQLITE_OK', row.x);
} catch (e) {
  console.log('SQLITE_FAIL', e.constructor.name, e.message);
}

// 2) WebAssembly — minimal (module (func (export "add") (param i32 i32) (result i32) (i32.add ...)))
try {
  const hex = '0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b';
  const bytes = Uint8Array.from(hex.match(/../g).map((h) => parseInt(h, 16)));
  const { instance } = await WebAssembly.instantiate(bytes);
  console.log('WASM_OK', instance.exports.add(1, 2));
} catch (e) {
  console.log('WASM_FAIL', e.constructor.name, e.message);
}

// 3) JIT codegen stability under a hot loop
try {
  let s = 0;
  for (let i = 0; i < 5_000_000; i++) s += i % 7;
  console.log('LOOP_OK', s);
} catch (e) {
  console.log('LOOP_FAIL', e.message);
}

// 4) TLS/crypto sanity (bundled CA roots present, no /etc/ssl needed)
try {
  const tls = await import('node:tls');
  console.log('TLS_ROOTS', (tls.rootCertificates?.length ?? 0) > 0 ? 'present' : 'MISSING');
} catch (e) {
  console.log('TLS_FAIL', e.message);
}

console.log('SMOKE_DONE');
