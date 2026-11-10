// dshgo-share: hosted conversation links for dsh-go (docs/design/share-links.md).
//
//   POST   /api/v1/c?ttl=7d|30d|forever   store a ciphertext → {id, deleteToken, expiresAt}
//   GET    /api/v1/c/<id>                 the ciphertext
//   DELETE /api/v1/c/<id>                 Bearer <deleteToken>, or X-Admin-Key
//   GET    /c/<id>                        the viewer page (decrypts with #k=…)
//   GET    /                              the home page (site/home/), its files
//                                         at /app.js, /assets/… (src/site.ts)
//   GET    /share/                        the landing page
//   GET    /beta, /beta/…                 beta builds behind an access key (src/beta.ts)
//   GET    /download, /download/…         the same builds for anyone, once
//                                         DOWNLOAD_ACCESS=public (src/download.ts)
//   POST   /api/usage/v1                  the app's anonymous usage report (src/usage.ts)
//   GET    /api/github/stars              the repository's star count, for the home page
//                                         (src/github.ts)
//
// Downloads, update checks and usage reports are counted in Analytics Engine
// without keeping IPs (src/stats.ts); scripts/stats.sh reads them.
//
// /update.json (a retired public mirror) is 404, and so is /download until
// DOWNLOAD_ACCESS=public.

import { fetchBlob, json, remove, upload } from './api';
import type { Env } from './env';
import { beta, isBetaPath } from './beta';
export { BetaGuard } from './beta-guard';
import { accessMode, download, isDownloadPath } from './download';
export { StatsSalt } from './stats';
import { usage } from './usage';
import { githubStars } from './github';
import type { Ctx } from './files';
import { HOME_PAGE, LANDING_PAGE, VIEWER_PAGE, asset, homeFile, notFound, redirect } from './site';

const VIEWER_PATH = /^\/c\/([0-9A-Za-z]{6,32})\/?$/;
const BLOB_PATH = /^\/api\/v1\/c\/([^/]+)$/;
/** Paths of the retired public download mirror; 404 (/download is the
 *  public page once DOWNLOAD_ACCESS=public). */
const RETIRED = /^\/(?:update\.json|download(?:\/.*)?)$/;

async function route(request: Request, env: Env, ctx: Ctx): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

  if (path.startsWith('/api/')) {
    if (path === '/api/usage/v1') return usage(request, env);
    if (path === '/api/github/stars') return githubStars(request, env, ctx);
    if (path === '/api/v1/c') {
      return method === 'POST' ? upload(request, env) : json(405, { error: 'method_not_allowed' }, { Allow: 'POST' });
    }
    const blob = BLOB_PATH.exec(path);
    if (blob) {
      const id = blob[1]!;
      if (method === 'GET') return fetchBlob(request, env, id);
      if (method === 'DELETE') return remove(request, env, id);
      return json(405, { error: 'method_not_allowed' }, { Allow: 'GET, DELETE' });
    }
    return json(404, { error: 'not_found' });
  }

  if (isBetaPath(path)) return beta(request, env, ctx);
  if (isDownloadPath(path) && accessMode(env) === 'public') return download(request, env, ctx);
  // public/home/ is served at the root only.
  if (RETIRED.test(path) || path.startsWith('/__edge/') || path.startsWith('/home/')) return notFound();
  if (method !== 'GET' && method !== 'HEAD') return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  if (path === '/') return asset(request, env, HOME_PAGE);
  const home = homeFile(path);
  if (home) return asset(request, env, home);
  if (path === '/share') return redirect('/share/', 301);
  if (path === '/share/' || path === '/share/index.html') return asset(request, env, LANDING_PAGE);
  if (VIEWER_PATH.test(path)) return asset(request, env, VIEWER_PAGE);
  if (path === VIEWER_PAGE) return notFound();
  if (path.endsWith('/') || path.endsWith('.html')) return notFound();
  return asset(request, env, path);
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      return await route(request, env, ctx);
    } catch (e) {
      console.error('unhandled', e instanceof Error ? e.message : String(e));
      return json(500, { error: 'internal' });
    }
  },
} satisfies ExportedHandler<Env>;
