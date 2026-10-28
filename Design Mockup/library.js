const ROOT = './Mockup Assets/';
const KEY = 'pokemon-pros-library-v1';
const listeners = new Set();
const blank = () => ({ scanned: {}, pulls: {}, auto: false });
let state = blank();
try {
  const saved = JSON.parse(localStorage.getItem(KEY));
  if (saved && typeof saved.auto === 'boolean' && saved.scanned && saved.pulls) state = saved;
} catch { /* Storage is optional for the showcase. */ }
function publish() {
  try { localStorage.setItem(KEY, JSON.stringify(state)); } catch { /* Keep working in memory. */ }
  listeners.forEach(fn => fn());
}
window.addEventListener('storage', event => {
  if (event.key !== KEY) return;
  try { const next = JSON.parse(event.newValue); if (next?.scanned && next?.pulls && typeof next.auto === 'boolean') { state = next; listeners.forEach(fn => fn()); } } catch { /* Ignore invalid storage. */ }
});

const controls = document.createElement('aside');
controls.className = 'mock-controls';
controls.innerHTML = `<strong>Library showcase</strong><label>Scan outcome <select id="scan-outcome"><option value="match">Card found</option><option value="multiple">Multiple matches</option><option value="missing">No match</option><option value="error">Recognition failed</option></select></label><button type="button" data-demo="seed">Load sample library</button><button type="button" data-demo="clear">Empty library</button><span>Simulated camera and recognition · no uploads</span>`;
document.querySelector('.device-grid').before(controls);
controls.querySelector('[data-demo="seed"]').onclick = () => { state.scanned = {0: 2, 3: 1}; state.pulls = {1: 1, 2: 3}; publish(); };
controls.querySelector('[data-demo="clear"]').onclick = () => { state.scanned = {}; state.pulls = {}; publish(); };

