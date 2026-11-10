// Static pages: the conversation viewer at /c/<id> and the landing page at
// /share/, both built from site/share/; the home page at / (site/home/dist,
// a community-made site), its files at their own paths (/app.js, /assets/…).
// scripts/build-site.mjs copies them into public/.

import type { Env } from './env';
import { HOME_FILES, PAGE_CSP } from './generated/pages';

/** Paths in public/. */
export const VIEWER_PAGE = '/c.html';
export const LANDING_PAGE = '/share/index.html';
export const HOME_PAGE = '/home/index.html';

/** Where a home page file such as /app.js sits in public/, or null. */
export function homeFile(path: string): string | null {
  return HOME_FILES.has(path) ? '/home' + path : null;
}

const COMMON: Record<string, string> = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Robots-Tag': 'noindex',
  'Strict-Transport-Security': 'max-age=31536000',
};

const HTML: Record<string, string> = {
  ...COMMON,
  'X-Frame-Options': 'DENY',
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=()',
  'Cache-Control': 'no-cache',
};

/** For a page without its own policy (none today; build-site.mjs checks). */
const FALLBACK_CSP =
  "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; " +
  "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

export function redirect(location: string, status = 302): Response {
  return new Response(null, { status, headers: { ...COMMON, Location: location, 'Cache-Control': 'no-store' } });
}

export function notFound(): Response {
  return new Response('Not found', {
    status: 404,
    headers: { ...COMMON, 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

/** Serves a file from public/ at [path] (not the request's own path). Only
 *  the home page and its files may be indexed (robots.txt says the same). */
export async function asset(request: Request, env: Env, path: string): Promise<Response> {
  const url = new URL(request.url);
  url.pathname = path;
  url.search = '';
  const res = await env.ASSETS.fetch(new Request(url.toString(), { method: request.method, headers: request.headers }));
  if (res.status === 404) return notFound();
  const headers = new Headers(res.headers);
  const html = (headers.get('Content-Type') ?? '').startsWith('text/html');
  for (const [k, v] of Object.entries(html ? HTML : COMMON)) headers.set(k, v);
  if (path.startsWith('/home/')) headers.delete('X-Robots-Tag');
  if (html) headers.set('Content-Security-Policy', PAGE_CSP[path] ?? FALLBACK_CSP);
  else if (res.status === 200) headers.set('Cache-Control', 'public, max-age=3600');
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
}
