#!/usr/bin/env node
// Compares the C and the Zig builds of the Windows helper (zeyvola-win.exe) on this Windows machine:
// size, start-up, every mode's wall time, CPU and peak memory. Used for docs/zig-port-performans.md.
//
//   node tools/bench/c-vs-zig.mjs [--c-rev <git rev>] [--scale <0.2..>] [--json <out.json>]
//
// --c-rev: the commit whose native/helper-windows/zeyvola-win.c is the C side (default: the last
// commit before the port, 785273e). It is built in a temporary folder with the flags of that
// commit's build.sh (zig cc -O2, no CRT). The Zig side is the working tree, built with build.zig
// twice: -Doptimize=fast (what ships) and -Doptimize=small. --scale multiplies the run counts.
// Runs are interleaved (C, Zig, Zig small, C, …) after one warm-up each, so drift in the machine's
// state (clock, caches, background work) hits all builds alike. Each run is checked for the right
// answer; a wrong one stops the benchmark. Needs zig 0.17 ($ZIG, tools/.cache/zig or PATH).
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, statSync, writeFileSync, readFileSync } from 'node:fs';
import { cpus, release, tmpdir, totalmem } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback; };
const C_REV = arg('c-rev', '785273e');
const SCALE = Number(arg('scale', '1'));
const JSON_OUT = arg('json', null);
if (process.platform !== 'win32') throw new Error('Windows only: the helper is a Windows program');

function findZig() {
  if (process.env.ZIG) return process.env.ZIG;
  for (const f of ['zig.exe', 'zig']) { const p = join(ROOT, 'tools', '.cache', 'zig', f); if (existsSync(p)) return p; }
  return 'zig';
}
const ZIG = findZig();
const sh = (cmd, args, opts = {}) => execFileSync(cmd, args, { stdio: ['ignore', 'pipe', 'inherit'], ...opts });
const work = mkdtempSync(join(tmpdir(), 'zeyvola-bench-'));
const zigCache = join(work, 'zig-cache');

// ─── builds ──────────────────────────────────────────────────────────────────

function buildC() {
  const dir = join(work, 'c');
  mkdirSync(join(dir, 'imports'), { recursive: true });
  const files = sh('git', ['ls-tree', '--name-only', '-r', C_REV, 'native/helper-windows/'], { cwd: ROOT, encoding: 'utf8' }).trim().split('\n');
  if (!files.includes('native/helper-windows/zeyvola-win.c')) throw new Error(`${C_REV}: native/helper-windows/zeyvola-win.c yok`);
  for (const f of files.filter((f) => /\.(c|h|rc|def)$/.test(f))) {
    writeFileSync(join(dir, f.slice('native/helper-windows/'.length)), sh('git', ['show', `${C_REV}:${f}`], { cwd: ROOT }));
  }
  const libs = readdirSync(join(dir, 'imports')).filter((f) => f.endsWith('.def')).sort().map((def) => {
    const lib = join(dir, def.replace(/\.def$/, '.lib'));
    sh(ZIG, ['dlltool', '-m', 'i386:x86-64', '-d', join(dir, 'imports', def), '-l', lib]);
    return lib;
  });
  // The flags of build.sh at that commit.
  sh(ZIG, ['cc', '-target', 'x86_64-windows-gnu', '-O2', '-Wall', '-Wextra', '-Wno-unused-parameter',
    '-nostdinc', '-nostdlib', '-fno-stack-protector', '-mno-stack-arg-probe', '-fno-builtin',
    '-s', '-Wl,--entry=mainCRTStartup', '-Wl,--subsystem,console',
    'zeyvola-win.c', 'zeyvola-win.rc', '-o', 'zeyvola-win.exe', ...libs], { cwd: dir, env: { ...process.env, ZIG_LOCAL_CACHE_DIR: zigCache } });
  return join(dir, 'zeyvola-win.exe');
}

function buildZig(optimize) {
  const prefix = join(work, `zig-${optimize}`);
  sh(ZIG, ['build', `-Doptimize=${optimize}`, '--prefix', prefix, '--cache-dir', zigCache], { cwd: join(ROOT, 'native', 'helper-windows') });
  return join(prefix, 'bin', 'zeyvola-win.exe');
}

