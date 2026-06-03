const DEFAULT_LANGUAGES = [
  { code: 'en', label: 'EN', flag: '\uD83C\uDDFA\uD83C\uDDF8', file: '/i18n/en.json', icon: 'images/lang/en.svg' },
  { code: 'ro', label: 'RO', flag: '\uD83C\uDDF7\uD83C\uDDF4', file: '/i18n/ro.json', icon: 'images/lang/ro.svg' }
];
const I18N = {};
let BRANDING = {};
const I18N_FALLBACK = {
  themeStyle: 'Theme',
  styleModern: 'Modern',
  styleClassic: 'Classic',
  styleGlass: 'Glass',
  theme: 'Mode',
  auto: 'Auto',
  light: 'Light',
  dark: 'Dark',
  poll: 'Poll',
  pollInterval: 'Poll interval',
  hoursSingular: 'hour',
  hoursPlural: 'hours',
  pollSaved: 'Poll interval saved',
  pollInvalid: 'Invalid interval (allowed: 1h, 3h, 6h, 12h)',
  fontSize: 'Font size',
  fontLegacy: 'Compact',
  fontCurrent: 'Standard',
  fontLarge: 'Large',
  fontSaved: 'Font size saved',
  language: 'Language',
  subtitleBase: 'Day / Month / Year aggregation, updated every',
  totalToday: 'Total Today',
  totalMonth: 'Current Month Total',
  totalYear: 'Current Year Total',
  day: 'Day',
  month: 'Month',
  year: 'Year',
  period: 'Period',
  total: 'Total',
  download: 'Download',
  upload: 'Upload',
  visual: 'Visual',
  visualHint: '(relative to max Total in current tab)',
  loading: 'Loading...',
  tab: 'Tab',
  samples: 'Samples',
  lastUpdate: 'Last update',
  dbSize: 'DB size',
  loadError: 'Load error',
  date: 'Date',
  status: 'Status',
  progress: 'Progress'
};

const TAB_LABEL_KEY = { day: 'day', month: 'month', year: 'year' };
const state = {
  activeTab: 'day',
  lang: 'en',
  themeStyle: 'modern',
  theme: 'auto',
  fontSize: '100',
  pollInterval: '',
  rows: { day: [], month: [], year: [] },
  details: { monthDays: [], yearMonths: [] },
  expanded: { month: null, year: null },
  info: {},
  languages: DEFAULT_LANGUAGES.slice(),
  themeOptions: [],
  themeStyleOptions: []
};
const prefersDarkQuery = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
const SHARED_HEADER_OWNS_CONTROLS = Boolean(window.MikroTikSharedHeader && window.MikroTikSharedHeader.ownsControls);
const MONTH_NAMES = {
  en: ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
  ro: ['Ian', 'Feb', 'Mar', 'Apr', 'Mai', 'Iun', 'Iul', 'Aug', 'Sep', 'Oct', 'Noi', 'Dec']
};
const DEFAULT_THEME_OPTIONS = [
  { value: 'auto', label: { en: 'Auto', ro: 'Auto' }, icon: 'images/ui/theme-auto.svg' },
  { value: 'light', label: { en: 'Light', ro: 'Luminos' }, icon: 'images/ui/theme-light.svg' },
  { value: 'dark', label: { en: 'Dark', ro: 'Intunecat' }, icon: 'images/ui/theme-dark.svg' }
];
const DEFAULT_THEME_STYLE_OPTIONS = [
  { value: 'modern', label: { en: 'Modern', ro: 'Modern' }, css: 'styles-modern.css' },
  { value: 'classic', label: { en: 'Classic', ro: 'Clasic' }, css: 'styles-classic.css' },
  { value: 'glass', label: { en: 'Glass', ro: 'Glass' }, css: 'styles-glass.css' }
];
const POLL_ITEMS = [
  { value: '1h', amount: 1 },
  { value: '3h', amount: 3 },
  { value: '6h', amount: 6 },
  { value: '12h', amount: 12 }
];
const FONT_ITEMS = [
  { value: '25', labelKey: 'fontLegacy' },
  { value: '50', labelKey: 'fontCurrent' },
  { value: '100', labelKey: 'fontLarge' }
];
const THEME_CSS_VERSION = '20260516f';

