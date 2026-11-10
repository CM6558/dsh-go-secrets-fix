#!/usr/bin/env node
// Rehearses scripts/publish-release.sh with nothing real: a fake dist/ and
// made-up keys. Nothing leaves this machine.
//
//  1. Dry runs (Aliyun OSS + GitHub, Tencent COS, China off, missing settings):
//     every step printed, nothing run — curl, rclone, npx, gh, ossutil and
//     coscli are all booby-trapped.
//  2. Real runs against fakes: `wrangler dev` (local R2 and KV), a static
//     server for the Hong Kong bucket and GitHub's downloads, fake ossutil /
//     coscli / gh (test/publish-fakes/). Public mode with OSS, key mode with
//     COS: publish, publish again (skips what's there), a changed APK under the
//     same version is refused, a corrupt copy on one route stops the release.
//
//   npm run smoke:publish                 both
//   npm run smoke:publish -- --dry-run-only

import { spawn, spawnSync } from 'node:child_process';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const worker = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fakes = join(worker, 'test/publish-fakes');
const script = join(worker, 'scripts/publish-release.sh');
const state = mkdtempSync(join(process.env.SMOKE_TMP ?? tmpdir(), 'dshgo-publish-'));
const dryOnly = process.argv.includes('--dry-run-only');

// The two newest versions in the changelog: the script takes notes from there.
const changelog = readFileSync(join(worker, '../../docs/changelog.md'), 'utf8');
const [VERSION, OLDER] = [...changelog.matchAll(/^## (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\b/gm)].map((m) => m[1]);

function makeDist(version) {
  const dir = join(state, `dist-${version}`);
  mkdirSync(dir, { recursive: true });
  const assets = {};
  const sums = [];
  for (const [flavor, size] of [['arm64', 900_000], ['x64', 950_000]]) {
    const name = `dsh-go-${version}-${flavor}.apk`;
    const bytes = randomBytes(size);
    writeFileSync(join(dir, name), bytes);
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    sums.push(`${sha256}  ${name}`);
    assets[flavor] = { name, size, sha256 };
  }
  writeFileSync(join(dir, 'SHA256SUMS'), sums.join('\n') + '\n');
  writeFileSync(join(dir, 'update.json'), JSON.stringify({
    schema: 1, version: `${version}+10291200`, tag: `v${version}`, title: `DSH Go ${version}`, publishedAt: '2026-10-29T04:00:00Z',
    notes: '', page: `https://github.com/ccch1mneyyy/dsh-go/releases/tag/v${version}`, assets,
  }, null, 2));
  return dir;
}

// Made-up keys, in files as the script wants them.
const keys = join(state, 'keys');
mkdirSync(keys, { mode: 0o700 });
const secret = (name, value) => (writeFileSync(join(keys, name), value + '\n', { mode: 0o600 }), join(keys, name));
const fake = {
  cf: secret('cf.token', 'fake-cf-' + randomBytes(12).toString('hex')),
  channel: 'dshc_' + randomBytes(32).toString('base64url'),
  id: 'LTAIfake' + randomBytes(8).toString('hex'),
  secret: randomBytes(20).toString('base64url'),
  key: 'dsh-sm9ke234',
};
const files = {
  cf: fake.cf,
  channel: secret('channel.token', fake.channel),
  id: secret('cn.id', fake.id),
  secret: secret('cn.secret', fake.secret),
  key: secret('beta.key', fake.key),
};
const log = join(state, 'cli.log');

const CN = {
  oss: { CN_PROVIDER: 'oss', CN_BUCKET: 'dshgo-dl', CN_REGION: 'cn-hongkong' },
  cos: { CN_PROVIDER: 'cos', CN_BUCKET: 'dshgo-dl-1250000000', CN_REGION: 'ap-hongkong' },
};

function publish(dist, args, env) {
  // Never anything of the caller's: no real tokens reach the script.
  const clean = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(CN_|GH_|BETA_|CF_|CLOUDFLARE|GITHUB_|R2_)/.test(k)));
  const r = spawnSync(script, [dist, ...args], {
    cwd: worker,
    encoding: 'utf8',
    timeout: 300_000,
    env: {
      ...clean, FAKE_LOG: log, FAKE_KEY_ID: fake.id, FAKE_KEY_SECRET: fake.secret, WRANGLER_SEND_METRICS: 'false',
      CF_TOKEN_FILE: files.cf, BETA_TOKEN_FILE: files.channel, BETA_KEY_FILE: files.key,
      CN_ACCESS_KEY_ID_FILE: files.id, CN_ACCESS_KEY_SECRET_FILE: files.secret, ...env,
    },
  });
  const out = (r.stdout ?? '') + (r.stderr ?? '');
  return { code: r.status, out };
}