export function setupLibrary(shell, cards, openCard) {
  let tab = 'pokemon', collection = 'scanned', phase = 'camera', cardIndex = 0, saved = false, timer, scanTrigger;
  const launcher = shell.querySelector('.launcher-layer');
  const nav = document.createElement('nav');
  nav.className = 'main-tabs'; nav.setAttribute('aria-label', 'Main navigation');
  nav.innerHTML = ['Pokémon', 'Packs', 'Your Library'].map((name, i) => `<button type="button" data-tab="${['pokemon','packs','library'][i]}" aria-pressed="${i === 0}">${name}</button>`).join('');
  launcher.querySelector('.app-bar').after(nav);
  const page = document.createElement('section'); page.className = 'collection-page'; page.hidden = true;
  launcher.append(page);
  const scanner = document.createElement('section'); scanner.className = 'scanner'; scanner.hidden = true;
  scanner.setAttribute('role','dialog'); scanner.setAttribute('aria-modal','true'); scanner.setAttribute('aria-label','Scan a card');
  shell.append(scanner);
  const original = [...launcher.children].filter(el => el !== nav && el !== page && !el.classList.contains('app-bar'));
  function switchTab(next) {
    tab = next;
    launcher.setAttribute("aria-label", next === "pokemon" ? "Choose a Pokémon" : next === "packs" ? "Virtual packs" : "Your Library");
    original.forEach(el => { el.hidden = next !== 'pokemon'; });
    page.hidden = next === 'pokemon';
    launcher.classList.toggle('has-collection', next !== 'pokemon');
    nav.querySelectorAll('button').forEach(b => b.setAttribute('aria-pressed', b.dataset.tab === next));
    render();
  }
  nav.addEventListener('click', e => { const b = e.target.closest('[data-tab]'); if (b) switchTab(b.dataset.tab); });
  function add(source, index) { state[source][index] = (Number(state[source][index]) || 0) + 1; publish(); }
  function render() {
    if (tab === 'pokemon') return;
    if (tab === 'packs') {
      page.innerHTML = `<p class="eyebrow">Virtual packs</p><h2>A little pack magic.</h2><p class="collection-subtitle">Open a pack. Keep every pull in your library.</p><div class="pack-stage"><img src="${ROOT}pack-mega-evolution.png" alt="Mega Evolution booster pack"><div><h3>Mega Evolution</h3><p>Three cards. One new discovery.</p><button class="primary-action" type="button" data-open-pack>Open Pack</button><p class="pack-feedback" role="status"></p></div></div>`;
      page.querySelector('[data-open-pack]').onclick = () => { [0,1,2].forEach(i => add('pulls', i)); page.querySelector('.pack-feedback').textContent = '3 cards added to Pack Pulls'; page.querySelector('[data-open-pack]').focus(); };
      return;
    }
    const entries = cards.map((card,i) => ({card,i,count:Number(state[collection][i]) || 0})).filter(x => x.count > 0);
    page.innerHTML = `<div class="library-heading"><div><p class="eyebrow">Collected by you</p><h2>Your Library</h2></div><button type="button" class="primary-action scan-button">Scan Cards</button></div><div class="collection-selector" role="group" aria-label="Collection source"><button type="button" data-source="scanned" aria-pressed="${collection === 'scanned'}">Scanned Cards</button><button type="button" data-source="pulls" aria-pressed="${collection === 'pulls'}">Pack Pulls</button></div><p class="collection-subtitle">${collection === 'scanned' ? 'Your collection, one scan at a time.' : 'Every card pulled from virtual packs.'} <span>${entries.reduce((sum,x) => sum + x.count,0)} cards</span></p><div class="library-grid"></div>`;
    page.querySelector('.scan-button').onclick = e => startScan(e.currentTarget);
    page.querySelectorAll('[data-source]').forEach(b => b.onclick = () => { collection = b.dataset.source; render(); page.querySelector(`[data-source="${collection}"]`).focus(); });
    const grid = page.querySelector('.library-grid');
    entries.forEach(({card,i,count}) => {
      const button = document.createElement('button'); button.className = 'library-card'; button.type = 'button';
      button.innerHTML = `<img src="${ROOT}${card.image}" alt="${card.name}"><span class="quantity">×${count}</span>`;
      button.setAttribute('aria-label', `${card.name}, ${count} copies. View card`);
      button.onclick = () => openCard(button, cards[i]); grid.append(button);
    });
    if (!entries.length) {
      grid.innerHTML = `<div class="library-empty"><span aria-hidden="true">✦</span><h3>${collection === 'scanned' ? 'Give your collection a home.' : 'Your next favourite is in a pack.'}</h3><p>${collection === 'scanned' ? 'Scan your first card to start your library.' : 'Open a virtual pack to see your pulls here.'}</p><button type="button" class="primary-action">${collection === 'scanned' ? 'Scan Cards' : 'Explore Packs'}</button></div>`;
      grid.querySelector('button').onclick = e => collection === 'scanned' ? startScan(e.currentTarget) : (switchTab('packs'), nav.querySelector('[data-tab="packs"]').focus());
    }
  }
  listeners.add(render);
  function startScan(trigger) { scanTrigger = trigger; scanner.hidden = false; launcher.inert = true; shell.querySelector('.home-layer').inert = true; resetScan(); }
  function closeScan() { clearTimeout(timer); scanner.hidden = true; launcher.inert = false; shell.querySelector('.home-layer').inert = false; (scanTrigger?.isConnected ? scanTrigger : page.querySelector('.scan-button'))?.focus(); }
  function resetScan() { clearTimeout(timer); phase = 'camera'; saved = false; drawScanner(); }
  function saveScan() { if (saved) return; saved = true; add('scanned',cardIndex); phase = 'saved'; drawScanner(); }
  function drawScanner() {
    const result = ['result','saved'].includes(phase);
    scanner.dataset.phase = phase;
    scanner.innerHTML = `<div class="camera-scene" aria-hidden="true"><img src="${ROOT}${cards[cardIndex].image}" alt=""></div><button type="button" class="scanner-close" aria-label="Close scanner">×</button><div class="scanner-label">${result ? 'Your collection' : 'Scan a card'}</div><div class="scanner-body"></div>`;
    scanner.querySelector('.scanner-close').onclick = closeScan;
    const body = scanner.querySelector('.scanner-body');
    if (phase === 'camera') {
      body.innerHTML = `<div class="scan-guide" aria-hidden="true"></div><p class="camera-hint">Place your card inside the frame</p><button type="button" class="shutter" aria-label="Capture card photo"><span></span></button>`;
      body.querySelector('.shutter').onclick = () => { phase = 'loading'; drawScanner(); timer = setTimeout(() => { const outcome = controls.querySelector('select').value; phase = outcome === 'match' ? 'result' : outcome; if (phase === 'result' && state.auto) saveScan(); else drawScanner(); }, 1600); };
    } else if (phase === 'loading') {
      body.innerHTML = `<div class="scan-loading" role="status"><span class="scan-spinner"></span><h3>Finding your card…</h3><p>Reading the card and matching its artwork</p></div>`;
    } else if (result) {
      body.innerHTML = `<div class="scan-result"><img src="${ROOT}${cards[cardIndex].image}" alt="${cards[cardIndex].name}"><div class="scan-result-copy"><p class="eyebrow" role="status">${saved ? 'Added to Library' : 'Card found'}</p><h3>${cards[cardIndex].name.split(' — ')[0]}</h3><p>${cards[cardIndex].name.split(' — ')[1]}</p>${saved ? '<div class="scan-actions"><button class="primary-action" data-next>Scan Another</button><button class="secondary-action" data-done>Done</button></div>' : '<button class="primary-action" data-add>Add to Library</button>'}<label class="auto-add"><input type="checkbox" ${state.auto ? 'checked' : ''}> Automatically add future scans</label></div></div>`;
      body.querySelector('[data-add]')?.addEventListener('click',saveScan);
      body.querySelector('[data-next]')?.addEventListener('click',() => { cardIndex = (cardIndex + 1) % cards.length; resetScan(); });
      body.querySelector('[data-done]')?.addEventListener('click',closeScan);
      body.querySelector('input').onchange = e => { state.auto = e.target.checked; publish(); if (state.auto && !saved) saveScan(); };
    } else if (phase === 'multiple') {
      body.innerHTML = `<div class="scan-message"><h3>Choose the matching artwork</h3><p>We found two possible cards.</p><div class="scan-candidates">${[0,2].map(i => `<button type="button" data-candidate="${i}"><img src="${ROOT}${cards[i].image}" alt="${cards[i].name}"></button>`).join('')}</div><button class="secondary-action" data-retry>Try Again</button></div>`;
      body.querySelectorAll('[data-candidate]').forEach(b => b.onclick = () => { cardIndex = Number(b.dataset.candidate); phase = 'result'; if (state.auto) saveScan(); else drawScanner(); });
    } else {
      body.innerHTML = `<div class="scan-message" role="status"><h3>${phase === 'missing' ? 'No matching card found' : 'Couldn’t finish this scan'}</h3><p>${phase === 'missing' ? 'Keep the card flat and make sure its text is clear.' : 'Please try capturing your card again.'}</p><button class="primary-action" data-retry>Try Again</button></div>`;
    }
    body.querySelector('[data-retry]')?.addEventListener('click',resetScan);
    (body.querySelector('button') || scanner.querySelector('.scanner-close')).focus({preventScroll:true});
  }
  scanner.addEventListener('keydown', e => {
    if (e.key === 'Escape') { e.stopPropagation(); closeScan(); }
    if (e.key !== 'Tab') return;
    const focusable = [...scanner.querySelectorAll('button,input')]; const first = focusable[0], last = focusable.at(-1);
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  });
}