function toNum(v) { const n = parseFloat(v || '0'); return Number.isFinite(n) ? n : 0; }
function fmtTraffic(v) {
  const gib = toNum(v);
  if (Math.abs(gib) >= 1024) {
    return `${(gib / 1024).toFixed(2)} TiB`;
  }
  return `${gib.toFixed(2)} GiB`;
}
function fmtBytes(v) {
  const n = Math.max(0, Number(v || 0));
  if (!Number.isFinite(n)) return '0 B';
  if (n < 1024) return `${Math.round(n)} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}
function t(key) {
  return BRANDING[key] || (I18N[state.lang] && I18N[state.lang][key]) || (I18N.en && I18N.en[key]) || I18N_FALLBACK[key] || key;
}

function uiMetricIcon(name) {
  return `<img class="ico-inline" src="images/ui/${name}.svg" alt="" />`;
}

function esc(v) {
  return String(v == null ? '' : v)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function textIfExists(id, value) {
  const el = document.getElementById(id);
  if (el) el.textContent = value;
}

function htmlIfExists(id, value) {
  const el = document.getElementById(id);
  if (el) el.innerHTML = value;
}

function valueIfExists(id, value) {
  const el = document.getElementById(id);
  if (el) el.value = value;
}

function getLanguageDef(code) {
  return (state.languages || []).find(l => l.code === code) || null;
}

function normalizeLanguageList(items) {
  if (!Array.isArray(items)) return DEFAULT_LANGUAGES.slice();
  const out = [];
  items.forEach((x) => {
    if (!x || typeof x !== 'object') return;
    const code = String(x.code || '').trim().toLowerCase();
    const label = String(x.label || code.toUpperCase()).trim();
    const flag = String(x.flag || '').trim();
    const file = String(x.file || '').trim();
    const icon = String(x.icon || `images/lang/${code}.svg`)
      .trim()
      .replace(/^\/+/, '')
      .replace(/^images\/lang\//, 'images/lang/');
    if (!/^[a-z][a-z0-9_-]{1,15}$/.test(code)) return;
    if (!file || file[0] !== '/') return;
    out.push({ code, label: label || code.toUpperCase(), flag, file, icon });
  });
  if (!out.find(l => l.code === 'en')) {
    out.unshift(DEFAULT_LANGUAGES[0]);
  }
  return out.length ? out : DEFAULT_LANGUAGES.slice();
}

function normalizeThemeOptions(items) {
  if (!Array.isArray(items)) return DEFAULT_THEME_OPTIONS.slice();
  const out = [];
  const seen = new Set();
  items.forEach((x) => {
    if (!x || typeof x !== 'object') return;
    const value = String(x.value || '').trim().toLowerCase();
    if (!/^[a-z][a-z0-9_-]{1,15}$/.test(value) || seen.has(value)) return;
    const label = x.label && typeof x.label === 'object'
      ? x.label
      : { en: String(x.label || value), ro: String(x.label || value) };
    const icon = String(x.icon || `images/ui/theme-${value}.svg`)
      .trim()
      .replace(/^\/+/, '')
      .replace(/^images\/ui\//, 'images/ui/');
    out.push({ value, label, icon });
    seen.add(value);
  });
  return out.length ? out : DEFAULT_THEME_OPTIONS.slice();
}

function normalizeThemeStyleOptions(items) {
  if (!Array.isArray(items)) return DEFAULT_THEME_STYLE_OPTIONS.slice();
  const out = [];
  const seen = new Set();
  items.forEach((x) => {
    if (!x || typeof x !== 'object') return;
    const value = String(x.value || '').trim().toLowerCase();
    if (!/^[a-z][a-z0-9_-]{1,15}$/.test(value) || seen.has(value)) return;
    const label = x.label && typeof x.label === 'object'
      ? x.label
      : { en: String(x.label || value), ro: String(x.label || value) };
    const css = String(x.css || `styles-${value}.css`)
      .trim()
      .replace(/^\/+/, '')
      .replace(/^images\/ui\//, '')
      .replace(/^style-/g, 'styles-');
    out.push({ value, label, css });
    seen.add(value);
  });
  return out.length ? out : DEFAULT_THEME_STYLE_OPTIONS.slice();
}

function getLocalizedLabel(entry) {
  if (!entry) return '';
  if (entry.label && typeof entry.label === 'object') {
    return entry.label[state.lang] || entry.label.en || entry.label.ro || entry.label[Object.keys(entry.label)[0]] || '';
  }
  if (entry.labelKey) return t(entry.labelKey);
  return String(entry.label || entry.value || '');
}

function currentThemeOption() {
  return (state.themeOptions || []).find((x) => x.value === state.theme) || (state.themeOptions || [])[0] || DEFAULT_THEME_OPTIONS[0];
}

function currentThemeStyleOption() {
  return (state.themeStyleOptions || []).find((x) => x.value === state.themeStyle) || (state.themeStyleOptions || [])[0] || DEFAULT_THEME_STYLE_OPTIONS[0];
}

function renderLanguageOptions() {
  const sel = document.getElementById('lang');
  const menu = document.getElementById('lang-menu');
  sel.innerHTML = '';
  menu.innerHTML = '';
  (state.languages || []).forEach((l) => {
    const opt = document.createElement('option');
    opt.value = l.code;
    opt.textContent = l.label;
    sel.appendChild(opt);

    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'lang-item';
    item.setAttribute('role', 'option');
    item.setAttribute('data-lang', l.code);
    item.innerHTML = `<img src="${l.icon}" alt="" /><span>${l.label}</span>`;
    item.addEventListener('click', () => {
      closeLanguageMenu();
      setLanguage(l.code);
    });
    menu.appendChild(item);
  });
  updateLanguageButton();
  if (sel) sel.value = state.lang;
}
function themeIconByMode(mode) {
  if (mode === 'light') return 'images/ui/theme-light.svg';
  if (mode === 'dark') return 'images/ui/theme-dark.svg';
  return 'images/ui/theme-auto.svg';
}

function updateLanguageButton() {
  const langDef = getLanguageDef(state.lang) || getLanguageDef('en');
  const icon = document.getElementById('lang-current-icon');
  const label = document.getElementById('lang-current-label');
  if (icon) icon.setAttribute('src', (langDef && langDef.icon) ? langDef.icon : 'images/lang/en.svg');
  if (label) label.textContent = (langDef && langDef.label) ? langDef.label : 'EN';
  const sel = document.getElementById('lang');
  if (sel) sel.value = state.lang;
}

function renderThemeStyleMenu() {
  const menu = document.getElementById('theme-style-menu');
  const sel = document.getElementById('theme-style');
  if (!menu) return;
  menu.innerHTML = '';
  if (sel) sel.innerHTML = '';
  (state.themeStyleOptions || []).forEach((x) => {
    const label = getLocalizedLabel(x);
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'theme-item';
    item.setAttribute('role', 'option');
    item.setAttribute('data-theme-style', x.value);
    item.innerHTML = `<img src="images/ui/theme-style.svg" alt="" /><span>${esc(label)}</span>`;
    item.addEventListener('click', () => {
      closeThemeStyleMenu();
      setThemeStyle(x.value);
    });
    menu.appendChild(item);

    if (sel) {
      const opt = document.createElement('option');
      opt.value = x.value;
      opt.textContent = label;
      sel.appendChild(opt);
    }
  });
  updateThemeStyleButton();
  if (sel) sel.value = state.themeStyle;
}

function updateThemeStyleButton() {
  const label = document.getElementById('theme-style-current-label');
  if (!label) return;
  label.textContent = getLocalizedLabel(currentThemeStyleOption());
  const sel = document.getElementById('theme-style');
  if (sel) sel.value = state.themeStyle;
}

function closeThemeStyleMenu() {
  const menu = document.getElementById('theme-style-menu');
  const toggle = document.getElementById('theme-style-toggle');
  closeDropdownMenu(menu, toggle);
}

function toggleThemeStyleMenu() {
  const menu = document.getElementById('theme-style-menu');
  const toggle = document.getElementById('theme-style-toggle');
  toggleDropdownMenu(menu, toggle, [closeThemeMenu, closeFontMenu, closePollMenu, closeLanguageMenu]);
}

function closeLanguageMenu() {
  const menu = document.getElementById('lang-menu');
  const toggle = document.getElementById('lang-toggle');
  closeDropdownMenu(menu, toggle);
}

function toggleLanguageMenu() {
  const menu = document.getElementById('lang-menu');
  const toggle = document.getElementById('lang-toggle');
  toggleDropdownMenu(menu, toggle, [closeThemeStyleMenu, closeThemeMenu, closeFontMenu, closePollMenu]);
}

function renderThemeMenu() {
  const menu = document.getElementById('theme-menu');
  const sel = document.getElementById('theme');
  if (!menu) return;
  menu.innerHTML = '';
  if (sel) sel.innerHTML = '';
  (state.themeOptions || []).forEach((x) => {
    const label = getLocalizedLabel(x);
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'theme-item';
    item.setAttribute('role', 'option');
    item.setAttribute('data-theme', x.value);
    item.innerHTML = `<img src="${x.icon || themeIconByMode(x.value)}" alt="" /><span>${esc(label)}</span>`;
    item.addEventListener('click', () => {
      closeThemeMenu();
      setTheme(x.value);
    });
    menu.appendChild(item);

    if (sel) {
      const opt = document.createElement('option');
      opt.value = x.value;
      opt.textContent = label;
      sel.appendChild(opt);
    }
  });
  updateThemeButton();
  if (sel) sel.value = state.theme;
}

function updateThemeButton() {
  const icon = document.getElementById('theme-current-icon');
  const label = document.getElementById('theme-current-label');
  const picked = currentThemeOption();
  if (icon) icon.setAttribute('src', picked && picked.icon ? picked.icon : themeIconByMode(state.theme));
  if (label) label.textContent = getLocalizedLabel(picked);
  const sel = document.getElementById('theme');
  if (sel) sel.value = state.theme;
}

function closeThemeMenu() {
  const menu = document.getElementById('theme-menu');
  const toggle = document.getElementById('theme-toggle');
  closeDropdownMenu(menu, toggle);
}

function toggleThemeMenu() {
  const menu = document.getElementById('theme-menu');
  const toggle = document.getElementById('theme-toggle');
  toggleDropdownMenu(menu, toggle, [closeThemeStyleMenu, closeFontMenu, closePollMenu, closeLanguageMenu]);
}

function renderFontMenu() {
  const menu = document.getElementById('font-menu');
  if (!menu) return;
  menu.innerHTML = '';
  FONT_ITEMS.forEach((x) => {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'theme-item';
    item.setAttribute('role', 'option');
    item.setAttribute('data-font-size', x.value);
    item.innerHTML = `<img src="images/ui/font-size.svg" alt="" /><span>${t(x.labelKey)}</span>`;
    item.addEventListener('click', () => {
      closeFontMenu();
      setFontSize(x.value);
    });
    menu.appendChild(item);
  });
  updateFontButton();
}

function updateFontButton() {
  const label = document.getElementById('font-current-label');
  if (!label) return;
  const key = state.fontSize === '25' ? 'fontLegacy' : state.fontSize === '100' ? 'fontLarge' : 'fontCurrent';
  label.textContent = t(key);
}

function closeFontMenu() {
  const menu = document.getElementById('font-menu');
  const toggle = document.getElementById('font-toggle');
  closeDropdownMenu(menu, toggle);
}

function toggleFontMenu() {
  const menu = document.getElementById('font-menu');
  const toggle = document.getElementById('font-toggle');
  toggleDropdownMenu(menu, toggle, [closeThemeStyleMenu, closeThemeMenu, closePollMenu, closeLanguageMenu]);
}

function renderPollMenu() {
  const menu = document.getElementById('poll-menu');
  if (!menu) return;
  menu.innerHTML = '';
  POLL_ITEMS.forEach((x) => {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'theme-item';
    item.setAttribute('role', 'option');
    item.setAttribute('data-poll', x.value);
    item.innerHTML = `<img src="images/ui/interval.svg" alt="" /><span>${formatPollInterval(x.value)}</span>`;
    item.addEventListener('click', () => {
      closePollMenu();
      savePollInterval(x.value).catch(() => {});
    });
    menu.appendChild(item);
  });
  updatePollButton();
}

function updatePollButton() {
  const label = document.getElementById('poll-current-label');
  if (!label) return;
  label.textContent = formatPollInterval(state.pollInterval || '1h');
}

function closePollMenu() {
  const menu = document.getElementById('poll-menu');
  const toggle = document.getElementById('poll-toggle');
  closeDropdownMenu(menu, toggle);
}

function togglePollMenu() {
  const menu = document.getElementById('poll-menu');
  const toggle = document.getElementById('poll-toggle');
  toggleDropdownMenu(menu, toggle, [closeThemeStyleMenu, closeThemeMenu, closeFontMenu, closeLanguageMenu]);
}

function formatPollInterval(v) {
  const s = (v || '').trim().toLowerCase();
  if (!s) return '-';
  const m = s.match(/^([0-9]+)h$/);
  if (!m) return s;
  const n = parseInt(m[1], 10);
  if (!Number.isFinite(n) || n <= 0) return s;
  const unitKey = (n === 1) ? 'hoursSingular' : 'hoursPlural';
  return `${n} ${t(unitKey)}`;
}

function normalizePollIntervalOption(v) {
  const s = String(v || '').trim().toLowerCase();
  if (s === '60m') return '1h';
  if (s === '180m') return '3h';
  if (s === '360m') return '6h';
  if (s === '720m') return '12h';
  if (/^[0-9]+$/.test(s)) {
    const n = parseInt(s, 10);
    if (n === 60) return '1h';
    if (n === 180) return '3h';
    if (n === 360) return '6h';
    if (n === 720) return '12h';
  }
  return s;
}

function isAllowedPollInterval(v) {
  const s = normalizePollIntervalOption(v);
  return s === '1h' || s === '3h' || s === '6h' || s === '12h';
}

function renderSubtitle() {
  const poll = formatPollInterval(state.pollInterval || '1h');
  textIfExists('subtitle', `${t('subtitleBase')} ${poll}.`);
}

function formatUpdatedLocal(raw) {
  const s = (raw || '').trim();
  if (!s) return '-';
  const m = s.match(/^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2})(?::[0-9]{2})? ([+-])([0-9]{2})([0-9]{2})$/);
  if (!m) return s;

  const yyyy = m[1];
  const mm = m[2];
  const dd = m[3];
  const hh = m[4];
  const mi = m[5];
  const sign = m[6];
  const offH = parseInt(m[7], 10);
  const offM = parseInt(m[8], 10);

  let tz = `GMT${sign}${offH}`;
  if (offM > 0) tz += `:${String(offM).padStart(2, '0')}`;

  if (state.lang === 'ro') {
    return `${dd}-${mm}-${yyyy} ${hh}:${mi} ${tz}`;
  }
  return `${mm}-${dd}-${yyyy} ${hh}:${mi} ${tz}`;
}

function parseCsv(txt) {
  const lines = (txt || '').trim().split('\n');
  if (lines.length <= 1) return [];
  return lines.slice(1).map(line => {
    const p = line.split(',');
    return { period: p[0] || '', total_gib: toNum(p[1]), rx_gib: toNum(p[2]), tx_gib: toNum(p[3]) };
  });
}

function parseDetailJson(items) {
  if (!Array.isArray(items)) return [];
  return items.map((x) => ({
    period: String(x && x.period ? x.period : ''),
    month_key: String(x && x.month_key ? x.month_key : ''),
    year_key: String(x && x.year_key ? x.year_key : ''),
    total_gib: toNum(x && x.total_gib),
    rx_gib: toNum(x && x.rx_gib),
    tx_gib: toNum(x && x.tx_gib)
  }));
}

function formatPeriod(tab, raw) {
  const s = String(raw || '').trim();
  if (!s) return s;

  if (tab === 'day') {
    const m = s.match(/^([0-9]{4})-([0-9]{2})-([0-9]{2})$/);
    if (!m) return s;
    const yyyy = m[1];
    const mm = m[2];
    const dd = m[3];
    if (state.lang === 'ro') return `${dd}-${mm}-${yyyy}`;
    return `${mm}-${dd}-${yyyy}`;
  }

  if (tab === 'month') {
    const m = s.match(/^([0-9]{4})-([0-9]{2})$/);
    if (!m) return s;
    const yyyy = m[1];
    const mi = parseInt(m[2], 10);
    if (!Number.isFinite(mi) || mi < 1 || mi > 12) return s;
    const names = MONTH_NAMES[state.lang] || MONTH_NAMES.en;
    return `${names[mi - 1]}-${yyyy}`;
  }

  return s;
}

function parseInfo(txt) {
  const out = {};
  (txt || '').trim().split('\n').forEach(line => {
    const i = line.indexOf('=');
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1);
  });
  return out;
}

function applyLanguage() {
  document.documentElement.lang = state.lang;
  document.title = t('appTitle');
  const brand = document.getElementById('brand-text');
  if (brand) brand.textContent = t('brandText');
  if (!SHARED_HEADER_OWNS_CONTROLS) {
    textIfExists('theme-style-label', t('themeStyle'));
    textIfExists('theme-label', t('theme'));
    textIfExists('poll-label', t('poll'));
    textIfExists('font-label', t('fontSize'));
    textIfExists('font-opt-legacy', t('fontLegacy'));
    textIfExists('font-opt-current', t('fontCurrent'));
    textIfExists('font-opt-large', t('fontLarge'));
    textIfExists('poll-interval-1h', `1 ${t('hoursSingular')}`);
    textIfExists('poll-interval-3h', `3 ${t('hoursPlural')}`);
    textIfExists('poll-interval-6h', `6 ${t('hoursPlural')}`);
    textIfExists('poll-interval-12h', `12 ${t('hoursPlural')}`);
    valueIfExists('lang', state.lang);
    textIfExists('lang-label', t('language'));
  }
  updateLanguageButton();
  if (!SHARED_HEADER_OWNS_CONTROLS) {
    renderLanguageOptions();
    renderThemeStyleMenu();
    renderThemeMenu();
    renderFontMenu();
    renderPollMenu();
  }
  renderSubtitle();
  textIfExists('label-day', t('totalToday'));
  textIfExists('label-month', t('totalMonth'));
  textIfExists('label-year', t('totalYear'));
  textIfExists('tab-day', t('day'));
  textIfExists('tab-month', t('month'));
  textIfExists('tab-year', t('year'));
  
  const headerRow = document.getElementById('table-header-row');
  if (headerRow) {
    headerRow.innerHTML = `
      <th id="th-period">${esc(t('period'))}</th>
      <th class="num" id="th-total">${uiMetricIcon('total')}${esc(t('total'))}</th>
      <th class="num" id="th-rx">${uiMetricIcon('rx')}RX <span class="th-hint text-inherit">(${esc(t('download'))})</span></th>
      <th class="num" id="th-tx">${uiMetricIcon('tx')}TX <span class="th-hint text-inherit">(${esc(t('upload'))})</span></th>
      <th id="th-visual">${uiMetricIcon('visual')}${esc(t('visual'))} <span class="th-hint text-inherit">${esc(t('visualHint'))}</span></th>
    `;
  }
}

function applyTheme() {
  const resolved = state.theme === 'auto' ? ((prefersDarkQuery && prefersDarkQuery.matches) ? 'dark' : 'light') : state.theme;
  document.documentElement.setAttribute('data-theme', resolved);
  valueIfExists('theme', state.theme);
  updateThemeButton();
}

function applyThemeStyle() {
  const picked = currentThemeStyleOption();
  const mode = picked && picked.value ? picked.value : 'modern';
  const css = document.getElementById('theme-style-css');
  if (css) {
    const href = (picked && picked.css)
      ? String(picked.css).replace(/^\/+/, '').replace(/^images\/ui\//, '').replace(/^style-/g, 'styles-')
      : `styles-${mode}.css`;
    css.setAttribute('href', `${href}?v=${THEME_CSS_VERSION}`);
  }
  document.documentElement.setAttribute('data-theme-style', mode);
  valueIfExists('theme-style', mode);
  updateThemeStyleButton();
}

function applyFontSize() {
  const mode = (state.fontSize === '25' || state.fontSize === '50' || state.fontSize === '100') ? state.fontSize : '100';
  document.documentElement.setAttribute('data-font-size', mode);
  valueIfExists('font-size', mode);
  updateFontButton();
}

function drawSparkline(elementId, values) {
  const el = document.getElementById(elementId);
  if (!el) return;
  if (state.themeStyle !== 'glass') {
    el.innerHTML = '';
    return;
  }

  // Ensure we have a nice visual dataset even if database is fresh
  let dataPoints = values ? [...values] : [];
  const targetLength = elementId === 'sparkline-day' ? 8 : 6;
  if (dataPoints.length === 0) {
    dataPoints = Array(targetLength).fill(0);
  } else if (dataPoints.length === 1) {
    dataPoints = [0, 0, 0, 0, 0, dataPoints[0]];
  } else if (dataPoints.length < targetLength) {
    while (dataPoints.length < targetLength) {
      dataPoints.unshift(0);
    }
  }

  const width = 110;
  const height = 36;
  const min = Math.min(...dataPoints);
  const max = Math.max(...dataPoints);
  const range = max - min || 1;

  // Detect light/dark mode for proper contrast
  const resolvedTheme = state.theme === 'auto' ? ((prefersDarkQuery && prefersDarkQuery.matches) ? 'dark' : 'light') : state.theme;
  const isDark = resolvedTheme === 'dark';

  const barGradStart = isDark ? 'rgba(255, 255, 255, 0.75)' : 'rgba(71, 85, 105, 0.7)';
  const barGradEnd = isDark ? 'rgba(255, 255, 255, 0.15)' : 'rgba(71, 85, 105, 0.15)';
  const waveGradStart = isDark ? 'rgba(255, 255, 255, 0.45)' : 'rgba(71, 85, 105, 0.35)';
  const waveGradEnd = isDark ? 'rgba(255, 255, 255, 0.0)' : 'rgba(71, 85, 105, 0.0)';
  const strokeColor = isDark ? 'rgba(255, 255, 255, 0.8)' : 'rgba(71, 85, 105, 0.8)';

  if (elementId === 'sparkline-day') {
    // Bar chart (histogram) to match "TOTAL TODAY" card from the mockup
    const barCount = dataPoints.length;
    const spacing = 3;
    const barWidth = (width - (spacing * (barCount - 1))) / barCount;
    let rectsHtml = '';
    dataPoints.forEach((val, idx) => {
      const x = idx * (barWidth + spacing);
      const h = Math.max(3, ((val - min) / range) * (height - 4));
      const y = height - h;
      rectsHtml += `<rect x="${x}" y="${y}" width="${barWidth}" height="${h}" rx="2" fill="url(#sparkline-bar-grad)" />`;
    });

    el.innerHTML = `
      <svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" style="overflow: visible; display: block;">
        <defs>
          <linearGradient id="sparkline-bar-grad" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="${barGradStart}" />
            <stop offset="100%" stop-color="${barGradEnd}" />
          </linearGradient>
        </defs>
        ${rectsHtml}
      </svg>
    `;
    return;
  }

  // Smooth cubic bezier wave curve to match "CURRENT MONTH" & "CURRENT YEAR" cards from the mockup
  const points = dataPoints.map((val, idx) => {
    const x = (idx / (dataPoints.length - 1)) * width;
    const y = height - ((val - min) / range) * (height - 4) - 2;
    return { x, y };
  });

  const getBezierPath = (pts) => {
    if (pts.length < 2) return '';
    let d = `M ${pts[0].x} ${pts[0].y}`;
    for (let i = 0; i < pts.length - 1; i++) {
      const p0 = pts[i];
      const p1 = pts[i+1];
      const cpX1 = p0.x + (p1.x - p0.x) / 2;
      const cpY1 = p0.y;
      const cpX2 = p0.x + (p1.x - p0.x) / 2;
      const cpY2 = p1.y;
      d += ` C ${cpX1} ${cpY1}, ${cpX2} ${cpY2}, ${p1.x} ${p1.y}`;
    }
    return d;
  };

  const strokePath = getBezierPath(points);
  const fillPath = `${strokePath} L ${width} ${height} L 0 ${height} Z`;

  el.innerHTML = `
    <svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" style="overflow: visible; display: block;">
      <defs>
        <linearGradient id="sparkline-wave-grad-${elementId}" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="${waveGradStart}" />
          <stop offset="100%" stop-color="${waveGradEnd}" />
        </linearGradient>
      </defs>
      <path d="${fillPath}" fill="url(#sparkline-wave-grad-${elementId})" />
      <path d="${strokePath}" fill="none" stroke="${strokeColor}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  `;
}

