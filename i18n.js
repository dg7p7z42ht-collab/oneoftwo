(() => {
  'use strict';

  const storageKey = 'oneoftwo.language';
  const languageNames = { en: 'English', pl: 'Polski', de: 'Deutsch' };
  // A future domain can supply a default. A manual selection still takes priority.
  const domainDefaults = {
    'oneoftwo.pl': 'pl',
    'www.oneoftwo.pl': 'pl',
    'oneoftwo.de': 'de',
    'www.oneoftwo.de': 'de'
  };
  const catalogs = {
    en: {
      'language.label': 'Interface language',
      'category.fashion': 'Fashion & Shoes',
      'category.jewellery': 'Jewellery & Watches',
      'category.home': 'Home & Living',
      'category.automotive': 'Automotive',
      'category.sports': 'Sports & Outdoors',
      'category.electronics': 'Electronics',
      'category.tools': 'Tools & Hardware',
      'category.toys': 'Toys & Games',
      'category.collectibles': 'Collectibles & Sets',
      'category.lost': 'Lost & Found',
      'category.parts': 'Missing Parts',
      'listing.type.available': 'I HAVE',
      'listing.type.wanted': "I'M LOOKING FOR"
    },
    pl: {
      'language.label': 'Język interfejsu',
      'category.fashion': 'Moda i obuwie',
      'category.jewellery': 'Biżuteria i zegarki',
      'category.home': 'Dom i wnętrze',
      'category.automotive': 'Motoryzacja',
      'category.sports': 'Sport i rekreacja',
      'category.electronics': 'Elektronika',
      'category.tools': 'Narzędzia i osprzęt',
      'category.toys': 'Zabawki i gry',
      'category.collectibles': 'Kolekcje i zestawy',
      'category.lost': 'Zgubione i znalezione',
      'category.parts': 'Brakujące części',
      'listing.type.available': 'MAM',
      'listing.type.wanted': 'SZUKAM'
    },
    de: {
      'language.label': 'Sprache der Benutzeroberfläche',
      'category.fashion': 'Mode & Schuhe',
      'category.jewellery': 'Schmuck & Uhren',
      'category.home': 'Haus & Wohnen',
      'category.automotive': 'Auto & Zubehör',
      'category.sports': 'Sport & Outdoor',
      'category.electronics': 'Elektronik',
      'category.tools': 'Werkzeug & Zubehör',
      'category.toys': 'Spielzeug & Spiele',
      'category.collectibles': 'Sammlerstücke & Sets',
      'category.lost': 'Verloren & Gefunden',
      'category.parts': 'Fehlende Teile',
      'listing.type.available': 'ICH HABE',
      'listing.type.wanted': 'ICH SUCHE'
    }
  };
  const bindings = {
    'data-i18n': null,
    'data-i18n-placeholder': 'placeholder',
    'data-i18n-aria-label': 'aria-label',
    'data-i18n-title': 'title',
    'data-i18n-content': 'content',
    'data-i18n-alt': 'alt'
  };
  const selector = Object.keys(bindings).map(attribute => `[${attribute}]`).join(',');
  const initialUrl = new URL(window.location.href);
  const pageDirectory = new URL('.', initialUrl).pathname;
  const localizedPaths = new Set([pageDirectory, `${pageDirectory}index.html`, `${pageDirectory}add-listing.html`]);
  const knownLanguage = value => Object.hasOwn(languageNames, value) ? value : null;

  let savedLanguage = null;
  let useUrlFallback = false;
  try {
    savedLanguage = knownLanguage(window.localStorage.getItem(storageKey));
  } catch {
    useUrlFallback = true;
  }
  const urlLanguage = knownLanguage(initialUrl.searchParams.get('lang'));
  const domainLanguage = Object.hasOwn(domainDefaults, initialUrl.hostname) ? domainDefaults[initialUrl.hostname] : 'en';
  let language = urlLanguage ?? savedLanguage ?? domainLanguage;
  useUrlFallback ||= urlLanguage !== null && savedLanguage !== urlLanguage;
  document.documentElement.lang = language;

  function t(key, params = {}) {
    const value = catalogs[language][key] ?? catalogs.en[key] ?? key;
    return value.replace(/\{(\w+)\}/g, (match, name) => Object.hasOwn(params, name) ? String(params[name]) : match);
  }

  function register(catalog) {
    for (const code of Object.keys(languageNames)) {
      Object.assign(catalogs[code], catalog[code]);
    }
  }

  function translate(root = document) {
    const nodes = [...root.querySelectorAll(selector)];
    if (root.matches?.(selector)) nodes.unshift(root);
    for (const node of nodes) {
      for (const [binding, target] of Object.entries(bindings)) {
        const key = node.getAttribute(binding);
        if (!key) continue;
        if (target) node.setAttribute(target, t(key));
        else node.textContent = t(key);
      }
    }
  }

  function href(path) {
    if (!useUrlFallback || !path || path.startsWith('#')) return path;
    const url = new URL(path, document.baseURI);
    if (url.origin !== initialUrl.origin || !localizedPaths.has(url.pathname)) return path;
    url.searchParams.set('lang', language);
    return url.href;
  }

  const originalLinks = new Map();
  function updateLinks() {
    for (const [anchor, path] of originalLinks) {
      const destination = href(path);
      if (anchor.getAttribute('href') !== destination) anchor.setAttribute('href', destination);
    }
  }

  function chooseLanguage(code) {
    language = code;
    try {
      window.localStorage.setItem(storageKey, code);
      useUrlFallback = window.localStorage.getItem(storageKey) !== code;
    } catch {
      useUrlFallback = true;
    }
    const url = new URL(window.location.href);
    if (useUrlFallback) url.searchParams.set('lang', code);
    else if (knownLanguage(url.searchParams.get('lang'))) url.searchParams.delete('lang');
    if (url.href !== window.location.href) {
      try {
        window.history.replaceState(window.history.state, '', url);
      } catch {
        // The link fallback still carries the selection if history is unavailable.
      }
    }
    applyLanguage();
  }

  function applyLanguage() {
    document.documentElement.lang = language;
    translate();
    updateLinks();
    for (const button of document.querySelectorAll('[data-language-switcher] button')) {
      button.setAttribute('aria-pressed', String(button.dataset.language === language));
    }
    document.dispatchEvent(new CustomEvent('oneoftwo:languagechange', { detail: { language } }));
  }

  window.OneOfTwoI18n = { t, register, translate, href, get language() { return language; } };

  document.addEventListener('DOMContentLoaded', () => {
    for (const switcher of document.querySelectorAll('[data-language-switcher]')) {
      switcher.setAttribute('role', 'group');
      switcher.setAttribute('data-i18n-aria-label', 'language.label');
      for (const [code, name] of Object.entries(languageNames)) {
        const button = document.createElement('button');
        button.type = 'button';
        button.dataset.language = code;
        button.lang = code;
        button.title = name;
        button.setAttribute('aria-label', name);
        button.setAttribute('aria-pressed', String(code === language));
        button.textContent = code.toUpperCase();
        button.addEventListener('click', () => chooseLanguage(code));
        switcher.append(button);
      }
    }
    for (const anchor of document.querySelectorAll('a[href]')) {
      const path = anchor.getAttribute('href');
      const url = new URL(path, document.baseURI);
      if (path && !path.startsWith('#') && url.origin === initialUrl.origin && localizedPaths.has(url.pathname)) {
        originalLinks.set(anchor, path);
      }
    }
    translate();
    updateLinks();
  });

  window.addEventListener('pageshow', event => {
    if (!event.persisted || useUrlFallback) return;
    let stored;
    try {
      stored = knownLanguage(window.localStorage.getItem(storageKey));
    } catch {
      return;
    }
    if (stored && stored !== language) {
      language = stored;
      applyLanguage();
    }
  });
})();