let passed = 0;
function check(ok, what, detail = '') {
  if (!ok) throw new Error(`${what}${detail ? `\n${detail}` : ''}`);
  passed++;
  console.log(`ok - ${what}`);
}
const noSecrets = (text) => ![fake.secret, fake.id, fake.channel, readFileSync(fake.cf, 'utf8').trim()].some((s) => text.includes(s));

// ── 1. Dry runs ──────────────────────────────────────────────────────────
function dryRuns() {
  const trapped = join(state, 'trapped-bin');
  mkdirSync(trapped);
  for (const tool of ['curl', 'rclone', 'npx', 'gh', 'ossutil', 'coscli', 'wrangler']) symlinkSync(join(fakes, 'forbidden'), join(trapped, tool));
  const PATH = `${trapped}:${process.env.PATH}`;
  const dist = makeDist(VERSION);
  writeFileSync(log, '');

  const oss = publish(dist, ['--dry-run', '--github'], { PATH, ...CN.oss, CN_BASE_URL: 'https://dshgo-dl.oss-cn-hongkong.aliyuncs.com/' });
  console.log(oss.out.replace(/^/gm, '  | '));
  check(oss.code === 0, 'dry run (OSS + GitHub) exits 0', oss.out);
  for (const s of ['== 1/5 R2', '== 2/5 China oss dshgo-dl', '== 3/5 GitHub', '== 4/5 check', '== 5/5 go live', 'ossutil cp', 'gh release create', '--draft', 'gh release edit', '--draft=false',
    `download China dsh-go-${VERSION}-arm64.apk`, 'routes: global cn github', '"routes": [']) {
    check(oss.out.includes(s), `dry run prints: ${s}`);
  }
  check(oss.out.indexOf('gh release edit') > oss.out.lastIndexOf('gh release download'), 'dry run: GitHub goes public only after every download');
  check(oss.out.lastIndexOf('beta/update.json') > oss.out.indexOf('--draft=false'), 'dry run: beta/update.json goes up last');

  const cos = publish(dist, ['--dry-run'], { PATH, ...CN.cos, CN_BASE_URL: 'https://dshgo-dl-1250000000.cos.ap-hongkong.myqcloud.com' });
  check(cos.code === 0 && cos.out.includes("coscli cp") && cos.out.includes('Content-Type:application/vnd.android.package-archive#Cache-Control:') && cos.out.includes('GitHub (off'), 'dry run (COS, no GitHub)', cos.out);
  check(cos.out.includes('https://dshgo-dl-1250000000.cos.ap-hongkong.myqcloud.com/' + VERSION), 'dry run: CN_BASE_URL gets its trailing slash');

  const off = publish(dist, ['--dry-run'], { PATH, CN_BASE_URL: '' });
  check(off.code === 0 && off.out.includes('skipped: CN_BASE_URL is empty') && off.out.includes('routes: global\n'), 'dry run without a China route: R2 only', off.out);
  const fromWrangler = publish(dist, ['--dry-run'], { PATH });
  check(fromWrangler.code === 0 && fromWrangler.out.includes('skipped: CN_BASE_URL is empty in wrangler.jsonc'), "CN_BASE_URL defaults to wrangler.jsonc's", fromWrangler.out);

  const missing = publish(dist, ['--dry-run'], { PATH, CN_BASE_URL: 'https://dshgo-dl.oss-cn-hongkong.aliyuncs.com/', CN_ACCESS_KEY_SECRET_FILE: join(keys, 'nope') });
  check(missing.code === 1 && ['CN_PROVIDER', 'CN_BUCKET', 'CN_REGION', 'CN_ACCESS_KEY_SECRET_FILE'].every((s) => missing.out.includes(s)), 'missing settings are all listed at once', missing.out);
  const skip = publish(dist, ['--dry-run', '--skip-verify'], { PATH, CN_BASE_URL: '' });
  check(skip.code === 1 && skip.out.includes('--skip-verify needs --no-latest'), 'nothing goes live unchecked', skip.out);
  check(publish(dist, ['--dry-run', '--skip-verify', '--no-latest'], { PATH, CN_BASE_URL: '' }).code === 0, '--skip-verify --no-latest is fine');

  check(readFileSync(log, 'utf8') === '', 'dry runs ran nothing (no curl, rclone, npx, gh, ossutil, coscli)', readFileSync(log, 'utf8'));
  check(noSecrets(oss.out + cos.out), 'dry runs print no secret');
}

// ── 2. Real runs against fakes ───────────────────────────────────────────
const workerEnv = { cwd: worker, env: { ...process.env, CLOUDFLARE_API_TOKEN: '', WRANGLER_SEND_METRICS: 'false' }, encoding: 'utf8' };
const port = () => 8700 + Math.floor(Math.random() * 400);