function renderKpis() {
  const isGlass = state.themeStyle === 'glass';
  document.getElementById('kpi-day').textContent = fmtTraffic(state.info.today_total_gib);
  document.getElementById('kpi-month').textContent = fmtTraffic(state.info.month_total_gib);
  document.getElementById('kpi-year').textContent = fmtTraffic(state.info.year_total_gib);

  const rxDayHtml = isGlass ? `${t('download')}: ${fmtTraffic(state.info.today_rx_gib)}` : `${uiMetricIcon('rx')}RX: ${fmtTraffic(state.info.today_rx_gib)}`;
  const txDayHtml = isGlass ? `${t('upload')}: ${fmtTraffic(state.info.today_tx_gib)}` : `${uiMetricIcon('tx')}TX: ${fmtTraffic(state.info.today_tx_gib)}`;
  document.getElementById('kpi-day-rx').innerHTML = rxDayHtml;
  document.getElementById('kpi-day-tx').innerHTML = txDayHtml;

  const rxMonthHtml = isGlass ? `${t('download')}: ${fmtTraffic(state.info.month_rx_gib)}` : `${uiMetricIcon('rx')}RX: ${fmtTraffic(state.info.month_rx_gib)}`;
  const txMonthHtml = isGlass ? `${t('upload')}: ${fmtTraffic(state.info.month_tx_gib)}` : `${uiMetricIcon('tx')}TX: ${fmtTraffic(state.info.month_tx_gib)}`;
  document.getElementById('kpi-month-rx').innerHTML = rxMonthHtml;
  document.getElementById('kpi-month-tx').innerHTML = txMonthHtml;

  const rxYearHtml = isGlass ? `${t('download')}: ${fmtTraffic(state.info.year_rx_gib)}` : `${uiMetricIcon('rx')}RX: ${fmtTraffic(state.info.year_rx_gib)}`;
  const txYearHtml = isGlass ? `${t('upload')}: ${fmtTraffic(state.info.year_tx_gib)}` : `${uiMetricIcon('tx')}TX: ${fmtTraffic(state.info.year_tx_gib)}`;
  document.getElementById('kpi-year-rx').innerHTML = rxYearHtml;
  document.getElementById('kpi-year-tx').innerHTML = txYearHtml;

  const dailyTotals = (state.rows.day || []).slice(0, 10).reverse().map(r => r.total_gib);
  const monthlyTotals = (state.rows.month || []).slice(0, 10).reverse().map(r => r.total_gib);
  const yearlyTotals = (state.rows.year || []).slice(0, 10).reverse().map(r => r.total_gib);

  drawSparkline('sparkline-day', dailyTotals);
  drawSparkline('sparkline-month', monthlyTotals);
  drawSparkline('sparkline-year', yearlyTotals);
}

