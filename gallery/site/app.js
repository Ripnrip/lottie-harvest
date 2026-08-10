const PER = 48;
let DATA = [], cat = 'all', page = 0, q = '';
const $ = (id) => document.getElementById(id);
const grid = $('grid'), pager = $('pager'), tabs = $('tabs'), count = $('count'), qEl = $('q');

async function init() {
  try {
    DATA = await (await fetch('data.json', { cache: 'no-store' })).json();
  } catch (e) { count.textContent = 'Failed to load data.json'; return; }
  buildTabs(); render();
}

function esc(s) { return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }

function collections() {
  const m = {};
  DATA.forEach(c => { const k = c.collection || 'misc'; m[k] = (m[k] || 0) + 1; });
  return Object.entries(m).sort((a, b) => b[1] - a[1]);
}

function buildTabs() {
  const entries = [['all', DATA.length], ...collections()];
  tabs.innerHTML = entries.map(([k, n]) =>
    `<button data-cat="${esc(k)}" class="${k === cat ? 'active' : ''}">${esc(k)}<span class="n">${n}</span></button>`
  ).join('');
  tabs.querySelectorAll('button').forEach(b => b.onclick = () => {
    cat = b.dataset.cat; page = 0; updateActive(); render();
  });
}
function updateActive() { tabs.querySelectorAll('button').forEach(b => b.classList.toggle('active', b.dataset.cat === cat)); }

function matchQ(c) { if (!q) return true; return (c.name + ' ' + (c.author || '')).toLowerCase().includes(q); }
function filt() { return DATA.filter(c => (cat === 'all' || (c.collection || 'misc') === cat) && matchQ(c)); }

function cardHTML(c) {
  const links = [
    c.page ? `<a href="${esc(c.page)}" target="_blank" rel="noopener">Page</a>` : '',
    c.lottie ? `<a href="${esc(c.lottie)}" target="_blank" rel="noopener">.lottie</a>` : '',
    c.json ? `<a href="${esc(c.json)}" target="_blank" rel="noopener">.json</a>` : '',
  ].join('');
  const dl = (c.downloads >= 0) ? `<div class="stats">⬇ ${c.downloads}</div>` : '';
  return `<div class="card">
    <div class="player"><lottie-player data-src="${esc(c.src)}" background="transparent" autoplay loop speed="1"></lottie-player></div>
    <div class="meta"><div class="name">${esc(c.name)}</div><div class="author">by ${esc(c.author || 'unknown')}</div>${dl}</div>
    <div class="links">${links}</div></div>`;
}

function buildPager(pages) {
  if (pages <= 1) { pager.innerHTML = ''; return; }
  const win = 2; let btns = [];
  btns.push(`<button data-p="prev" ${page === 0 ? 'disabled' : ''}>‹</button>`);
  for (let p = 0; p < pages; p++) {
    if (p === 0 || p === pages - 1 || (p >= page - win && p <= page + win)) {
      btns.push(`<button data-p="${p}" class="${p === page ? 'active' : ''}">${p + 1}</button>`);
    } else if (btns[btns.length - 1].indexOf('…') === -1) {
      btns.push(`<button disabled>…</button>`);
    }
  }
  btns.push(`<button data-p="next" ${page === pages - 1 ? 'disabled' : ''}>›</button>`);
  pager.innerHTML = btns.join('');
  pager.querySelectorAll('button[data-p]').forEach(b => b.onclick = () => {
    if (b.disabled) return;
    const v = b.dataset.p;
    page = v === 'prev' ? page - 1 : v === 'next' ? page + 1 : +v;
    render(); window.scrollTo({ top: 0, behavior: 'smooth' });
  });
}

let io;
function observe() {
  if (!io) io = new IntersectionObserver((es) => {
    es.forEach(e => { if (!e.isIntersecting) return; const el = e.target;
      if (!el.hasAttribute('src')) el.setAttribute('src', el.dataset.src); io.unobserve(el); });
  }, { rootMargin: '300px' });
  document.querySelectorAll('[data-src]').forEach(el => io.observe(el));
}

function render() {
  const f = filt();
  const pages = Math.max(1, Math.ceil(f.length / PER));
  if (page >= pages) page = pages - 1; if (page < 0) page = 0;
  grid.innerHTML = f.slice(page * PER, (page + 1) * PER).map(cardHTML).join('');
  const where = cat === 'all' ? '' : ` in ${esc(cat)}`;
  const what = q ? ` matching “${esc(q)}”` : '';
  count.textContent = `${f.length} animations${where}${what}`;
  buildPager(pages); observe();
}

qEl.oninput = () => { q = qEl.value.trim().toLowerCase(); page = 0; render(); };
init();