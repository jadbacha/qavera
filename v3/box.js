/* QAVERA v3 — signature box page (Chocolate Bonbons; earlier Premium, Luxury).
   BOX.alwaysCustom: the customer always chooses how many of each flavour
   (no toggle), with a Random mix button.
   BOX.noChoice: no flavour choice at all (an even mix we pack, e.g. Just
   Chocolate); the flavours are only listed. BOX.plain: plain chocolate
   pieces in the flavour list (not painted).
   BOX.designs: box designs on one page (Classic, Christmas, National Day…),
   each its own product with its own sizes and photos; a design with "until"
   (YYYY-MM-DD, Qatar time) disappears after that day, and a design shows only
   once its product exists in the database.
   The page defines BOX before loading this file (see bonbons.html).
   Sizes/prices come from Supabase (products + product_variants); the numbers
   in BOX are only a fallback while loading. Cart items match what checkout
   and create_qavera_order expect: variant_id + optional flavors. */
(function () {
  'use strict';

  const { qar, escapeHtml } = window.QaveraFormat;
  const SIZE_ORDER = ['mini', 'small', 'medium', 'large'];

  const sb = window.supabase.createClient(
    'https://rhwajaceuhpfwughlgpd.supabase.co',
    'sb_publishable_z19paX78926eQBcMOLw-dA_T8um0KS0'
  );

  const state = {
    size: 'small',
    image: 0,
    customize: !!BOX.alwaysCustom,
    counts: [],
    productId: null,
    productName: BOX.dbName,
    variants: {}, // size -> { id, name, price }
    design: null
  };

  // ---------- box designs ----------
  const qatarToday = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Qatar' });
  const DESIGNS = (BOX.designs || []).filter(d => !d.until || qatarToday <= d.until);
  const designData = {}; // key -> { productId, productName, variants, soldOut, inDb }
  DESIGNS.forEach(d => { designData[d.key] = { productId: null, productName: d.dbName, variants: {}, soldOut: false, inDb: !d.needsDb }; });
  const currentDesign = () => DESIGNS.find(d => d.key === state.design) || null;

  // ---------- painted bonbon (illustration only: real shell colours vary) ----------
  function shade(hex, amount) {
    const n = parseInt(hex.slice(1), 16);
    const mix = c => Math.round(c * (1 - amount));
    const r = mix(n >> 16), g = mix((n >> 8) & 255), b = mix(n & 255);
    return `rgb(${r}, ${g}, ${b})`;
  }

  function bonbonStyle(colour) {
    if (BOX.plain) return `--a:${shade(colour, .45)};--b:${colour};--paint:none;`;
    const light = parseInt(colour.slice(1), 16) > 0xdddddd;
    const a = light ? '#bdb6a8' : shade(colour, .55);
    return `--a:${a};--b:${colour};--paint:linear-gradient(35deg, transparent 46%, rgba(196,169,128,.55) 46% 50%, transparent 50%);`;
  }

  // ---------- rendering ----------
  const el = id => document.getElementById(id);

  function priceFor(size) {
    return state.variants[size]?.price ?? BOX.sizes[size].price;
  }

  // Sizes on this page. A size marked needsDb (the Mini) only shows once it
  // exists in the database, so it can't be ordered before it is set up.
  function visibleSizes() {
    return SIZE_ORDER.filter(size => BOX.sizes[size] && (!BOX.sizes[size].needsDb || state.variants[size]));
  }

  function visibleDesigns() {
    return DESIGNS.filter(d => designData[d.key].inDb);
  }

  function applyDesign(key) {
    const d = DESIGNS.find(x => x.key === key);
    if (!d) return;
    state.design = key;
    BOX.sizes = d.sizes;
    BOX.dbName = d.dbName;
    BOX.displayName = d.displayName;
    const data = designData[key];
    state.variants = data.variants;
    state.productId = data.productId;
    state.productName = data.productName;
    if (!BOX.sizes[state.size]) state.size = SIZE_ORDER.find(sz => BOX.sizes[sz]);
    state.image = 0;
    setSoldOut(data.soldOut);
  }

  function renderDesigns() {
    const box = el('designs');
    if (!box) return;
    const list = visibleDesigns();
    box.closest('.design-step').hidden = list.length < 2;
    box.innerHTML = list.map(d => `
      <button type="button" class="design" role="radio" aria-checked="${d.key === state.design}" data-design="${d.key}">
        <span class="swatch" style="background:${d.swatch}"></span>
        <strong>${escapeHtml(d.label)}</strong>
        <span class="caption">${escapeHtml(d.note || '')}</span>
      </button>`).join('');
  }

  function renderSizes() {
    const sizes = visibleSizes();
    el('sizes').classList.toggle('has-4', sizes.length === 4);
    el('sizes').innerHTML = sizes.map(size => {
      const s = BOX.sizes[size];
      return `
        <button type="button" class="size" role="radio" aria-checked="${size === state.size}" data-size="${size}">
          <span class="swatch" style="background:${s.swatch}"></span>
          <span class="pieces">${s.pieces}<small>pieces</small></span>
          <span class="colour caption">${s.label ? `${escapeHtml(s.label)} · ` : ''}${escapeHtml(s.colour)} box</span>
          <span class="price">${qar(priceFor(size))}</span>
        </button>`;
    }).join('');
  }

  function renderGallery() {
    const images = BOX.sizes[state.size].images;
    el('galleryStage').innerHTML = images.map((src, i) =>
      `<img src="${escapeHtml(src)}" alt="${escapeHtml(BOX.displayName)}, ${BOX.sizes[state.size].pieces} pieces" class="${i === state.image ? 'active' : ''}">`
    ).join('');
    el('galleryThumbs').innerHTML = images.map((src, i) =>
      `<button type="button" aria-label="Photo ${i + 1}" aria-pressed="${i === state.image}" data-image="${i}"><img src="${escapeHtml(src)}" alt=""></button>`
    ).join('');
  }

  function target() { return BOX.sizes[state.size].pieces; }
  function totalCount() { return state.counts.reduce((a, b) => a + b, 0); }

  function renderCustomiser() {
    if (BOX.noChoice) return;
    const total = totalCount();
    const goal = target();
    el('customCount').textContent = `${total} / ${goal}`;
    el('customCount').classList.toggle('full', total === goal);
    el('customBar').style.width = `${Math.min(100, (total / goal) * 100)}%`;
    el('flavourRows').innerHTML = BOX.flavours.map((f, i) => `
      <div class="flavour-row">
        <div class="bonbon" style="${bonbonStyle(f.colour)}"></div>
        <div><strong>${escapeHtml(f.name)}</strong><span class="flavour-desc">${escapeHtml(f.desc)}</span></div>
        <div class="v3-qty">
          <button type="button" data-flavour="${i}" data-change="-1" aria-label="One less ${escapeHtml(f.name)}" ${state.counts[i] <= 0 ? 'disabled' : ''}>−</button>
          <span>${state.counts[i]}</span>
          <button type="button" data-flavour="${i}" data-change="1" aria-label="One more ${escapeHtml(f.name)}" ${total >= goal ? 'disabled' : ''}>+</button>
        </div>
      </div>`).join('');
  }

  function renderTotal() {
    el('buyTotal').textContent = qar(priceFor(state.size));
  }

  function renderAll() {
    renderDesigns();
    renderSizes();
    renderGallery();
    renderCustomiser();
    renderTotal();
  }

  function resetCounts() {
    state.counts = (BOX.alwaysCustom || BOX.noChoice)
      ? BOX.flavours.map(() => 0)
      : [...BOX.sizes[state.size].defaults];
  }

  // Random mix: every flavour at least once (when the box holds enough
  // pieces), the rest spread at random. In the 25 and 48 boxes no flavour
  // gets more than 8 pieces.
  function randomCounts() {
    const n = BOX.flavours.length;
    const pieces = target();
    const cap = pieces > 12 ? 8 : pieces;
    const counts = Array(n).fill(0);
    if (pieces >= n) {
      counts.fill(1);
      for (let left = pieces - n; left > 0; left--) {
        const open = counts.map((c, i) => (c < cap ? i : -1)).filter(i => i >= 0);
        counts[open[Math.floor(Math.random() * open.length)]]++;
      }
    } else {
      const order = [...Array(n).keys()].sort(() => Math.random() - 0.5);
      order.slice(0, pieces).forEach(i => { counts[i] = 1; });
    }
    return counts;
  }

  // ---------- events ----------
  el('sizes').addEventListener('click', event => {
    const button = event.target.closest('[data-size]');
    if (!button) return;
    state.size = button.dataset.size;
    state.image = 0;
    resetCounts();
    el('customMsg').textContent = '';
    renderAll();
  });

  if (el('designs')) el('designs').addEventListener('click', event => {
    const button = event.target.closest('[data-design]');
    if (!button || button.dataset.design === state.design) return;
    applyDesign(button.dataset.design);
    resetCounts();
    el('customMsg').textContent = '';
    renderAll();
  });

  el('galleryThumbs').addEventListener('click', event => {
    const button = event.target.closest('[data-image]');
    if (!button) return;
    state.image = Number(button.dataset.image);
    renderGallery();
  });

  if (el('customToggle')) el('customToggle').addEventListener('change', event => {
    state.customize = event.target.checked;
    el('customiser').classList.toggle('open', state.customize);
    el('customiser').setAttribute('aria-hidden', String(!state.customize));
    el('customMsg').textContent = '';
  });

  if (el('flavourRows')) el('flavourRows').addEventListener('click', event => {
    const button = event.target.closest('[data-flavour]');
    if (!button || button.disabled) return;
    const i = Number(button.dataset.flavour);
    const change = Number(button.dataset.change);
    if (change > 0 && totalCount() >= target()) return;
    if (change < 0 && state.counts[i] <= 0) return;
    state.counts[i] += change;
    el('customMsg').textContent = '';
    renderCustomiser();
  });

  if (el('customEven')) el('customEven').addEventListener('click', () => { resetCounts(); el('customMsg').textContent = ''; renderCustomiser(); });
  if (el('customRandom')) el('customRandom').addEventListener('click', () => { state.counts = randomCounts(); el('customMsg').textContent = ''; renderCustomiser(); });
  if (el('customClear')) el('customClear').addEventListener('click', () => { state.counts = state.counts.map(() => 0); el('customMsg').textContent = ''; renderCustomiser(); });

  el('addToBox').addEventListener('click', () => {
    const size = state.size;
    const s = BOX.sizes[size];
    const custom = state.customize && !BOX.noChoice;

    if (custom && totalCount() !== s.pieces) {
      const left = s.pieces - totalCount();
      el('customMsg').textContent = left > 0
        ? `Choose ${left} more piece${left === 1 ? '' : 's'} to fill your ${s.pieces}-piece box.`
        : `Your box holds ${s.pieces} pieces. Remove ${-left} to continue.`;
      return;
    }

    const variant = state.variants[size];
    const key = custom ? state.counts.join('-') : 'standard';

    window.QaveraCart.add({
      id: `${BOX.key}-box-${state.design && state.design !== DESIGNS[0]?.key ? `${state.design}-` : ''}${size}-${key}`,
      size,
      product_id: state.productId,
      variant_id: variant?.id || null,
      product_name: state.productName,
      variant_name: variant?.name || s.dbVariant,
      display_name: BOX.displayName,
      display_detail: `${s.label ? `${s.label} · ` : ''}${s.pieces} pieces · ${s.colour} box`,
      name: `${BOX.displayName} — ${s.cartLabel}${custom ? ' — Customized' : ''}`,
      price: priceFor(size),
      image: s.images[0],
      quantity: 1,
      customized: custom,
      flavors: custom ? BOX.flavours.map((f, i) => ({ name: f.name, quantity: state.counts[i] })) : null
    });
  });

  // ---------- collection grid ----------
  el('collection').innerHTML = BOX.flavours.map((f, i) => `
    <article class="flavour-card reveal${i % 3 ? ' d' + (i % 3) : ''}">
      <div class="bonbon" style="${bonbonStyle(f.colour)}"></div>
      <div>
        <span class="caption">Nº ${String(i + 1).padStart(2, '0')}</span>
        <h3>${escapeHtml(f.name)}</h3>
        ${f.desc ? `<p>${escapeHtml(f.desc)}</p>` : ''}
      </div>
    </article>`).join('');

  // ---------- sold out (set by an admin) ----------
  const addLabel = el('addToBox').innerHTML;
  function setSoldOut(on) {
    const button = el('addToBox');
    button.disabled = on;
    button.classList.toggle('is-sold-out', on);
    button.innerHTML = on ? 'Sold out' : addLabel;
    document.querySelectorAll('.sold-out-note').forEach(n => n.remove());
    if (on) button.closest('.buy-row').insertAdjacentHTML('afterend',
      `<p class="sold-out-note">The ${escapeHtml(BOX.displayName)} is sold out for now. Please check back soon.</p>`);
  }
  const markSoldOut = () => setSoldOut(true);

  // ---------- live sizes and prices from Supabase ----------
  async function loadDesign(d) {
    const data = designData[d.key];
    const { data: product, error } = await sb
      .from('products').select('*').ilike('name', d.dbName).eq('active', true).maybeSingle();
    if (error || !product) return;
    data.inDb = true;
    data.productId = product.id;
    data.productName = product.name;
    data.soldOut = product.in_stock === false;
    const { data: variants, error: vError } = await sb
      .from('product_variants').select('id, name, price, active').eq('product_id', product.id).eq('active', true);
    if (vError || !variants) return;
    SIZE_ORDER.filter(size => d.sizes[size]).forEach(size => {
      const words = d.sizes[size].variantNames;
      const match = variants.find(v => {
        const n = String(v.name || '').trim().toLowerCase();
        return words.includes(n) || words.some(w => n.startsWith(w + ' '));
      });
      if (match) data.variants[size] = { id: match.id, name: match.name, price: Number(match.price) };
    });
  }

  async function loadFromSupabase() {
    if (DESIGNS.length) {
      try {
        await Promise.all(DESIGNS.map(d => loadDesign(d).catch(err => console.warn('QAVERA: could not load', d.dbName, err))));
      } finally {
        applyDesign(state.design);
        renderAll();
      }
      return;
    }
    try {
      const { data: product, error } = await sb
        .from('products').select('*').ilike('name', BOX.dbName).eq('active', true).maybeSingle();
      if (error || !product) return;
      state.productId = product.id;
      state.productName = product.name;
      if (product.in_stock === false) markSoldOut();

      const { data: variants, error: vError } = await sb
        .from('product_variants').select('id, name, price, active').eq('product_id', product.id).eq('active', true);
      if (vError || !variants) return;

      SIZE_ORDER.filter(size => BOX.sizes[size]).forEach(size => {
        const words = BOX.sizes[size].variantNames;
        const match = variants.find(v => {
          const n = String(v.name || '').trim().toLowerCase();
          return words.includes(n) || words.some(w => n.startsWith(w + ' '));
        });
        if (match) state.variants[size] = { id: match.id, name: match.name, price: Number(match.price) };
      });
      renderSizes();
      renderTotal();
    } catch (err) {
      console.warn('QAVERA: could not load box sizes from Supabase; using page prices.', err);
    }
  }

  if (DESIGNS.length) applyDesign(DESIGNS[0].key);
  resetCounts();
  renderAll();
  loadFromSupabase();
})();