function renderRows() {
  const rows = state.rows[state.activeTab] || [];
  const tbody = document.getElementById('rows');
  const maxTotal = Math.max(0, ...rows.map(r => r.total_gib));
  tbody.innerHTML = '';

  const monthDetailsByMonth = {};
  (state.details.monthDays || []).forEach((r) => {
    const k = String(r.month_key || '');
    if (!k) return;
    if (!monthDetailsByMonth[k]) monthDetailsByMonth[k] = [];
    monthDetailsByMonth[k].push(r);
  });

  const yearDetailsByYear = {};
  (state.details.yearMonths || []).forEach((r) => {
    const k = String(r.year_key || '');
    if (!k) return;
    if (!yearDetailsByYear[k]) yearDetailsByYear[k] = [];
    yearDetailsByYear[k].push(r);
  });

  rows.forEach(r => {
    const pct = maxTotal > 0 ? (r.total_gib / maxTotal) * 100 : 0;
    const isMax = maxTotal > 0 && Math.abs(r.total_gib - maxTotal) < 1e-9;
    const barColor = isMax ? 'var(--bar-max, #53c16f)' : 'var(--blue, #3f8cff)';
    const rowKey = String(r.period || '');
    const isMonthTab = state.activeTab === 'month';
    const isYearTab = state.activeTab === 'year';
    const detailRows = isMonthTab
      ? (monthDetailsByMonth[rowKey] || [])
      : (isYearTab ? (yearDetailsByYear[rowKey] || []) : []);
    const canExpand = detailRows.length > 0;
    const isExpanded = (isMonthTab && state.expanded.month === rowKey) || (isYearTab && state.expanded.year === rowKey);
    const showExpand = isMonthTab || isYearTab;
    const prefix = showExpand
      ? (canExpand ? `<button class="expander" type="button" data-key="${esc(rowKey)}" aria-label="toggle">${isExpanded ? '&#9662;' : '&#9656;'}</button>` : '<span class="expander-empty"></span>')
      : '';

    const tr = document.createElement('tr');
    if (isExpanded) tr.className = 'group-parent-expanded';
    
    tr.innerHTML = `
      <td>${prefix}${esc(formatPeriod(state.activeTab, r.period))}</td>
      <td class="num">${esc(fmtTraffic(r.total_gib))}</td>
      <td class="num">${esc(fmtTraffic(r.rx_gib))}</td>
      <td class="num">${esc(fmtTraffic(r.tx_gib))}</td>
      <td><div class="bar-wrap"><div class="bar" style="width:${pct.toFixed(2)}%; background:${barColor};"></div></div></td>
    `;
    tbody.appendChild(tr);

    if (canExpand) {
      const toggleGroup = () => {
        if (isMonthTab) state.expanded.month = (state.expanded.month === rowKey) ? null : rowKey;
        if (isYearTab) state.expanded.year = (state.expanded.year === rowKey) ? null : rowKey;
        renderRows();
      };

      const btn = tr.querySelector('.expander');
      if (btn) {
        btn.addEventListener('click', (e) => {
          e.stopPropagation();
          toggleGroup();
        });
      }

      const firstCell = tr.querySelector('td');
      if (firstCell) {
        firstCell.style.cursor = 'pointer';
        firstCell.addEventListener('click', (e) => {
          if (e.target && e.target.closest && e.target.closest('.expander')) return;
          toggleGroup();
        });
      }
    }

    if (isExpanded) {
      const detailMaxTotal = Math.max(0, ...detailRows.map(d => d.total_gib));
      detailRows.forEach((d, idx) => {
        const dpct = detailMaxTotal > 0 ? (d.total_gib / detailMaxTotal) * 100 : 0;
        const detailIsMax = detailMaxTotal > 0 && Math.abs(d.total_gib - detailMaxTotal) < 1e-9;
        const detailBarColor = detailIsMax ? 'var(--bar-max, #53c16f)' : 'var(--blue, #3f8cff)';
        const dtr = document.createElement('tr');
        const isFirstDetail = idx === 0;
        const isLastDetail = idx === detailRows.length - 1;
        dtr.className = `detail-row${isFirstDetail ? ' detail-row-first' : ''}${isLastDetail ? ' detail-row-last' : ''}`;
        
        dtr.innerHTML = `
          <td class="detail-period">${esc(formatPeriod(isMonthTab ? 'day' : 'month', d.period))}</td>
          <td class="num">${esc(fmtTraffic(d.total_gib))}</td>
          <td class="num">${esc(fmtTraffic(d.rx_gib))}</td>
          <td class="num">${esc(fmtTraffic(d.tx_gib))}</td>
          <td><div class="bar-wrap"><div class="bar" style="width:${dpct.toFixed(2)}%; background:${detailBarColor};"></div></div></td>
        `;
        tbody.appendChild(dtr);
      });
    }
  });

  const sampleByTab = {
    day: state.info.samples_day || state.info.samples || '0',
    month: state.info.samples_month || state.info.samples || '0',
    year: state.info.samples_year || state.info.samples || '0'
  };
  const samples = sampleByTab[state.activeTab] || state.info.samples || '0';
  const updated = formatUpdatedLocal(state.info.updated_local || '');
  const activeLabel = t(TAB_LABEL_KEY[state.activeTab] || state.activeTab);
  const poll = formatPollInterval(state.pollInterval);
  const dbSize = fmtBytes(state.info.db_size_bytes || '0');
  htmlIfExists('meta', `${t('tab')}: ${esc(activeLabel)} | ${uiMetricIcon('samples')}${t('samples')}: ${esc(samples)} | ${uiMetricIcon('updated')}${t('lastUpdate')}: ${esc(updated)} | ${uiMetricIcon('db-size')}${t('dbSize')}: ${esc(dbSize)} | ${uiMetricIcon('interval')}${t('pollInterval')}: ${esc(poll)}`);
}

