/* QAVERA v3 — signature box pages (Premium, Luxury).
   The page defines BOX before loading this file (see premium-v3.html).
   Sizes/prices come from Supabase (products + product_variants); the numbers
   in BOX are only a fallback while loading. Cart items match what checkout
   and create_qavera_order expect: variant_id + optional flavors. */
(function () {
  'use strict';

  const { qar, escapeHtml } = window.QaveraFormat;
  const SIZE_ORDER = ['small', 'medium', 'large'];

  const sb = window.supabase.createClient(
    'https://rhwajaceuhpfwughlgpd.supabase.co',
    'sb_publishable_z19paX78926eQBcMOLw-dA_T8um0KS0'
  );

  const state = {
    size: 'small',
    image: 0,
    customize: false,
    counts: [],
    productId: null,
    productName: BOX.dbName,
    variants: {} // size -> { id, name, price }
  };

  // ---------- painted bonbon in a flavour's shell colour ----------
  function shade(hex, amount) {
    const n = parseInt(hex.slice(1), 16);
    const mix = c => Math.round(c * (1 - amount));
    const r = mix(n >> 16), g = mix((n >> 8) & 255), b = mix(n & 255);
    return `rgb(${r}, ${g}, ${b})`;
  }

  function bonbonStyle(colour) {
    const light = parseInt(colour.slice(1), 16) > 0xdddddd;
    const a = light ? '#bdb6a8' : shade(colour, .55);
    return `--a:${a};--b:${colour};--paint:linear-gradient(35deg, transparent 46%, rgba(196,169,128,.55) 46% 50%, transparent 50%);`;
  }

  // ---------- rendering ----------
  const el = id => document.getElementById(id);

  function priceFor(size) {
    return state.variants[size]?.price ?? BOX.sizes[size].price;
  }

  function renderSizes() {
    el('sizes').innerHTML = SIZE_ORDER.map(size => {
      const s = BOX.sizes[size];
      return `
        <button type="button" class="size" role="radio" aria-checked="${size === state.size}" data-size="${size}">
          <span class="swatch" style="background:${s.swatch}"></span>
          <span class="pieces">${s.pieces}<small>pieces</small></span>
          <span class="colour caption">${escapeHtml(s.colour)} box</span>
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
    const total = totalCount();
    const goal = target();
    el('customCount').textContent = `${total} / ${goal}`;
    el('customCount').classList.toggle('full', total === goal);
    el('customBar').style.width = `${Math.min(100, (total / goal) * 100)}%`;
    el('flavourRows').innerHTML = BOX.flavours.map((f, i) => `
      <div class="flavour-row">
        <div class="bonbon" style="${bonbonStyle(f.colour)}"></div>
        <div><strong>${escapeHtml(f.name)}</strong><span class="caption">${escapeHtml(f.shell)} shell</span></div>
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
    renderSizes();
    renderGallery();
    renderCustomiser();
    renderTotal();
  }

  function resetCounts() {
    state.counts = [...BOX.sizes[state.size].defaults];
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

  el('galleryThumbs').addEventListener('click', event => {
    const button = event.target.closest('[data-image]');
    if (!button) return;
    state.image = Number(button.dataset.image);
    renderGallery();
  });

  el('customToggle').addEventListener('change', event => {
    state.customize = event.target.checked;
    el('customiser').classList.toggle('open', state.customize);
    el('customiser').setAttribute('aria-hidden', String(!state.customize));
    el('customMsg').textContent = '';
  });

  el('flavourRows').addEventListener('click', event => {
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

  el('customEven').addEventListener('click', () => { resetCounts(); el('customMsg').textContent = ''; renderCustomiser(); });
  el('customClear').addEventListener('click', () => { state.counts = state.counts.map(() => 0); el('customMsg').textContent = ''; renderCustomiser(); });

  el('addToBox').addEventListener('click', () => {
    const size = state.size;
    const s = BOX.sizes[size];
    const custom = state.customize;

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
      id: `${BOX.key}-box-${size}-${key}`,
      size,
      product_id: state.productId,
      variant_id: variant?.id || null,
      product_name: state.productName,
      variant_name: variant?.name || s.dbVariant,
      display_name: BOX.displayName,
      display_detail: `${s.pieces} pieces · ${s.colour} box`,
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
        <span class="caption">Nº ${String(i + 1).padStart(2, '0')} · ${escapeHtml(f.shell)} shell</span>
        <h3>${escapeHtml(f.name)}</h3>
        <p>${escapeHtml(f.desc)}</p>
      </div>
    </article>`).join('');

  // ---------- live sizes and prices from Supabase ----------
  async function loadFromSupabase() {
    try {
      const { data: product, error } = await sb
        .from('products').select('id, name').ilike('name', BOX.dbName).eq('active', true).maybeSingle();
      if (error || !product) return;
      state.productId = product.id;
      state.productName = product.name;

      const { data: variants, error: vError } = await sb
        .from('product_variants').select('id, name, price, active').eq('product_id', product.id).eq('active', true);
      if (vError || !variants) return;

      SIZE_ORDER.forEach(size => {
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

  resetCounts();
  renderAll();
  loadFromSupabase();
})();
