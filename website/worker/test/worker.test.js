import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import worker, { purge, resetForTests } from '../index.js';
import { describeAgent, buildEntry } from '../visitor.js';

const UA = {
  iphone: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1',
  ipad: 'Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1',
  pixel: 'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
  galaxyTab: 'Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
  samsung: 'Mozilla/5.0 (Linux; Android 14; SM-S921U) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/26.0 Chrome/122.0.0.0 Mobile Safari/537.36',
  edge: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0',
  chromeMac: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  safariMac: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15',
  firefox: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0',
  chromeIos: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/131.0.6778.73 Mobile/15E148 Safari/604.1',
  googlebot: 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)',
};

test('tells phones, tablets, and desktops apart, with the browser and OS', () => {
  assert.deepEqual(describeAgent(UA.iphone), { device: 'phone', browser: 'Safari 18', os: 'iOS', bot: false });
  assert.deepEqual(describeAgent(UA.ipad), { device: 'tablet', browser: 'Safari 17', os: 'iOS', bot: false });
  assert.deepEqual(describeAgent(UA.pixel), { device: 'phone', browser: 'Chrome 131', os: 'Android', bot: false });
  assert.deepEqual(describeAgent(UA.galaxyTab), { device: 'tablet', browser: 'Chrome 130', os: 'Android', bot: false });
  assert.deepEqual(describeAgent(UA.samsung), { device: 'phone', browser: 'Samsung Internet 26', os: 'Android', bot: false });
  assert.deepEqual(describeAgent(UA.edge), { device: 'desktop', browser: 'Edge 131', os: 'Windows', bot: false });
  assert.deepEqual(describeAgent(UA.chromeMac), { device: 'desktop', browser: 'Chrome 131', os: 'macOS', bot: false });
  assert.deepEqual(describeAgent(UA.safariMac), { device: 'desktop', browser: 'Safari 18', os: 'macOS', bot: false });
  assert.deepEqual(describeAgent(UA.firefox), { device: 'desktop', browser: 'Firefox 133', os: 'Windows', bot: false });
  assert.deepEqual(describeAgent(UA.chromeIos), { device: 'phone', browser: 'Chrome 131', os: 'iOS', bot: false });
  assert.equal(describeAgent(UA.googlebot).bot, true);
  assert.equal(describeAgent('').device, 'desktop');
});

test('lets the Sec-CH-UA-Mobile hint settle phone or not', () => {
  assert.equal(describeAgent(UA.chromeMac, '?1').device, 'phone');
  assert.equal(describeAgent(UA.pixel, '?0').device, 'desktop');
  assert.equal(describeAgent(UA.galaxyTab, '?0').device, 'tablet');
});

function request(body, headers = {}, cf = {}) {
  const r = new Request('https://weekendboise.com/api/log', {
    method: 'POST',
    body: typeof body === 'string' ? body : JSON.stringify(body),
    headers: { 'user-agent': UA.iphone, 'cf-connecting-ip': '203.0.113.7', ...headers },
  });
  Object.defineProperty(r, 'cf', { value: cf });
  return r;
}

test('builds a row from the request and the beacon', () => {
  const body = { kind: 'search', path: '/', qs: 'q=jazz&city=Boise', q: 'jazz', results: 12, w: 390, ref: 'https://www.google.com/' };
  const row = buildEntry(request(body, {}, { country: 'US', region: 'Idaho', city: 'Boise', asOrganization: 'Sparklight' }), body, new Date('2026-11-08T20:00:00Z'));
  assert.equal(row.ts, '2026-11-08T20:00:00.000Z');
  assert.equal(row.ip, '203.0.113.7');
  assert.equal(row.city, 'Boise');
  assert.equal(row.asn_org, 'Sparklight');
  assert.equal(row.device, 'phone');
  assert.equal(row.browser, 'Safari 18');
  assert.equal(row.qs, 'q=jazz&city=Boise');
  assert.equal(row.q, 'jazz');
  assert.equal(row.results, 12);
  assert.equal(row.width, 390);
  assert.equal(row.bot, 0);
});

test('rejects bodies that are not log entries, and caps long fields', () => {
  assert.equal(buildEntry(request('{}'), {}), null);
  assert.equal(buildEntry(request('{}'), { kind: 'delete' }), null);
  const row = buildEntry(request('{}'), { kind: 'search', q: 'x'.repeat(5000), results: -1, w: 'wide' });
  assert.equal(row.q.length, 200);
  assert.equal(row.results, null);
  assert.equal(row.width, null);
});

function fakeDb() {
  const calls = [];
  return {
    calls,
    prepare(sql) {
      const stmt = { sql, args: [], bind(...a) { stmt.args = a; return stmt; }, async run() { calls.push(stmt); return {}; } };
      return stmt;
    },
    async batch(stmts) { for (const s of stmts) calls.push(s); return []; },
  };
}

beforeEach(() => resetForTests());

test('stores a visit once the table exists, and answers 204', async () => {
  const db = fakeDb();
  const res = await worker.fetch(request({ kind: 'view', path: '/', qs: '', results: 300 }), { LOG_DB: db });
  assert.equal(res.status, 204);
  assert.match(db.calls[0].sql, /CREATE TABLE IF NOT EXISTS visits/);
  const insert = db.calls.find((c) => c.sql.startsWith('INSERT'));
  assert.ok(insert);
  assert.ok(insert.args.includes('203.0.113.7'));
  assert.ok(insert.args.includes('view'));

  await worker.fetch(request({ kind: 'search', q: 'jazz' }), { LOG_DB: db });
  assert.equal(db.calls.filter((c) => c.sql.startsWith('CREATE TABLE')).length, 1, 'the table is created once');
});

test('turns away other methods, bad JSON, and oversized bodies without storing them', async () => {
  const db = fakeDb();
  const get = new Request('https://weekendboise.com/api/log');
  assert.equal((await worker.fetch(get, { LOG_DB: db })).status, 405);
  assert.equal((await worker.fetch(request('not json'), { LOG_DB: db })).status, 400);
  assert.equal((await worker.fetch(request('x'.repeat(5000)), { LOG_DB: db })).status, 413);
  assert.equal(db.calls.filter((c) => c.sql.startsWith('INSERT')).length, 0);
});

test('never shows a database failure to the visitor', async () => {
  const db = fakeDb();
  db.prepare = () => { throw new Error('D1 is down'); };
  db.batch = async () => { throw new Error('D1 is down'); };
  const original = console.error;
  console.error = () => {};
  try {
    assert.equal((await worker.fetch(request({ kind: 'view' }), { LOG_DB: db })).status, 204);
  } finally {
    console.error = original;
  }
});

test('passes everything else to the static files, and 404s other API paths', async () => {
  const env = { ASSETS: { fetch: async () => new Response('page') } };
  assert.equal(await (await worker.fetch(new Request('https://weekendboise.com/sources/'), env)).text(), 'page');
  assert.equal((await worker.fetch(new Request('https://weekendboise.com/api/other'), env)).status, 404);
});

test('the daily purge deletes rows older than 90 days', async () => {
  const db = fakeDb();
  await purge({ LOG_DB: db }, new Date('2026-11-08T00:00:00Z'));
  const del = db.calls.find((c) => c.sql.startsWith('DELETE'));
  assert.deepEqual(del.args, ['2026-08-10T00:00:00.000Z']);
});