function setActiveTab(tab) {
  state.activeTab = tab;
  document.querySelectorAll('.tab').forEach(btn => btn.classList.toggle('active', btn.dataset.tab === tab));
  renderRows();
}

function setLanguage(lang) {
  state.lang = getLanguageDef(lang) ? lang : 'en';
  localStorage.setItem('mtm_lang', state.lang);
  applyLanguage();
  renderRows();
  saveSettings({ language: state.lang }).catch(() => {});
}

function setTheme(theme) {
  state.theme = getThemeDef(String(theme || '').toLowerCase()) ? String(theme || '').toLowerCase() : 'auto';
  localStorage.setItem('mtm_theme', state.theme);
  applyTheme();
  saveSettings({ theme: state.theme }).catch(() => {});
}

function setThemeStyle(mode) {
  state.themeStyle = getThemeStyleDef(String(mode || '').toLowerCase()) ? String(mode || '').toLowerCase() : 'modern';
  localStorage.setItem('mtm_theme_style', state.themeStyle);
  applyThemeStyle();
  renderRows();
  saveSettings({ theme_style: state.themeStyle }).catch(() => {});
}

function setFontSize(mode) {
  const next = (mode === '25' || mode === '50' || mode === '100') ? mode : '100';
  state.fontSize = next;
  localStorage.setItem('mtm_font_size', next);
  applyFontSize();
  saveSettings({ font_size: next }).catch(() => {});
  textIfExists('meta', `${t('fontSaved')}: ${t(next === '25' ? 'fontLegacy' : next === '100' ? 'fontLarge' : 'fontCurrent')}`);
  setTimeout(() => { window.location.reload(); }, 500);
}

