// Event grid: loads the slim events file, then filters, searches, sorts, and pages in the browser.
// All event text comes from outside sources, so it is only ever set with textContent.

const cfg = JSON.parse(document.getElementById('tv-config').textContent);
const PAGE_SIZES = [25, 50, 100, 250, 500];
const DEFAULT_PER = PAGE_SIZES[0];
const TZ = 'America/Boise';

const ymdFmt = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' });
const timeFmt = new Intl.DateTimeFormat('en-US', { timeZone: TZ, hour: 'numeric', minute: '2-digit' });
// "17:30" in Boise time, for comparing times as strings.
const hmFmt = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const dayFmt = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' });
const shortFmt = new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric' });
const numFmt = new Intl.NumberFormat('en-US');

const $ = (id) => document.getElementById(id);
const el = {
  q: $('q'), when: $('when'), from: $('from'), to: $('to'), city: $('city'), size: $('size'), cost: $('cost'),
  reset: $('reset'), cats: $('cats'), count: $('count'), rows: $('rows'), sourceNote: $('source-note'),
  pagerTop: $('pager-top'), pagerBottom: $('pager-bottom'), per: $('per'),
  meetup: $('meetup'), meetupCount: $('meetup-n'), meetupChip: $('meetup-chip'),
  more: $('more'), moreCount: $('more-n'), controls: document.querySelector('.controls'),
};