async function up(url) {
  const deadline = Date.now() + 90_000;
  for (;;) {
    try {
      if ((await fetch(url)).status < 500) return;
    } catch {}
    if (Date.now() > deadline) throw new Error(`${url} did not come up`);
    await new Promise((r) => setTimeout(r, 400));
  }
}

async function realRun(mode, provider) {
  const dir = join(state, `run-${mode}`);
  const persist = join(dir, 'persist');
  const served = join(dir, 'served');
  mkdirSync(join(served, 'cn'), { recursive: true });
  mkdirSync(join(served, 'gh'), { recursive: true });
  writeFileSync(log, '');
  const betaSecret = randomBytes(32).toString('base64url');
  for (const [k, v] of [
    [`beta:chan:${createHash('sha256').update(fake.channel).digest('hex')}`, { label: 'smoke-app' }],
    [`beta:key:${createHmac('sha256', betaSecret).update(`key\n${fake.key}`).digest('hex')}`, { label: 'smoke' }],
  ]) {
    const r = spawnSync('npx', ['wrangler', 'kv', 'key', 'put', k, JSON.stringify(v), '--binding', 'QUOTA', '--local', '--persist-to', persist], workerEnv);
    if (r.status !== 0) throw new Error(r.stderr);
  }
  const sport = port();
  const wport = sport + 400;
  const cnBase = `http://127.0.0.1:${sport}/cn/`;
  const ghBase = `http://127.0.0.1:${sport}/gh`;
  const origin = `http://127.0.0.1:${wport}`;
  const server = spawn('python3', [join(fakes, 'static_server.py'), served, String(sport)], { stdio: 'ignore' });
  const dev = spawn('npx', ['wrangler', 'dev', '--local', '--ip', '127.0.0.1', '--port', String(wport), '--persist-to', persist,
    '--var', `BETA_SECRET:${betaSecret}`, '--var', `DOWNLOAD_ACCESS:${mode}`, '--var', `CN_BASE_URL:${cnBase}`, '--show-interactive-dev-session=false'],
  { ...workerEnv, stdio: ['ignore', 'pipe', 'pipe'] });
  let devOut = '';
  dev.stdout.on('data', (d) => (devOut += d));
  dev.stderr.on('data', (d) => (devOut += d));
  const env = {
    PATH: `${fakes}:${process.env.PATH}`, ...CN[provider], FAKE_BUCKET: CN[provider].CN_BUCKET, FAKE_REGION: CN[provider].CN_REGION,
    FAKE_CN_ROOT: join(served, 'cn'), FAKE_GH_ROOT: join(served, 'gh'),
    R2_LOCAL_PERSIST: persist, BETA_ORIGIN: origin, CN_BASE_URL: cnBase, GITHUB_DOWNLOAD_BASE: ghBase,
  };
  // spawnSync blocks the event loop, so a kept-alive socket can be closed under
  // fetch's feet while a publish runs: one retry.
  const get = (url, init) => fetch(url, init).catch(() => fetch(url, init));
  const feed = async () => (await get(`${origin}/beta/update.json`, { headers: { Authorization: `Bearer ${fake.channel}` } })).json();
  try {
    await up(`http://127.0.0.1:${sport}/`);
    await up(`${origin}/robots.txt`).catch((e) => { throw new Error(`${e.message}\n${devOut.slice(-3000)}`); });
    const dist = makeDist(VERSION);
    const tag = `v${VERSION}`;

    const first = publish(dist, ['--github'], env);
    console.log(first.out.replace(/^/gm, '  | '));
    check(first.code === 0 && first.out.includes(`published ${VERSION}: global cn github`), `${mode}/${provider}: publishes to R2, China and GitHub`, first.out);
    check(first.out.includes(mode === 'public' ? `${origin}/download offers ${VERSION}` : `${origin}/beta (access key) offers ${VERSION}`), `${mode}: the live page offers it on every route`);
    check(noSecrets(first.out + readFileSync(log, 'utf8')), `${mode}: no secret in the output or on any command line`);
    check(readdirSync(join(served, 'cn', VERSION)).sort().join(' ') === `SHA256SUMS dsh-go-${VERSION}-arm64.apk dsh-go-${VERSION}-x64.apk`, `${mode}: China has both APKs and SHA256SUMS`);
    const gh = JSON.parse(readFileSync(join(served, 'gh', tag, 'update.json'), 'utf8'));
    const release = JSON.parse(readFileSync(join(served, 'gh', tag, '.release.json'), 'utf8'));
    check(!existsSync(join(served, 'gh', '_drafts', tag)) && release.title === `DSH Go ${VERSION}` && /^### 中文\n[\s\S]+\n### English\n/.test(release.notes), `${mode}: GitHub release published, notes from the changelog`);
    check(!('url' in gh.assets.arm64) && !('routes' in gh) && gh.notesByLocale.en, `${mode}: GitHub's update.json lets the app use GitHub URLs`);
    const latest = await feed();
    check(JSON.stringify(latest.routes) === '["global","cn","github"]' && latest.assets.arm64.url === `${origin}/beta/${VERSION}/dsh-go-${VERSION}-arm64.apk`, `${mode}: beta/update.json lists the routes; the app's URLs are as before`);
    const calls = readFileSync(log, 'utf8');
    check(calls.indexOf('--draft=false') > calls.lastIndexOf('release download'), `${mode}: GitHub went public after every file was downloaded back`);

    // What a visitor gets from workerd itself.
    if (mode === 'public') {
      const old = await get(`${origin}/beta?lang=en`, { redirect: 'manual' });
      check(old.status === 302 && old.headers.get('location') === '/download?lang=en', 'public: the old /beta link redirects to /download');
      const page = await (await get(`${origin}/download?via=cn`)).text();
      check(page.includes(`href="/download/get?via=cn&amp;v=${VERSION}"`) && /id="via-0" value="cn" checked/.test(page), 'public: ?via=cn picks the China route');
      const hop = await get(`${origin}/download/get?via=cn&v=${VERSION}`, { redirect: 'manual' });
      check(hop.status === 302 && hop.headers.get('location') === `${cnBase}${VERSION}/dsh-go-${VERSION}-arm64.apk`, 'public: the China button is counted and redirects to the bucket');
      const file = `${origin}/download/${VERSION}/dsh-go-${VERSION}-arm64.apk`;
      const part = await get(file, { headers: { Range: 'bytes=100-199' } });
      check(part.status === 206 && part.headers.get('content-range') === `bytes 100-199/900000` && (await part.arrayBuffer()).byteLength === 100, 'public: Range gives 206');
      const full = await get(file);
      const bytes = Buffer.from(await full.arrayBuffer());
      check(full.headers.get('cache-control') === 'public, max-age=31536000, immutable' && bytes.length === 900_000, 'public: the APK is cacheable');
      const past = await get(file, { headers: { Range: 'bytes=900000-' } });
      await past.arrayBuffer();
      check(past.status === 416, 'public: a range past the end is 416');
    }

    const again = publish(dist, ['--github'], env);
    const skipped = (again.out.match(/already there/g) ?? []).length;
    check(again.code === 0 && skipped === 8, `${mode}: publishing again skips what's there (${skipped} files)`, again.out);

    const apk = join(dist, `dsh-go-${VERSION}-arm64.apk`);
    appendFileSync(apk, 'changed');
    const m = JSON.parse(readFileSync(join(dist, 'update.json'), 'utf8'));
    const sha = createHash('sha256').update(readFileSync(apk)).digest('hex');
    writeFileSync(join(dist, 'SHA256SUMS'), readFileSync(join(dist, 'SHA256SUMS'), 'utf8').replace(m.assets.arm64.sha256, sha));
    Object.assign(m.assets.arm64, { size: m.assets.arm64.size + 7, sha256: sha });
    writeFileSync(join(dist, 'update.json'), JSON.stringify(m));
    const changed = publish(dist, ['--github'], env);
    check(changed.code === 1 && changed.out.includes('already up with another size'), `${mode}: a changed APK under the same version is refused`, changed.out);

    // The Hong Kong bucket holds a broken copy of the older version: nothing goes live.
    const older = makeDist(OLDER);
    const name = `dsh-go-${OLDER}-arm64.apk`;
    mkdirSync(join(served, 'cn', OLDER));
    const broken = readFileSync(join(older, name));
    broken[1234] ^= 0xff;
    writeFileSync(join(served, 'cn', OLDER, name), broken);
    const corrupt = publish(older, ['--github'], env);
    check(corrupt.code === 1 && corrupt.out.includes(`China ${name} doesn't match`), `${mode}: a corrupt copy on one route stops the release`, corrupt.out);
    check((await feed()).version.startsWith(`${VERSION}+`) && existsSync(join(served, 'gh', '_drafts', `v${OLDER}`)), `${mode}: the page, the app and GitHub stay on ${VERSION}`);
  } catch (e) {
    e.message += `${e.cause ? ` (${e.cause.message ?? e.cause})` : ''}\n--- wrangler dev ---\n${devOut.slice(-3000)}`;
    throw e;
  } finally {
    dev.kill('SIGTERM');
    server.kill('SIGTERM');
  }
}

try {
  console.log(`publish smoke: ${VERSION} (and ${OLDER}) in ${state}`);
  dryRuns();
  if (!dryOnly) {
    await realRun('public', 'oss');
    await realRun('key', 'cos');
  }
  console.log(`publish smoke: all ${passed} passed`);
  rmSync(state, { recursive: true, force: true });
} catch (e) {
  console.error(`publish smoke: FAILED ${e.message}\n(kept ${state})`);
  process.exit(1);
}