async function loadAll() {
  const q = `?_=${Date.now()}`;
  const [d, m, y, i, md, ym] = await Promise.all([
    fetch('/day.csv' + q).then(r => r.text()),
    fetch('/month.csv' + q).then(r => r.text()),
    fetch('/year.csv' + q).then(r => r.text()),
    fetch('/info.txt' + q).then(r => r.text()),
    fetch('/api/month_days.json' + q).then(r => r.json()),
    fetch('/api/year_months.json' + q).then(r => r.json())
  ]);

  state.rows.day = parseCsv(d);
  state.rows.month = parseCsv(m);
  state.rows.year = parseCsv(y);
  state.details.monthDays = parseDetailJson(md);
  state.details.yearMonths = parseDetailJson(ym);
  state.info = parseInfo(i);

  renderKpis();
  renderRows();
}

async function loadSettings() {
  const q = `?_=${Date.now()}`;
  try {
    const d = await fetch('/api/settings.json' + q).then(r => r.json());
    const pRaw = (d && d.poll_interval) ? d.poll_interval : ((d && d.effective_poll_interval) ? d.effective_poll_interval : '');
    const p = normalizePollIntervalOption(pRaw);
    const theme = (d && getThemeDef(String(d.theme || '').toLowerCase())) ? String(d.theme || '').toLowerCase() : '';
    const themeStyleRaw = String((d && (d.theme_style || d.themeStyle)) || '').toLowerCase();
    const themeStyle = (d && getThemeStyleDef(themeStyleRaw)) ? themeStyleRaw : '';
    const lang = (d && getLanguageDef(String(d.language || '').toLowerCase())) ? String(d.language || '').toLowerCase() : '';
    const fontSize = (d && (d.font_size === '25' || d.font_size === '50' || d.font_size === '100')) ? d.font_size : '';
    state.pollInterval = p;
    valueIfExists('poll-interval', isAllowedPollInterval(p) ? p : '1h');
    updatePollButton();
    if (theme) {
      state.theme = theme;
      localStorage.setItem('mtm_theme', theme);
      applyTheme();
    }
    if (themeStyle) {
      state.themeStyle = themeStyle;
      localStorage.setItem('mtm_theme_style', themeStyle);
      applyThemeStyle();
    }
    if (lang) {
      state.lang = lang;
      localStorage.setItem('mtm_lang', lang);
      applyLanguage();
    }
    if (fontSize) {
      state.fontSize = fontSize;
      localStorage.setItem('mtm_font_size', fontSize);
      applyFontSize();
    }
    renderSubtitle();
    renderRows();
  } catch (_) {}
}