// Dates are handled as YYYY-MM-DD strings in Boise time; noon UTC keeps day math clear of DST edges.
const boiseDay = (date) => ymdFmt.format(date);
const asDate = (ymd) => new Date(`${ymd}T12:00:00Z`);
const addDays = (ymd, n) => { const d = asDate(ymd); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
// Lowercase, no accents, no apostrophes: "Women's" and "womens" both become "womens".
const fold = (s) => (s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/['‘’]/g, '').toLowerCase();
// Short forms people search with. A search word matches if the event has it or any of its long forms.
const ALIASES = { bsu: ['boise state'], nnu: ['northwest nazarene'], cofi: ['college of idaho'], meetups: ['meetup'] };
const searchTerms = (q) => fold(q).split(/\s+/).filter(Boolean).map((w) => [w, ...(ALIASES[w] || [])]);
const today = () => boiseDay(new Date());
// "Tonight" is events that start today at 5 PM or later and end by 2 AM (last call in Idaho).
// An event with no end time counts if it starts in that window.
const EVENING = '17:00';
const LAST_CALL = '02:00';
// A timed event with no end (or an end not after its start) is taken to last 3 hours, so it
// leaves the list 3 hours after it starts.
const ASSUMED_LENGTH = 3 * 60 * 60 * 1000;

// Display-only shortening from website/data/display.json, so grid rows fit on one line.
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const PHRASES = (cfg.phrases || []).map(([long, short]) => [new RegExp(`\\b${escapeRe(long)}(?=\\W|$)`, 'gi'), short]);
const shorten = (s) => PHRASES.reduce((text, [re, short]) => text.replace(re, short), s || '');
// "Wassmuth Center for Human Rights, 777 South 8th Street, Boise, ID 83702" keeps only the name.
// True when an event's link goes to meetup.com (or a subdomain of it).
const isMeetup = (u) => /^https?:\/\/([^/?#]+\.)?meetup\.com([/?#:]|$)/i.test(u || '');
const dropAddress = (v) => (/^\D[^,]*,.*(\b\d{5}\b|,\s*(ID|Idaho)\b)/.test(v) ? v.split(',')[0] : v);

// Cost filter values (kept in the URL as ?cost=) to tiers. An unknown cost matches only "Any cost".
// The ranges are in the Cost header's tooltip, not on each cell (docs/cost-tiers.md).
const COST_TIERS = { free: 'free', 1: '$', 2: '$$', 3: '$$$' };
const COST_LABELS = { free: 'Free', $: '$', $$: '$$', $$$: '$$$' };
const NO_LINK = 'Information not available';

const state = { q: '', cats: new Set(), city: '', size: '', cost: '', source: '', meetup: false, when: '', from: '', to: '', sort: 'date', dir: 1, page: 1, per: DEFAULT_PER };
let events = [];

function prepare(e) {
  const allDay = Boolean(e.a) || e.s.length === 10;
  const sd = allDay ? e.s.slice(0, 10) : boiseDay(new Date(e.s));
  let ed = e.e ? (allDay ? e.e.slice(0, 10) : boiseDay(new Date(e.e))) : sd;
  if (ed < sd) ed = sd;
  const catLabel = cfg.categories[e.k] || e.k;
  const meetup = isMeetup(e.u);
  const dateText = sd === ed ? dayFmt.format(asDate(sd)) : `${dayFmt.format(asDate(sd))} to ${shortFmt.format(asDate(ed))}`;
  const timeText = allDay ? 'All day' : timeFmt.format(new Date(e.s));
  // Search reads everything a card shows (date, time, size, title, Meetup, city, venue, category,
  // cost) plus the tags, the description, and the names of the sources that listed the event.
  const meetupSlug = meetup ? ((e.u || '').match(/meetup\.com\/([^/?#]+)/i) || [])[1] || '' : '';
  const searchable = [
    dateText, timeText, (cfg.sizes[e.z] || '').split(':')[0], e.t, shorten(e.t), meetup ? 'Meetup' : '', e.c, e.v,
    catLabel, e.p === 'free' ? 'Free' : '', (e.g || []).join(' '), e.d, (e.r || []).map((n) => cfg.sources[n] || n).join(' '),
    // Source ids such as meetup-boise-ai-builders, and the Meetup group's slug from the link, with
    // its hyphens also as spaces so "boise ai" finds it.
    (e.r || []).join(' '), meetupSlug, meetupSlug.replace(/-/g, ' '),
  ];
  const instant = allDay ? 0 : Date.parse(e.s);
  const endParsed = !allDay && e.e ? Date.parse(e.e) : NaN;
  const end = allDay ? 0 : (endParsed > instant ? endParsed : instant + ASSUMED_LENGTH);
  return {
    title: e.t, venue: e.v, shortTitle: shorten(e.t), shortVenue: shorten(dropAddress(e.v || '')), city: e.c, cat: e.k, catLabel, tags: e.g || [], size: e.z, cost: e.p || '', broken: Boolean(e.x), url: e.u, desc: e.d, src: e.r || [], meetup,
    sd, ed, allDay,
    instant, end,
    // Boise "YYYY-MM-DD HH:MM" of the start and the real end (blank without one), for Tonight.
    // An end exactly at the start counts as no end.
    startKey: allDay ? '' : `${sd} ${hmFmt.format(new Date(instant))}`,
    endKey: endParsed > instant ? `${boiseDay(new Date(endParsed))} ${hmFmt.format(new Date(endParsed))}` : '',
    dateText, timeText,
    hay: fold(searchable.join(' ')),
  };
}

function presetRange(when) {
  const t = today();
  switch (when) {
    case 'today': case 'tonight': return [t, t];
    case 'tomorrow': return [addDays(t, 1), addDays(t, 1)];
    case 'weekend': {
      const dow = asDate(t).getUTCDay();
      if (dow === 0) return [t, t];
      if (dow === 6) return [t, addDays(t, 1)];
      const fri = addDays(t, 5 - dow);
      return [fri, addDays(fri, 2)];
    }
    case 'week': return [t, addDays(t, 6)];
    case 'month': return [t, addDays(t, 29)];
    case 'custom': return [state.from, state.to];
    default: return ['', ''];
  }
}

// Meetup events are hidden until "Include Meetups" is checked. Two things include them without it:
// opening the page for one Meetup group from the sources page; searching for "meetup" (or
// "meetups", or the start of it, such as "meet"), since that search asks for them; and a search
// that only Meetup events match, so it finds them instead of nothing. render() decides the last.
const searchesMeetup = (words) => words.some((forms) => forms.some((f) => f.length >= 4 && 'meetups'.startsWith(f)));
const meetupsForced = (words) => state.source.startsWith('meetup-') || searchesMeetup(words);

// Every filter except the Meetup one, which render() applies.
function matches(e, words, from, to, skipCats, now) {
  if (e.ed < from) return false;
  if (to && e.sd > to) return false;
  // Timed events that are over drop off the list, in every date choice.
  if (!e.allDay && e.end <= now) return false;
  if (state.when === 'tonight') {
    if (e.allDay || e.sd !== from || e.startKey < `${from} ${EVENING}`) return false;
    if (e.endKey && e.endKey > `${addDays(from, 1)} ${LAST_CALL}`) return false;
  }
  if (state.city && e.city !== state.city) return false;
  if (state.size && e.size !== state.size) return false;
  if (COST_TIERS[state.cost] && e.cost !== COST_TIERS[state.cost]) return false;
  if (state.source && !e.src.includes(state.source)) return false;
  if (!skipCats && state.cats.size && !state.cats.has(e.cat)) return false;
  for (const forms of words) if (!forms.some((f) => e.hay.includes(f))) return false;
  return true;
}

const sorters = {
  date: (a, b) => a.sd.localeCompare(b.sd) || a.instant - b.instant || a.title.localeCompare(b.title),
  title: (a, b) => a.title.localeCompare(b.title) || sorters.date(a, b),
  venue: (a, b) => a.venue.localeCompare(b.venue) || sorters.date(a, b),
  city: (a, b) => a.city.localeCompare(b.city) || sorters.date(a, b),
};

function render() {
  const words = searchTerms(state.q);
  const [rangeFrom, to] = presetRange(state.when);
  const from = rangeFrom && rangeFrom > today() ? rangeFrom : today();

  // Category counts reflect every other filter, so a chip shows what clicking it would give.
  // The Meetup count is how many Meetup events checking the box would add, or did add.
  const now = Date.now();
  const found = events.filter((e) => matches(e, words, from, to, true, now));
  const inCats = (e) => !state.cats.size || state.cats.has(e.cat);
  const meetups = found.filter((e) => e.meetup && inCats(e)).length;
  let forced = meetupsForced(words);
  if (!state.meetup && !forced && words.length && meetups && !found.some((e) => !e.meetup && inCats(e))) forced = true;
  const include = state.meetup || forced;
  const counts = {};
  const shown = [];
  for (const e of found) {
    if (e.meetup && !include) continue;
    counts[e.cat] = (counts[e.cat] || 0) + 1;
    if (inCats(e)) shown.push(e);
  }
  const sorter = sorters[state.sort] || sorters.date;
  shown.sort((a, b) => sorter(a, b) * state.dir);

  const pages = Math.max(1, Math.ceil(shown.length / state.per));
  state.page = Math.min(Math.max(1, state.page), pages);
  const start = (state.page - 1) * state.per;
  const slice = shown.slice(start, start + state.per);

  renderChips(counts);
  el.meetup.checked = include;
  el.meetup.disabled = forced;
  el.meetupCount.textContent = numFmt.format(meetups);
  el.meetupChip.classList.toggle('empty', !meetups);
  // The phone's "More filters" button counts the filters set behind it.
  const hidden = (state.from || state.to ? 1 : 0) + (state.size ? 1 : 0) + (state.cost ? 1 : 0) + state.cats.size + (state.meetup ? 1 : 0);
  el.moreCount.textContent = hidden ? ` (${hidden})` : '';
  renderSourceNote();
  renderRows(slice);
  el.count.textContent = shown.length
    ? `Showing ${numFmt.format(start + 1)} to ${numFmt.format(start + slice.length)} of ${numFmt.format(shown.length)} events`
    : 'No events match these filters';
  renderPager(el.pagerTop, pages);
  renderPager(el.pagerBottom, pages);
  renderSortHeaders();
  writeUrl();
}

function renderChips(counts) {
  el.cats.replaceChildren();
  const ids = Object.keys(cfg.categories);
  for (const id of ids) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = `chip cat-${id}`;
    b.dataset.cat = id;
    b.setAttribute('aria-pressed', state.cats.has(id) ? 'true' : 'false');
    const n = counts[id] || 0;
    if (!n && !state.cats.has(id)) b.classList.add('empty');
    const label = document.createElement('span');
    label.textContent = cfg.categories[id];
    const count = document.createElement('span');
    count.className = 'n';
    count.textContent = numFmt.format(n);
    b.append(label, count);
    el.cats.append(b);
  }
}

// Set when the page was opened from the sources page for one source.
function renderSourceNote() {
  el.sourceNote.replaceChildren();
  el.sourceNote.hidden = !state.source;
  if (!state.source) return;
  const label = document.createElement('span');
  label.textContent = `Only events from ${cfg.sources[state.source] || state.source}. `;
  const clear = document.createElement('button');
  clear.type = 'button';
  clear.className = 'link';
  clear.textContent = 'Show every source';
  clear.addEventListener('click', () => { state.source = ''; state.page = 1; render(); });
  el.sourceNote.append(label, clear);
}

function cell(text, className) {
  const td = document.createElement('td');
  if (className) td.className = className;
  if (text) td.textContent = text;
  return td;
}

function costBadge(tier) {
  const badge = document.createElement('span');
  badge.className = 'cost';
  badge.textContent = COST_LABELS[tier];
  return badge;
}

function renderRows(list) {
  const frag = document.createDocumentFragment();
  for (const e of list) {
    const tr = document.createElement('tr');

    const date = cell(e.dateText, 'c-date');
    date.dataset.label = 'Date';
    const time = cell(e.timeText, 'c-time');
    time.dataset.label = 'Time';

    const title = cell('', 'c-title');
    if (e.broken) {
      // The nightly link check found this page gone, so there is nothing to link to.
      title.textContent = e.shortTitle;
      title.classList.add('no-link');
      title.title = NO_LINK;
    } else if (/^https?:\/\//i.test(e.url)) {
      const a = document.createElement('a');
      a.href = e.url;
      a.target = '_blank';
      a.rel = 'noopener';
      a.textContent = e.shortTitle;
      title.append(a);
    } else {
      title.textContent = e.shortTitle;
    }
    // Hover shows the full title, then the description.
    if (!e.broken) title.title = e.desc ? `${e.title}\n\n${e.desc}` : e.title;

    // On phones the venue line reads "Nampa | Ford Idaho Center", or "Meetup | Boise | Shift Cafe"
    // when the link goes to meetup.com; those parts are hidden on desktop.
    const venue = cell('', 'c-venue');
    const lead = (text) => {
      const part = document.createElement('span');
      part.className = 'v-city';
      part.textContent = text;
      const sep = document.createElement('span');
      sep.className = 'v-sep';
      sep.textContent = ' | ';
      venue.append(part, sep);
    };
    if (isMeetup(e.url)) lead('Meetup');
    if (e.city && e.city !== 'Other') lead(e.city);
    venue.append(e.shortVenue || '');
    if (e.venue) venue.title = e.venue;
    venue.dataset.label = 'Venue';
    const city = cell(e.city, 'c-city');
    city.dataset.label = 'City';

    const cat = cell('', 'c-cat');
    const pill = document.createElement('span');
    pill.className = `pill cat-${e.cat}`;
    pill.textContent = e.catLabel;
    cat.append(pill);

    const size = cell('', 'c-size');
    if (e.size) {
      const badge = document.createElement('span');
      badge.className = 'size';
      badge.textContent = e.size;
      badge.title = cfg.sizes[e.size] || e.size;
      size.append(badge);
    }

    // Desktop shows cost in its own column; phones show it beside the size badge.
    const cost = cell('', 'c-cost');
    if (COST_LABELS[e.cost]) {
      cost.append(costBadge(e.cost));
      const beside = costBadge(e.cost);
      beside.classList.add('m-only');
      size.append(beside);
    }

    tr.append(date, time, title, venue, city, cat, size, cost);
    frag.append(tr);
  }
  if (!list.length) {
    const tr = document.createElement('tr');
    const td = cell('', 'empty-row');
    td.colSpan = 8;
    const p = document.createElement('span');
    p.textContent = 'Nothing matches. ';
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'link';
    b.textContent = 'Clear the filters';
    b.addEventListener('click', resetAll);
    td.append(p, b);
    tr.append(td);
    frag.append(tr);
  }
  el.rows.replaceChildren(frag);
}

function renderPager(nav, pages) {
  nav.replaceChildren();
  if (pages <= 1) return;
  const add = (label, page, disabled, aria) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'btn small';
    b.textContent = label;
    b.disabled = disabled;
    if (aria) b.setAttribute('aria-label', aria);
    b.addEventListener('click', () => {
      state.page = page;
      render();
      if (nav === el.pagerBottom) document.querySelector('.status').scrollIntoView({ block: 'start' });
    });
    nav.append(b);
  };
  add('First', 1, state.page === 1);
  add('Prev', state.page - 1, state.page === 1, 'Previous page');
  const info = document.createElement('span');
  info.className = 'page-info';
  info.textContent = `Page ${state.page} of ${pages}`;
  nav.append(info);
  add('Next', state.page + 1, state.page === pages, 'Next page');
  add('Last', pages, state.page === pages);
}

function renderSortHeaders() {
  for (const th of document.querySelectorAll('th[data-sort]')) {
    const active = th.dataset.sort === state.sort;
    if (active) th.setAttribute('aria-sort', state.dir === 1 ? 'ascending' : 'descending');
    else th.removeAttribute('aria-sort');
  }
}

// Always listed, even with no events yet. Any other city in the data, such as Other, follows them.
const CITIES = ['Boise', 'Caldwell', 'Eagle', 'Emmett', 'Garden City', 'Kuna', 'Marsing', 'Meridian', 'Middleton',
  'Mountain Home', 'Nampa', 'Payette', 'Star', 'Weiser'];

function fillSelects() {
  const byCity = Object.fromEntries(CITIES.map((c) => [c, 0]));
  for (const e of events) if (e.city) byCity[e.city] = (byCity[e.city] || 0) + 1;
  const extra = Object.keys(byCity).filter((c) => !CITIES.includes(c)).sort((a, b) => a.localeCompare(b));
  for (const name of [...CITIES, ...extra]) {
    const n = byCity[name];
    const o = document.createElement('option');
    o.value = name;
    o.textContent = `${name} (${numFmt.format(n)})`;
    el.city.append(o);
  }
  // Largest first, so the list reads down in size.
  for (const [id, label] of Object.entries(cfg.sizes).sort((a, b) => cfg.sizeOrder.indexOf(b[0]) - cfg.sizeOrder.indexOf(a[0]))) {
    const o = document.createElement('option');
    o.value = id;
    o.textContent = label;
    el.size.append(o);
  }
}

function syncControls() {
  el.q.value = state.q;
  el.when.value = state.when;
  el.city.value = state.city;
  el.size.value = state.size;
  el.cost.value = state.cost;
  el.per.value = String(state.per);
  const [f, t] = presetRange(state.when);
  el.from.value = f;
  el.to.value = t;
}

function readUrl() {
  const p = new URLSearchParams(location.search);
  state.q = p.get('q') || '';
  state.cats = new Set((p.get('cat') || '').split(',').filter((c) => c in cfg.categories));
  state.city = p.get('city') || '';
  state.size = p.get('size') || '';
  state.cost = ['free', '1', '2', '3'].includes(p.get('cost')) ? p.get('cost') : '';
  state.source = p.get('source') || '';
  state.meetup = p.get('meetup') === '1';
  state.when = p.get('when') || '';
  state.from = p.get('from') || '';
  state.to = p.get('to') || '';
  if (state.from || state.to) state.when = 'custom';
  const [sort, dir] = (p.get('sort') || 'date').split(':');
  state.sort = sort in sorters ? sort : 'date';
  state.dir = dir === 'desc' ? -1 : 1;
  state.page = Number.parseInt(p.get('page') || '1', 10) || 1;
  const per = Number.parseInt(p.get('per') || '', 10);
  state.per = PAGE_SIZES.includes(per) ? per : DEFAULT_PER;
}

function writeUrl() {
  const p = new URLSearchParams();
  if (state.q) p.set('q', state.q);
  if (state.cats.size) p.set('cat', [...state.cats].join(','));
  if (state.city) p.set('city', state.city);
  if (state.size) p.set('size', state.size);
  if (state.cost) p.set('cost', state.cost);
  if (state.source) p.set('source', state.source);
  if (state.meetup) p.set('meetup', '1');
  if (state.when === 'custom') {
    if (state.from) p.set('from', state.from);
    if (state.to) p.set('to', state.to);
  } else if (state.when) {
    p.set('when', state.when);
  }
  if (state.sort !== 'date' || state.dir !== 1) p.set('sort', `${state.sort}${state.dir === -1 ? ':desc' : ''}`);
  if (state.per !== DEFAULT_PER) p.set('per', String(state.per));
  if (state.page > 1) p.set('page', String(state.page));
  const qs = p.toString();
  history.replaceState(null, '', qs ? `?${qs}` : location.pathname);
}

function resetAll() {
  Object.assign(state, { q: '', cats: new Set(), city: '', size: '', cost: '', source: '', meetup: false, when: '', from: '', to: '', sort: 'date', dir: 1, page: 1 });
  syncControls();
  render();
}

function onFilter(fn) {
  return (ev) => { fn(ev); state.page = 1; render(); };
}

let searchTimer;
el.q.addEventListener('input', () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(onFilter(() => { state.q = el.q.value.trim(); }), 150);
});
el.when.addEventListener('change', onFilter(() => {
  state.when = el.when.value;
  if (state.when !== 'custom') { state.from = ''; state.to = ''; }
  const [f, t] = presetRange(state.when);
  el.from.value = f;
  el.to.value = t;
}));
for (const input of [el.from, el.to]) {
  input.addEventListener('change', onFilter(() => {
    state.when = 'custom';
    el.when.value = 'custom';
    state.from = el.from.value;
    state.to = el.to.value;
  }));
}
el.city.addEventListener('change', onFilter(() => { state.city = el.city.value; }));
el.size.addEventListener('change', onFilter(() => { state.size = el.size.value; }));
el.cost.addEventListener('change', onFilter(() => { state.cost = el.cost.value; }));
el.meetup.addEventListener('change', onFilter(() => { state.meetup = el.meetup.checked; }));
el.reset.addEventListener('click', resetAll);
function setMoreOpen(open) {
  el.controls.classList.toggle('open', open);
  el.more.setAttribute('aria-expanded', open ? 'true' : 'false');
  el.more.firstChild.textContent = open ? 'Fewer filters' : 'More filters';
}
el.more.addEventListener('click', () => setMoreOpen(!el.controls.classList.contains('open')));
// Choosing "Custom dates" opens the panel, so the From and To boxes are there to fill in.
el.when.addEventListener('change', () => { if (el.when.value === 'custom') setMoreOpen(true); });
for (const n of PAGE_SIZES) {
  const o = document.createElement('option');
  o.value = String(n);
  o.textContent = String(n);
  el.per.append(o);
}
el.per.value = String(state.per);
// Keep the first event on screen in view when the page size changes.
el.per.addEventListener('change', () => {
  const first = (state.page - 1) * state.per;
  state.per = Number(el.per.value);
  state.page = Math.floor(first / state.per) + 1;
  render();
});
el.cats.addEventListener('click', onFilter((ev) => {
  const chip = ev.target.closest('.chip');
  if (!chip) return;
  const id = chip.dataset.cat;
  if (state.cats.has(id)) state.cats.delete(id);
  else state.cats.add(id);
}));
for (const th of document.querySelectorAll('th[data-sort] button')) {
  th.addEventListener('click', () => {
    const key = th.parentElement.dataset.sort;
    if (state.sort === key) state.dir = -state.dir;
    else { state.sort = key; state.dir = 1; }
    state.page = 1;
    render();
  });
}
document.addEventListener('keydown', (ev) => {
  if (ev.key === '/' && document.activeElement?.tagName !== 'INPUT') {
    ev.preventDefault();
    el.q.focus();
  }
});

// The build writes the ingest time in UTC; show it in Boise time.
const asOf = document.getElementById('as-of');
if (asOf && cfg.lastIngest) {
  const when = new Date(cfg.lastIngest);
  if (!Number.isNaN(when.getTime())) {
    asOf.textContent = new Intl.DateTimeFormat('en-US', {
      timeZone: TZ, month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
    }).format(when);
  }
}

fetch(cfg.events)
  .then((r) => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
  .then((list) => {
    events = list.map(prepare);
    fillSelects();
    readUrl();
    syncControls();
    render();
  })
  .catch((err) => {
    el.count.textContent = `Could not load events (${err.message}).`;
  });