function buildMeasure() {
  const bin = join(work, 'measure.exe');
  sh(ZIG, ['build-exe', join(ROOT, 'tools', 'bench', 'measure.zig'), '-target', 'x86_64-windows-gnu', '-O', 'fast', '--cache-dir', zigCache, `-femit-bin=${bin}`]);
  return bin;
}

/** ffmpeg-codecs sizes for both macOS architectures (not runnable here). */
function listerSizes() {
  const src = join(work, 'ffmpeg-codecs.c');
  writeFileSync(src, sh('git', ['show', `${C_REV}:tools/codec-audit/ffmpeg-codecs.c`], { cwd: ROOT }));
  const out = {};
  for (const [arch, target] of [['arm64', 'aarch64-macos'], ['x86_64', 'x86_64-macos']]) {
    const c = join(work, `ffc-c-${arch}`);
    const z = join(work, `ffc-zig-${arch}`);
    sh(ZIG, ['cc', '-target', target, '-O1', '-o', c, src], { env: { ...process.env, ZIG_LOCAL_CACHE_DIR: zigCache } });
    sh(ZIG, ['build-exe', join(ROOT, 'tools', 'codec-audit', 'ffmpeg-codecs.zig'), '-target', target, '-lc', '-O', 'small', '--cache-dir', zigCache, `-femit-bin=${z}`]);
    out[arch] = { c: statSync(c).size, zig: statSync(z).size };
  }
  return out;
}

const { peImports } = await import(pathToFileURL(join(ROOT, 'tools', 'codec-audit.mjs')).href);

// ─── measuring ───────────────────────────────────────────────────────────────

let MEASURE;