function getThemeDef(code) {
  return (state.themeOptions || []).find((x) => x.value === code) || null;
}

function getThemeStyleDef(code) {
  return (state.themeStyleOptions || []).find((x) => x.value === code) || null;
}

async function loadThemeConfig() {
  const q = `?_=${Date.now()}`;
  try {
    const [themeOptions, themeStyleOptions] = await Promise.all([
      fetch('common/theme-options.json' + q).then(r => r.json()),
      fetch('common/theme-styles.json' + q).then(r => r.json())
    ]);
    state.themeOptions = normalizeThemeOptions(themeOptions);
    state.themeStyleOptions = normalizeThemeStyleOptions(themeStyleOptions);
  } catch (_) {
    state.themeOptions = DEFAULT_THEME_OPTIONS.slice();
    state.themeStyleOptions = DEFAULT_THEME_STYLE_OPTIONS.slice();
  }
  if (!SHARED_HEADER_OWNS_CONTROLS) {
    renderThemeMenu();
    renderThemeStyleMenu();
  }
}

async function saveSettings(patch) {
  const res = await fetch('/api/settings', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(patch || {})
  });
  if (!res.ok) throw new Error('save_failed');
  return res.json();
}

async function loadTranslations() {
  const q = `?_=${Date.now()}`;
  try {
    try {
      BRANDING = await fetch('/branding.json' + q).then(r => r.ok ? r.json() : {});
    } catch (_) {
      BRANDING = {};
    }
    const loaded = await Promise.all((state.languages || []).map(async (l) => {
      const data = await fetch(`${l.file}${q}`).then(r => r.json());
      return { code: l.code, data: data || {} };
    }));
    loaded.forEach((x) => { I18N[x.code] = x.data; });
    if (!I18N.en) I18N.en = {};
    applyLanguage();
    renderRows();
  } catch (_) {}
}

async function loadLanguageConfig() {
  const q = `?_=${Date.now()}`;
  try {
    const cfg = await fetch('/i18n/languages.json' + q).then(r => r.json());
    state.languages = normalizeLanguageList(cfg);
  } catch (_) {
    state.languages = DEFAULT_LANGUAGES.slice();
  }
  if (!SHARED_HEADER_OWNS_CONTROLS) {
    renderLanguageOptions();
  }
  if (!getLanguageDef(state.lang)) state.lang = 'en';
  valueIfExists('lang', state.lang);
}

