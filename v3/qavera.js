/* =========================================================
   QAVERA v3 — shared site script
   Include as the FIRST element inside <body>:
     <script src="v3/qavera.js"></script>
   Optional <body> attributes:
     data-page="shop"          highlights the matching menu link
     class="v3-overlay-header" transparent header over a dark hero
   Provides window.QaveraCart for product pages.
========================================================= */
(function () {
  'use strict';

  // One place for every v3 page address (change here at launch).
  const PAGES = {
    home: 'home.html',
    shop: 'shop.html',
    premium: 'premium.html',
    luxury: 'luxury.html',
    assorted: 'assorted.html',
    slabs: 'slabs.html',
    spreads: 'spreads.html',
    homeCollection: 'home-collection.html',
    story: 'ourstory.html',
    contact: 'contactus.html',
    account: 'account.html',
    login: 'login.html',
    checkout: 'checkout.html'
  };

  const WHATSAPP = 'https://wa.me/97450968968';
  const INSTAGRAM = 'https://www.instagram.com/qaverachocolate';
  const EMAIL = 'info@qavera.qa';
  const MAPS = 'https://maps.app.goo.gl/232khX7N1295W4LY9';
  const CART_KEY = 'qaveraCart';

  const body = document.body;
  const page = body.dataset.page || '';
  document.documentElement.classList.add('v3-js');

  const current = key => (key === page ? ' aria-current="page"' : '');
  const PANTRY = ['assorted', 'slabs', 'spreads'];
  const icon = {
    user: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="4"/><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6"/></svg>',
    bag: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 8h14l-1.2 12H6.2z"/><path d="M9 8V6a3 3 0 0 1 6 0v2"/></svg>',
    close: '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none"><path d="M5 5l14 14M19 5L5 19"/></svg>'
  };

  // ---------------------------------------------------------
  // Loading screen: once per visit (not on every page).
  // ---------------------------------------------------------
  let seenLoader = false;
  try { seenLoader = sessionStorage.getItem('qaveraV3Intro') === '1'; } catch (_) {}

  if (!seenLoader && !body.hasAttribute('data-no-loader')) {
    body.insertAdjacentHTML('afterbegin', `
      <div class="v3-loader" id="v3Loader" aria-hidden="true">
        <div class="v3-loader-inner">
          <img src="v3/loader-logo.webp" alt="">
          <div class="v3-loader-line"></div>
          <span class="caption">Hand-painted chocolate</span>
        </div>
      </div>`);
    body.classList.add('v3-lock');
    const started = Date.now();
    const hide = () => {
      const loader = document.getElementById('v3Loader');
      if (!loader || loader.classList.contains('done')) return;
      loader.classList.add('done');
      body.classList.remove('v3-lock');
      try { sessionStorage.setItem('qaveraV3Intro', '1'); } catch (_) {}
      setTimeout(() => loader.remove(), 1000);
    };
    window.addEventListener('load', () => setTimeout(hide, Math.max(0, 3000 - (Date.now() - started))));
    setTimeout(hide, 5000); // never keep people waiting
  }

  // ---------------------------------------------------------
  // Header + mobile menu
  // ---------------------------------------------------------
  body.insertAdjacentHTML('afterbegin', `
    <header class="v3-header" id="v3Header">
      <button class="v3-menu-toggle" id="v3MenuToggle" type="button" aria-label="Open menu" aria-expanded="false" aria-controls="v3MobileMenu">
        <span></span><span></span>
      </button>
      <nav class="v3-nav" aria-label="Main">
        <a href="${PAGES.shop}"${current('shop')}>Shop</a>
        <a href="${PAGES.premium}"${current('premium')}>Premium</a>
        <a href="${PAGES.luxury}"${current('luxury')}>Luxury</a>
        <div class="v3-drop${PANTRY.includes(page) ? ' is-current' : ''}">
          <button type="button" class="v3-drop-toggle" aria-expanded="false" aria-controls="v3PantryMenu">Pantry<span aria-hidden="true">▾</span></button>
          <div class="v3-drop-panel" id="v3PantryMenu">
            <a href="${PAGES.assorted}"${current('assorted')}><span>Wrapped Chocolate</span><small>500 G · QAR 190</small></a>
            <a href="${PAGES.slabs}"${current('slabs')}><span>Slabs</span><small>100 G · QAR 60</small></a>
            <a href="${PAGES.spreads}"${current('spreads')}><span>Spreads</span><small>260 G · QAR 50</small></a>
            <a class="v3-drop-all" href="${PAGES.shop}#pantry">View the pantry →</a>
          </div>
        </div>
        <a href="${PAGES.homeCollection}"${current('homeCollection')}>The Home</a>
        <a href="${PAGES.story}"${current('story')}>Story</a>
      </nav>
      <a class="v3-brand" href="${PAGES.home}" aria-label="QAVERA home">
        <img src="Qavera without artisan.png" alt="QAVERA">
      </a>
      <div class="v3-header-right">
        <a class="hide-sm" href="${PAGES.contact}"${current('contact')}>Contact</a>
        <a class="v3-icon" href="${PAGES.account}" aria-label="Your account">${icon.user}</a>
        <button class="v3-cart-button" id="v3CartButton" type="button" aria-label="Open your cart" aria-controls="v3Cart">
          ${icon.bag}<span class="v3-count" data-cart-count>0</span>
        </button>
      </div>
    </header>
    <div class="v3-mobile-menu" id="v3MobileMenu" aria-hidden="true">
      <nav aria-label="Mobile">
        <a href="${PAGES.home}"${current('home')}>Home</a>
        <a href="${PAGES.shop}"${current('shop')}>Shop all</a>
        <a href="${PAGES.premium}"${current('premium')}>Premium Box</a>
        <a href="${PAGES.luxury}"${current('luxury')}>Luxury Box</a>
        <div class="v3-mobile-group${PANTRY.includes(page) ? ' is-current' : ''}">
          <button type="button" class="v3-mobile-group-toggle" aria-expanded="false" aria-controls="v3MobilePantry">Pantry<span aria-hidden="true">+</span></button>
          <div class="v3-mobile-group-panel" id="v3MobilePantry">
            <div>
              <a href="${PAGES.assorted}"${current('assorted')}>Wrapped Chocolate</a>
              <a href="${PAGES.slabs}"${current('slabs')}>Slabs</a>
              <a href="${PAGES.spreads}"${current('spreads')}>Spreads</a>
            </div>
          </div>
        </div>
        <a href="${PAGES.homeCollection}"${current('homeCollection')}>The Home</a>
        <a href="${PAGES.story}"${current('story')}>Our story</a>
        <a href="${PAGES.contact}"${current('contact')}>Contact</a>
        <a href="${PAGES.account}"${current('account')}>Account</a>
      </nav>
      <div class="v3-mobile-menu-foot caption">
        <span>Hand-painted chocolate · Crafted in Qatar</span>
        <a href="${INSTAGRAM}" target="_blank" rel="noopener">Instagram</a>
      </div>
    </div>`);

  const header = document.getElementById('v3Header');
  const onScroll = () => header.classList.toggle('scrolled', window.scrollY > 40);
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  document.querySelectorAll('.v3-drop').forEach(drop => {
    const toggle = drop.querySelector('.v3-drop-toggle');
    const setOpen = open => { drop.classList.toggle('open', open); toggle.setAttribute('aria-expanded', String(open)); };
    toggle.addEventListener('click', () => setOpen(!drop.classList.contains('open')));
    drop.addEventListener('mouseenter', () => setOpen(true));
    drop.addEventListener('mouseleave', () => setOpen(false));
    drop.addEventListener('focusout', event => { if (!drop.contains(event.relatedTarget)) setOpen(false); });
    document.addEventListener('keydown', event => { if (event.key === 'Escape') setOpen(false); });
    document.addEventListener('click', event => { if (!drop.contains(event.target)) setOpen(false); });
  });

  const menuToggle = document.getElementById('v3MenuToggle');
  const mobileMenu = document.getElementById('v3MobileMenu');

  // Pantry sub-menu in the phone menu: closed until tapped.
  const mobileGroup = mobileMenu.querySelector('.v3-mobile-group');
  const mobileGroupToggle = mobileGroup.querySelector('.v3-mobile-group-toggle');
  const setGroup = open => {
    mobileGroup.classList.toggle('open', open);
    mobileGroupToggle.setAttribute('aria-expanded', String(open));
  };
  mobileGroupToggle.addEventListener('click', () => setGroup(!mobileGroup.classList.contains('open')));

  const setMenu = open => {
    body.classList.toggle('v3-menu-open', open);
    body.classList.toggle('v3-lock', open);
    menuToggle.setAttribute('aria-expanded', String(open));
    menuToggle.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
    mobileMenu.setAttribute('aria-hidden', String(!open));
    if (!open) setGroup(false);
  };
  menuToggle.addEventListener('click', () => setMenu(!body.classList.contains('v3-menu-open')));
  mobileMenu.querySelectorAll('a').forEach(a => a.addEventListener('click', () => setMenu(false)));

  // ---------------------------------------------------------
  // Cart (same storage key and item format as the rest of the site)
  // ---------------------------------------------------------
  const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, ch => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);

  const qar = value => {
    const amount = Number(value || 0);
    return `QAR ${Number.isInteger(amount) ? amount : amount.toFixed(2)}`;
  };

  function readCart() {
    try {
      const parsed = JSON.parse(localStorage.getItem(CART_KEY) || '[]');
      return Array.isArray(parsed) ? parsed.filter(item => item && Number(item.quantity) > 0) : [];
    } catch (_) {
      return [];
    }
  }

  function writeCart(cart) {
    try { localStorage.setItem(CART_KEY, JSON.stringify(cart)); } catch (_) {}
    // Any older checkout handoff copy is now out of date.
    try { sessionStorage.removeItem('qaveraCheckoutCart'); } catch (_) {}
    renderCart();
    window.dispatchEvent(new CustomEvent('qavera:cart'));
  }

  // A stable painted-bonbon style for items without a photo.
  const paintFor = text => {
    let hash = 0;
    for (const ch of String(text)) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
    return `p${hash % 12 + 1}`;
  };

  body.insertAdjacentHTML('beforeend', `
    <div class="v3-cart-backdrop" id="v3CartBackdrop"></div>
    <aside class="v3-cart" id="v3Cart" role="dialog" aria-modal="true" aria-labelledby="v3CartTitle" aria-hidden="true">
      <div class="v3-cart-head">
        <h2 id="v3CartTitle">Your <em>cart</em></h2>
        <button class="v3-cart-close" id="v3CartClose" type="button" aria-label="Close cart">${icon.close}</button>
      </div>
      <div class="v3-cart-items" id="v3CartItems"></div>
      <div class="v3-cart-foot" id="v3CartFoot">
        <div class="v3-cart-row"><span class="caption">Subtotal</span><span class="v3-cart-total" id="v3CartSubtotal">QAR 0</span></div>
        <p class="v3-cart-note">At checkout: delivery (QAR 20) or free pickup, your date and time, and points.</p>
        <a class="btn btn-solid btn-block" id="v3CheckoutButton" href="${PAGES.checkout}">Checkout <span class="arrow">→</span></a>
      </div>
    </aside>
    <div class="v3-toast" id="v3Toast" role="status" aria-live="polite"></div>`);

  const cartEl = document.getElementById('v3Cart');
  const cartItemsEl = document.getElementById('v3CartItems');
  const cartFootEl = document.getElementById('v3CartFoot');
  let lastFocus = null;

  function renderCart() {
    const cart = readCart();
    const count = cart.reduce((sum, item) => sum + Number(item.quantity || 0), 0);
    const subtotal = cart.reduce((sum, item) => sum + Number(item.price || 0) * Number(item.quantity || 0), 0);

    document.querySelectorAll('[data-cart-count]').forEach(el => {
      if (el.textContent !== String(count)) {
        el.textContent = count;
        el.classList.remove('bump');
        void el.offsetWidth;
        el.classList.add('bump');
        setTimeout(() => el.classList.remove('bump'), 400);
      }
    });

    if (!cart.length) {
      cartItemsEl.innerHTML = `
        <div class="v3-cart-empty">
          <div class="bonbon p9" style="margin:0 auto"></div>
          <p class="display">Your cart is <em>empty</em>.</p>
          <p>Start with a Premium or Luxury box, or something from the pantry.</p>
          <a class="btn btn-line" href="${PAGES.shop}">Explore the collection</a>
        </div>`;
      cartFootEl.hidden = true;
      return;
    }

    cartFootEl.hidden = false;
    document.getElementById('v3CartSubtotal').textContent = qar(subtotal);

    cartItemsEl.innerHTML = cart.map((item, index) => {
      const flavours = Array.isArray(item.flavors)
        ? item.flavors.filter(f => Number(f.quantity) > 0).map(f => `${escapeHtml(f.name)} ×${Number(f.quantity)}`).join(', ')
        : '';
      const detail = item.display_detail || item.variant_name || item.size || '';
      const thumb = item.image
        ? `<div class="v3-cart-thumb"><img src="${escapeHtml(item.image)}" alt=""></div>`
        : `<div class="v3-cart-thumb painted"><div class="bonbon ${/^p\d{1,2}$/.test(item.paint || '') ? item.paint : paintFor(item.product_name || item.name)}"></div></div>`;
      return `
        <div class="v3-cart-item">
          ${thumb}
          <div>
            <h3>${escapeHtml(item.display_name || item.product_name || item.name)}</h3>
            ${detail ? `<span class="caption">${escapeHtml(detail)}${item.customized ? ' · Customized' : ''}</span>` : ''}
            ${flavours ? `<p class="v3-cart-flavours">${flavours}</p>` : ''}
            <div class="v3-qty" style="margin-top:.8rem">
              <button type="button" data-cart-dec="${index}" aria-label="One less">−</button>
              <span>${Number(item.quantity)}</span>
              <button type="button" data-cart-inc="${index}" aria-label="One more">+</button>
            </div>
          </div>
          <div class="v3-cart-item-side">
            <span class="v3-cart-price">${qar(Number(item.price) * Number(item.quantity))}</span>
            <button type="button" class="v3-cart-remove" data-cart-remove="${index}">Remove</button>
          </div>
        </div>`;
    }).join('');
  }

  cartItemsEl.addEventListener('click', event => {
    const cart = readCart();
    const inc = event.target.closest('[data-cart-inc]');
    const dec = event.target.closest('[data-cart-dec]');
    const rem = event.target.closest('[data-cart-remove]');
    if (inc) { cart[inc.dataset.cartInc].quantity = Number(cart[inc.dataset.cartInc].quantity) + 1; writeCart(cart); }
    if (dec) {
      const item = cart[dec.dataset.cartDec];
      item.quantity = Number(item.quantity) - 1;
      writeCart(item.quantity > 0 ? cart : cart.filter(i => i !== item));
    }
    if (rem) { cart.splice(Number(rem.dataset.cartRemove), 1); writeCart(cart); }
  });

  function openCart() {
    lastFocus = document.activeElement;
    renderCart();
    body.classList.add('v3-cart-open', 'v3-lock');
    cartEl.setAttribute('aria-hidden', 'false');
    setTimeout(() => document.getElementById('v3CartClose').focus(), 50);
  }

  function closeCart() {
    body.classList.remove('v3-cart-open');
    if (!body.classList.contains('v3-menu-open')) body.classList.remove('v3-lock');
    cartEl.setAttribute('aria-hidden', 'true');
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  document.getElementById('v3CartButton').addEventListener('click', openCart);
  document.getElementById('v3CartClose').addEventListener('click', closeCart);
  document.getElementById('v3CartBackdrop').addEventListener('click', closeCart);
  document.addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    if (body.classList.contains('v3-cart-open')) closeCart();
    else if (body.classList.contains('v3-menu-open')) setMenu(false);
  });

  // Hand the current cart to checkout (checkout reads this first).
  document.getElementById('v3CheckoutButton').addEventListener('click', () => {
    try { sessionStorage.setItem('qaveraCheckoutCart', JSON.stringify(readCart())); } catch (_) {}
  });

  // Keep tabs in sync.
  window.addEventListener('storage', event => { if (event.key === CART_KEY) renderCart(); });

  let toastTimer = null;
  function toast(message) {
    const el = document.getElementById('v3Toast');
    el.textContent = message;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 2600);
  }

  window.QaveraCart = {
    items: readCart,
    /** Add an item ({ id, name, price, quantity, ... }); same id adds to its quantity. */
    add(item, { open = true } = {}) {
      const cart = readCart();
      const quantity = Math.max(1, Number(item.quantity || 1));
      const existing = cart.find(i => i.id === item.id);
      if (existing) existing.quantity = Number(existing.quantity || 0) + quantity;
      else cart.push({ ...item, quantity });
      writeCart(cart);
      if (open) openCart();
      else toast(`${item.display_name || item.product_name || item.name} added to your cart`);
    },
    open: openCart,
    close: closeCart,
    clear() { writeCart([]); },
    render: renderCart,
    toast
  };
  window.QaveraPages = PAGES;
  window.QaveraFormat = { qar, escapeHtml };

  // ---------------------------------------------------------
  // Footer, reveal animations
  // ---------------------------------------------------------
  document.addEventListener('DOMContentLoaded', () => {
    // The cart was created before the page content existed; move it to the end.
    ['v3CartBackdrop', 'v3Cart', 'v3Toast'].forEach(id => body.appendChild(document.getElementById(id)));

    if (!body.hasAttribute('data-no-footer')) {
      const cartBackdrop = document.getElementById('v3CartBackdrop');
      cartBackdrop.insertAdjacentHTML('beforebegin', `
        <footer class="v3-footer">
          <div class="v3-footer-top">
            <div class="v3-footer-brand">
              <img src="Qavera without artisan.png" alt="QAVERA">
              <p>Hand-painted chocolate, crafted in Qatar.</p>
            </div>
            <div class="v3-footer-col">
              <h4>Shop</h4>
              <a href="${PAGES.premium}">Premium Box</a>
              <a href="${PAGES.luxury}">Luxury Box</a>
              <a href="${PAGES.assorted}">Wrapped Chocolate</a>
              <a href="${PAGES.slabs}">Slabs</a>
              <a href="${PAGES.spreads}">Spreads</a>
              <a href="${PAGES.homeCollection}">The Home</a>
            </div>
            <div class="v3-footer-col">
              <h4>House</h4>
              <a href="${PAGES.story}">Our story</a>
              <a href="${PAGES.account}">Your account</a>
              <a href="${PAGES.contact}">Contact us</a>
            </div>
            <div class="v3-footer-col">
              <h4>Connect</h4>
              <a href="${INSTAGRAM}" target="_blank" rel="noopener">Instagram</a>
              <a href="${WHATSAPP}" target="_blank" rel="noopener">WhatsApp</a>
              <a href="mailto:${EMAIL}">${EMAIL}</a>
              <a href="${MAPS}" target="_blank" rel="noopener">Location</a>
            </div>
          </div>
          <div class="v3-footer-bottom caption">
            <span>© ${new Date().getFullYear()} QAVERA Chocolate</span>
            <span>Qatar</span>
          </div>
        </footer>`);
    }

    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          entry.target.classList.add('in');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
    document.querySelectorAll('.reveal').forEach(el => observer.observe(el));

    renderCart();
  });
})();