/** One run through measure.exe; `feed(stdin)` writes the program's input. */
function measure(exe, args, feed) {
  return new Promise((done, fail) => {
    const p = spawn(MEASURE, [exe, ...args], { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    let out = '';
    let err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.stdin.on('error', () => {}); // the program may exit before reading everything (an error)
    p.on('error', fail);
    p.on('close', () => {
      const last = err.trim().split('\n').pop();
      try { done({ ...JSON.parse(last), stdout: out }); } catch { fail(new Error(`measure: ${err}`)); }
    });
    Promise.resolve(feed ? feed(p.stdin) : null).then(() => p.stdin.end(), () => p.stdin.end());
  });
}

const write = (stream, buf) => new Promise((ok) => { if (stream.write(buf)) ok(); else stream.once('drain', ok); });

function header(kind, len, time, duration) {
  const b = Buffer.alloc(24);
  b.writeUInt32LE(kind, 0); b.writeUInt32LE(len, 4); b.writeBigInt64LE(BigInt(time), 8); b.writeBigInt64LE(BigInt(duration), 16);
  return b;
}

/** 30 distinct NV12 frames (a moving gradient with a square), cycled; 1/30 s of a 440 Hz tone. */
function material(w, h) {
  const frames = [];
  for (let i = 0; i < 30; i++) {
    const f = Buffer.alloc(w * h * 3 / 2, 128);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const inSquare = Math.abs(x - (i * w) / 30) < w / 10 && Math.abs(y - h / 2) < h / 10;
      f[y * w + x] = inSquare ? 235 : ((x + y + i * 4) & 0xff);
    }
    frames.push(f);
  }
  const audio = Buffer.alloc((48000 / 30) * 4);
  for (let s = 0; s < 48000 / 30; s++) { const v = Math.round(6000 * Math.sin((s * 2 * Math.PI * 440) / 48000)); audio.writeInt16LE(v, s * 4); audio.writeInt16LE(v, s * 4 + 2); }
  return { frames, audio };
}

function packets(w, h, count, withAudio) {
  const m = material(w, h);
  return async (stdin) => {
    const d = Math.round(1e7 / 30);
    for (let i = 0; i < count; i++) {
      const t = Math.round((i * 1e7) / 30);
      await write(stdin, header(1, m.frames[i % 30].length, t, d));
      await write(stdin, m.frames[i % 30]);
      if (withAudio) { await write(stdin, header(2, m.audio.length, t, d)); await write(stdin, m.audio); }
    }
    await write(stdin, header(3, 0, 0, 0));
  };
}

const median = (a) => { const s = [...a].sort((x, y) => x - y); const n = s.length; return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2; };
const stats = (a) => ({ median: median(a), min: Math.min(...a), max: Math.max(...a), mean: a.reduce((x, y) => x + y, 0) / a.length });

async function scenario(name, builds, runs, makeArgs, feed, check) {
  process.stderr.write(`${name}: `);
  const res = Object.fromEntries(builds.map((b) => [b.id, []]));
  for (let r = -1; r < runs; r++) { // r = -1: warm-up, not counted
    for (const b of builds) {
      const m = await measure(b.exe, makeArgs(b, r), feed);
      const problem = check(m);
      if (problem) throw new Error(`${name} / ${b.id}: ${problem}\n${m.stdout}`);
      if (r >= 0) res[b.id].push(m);
    }
    process.stderr.write('.');
  }
  process.stderr.write('\n');
  const summary = {};
  const samples = {};
  for (const b of builds) {
    const ms = res[b.id];
    samples[b.id] = { wallMs: ms.map((m) => m.wallUs / 1000), megacycles: ms.map((m) => m.cycles / 1e6) };
    summary[b.id] = {
      runs: ms.length,
      wallMs: stats(samples[b.id].wallMs),
      cpuMs: stats(ms.map((m) => (m.userUs + m.kernelUs) / 1000)),
      megacycles: stats(samples[b.id].megacycles),
      peakWorkingSetMb: stats(ms.map((m) => m.peakWorkingSetKb / 1024)),
      peakPrivateMb: stats(ms.map((m) => m.peakPrivateKb / 1024)),
    };
  }
  // The ratio of medians against C, with a 95 % bootstrap interval: an interval that holds 1.0 means
  // the difference is within this machine's run-to-run noise.
  const versusC = {};
  for (const b of builds.filter((x) => x.id !== 'c')) {
    versusC[b.id] = {};
    for (const key of ['wallMs', 'megacycles']) versusC[b.id][key] = medianRatio(samples[b.id][key], samples.c[key]);
  }
  return { name, summary, versusC, samples };
}

/** Deterministic PRNG (mulberry32), so a rerun on the same data gives the same interval. */
function rng(seed) {
  let a = seed >>> 0;
  return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}

function medianRatio(x, base, rounds = 5000) {
  const rand = rng(0x5eed);
  const pick = (a) => a.map(() => a[Math.floor(rand() * a.length)]);
  const ratios = [];
  for (let i = 0; i < rounds; i++) ratios.push(median(pick(x)) / median(pick(base)));
  ratios.sort((p, q) => p - q);
  return { ratio: median(x) / median(base), low: ratios[Math.floor(rounds * 0.025)], high: ratios[Math.floor(rounds * 0.975)] };
}

const ok = (m) => (m.exit === 0 ? null : `exit ${m.exit}`);
const doneLine = (frames) => (m) => ok(m) ?? (m.stdout.includes(`"type":"done","frames":${frames}`) ? null : 'no done line');

// ─── main ────────────────────────────────────────────────────────────────────

try {
  process.stderr.write(`derleniyor (C: ${C_REV}, Zig: çalışma ağacı)…\n`);
  MEASURE = buildMeasure();
  const builds = [
    { id: 'c', label: 'C (zig cc -O2)', exe: buildC() },
    { id: 'zig', label: 'Zig (fast, yayımlanan)', exe: buildZig('fast') },
    { id: 'zigSmall', label: 'Zig (small)', exe: buildZig('small') },
  ];
  const n = (k) => Math.max(1, Math.round(k * SCALE));
  const tmp = (b, name) => join(work, `${b.id}-${name}`);

  // An MP4 with two minutes of AAC sound for --extract-audio, written once by the shipping build.
  const extractSource = join(work, 'extract-source.mp4');
  const src = await measure(builds[1].exe, ['--encode-mp4', extractSource, '320', '180', '30', '300000', '1'], packets(320, 180, 30 * 120, true));
  if (src.exit !== 0) throw new Error(`extract source: ${src.stdout}`);

  const results = [];
  results.push(await scenario('start (--version)', builds, n(60), () => ['--version'], null, (m) => ok(m) ?? (m.stdout.includes('"version"') ? null : 'no version')));
  results.push(await scenario('--input: hook up, "stop", hook down', builds, n(30), () => ['--input'], async (s) => { await write(s, 'stop\n'); }, (m) => ok(m) ?? (m.stdout.includes('"ready"') ? null : 'no ready')));
  results.push(await scenario('--encode-probe', builds, n(10), (b) => ['--encode-probe', tmp(b, 'probe.mp4')], null, doneLine(2)));
  results.push(await scenario('--encode-mp4 1280×720, 10 s (300 frames) + AAC', builds, n(5), (b) => ['--encode-mp4', tmp(b, '720.mp4'), '1280', '720', '30', '5000000', '1'], packets(1280, 720, 300, true), doneLine(300)));
  results.push(await scenario('--encode-mp4 1920×1080, 10 s (300 frames) + AAC', builds, n(5), (b) => ['--encode-mp4', tmp(b, '1080.mp4'), '1920', '1080', '30', '8000000', '1'], packets(1920, 1080, 300, true), doneLine(300)));
  results.push(await scenario('--extract-audio 120 s AAC → WAV', builds, n(10), (b) => ['--extract-audio', extractSource, tmp(b, 'out.wav')], null, (m) => ok(m) ?? (m.stdout.includes('"converted":true') ? null : 'not converted')));

  const binaries = builds.map((b) => {
    const imports = peImports(readFileSync(b.exe));
    return { id: b.id, label: b.label, bytes: statSync(b.exe).size, dlls: imports.length, functions: imports.reduce((k, i) => k + i.functions.length, 0) };
  });
  const report = {
    date: new Date().toISOString(),
    machine: { cpu: cpus()[0].model.trim(), threads: cpus().length, memoryGb: Math.round(totalmem() / 2 ** 30), windows: release(), node: process.version, zig: sh(ZIG, ['version'], { encoding: 'utf8' }).trim() },
    cRevision: C_REV,
    builds: builds.map(({ id, label }) => ({ id, label })),
    binaries,
    lister: listerSizes(),
    results,
  };
  if (JSON_OUT) writeFileSync(JSON_OUT, `${JSON.stringify(report, null, 2)}\n`);

  // A readable summary.
  const f = (v, d = 1) => v.toFixed(d);
  console.log(`\n${report.machine.cpu} · ${report.machine.threads} iş parçacığı · Windows ${report.machine.windows} · zig ${report.machine.zig}\n`);
  console.log('| İkili | Bayt | DLL | İşlev |\n| --- | ---: | ---: | ---: |');
  for (const b of binaries) console.log(`| ${b.label} | ${b.bytes} | ${b.dlls} | ${b.functions} |`);
  for (const r of results) {
    console.log(`\n${r.name}\n| Derleme | Süre medyan (ms) | min–maks | C'ye göre | CPU döngüsü medyan (M) | C'ye göre | Tepe çalışma kümesi (MB) |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: |`);
    const pct = (v) => `${v >= 1 ? '+' : ''}${f((v - 1) * 100)}`;
    const vs = (b, key) => {
      if (b.id === 'c') return '—';
      const v = r.versusC[b.id][key];
      return `${pct(v.ratio)} % [${pct(v.low)}, ${pct(v.high)}]`;
    };
    for (const b of builds) {
      const s = r.summary[b.id];
      console.log(`| ${b.label} | ${f(s.wallMs.median)} | ${f(s.wallMs.min)}–${f(s.wallMs.max)} | ${vs(b, 'wallMs')} | ${f(s.megacycles.median)} | ${vs(b, 'megacycles')} | ${f(s.peakWorkingSetMb.median)} |`);
    }
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}