async function savePollInterval(value) {
  const sel = document.getElementById('poll-interval');
  const v = normalizePollIntervalOption(value || sel.value || '');
  if (!isAllowedPollInterval(v)) {
    textIfExists('meta', t('pollInvalid'));
    return;
  }

  try {
    await saveSettings({ poll_interval: v });
  } catch (_) {
    textIfExists('meta', t('loadError'));
    return;
  }
  state.pollInterval = v;
  if (sel) sel.value = v;
  updatePollButton();
  renderSubtitle();
  renderRows();
  textIfExists('meta', `${t('pollSaved')}: ${formatPollInterval(v)}`);
  setTimeout(() => { renderRows(); }, 1200);
}

const storedLang = localStorage.getItem('mtm_lang');
const storedTheme = localStorage.getItem('mtm_theme');
const storedThemeStyle = localStorage.getItem('mtm_theme_style');
const storedFontSize = localStorage.getItem('mtm_font_size');
state.lang = (typeof storedLang === 'string' && storedLang) ? storedLang.toLowerCase() : 'en';
state.theme = (storedTheme === 'dark' || storedTheme === 'light' || storedTheme === 'auto') ? storedTheme : 'auto';
state.themeStyle = (typeof storedThemeStyle === 'string' && storedThemeStyle) ? storedThemeStyle.toLowerCase() : 'modern';
state.fontSize = (storedFontSize === '25' || storedFontSize === '50' || storedFontSize === '100') ? storedFontSize : '100';
if (prefersDarkQuery) {
  const onThemePrefChange = () => { if (state.theme === 'auto') applyTheme(); };
  if (prefersDarkQuery.addEventListener) prefersDarkQuery.addEventListener('change', onThemePrefChange);
  else if (prefersDarkQuery.addListener) prefersDarkQuery.addListener(onThemePrefChange);
}
textIfExists('meta', t('loading'));
if (!SHARED_HEADER_OWNS_CONTROLS) {
  document.getElementById('theme-style-toggle').addEventListener('click', () => toggleThemeStyleMenu());
  document.getElementById('theme-toggle').addEventListener('click', () => toggleThemeMenu());
  document.getElementById('font-toggle').addEventListener('click', () => toggleFontMenu());
  document.getElementById('poll-toggle').addEventListener('click', () => togglePollMenu());
  document.getElementById('lang-toggle').addEventListener('click', () => toggleLanguageMenu());
  document.addEventListener('click', (e) => {
    const themeStyleWrap = document.getElementById('theme-style-dropdown');
    if (!themeStyleWrap || !themeStyleWrap.contains(e.target)) closeThemeStyleMenu();
    const themeWrap = document.getElementById('theme-dropdown');
    if (!themeWrap || !themeWrap.contains(e.target)) closeThemeMenu();
    const fontWrap = document.getElementById('font-dropdown');
    if (!fontWrap || !fontWrap.contains(e.target)) closeFontMenu();
    const pollWrap = document.getElementById('poll-dropdown');
    if (!pollWrap || !pollWrap.contains(e.target)) closePollMenu();
    const wrap = document.getElementById('lang-dropdown');
    if (!wrap || !wrap.contains(e.target)) closeLanguageMenu();
  });
}

window.addEventListener('mikrotik:header-setting-changed', async (event) => {
  const detail = event?.detail || {};
  if (detail.key === 'theme') {
    state.theme = detail.value || state.theme;
    localStorage.setItem('mtm_theme', state.theme);
    applyTheme();
    renderRows();
  } else if (detail.key === 'themeStyle') {
    state.themeStyle = detail.value || state.themeStyle;
    localStorage.setItem('mtm_theme_style', state.themeStyle);
    applyThemeStyle();
    renderRows();
  } else if (detail.key === 'fontSize') {
    state.fontSize = detail.value || state.fontSize;
    localStorage.setItem('mtm_font_size', state.fontSize);
    applyFontSize();
    renderRows();
  } else if (detail.key === 'language') {
    state.lang = detail.value || state.lang;
    localStorage.setItem('mtm_lang', state.lang);
    applyLanguage();
    renderRows();
  } else if (detail.key === 'pollInterval') {
    state.pollInterval = detail.value || state.pollInterval;
    valueIfExists('poll-interval', isAllowedPollInterval(state.pollInterval) ? state.pollInterval : '1h');
    updatePollButton();
    renderSubtitle();
    renderRows();
  }
});

if (window.MikroTikSharedHeader && typeof window.MikroTikSharedHeader.whenReady === 'function') {
  window.MikroTikSharedHeader.whenReady().then(() => {
    const sharedState = window.MikroTikSharedHeader.getState ? window.MikroTikSharedHeader.getState() : null;
    if (sharedState) {
      if (sharedState.theme) state.theme = sharedState.theme;
      if (sharedState.themeStyle) state.themeStyle = sharedState.themeStyle;
      if (sharedState.fontSize) state.fontSize = sharedState.fontSize;
      if (sharedState.language) state.lang = sharedState.language;
      if (sharedState.pollInterval) state.pollInterval = sharedState.pollInterval;
    }
  }).catch(() => {});
}

document.querySelectorAll('.tab').forEach(btn => btn.addEventListener('click', () => setActiveTab(btn.dataset.tab)));
loadThemeConfig().then(() => {
  applyThemeStyle();
  applyTheme();
  applyFontSize();
  applyLanguage();
  loadAll().catch(e => { textIfExists('meta', `${t('loadError')}: ${e}`); });
  loadLanguageConfig().then(() => {
    loadSettings().catch(() => {});
    loadTranslations().catch(() => {});
  }).catch(() => {
    loadSettings().catch(() => {});
    loadTranslations().catch(() => {});
  });
}).catch(() => {
  applyThemeStyle();
  applyTheme();
  applyFontSize();
  applyLanguage();
  loadAll().catch(e => { textIfExists('meta', `${t('loadError')}: ${e}`); });
  loadLanguageConfig().then(() => {
    loadSettings().catch(() => {});
    loadTranslations().catch(() => {});
  }).catch(() => {
    loadSettings().catch(() => {});
    loadTranslations().catch(() => {});
  });
});
setInterval(() => { loadAll().catch(() => {}); }, 60000);
