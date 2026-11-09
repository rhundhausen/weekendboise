// Turns a request to /api/log into one row of the visitor log. Kept apart from index.js so the
// tests can run it under Node without the Workers runtime.

const LIMITS = { path: 200, qs: 1000, q: 200, ref: 300, ua: 500 };

function clip(value, max) {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  return text ? text.slice(0, max) : null;
}

// Phone, tablet, or desktop, with the browser and operating system, from the User-Agent.
// Chromium browsers also send Sec-CH-UA-Mobile, which settles phone or not when it is there.
export function describeAgent(ua, mobileHint) {
  const s = ua || '';
  const bot = /bot|crawl|spider|slurp|headless|lighthouse|preview/i.test(s);

  let device = 'desktop';
  if (/iPad|Tablet|PlayBook|Silk|Kindle/i.test(s) || (/Android/i.test(s) && !/Mobile/i.test(s))) device = 'tablet';
  else if (/Mobi|iPhone|iPod|Android|Windows Phone/i.test(s)) device = 'phone';
  if (mobileHint === '?1') device = 'phone';
  else if (mobileHint === '?0' && device === 'phone') device = 'desktop';

  // Order matters: Edge, Opera, and Samsung Internet also say Chrome, and Chrome also says Safari.
  const browsers = [
    ['Edge', /Edg(?:e|A|iOS)?\/([\d]+)/],
    ['Opera', /(?:OPR|OPiOS)\/([\d]+)/],
    ['Samsung Internet', /SamsungBrowser\/([\d]+)/],
    ['Firefox', /(?:Firefox|FxiOS)\/([\d]+)/],
    ['Chrome', /(?:Chrome|CriOS)\/([\d]+)/],
    ['Safari', /Version\/([\d]+)[\d.]* (?:Mobile\/\S+ )?Safari\//],
  ];
  let browser = 'Other';
  for (const [name, re] of browsers) {
    const m = s.match(re);
    if (m) { browser = `${name} ${m[1]}`; break; }
  }

  let os = 'Other';
  if (/iPhone|iPad|iPod/.test(s)) os = 'iOS';
  else if (/Android/.test(s)) os = 'Android';
  else if (/Windows/.test(s)) os = 'Windows';
  else if (/CrOS/.test(s)) os = 'ChromeOS';
  else if (/Mac OS X|Macintosh/.test(s)) os = 'macOS';
  else if (/Linux/.test(s)) os = 'Linux';

  return { device, browser, os, bot };
}

// One log row, or null when the body is not a log entry. Lengths are capped because anyone
// can post to the endpoint.
export function buildEntry(request, body, now = new Date()) {
  if (!body || typeof body !== 'object' || !['view', 'search'].includes(body.kind)) return null;
  const headers = request.headers;
  const cf = request.cf || {};
  const ua = headers.get('user-agent') || '';
  const agent = describeAgent(ua, headers.get('sec-ch-ua-mobile'));
  const results = Number.isInteger(body.results) && body.results >= 0 ? body.results : null;
  const width = Number.isInteger(body.w) && body.w > 0 && body.w < 100000 ? body.w : null;
  return {
    ts: now.toISOString(),
    kind: body.kind,
    ip: headers.get('cf-connecting-ip') || null,
    country: clip(cf.country, 8),
    region: clip(cf.region, 80),
    city: clip(cf.city, 80),
    asn_org: clip(cf.asOrganization, 120),
    device: agent.device,
    browser: agent.browser,
    os: agent.os,
    bot: agent.bot ? 1 : 0,
    width,
    path: clip(body.path, LIMITS.path),
    qs: clip(body.qs, LIMITS.qs),
    q: clip(body.q, LIMITS.q),
    results,
    referrer: clip(body.ref, LIMITS.ref),
    ua: clip(ua, LIMITS.ua),
  };
}

export const COLUMNS = ['ts', 'kind', 'ip', 'country', 'region', 'city', 'asn_org', 'device', 'browser', 'os', 'bot',
  'width', 'path', 'qs', 'q', 'results', 'referrer', 'ua'];
