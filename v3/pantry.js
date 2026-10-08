/* QAVERA v3 — pantry product pages.
   Each page defines PAGE_KEY and PRODUCTS before loading this file:
   PRODUCTS = [{ name, display, desc, size, price, paint, image? }]
   `name` and `size` must match Supabase products.name / product_variants.name,
   because checkout looks the product up by name. */
(function () {
  'use strict';

  const { qar, escapeHtml } = window.QaveraFormat;
  const pages = window.QaveraPages;

  const RANGES = [
    { key: 'assorted', title: 'Wrapped Chocolate', meta: '1 KG · QAR 380', paint: 'p1' },
    { key: 'slabs', title: 'Slabs', meta: '100 G · QAR 60', paint: 'p4' },
    { key: 'spreads', title: 'Spreads', meta: '280 G · QAR 50', paint: 'p8' }
  ];

  // Same id rule as the original pages, so carts stay compatible.
  const idFor = name => name.toLowerCase().replace(/\s+/g, '-');

  document.getElementById('products').innerHTML = PRODUCTS.map((p, i) => `
    <article class="product reveal${i % 3 ? ' d' + (i % 3) : ''}" data-index="${i}">
      <div class="product-visual">
        ${p.image
          ? `<img src="${escapeHtml(p.image)}" alt="${escapeHtml(p.display.replace(/<[^>]+>/g, ''))}" loading="lazy">`
          : `<div class="bonbon ${p.paint}"></div><span class="soon caption">Photo coming soon</span>`}
        ${p.image ? '' : `<span class="caption">Nº ${String(i + 1).padStart(2, '0')}</span>`}
      </div>
      <div class="product-body">
        <h3>${p.display}</h3>
        <p>${escapeHtml(p.desc)}</p>
        <div class="product-meta">
          <span class="caption">${escapeHtml(p.size)}</span>
          <span class="product-price">${qar(p.price)}</span>
        </div>
        <div class="product-actions">
          <div class="v3-qty" aria-label="Quantity">
            <button type="button" data-step="-1" aria-label="One less">−</button>
            <span data-qty>1</span>
            <button type="button" data-step="1" aria-label="One more">+</button>
          </div>
          <button type="button" class="btn btn-ink" data-add>Add to cart</button>
        </div>
      </div>
    </article>`).join('');

  document.getElementById('products').addEventListener('click', event => {
    const card = event.target.closest('.product');
    if (!card) return;
    const qtyEl = card.querySelector('[data-qty]');
    const step = event.target.closest('[data-step]');

    if (step) {
      qtyEl.textContent = Math.min(20, Math.max(1, Number(qtyEl.textContent) + Number(step.dataset.step)));
      return;
    }

    const addButton = event.target.closest('[data-add]');
    if (!addButton) return;

    const p = PRODUCTS[Number(card.dataset.index)];
    window.QaveraCart.add({
      id: idFor(p.name),
      name: p.name,
      product_name: p.name,
      variant_name: p.size,
      size: p.size,
      price: p.price,
      quantity: Number(qtyEl.textContent),
      image: p.image || '',
      paint: p.paint
    });

    qtyEl.textContent = '1';
    addButton.textContent = 'Added ✓';
    addButton.classList.add('added');
    setTimeout(() => {
      addButton.textContent = 'Add to cart';
      addButton.classList.remove('added');
    }, 1800);
  });

  // Sold out: products an admin marked out of stock keep their card, with no Add to cart.
  fetch('https://rhwajaceuhpfwughlgpd.supabase.co/rest/v1/products?select=name&active=eq.true&in_stock=eq.false', {
    headers: { apikey: 'sb_publishable_z19paX78926eQBcMOLw-dA_T8um0KS0' }
  })
    .then(response => (response.ok ? response.json() : []))
    .then(rows => {
      const soldOut = new Set((rows || []).map(row => String(row.name).trim().toLowerCase()));
      document.querySelectorAll('#products .product').forEach(card => {
        const p = PRODUCTS[Number(card.dataset.index)];
        if (!soldOut.has(p.name.trim().toLowerCase())) return;
        card.classList.add('sold-out');
        card.querySelector('.product-visual').insertAdjacentHTML('beforeend', '<span class="sold-out-tag">Sold out</span>');
        card.querySelector('.product-actions').innerHTML = '<button type="button" class="btn btn-ink" disabled>Sold out</button>';
      });
    })
    .catch(() => { /* offline or not set up yet: everything stays on sale */ });

  document.getElementById('moreGrid').innerHTML = RANGES
    .filter(r => r.key !== PAGE_KEY)
    .map((r, i) => `
      <a class="more-card reveal${i ? ' d' + i : ''}" href="${pages[r.key]}">
        <div><h3>${r.title}</h3><span class="caption">${r.meta}</span></div>
        <div class="bonbon ${r.paint}"></div>
      </a>`).join('');
})();
