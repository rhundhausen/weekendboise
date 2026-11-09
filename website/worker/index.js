// The site's Worker. Static files are served straight from website/public; wrangler.jsonc sends
// only /api/* here. POST /api/log records a visit in the private LOG_DB database, which only
// the Cloudflare account can read (see website/README.md, "Visitor log"). Nothing reads the log
// back over the web.

import { buildEntry, COLUMNS } from './visitor.js';
import { SCHEMA, KEEP_DAYS } from './schema.js';

const MAX_BODY = 4096;
let ready = null;

function ensureTable(db) {
  ready ??= db.batch(SCHEMA.map((sql) => db.prepare(sql))).catch((err) => { ready = null; throw err; });
  return ready;
}

async function logVisit(request, env) {
  if (request.method !== 'POST') return new Response(null, { status: 405, headers: { allow: 'POST' } });
  if (!env.LOG_DB) return new Response(null, { status: 204 });

  const text = await request.text();
  if (text.length > MAX_BODY) return new Response(null, { status: 413 });
  let body;
  try { body = JSON.parse(text); } catch { return new Response(null, { status: 400 }); }
  const row = buildEntry(request, body);
  if (!row) return new Response(null, { status: 400 });

  await ensureTable(env.LOG_DB);
  const sql = `INSERT INTO visits (${COLUMNS.join(', ')}) VALUES (${COLUMNS.map(() => '?').join(', ')})`;
  await env.LOG_DB.prepare(sql).bind(...COLUMNS.map((c) => row[c])).run();
  return new Response(null, { status: 204 });
}

export async function purge(env, now = new Date()) {
  if (!env.LOG_DB) return;
  await ensureTable(env.LOG_DB);
  const cutoff = new Date(now.getTime() - KEEP_DAYS * 86400000).toISOString();
  await env.LOG_DB.prepare('DELETE FROM visits WHERE ts < ?').bind(cutoff).run();
}

export function resetForTests() { ready = null; }

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (pathname === '/api/log') {
      try {
        return await logVisit(request, env);
      } catch (err) {
        // A logging failure must never show on the page; the beacon ignores the answer anyway.
        console.error('visitor log failed', err);
        return new Response(null, { status: 204 });
      }
    }
    if (pathname.startsWith('/api/')) return new Response('Not found', { status: 404 });
    return env.ASSETS.fetch(request);
  },

  async scheduled(controller, env, ctx) {
    ctx.waitUntil(purge(env));
  },
};
