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
    { key: 'assorted', title: 'Wrapped Chocolate', meta: '500 G · QAR 190', paint: 'p1' },
    { key: 'slabs', title: 'Slabs', meta: '100 G · QAR 50', paint: 'p4' },
    { key: 'spreads', title: 'Spreads', meta: '260 G · QAR 50', paint: 'p8' },
    { key: 'bites', title: 'Bites', meta: '100 G · QAR 25', paint: 'p6' }
  ];

  // Same id rule as the original pages, so carts stay compatible.
  const idFor = name => name.toLowerCase().replace(/\s+/g, '-');

  document.getElementById('products').innerHTML = PRODUCTS.map((p, i) => `
    <article class="product reveal${i % 3 ? ' d' + (i % 3) : ''}" data-index="${i}">
      <div class="product-visual">
        ${p.image
          ? `<img src="${escapeHtml(p.image)}" alt="${escapeHtml(p.display.replace(/<[^>]+>/g, ''))}" loading="lazy">`
          : `<div class="bonbon ${p.paint}"></div><span class="soon caption">Photo coming soon</span>`}
        <span class="caption">Nº ${String(i + 1).padStart(2, '0')}</span>
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

  document.getElementById('moreGrid').innerHTML = RANGES
    .filter(r => r.key !== PAGE_KEY)
    .map((r, i) => `
      <a class="more-card reveal${i ? ' d' + i : ''}" href="${pages[r.key]}">
        <div><h3>${r.title}</h3><span class="caption">${r.meta}</span></div>
        <div class="bonbon ${r.paint}"></div>
      </a>`).join('');
})();
