// Counting downloads and update checks without keeping anyone's IP
// (docs/design/share-links.md §15). Everything goes to Workers Analytics
// Engine; it is read only through scripts/stats.sh with an API token, never
// through a public endpoint.
//
//   dshgo_downloads  GET /download/get (a download button): day, route,
//                    version, country, daily device code
//   dshgo_checks     GET /beta/update.json answered to the app's channel
//                    token: day, daily device code, app version and ABI (when
//                    the User-Agent says), country
//   dshgo_usage      POST /api/usage/v1, the app's own report (src/usage.ts)
//
// The daily device code is HMAC(today's salt, IP + User-Agent), 64 bits. The
// salt is random: the StatsSalt Durable Object makes it on the day's first
// request and deletes it when the day is over. Codes from different days
// can't be linked, and nothing stored leads back to an IP. Days are UTC+8.
//
// Counting never gets in the way: it runs after the response (waitUntil) and
// any failure just means a point isn't written. Without a dataset bound
// (Analytics Engine not enabled) nothing is counted and no salt is made.

import type { Env } from './env';
import { clientKey } from './limits';
import { countryOf } from './routes';

const DAY_MS = 86_400_000;
/** Days start at midnight UTC+8, where the app's people mostly are. */
const OFFSET_MS = 8 * 3_600_000;

export function statsDay(now = Date.now()): string {
  return new Date(now + OFFSET_MS).toISOString().slice(0, 10);
}

/** When the next stats day starts (ms). */
export function nextDayStart(now = Date.now()): number {
  return Math.floor((now + OFFSET_MS) / DAY_MS) * DAY_MS + DAY_MS - OFFSET_MS;
}

/** [day] moved by [days] (calendar arithmetic on YYYY-MM-DD). */
export function addDays(day: string, days: number): string {
  return new Date(Date.parse(`${day}T00:00:00Z`) + days * DAY_MS).toISOString().slice(0, 10);
}

const encoder = new TextEncoder();

function base64url(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function hex(bytes: ArrayBuffer, take: number): string {
  return [...new Uint8Array(bytes).slice(0, take)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function hmacHex(key: string | CryptoKey, message: string, bytes: number): Promise<string> {
  const k =
    typeof key === 'string'
      ? await crypto.subtle.importKey('raw', encoder.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
      : key;
  return hex(await crypto.subtle.sign('HMAC', k, encoder.encode(message)), bytes);
}

// ── The day's salt ───────────────────────────────────────────────────────

interface Salt {
  day: string;
  salt: string;
}

/** One object (named "salt") holds today's random salt; an alarm deletes it
 *  once the day is over, so yesterday's codes can't be recomputed. */
export class StatsSalt {
  now = () => Date.now();

  constructor(private readonly state: DurableObjectState) {}

  async fetch(): Promise<Response> {
    const day = statsDay(this.now());
    let stored = await this.state.storage.get<Salt>('salt');
    if (!stored || stored.day !== day) {
      stored = { day, salt: base64url(crypto.getRandomValues(new Uint8Array(32))) };
      await this.state.storage.put('salt', stored);
      await this.state.storage.setAlarm(nextDayStart(this.now()));
    }
    return new Response(JSON.stringify(stored), { headers: { 'Content-Type': 'application/json' } });
  }

  async alarm(): Promise<void> {
    const stored = await this.state.storage.get<Salt>('salt');
    if (stored && stored.day === statsDay(this.now())) {
      await this.state.storage.setAlarm(nextDayStart(this.now()));
      return;
    }
    await this.state.storage.deleteAll();
  }
}

// Each isolate keeps the day's key in memory until the day changes.
let saltMemo: { day: string; key: CryptoKey } | null = null;

/** For tests. */
export function resetStatsMemo(): void {
  saltMemo = null;
}

async function todaysKey(env: Env, now: number): Promise<CryptoKey | null> {
  const day = statsDay(now);
  if (saltMemo?.day === day) return saltMemo.key;
  if (!env.STATS_SALT) return null;
  try {
    const stub = env.STATS_SALT.get(env.STATS_SALT.idFromName('salt'));
    const res = await stub.fetch('https://stats-salt/');
    const got = (await res.json()) as Salt;
    if (got.day !== day || typeof got.salt !== 'string' || got.salt.length < 32) return null;
    const key = await crypto.subtle.importKey('raw', encoder.encode(got.salt), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    saltMemo = { day, key };
    return key;
  } catch {
    return null;
  }
}

/** Today's code for whoever sent [request]: 16 hex characters, or '' when the
 *  salt can't be had. IPv6 counts by its /64 (src/limits.ts). */
export async function deviceCode(env: Env, request: Request, now = Date.now()): Promise<string> {
  const key = await todaysKey(env, now);
  if (!key) return '';
  return hmacHex(key, `${clientKey(request)}\n${request.headers.get('User-Agent') ?? ''}`, 8);
}

// ── Writing ──────────────────────────────────────────────────────────────

function write(dataset: AnalyticsEngineDataset | undefined, point: AnalyticsEngineDataPoint): void {
  if (!dataset) return;
  try {
    dataset.writeDataPoint(point);
  } catch (e) {
    console.error('stats write failed', e instanceof Error ? e.message : String(e));
  }
}

/** dshgo_downloads: blob1 day, blob2 route, blob3 version, blob4 country, blob5 device. */
export async function countDownload(env: Env, request: Request, route: string, version: string, now = Date.now()): Promise<void> {
  if (!env.DOWNLOADS) return;
  const device = await deviceCode(env, request, now);
  write(env.DOWNLOADS, { indexes: [route], blobs: [statsDay(now), route, version, countryOf(request) ?? 'XX', device], doubles: [1] });
}

const ABIS = new Set(['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86']);

/** `dsh-app-updater/<version> (<abi>)` → its parts. The app's updater says
 *  only `dsh-app-updater` today; a later build can add them. */
export function parseUpdaterAgent(ua: string | null): { app: string; abi: string } {
  const m = /^dsh-app-updater\/([0-9][0-9A-Za-z.+-]{0,39})(?:\s+\(([a-z0-9_-]{1,16})\))?/.exec(ua ?? '');
  return { app: m?.[1] ?? '', abi: m?.[2] && ABIS.has(m[2]) ? m[2] : '' };
}

/** dshgo_checks: blob1 day, blob2 device, blob3 app version, blob4 ABI, blob5 country. */
export async function countCheck(env: Env, request: Request, now = Date.now()): Promise<void> {
  if (!env.CHECKS) return;
  const device = await deviceCode(env, request, now);
  const { app, abi } = parseUpdaterAgent(request.headers.get('User-Agent'));
  write(env.CHECKS, { indexes: [device || 'none'], blobs: [statsDay(now), device, app, abi, countryOf(request) ?? 'XX'], doubles: [1] });
}

export { write as writeStat };
