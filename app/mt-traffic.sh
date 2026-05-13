#!/bin/sh
set -eu

: "${MT_HOST:?MT_HOST is required}"
: "${MT_COMMUNITY:?MT_COMMUNITY is required}"
: "${IFINDEX:=auto}"
: "${IFNAME_PATTERN:=pppoe}"
: "${POLL_INTERVAL:=1h}"
: "${POLL_SEC:=}"
: "${HTTP_PORT:=8080}"
: "${TZ:=Europe/Bucharest}"
: "${DATA_DIR:=/data}"

export TZ

DB="$DATA_DIR/traffic.db"
WWW="$DATA_DIR/www"
SETTINGS_PATH="$DATA_DIR/settings.json"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

mkdir -p "$WWW"

ACTIVE_IFINDEX=""
POLL_SLEEP_SEC="3600"
ACTIVE_POLL_INTERVAL="1h"

parse_interval_to_sec() {
  RAW="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$RAW" in
    ''|*[!0-9smh]*) return 1 ;;
  esac

  case "$RAW" in
    *s) N="${RAW%s}"; S="$N" ;;
    *m) N="${RAW%m}"; S="$((N * 60))" ;;
    *h) N="${RAW%h}"; S="$((N * 3600))" ;;
    *)  N="$RAW"; RAW="${RAW}m"; S="$((N * 60))" ;;
  esac

  case "$N" in ''|*[!0-9]*) return 1 ;; esac
  [ "$S" -gt 0 ] 2>/dev/null || return 1

  PARSED_INTERVAL_RAW="$RAW"
  PARSED_INTERVAL_SEC="$S"
  return 0
}

read_runtime_poll_interval() {
  if [ ! -f "$SETTINGS_PATH" ]; then
    return 1
  fi

  V="$(SETTINGS_PATH_ENV="$SETTINGS_PATH" python3 - <<'PY'
import json
import os
from pathlib import Path

p = Path(os.environ["SETTINGS_PATH_ENV"])
try:
    data = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)
v = data.get("poll_interval", "")
print(v if isinstance(v, str) else "")
PY
)"
  [ -n "$V" ] || return 1
  printf '%s\n' "$V"
  return 0
}

resolve_poll_interval() {
  RUNTIME="$(read_runtime_poll_interval || true)"
  if parse_interval_to_sec "$RUNTIME"; then
    POLL_SLEEP_SEC="$PARSED_INTERVAL_SEC"
    ACTIVE_POLL_INTERVAL="$PARSED_INTERVAL_RAW"
    return 0
  fi

  if parse_interval_to_sec "${POLL_INTERVAL:-}"; then
    POLL_SLEEP_SEC="$PARSED_INTERVAL_SEC"
    ACTIVE_POLL_INTERVAL="$PARSED_INTERVAL_RAW"
    return 0
  fi

  case "${POLL_SEC:-}" in
    ''|*[!0-9]*)
      POLL_SLEEP_SEC="3600"
      ACTIVE_POLL_INTERVAL="1h"
      ;;
    *)
      if [ "$POLL_SEC" -gt 0 ] 2>/dev/null; then
        POLL_SLEEP_SEC="$POLL_SEC"
        ACTIVE_POLL_INTERVAL="${POLL_SEC}s"
      else
        POLL_SLEEP_SEC="3600"
        ACTIVE_POLL_INTERVAL="1h"
      fi
      ;;
  esac
}

sleep_poll_interval() {
  TARGET="$POLL_SLEEP_SEC"
  ELAPSED=0
  while [ "$ELAPSED" -lt "$TARGET" ]; do
    REMAIN=$((TARGET - ELAPSED))
    STEP=5
    if [ "$REMAIN" -lt "$STEP" ]; then
      STEP="$REMAIN"
    fi
    [ "$STEP" -gt 0 ] 2>/dev/null || break
    sleep "$STEP"
    ELAPSED=$((ELAPSED + STEP))
    resolve_poll_interval
    TARGET="$POLL_SLEEP_SEC"
    if [ "$TARGET" -le "$ELAPSED" ]; then
      break
    fi
  done
}

is_auto_ifindex() {
  case "$IFINDEX" in
    ""|auto|pppoe) return 0 ;;
    *) return 1 ;;
  esac
}

detect_pppoe_ifindex() {
  WALK="$(snmpwalk -v2c -c "$MT_COMMUNITY" -On "$MT_HOST" "1.3.6.1.2.1.31.1.1.1.1" 2>/dev/null || true)"
  if [ -z "$WALK" ]; then
    WALK="$(snmpwalk -v2c -c "$MT_COMMUNITY" -On "$MT_HOST" "1.3.6.1.2.1.2.2.1.2" 2>/dev/null || true)"
  fi
  [ -n "$WALK" ] || return 1

  FIRST_MATCH=""
  UP_MATCH=""

  while IFS= read -r LINE; do
    [ -n "$LINE" ] || continue
    OID="${LINE%% = *}"
    IDX="${OID##*.}"
    case "$IDX" in
      ''|*[!0-9]*) continue ;;
    esac

    NAME="${LINE#*= }"
    NAME="${NAME#STRING: }"
    NAME_LC="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')"

    if ! printf '%s\n' "$NAME_LC" | grep -Eiq "$IFNAME_PATTERN"; then
      continue
    fi

    if [ -z "$FIRST_MATCH" ]; then
      FIRST_MATCH="$IDX"
    fi

    STATUS="$(snmpget -v2c -c "$MT_COMMUNITY" -Oqv "$MT_HOST" "1.3.6.1.2.1.2.2.1.8.$IDX" 2>/dev/null || true)"
    STATUS_LC="$(printf '%s' "$STATUS" | tr '[:upper:]' '[:lower:]')"
    case "$STATUS_LC" in
      1|up*|'INTEGER: up(1)')
        UP_MATCH="$IDX"
        break
        ;;
    esac
  done <<EOF
$WALK
EOF

  if [ -n "$UP_MATCH" ]; then
    printf '%s\n' "$UP_MATCH"
    return 0
  fi
  if [ -n "$FIRST_MATCH" ]; then
    printf '%s\n' "$FIRST_MATCH"
    return 0
  fi
  return 1
}

resolve_ifindex() {
  if is_auto_ifindex; then
    DETECTED="$(detect_pppoe_ifindex || true)"
    if [ -n "$DETECTED" ]; then
      ACTIVE_IFINDEX="$DETECTED"
      return 0
    fi
    return 1
  fi

  ACTIVE_IFINDEX="$IFINDEX"
  return 0
}

write_ui() {
cat > "$WWW/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>MikroTik Traffic Monitor</title>
  <style>
    :root {
      --bg: #f6f8fb;
      --card: #ffffff;
      --border: #e6eaf2;
      --text: #1f2937;
      --muted: #64748b;
      --blue: #2563eb;
      --table-head: #fafbfe;
      --table-border: #eef1f6;
      --bar-bg: #edf2f7;
    }
    html[data-theme="dark"] {
      --bg: #252a31;
      --card: #21262d;
      --border: #2a416b;
      --text: #d6d6d6;
      --muted: #a69f96;
      --blue: #2d5ec7;
      --table-head: #232931;
      --table-border: #344463;
      --bar-bg: #2a3443;
    }
    body { margin: 0; padding: 20px; background: var(--bg); color: var(--text); font-family: Arial, sans-serif; }
    h1 { margin: 0 0 6px; font-size: 22px; }
    .subtitle { color: var(--muted); margin-bottom: 14px; font-size: 13px; }
    .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px; margin-bottom: 14px; }
    .kpi { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 12px; }
    .kpi .label { font-size: 12px; color: var(--muted); margin-bottom: 4px; }
    .kpi .val { font-size: 20px; font-weight: bold; }
    .kpi .sub { font-size: 12px; color: var(--muted); margin-top: 6px; }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 12px; }
    .tabs { display: flex; gap: 8px; margin-bottom: 10px; flex-wrap: wrap; }
    .tab { border: 1px solid var(--border); background: var(--card); color: var(--text); border-radius: 999px; padding: 7px 12px; font-size: 13px; cursor: pointer; }
    .tab.active { background: var(--blue); color: #fff; border-color: var(--blue); }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { text-align: left; border-bottom: 1px solid var(--table-border); padding: 8px; }
    th { background: var(--table-head); }
    .expander { border: 0; background: transparent; color: var(--muted); cursor: pointer; padding: 0 6px 0 0; font-size: 12px; }
    .expander-empty { display: inline-block; width: 12px; margin-right: 6px; }
    .detail-row td { background: var(--table-head); }
    .detail-period { padding-left: 24px; color: var(--muted); }
    .num { text-align: right; font-variant-numeric: tabular-nums; }
    .bar-wrap { width: 140px; max-width: 100%; height: 8px; border-radius: 999px; background: var(--bar-bg); overflow: hidden; }
    .bar { height: 8px; background: var(--blue); }
    .meta { margin-top: 8px; color: var(--muted); font-size: 12px; }
    .topbar { display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; }
    .controls { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; justify-content: flex-end; }
    .control { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
    .control-icon { width: 14px; height: 14px; display: inline-flex; align-items: center; justify-content: center; color: var(--muted); }
    .control-icon img { width: 14px; height: 14px; display: block; opacity: .85; }
    .lang-dropdown { position: relative; width: fit-content; min-width: 0; }
    .lang-toggle { display: inline-flex; align-items: center; gap: 4px; border: 1px solid var(--border); border-radius: 8px; background: var(--card); color: var(--text); padding: 2px 7px; min-height: 26px; font-size: 12px; cursor: pointer; }
    .lang-toggle img { width: 14px; height: 14px; display: block; }
    .lang-caret { color: var(--muted); font-size: 10px; }
    .lang-menu { position: absolute; right: 0; top: calc(100% + 6px); min-width: 0; border: 1px solid var(--border); border-radius: 8px; background: var(--card); box-shadow: 0 6px 20px rgba(0,0,0,.12); display: none; z-index: 30; padding: 3px; }
    .lang-menu.open { display: block; }
    .lang-item { width: 100%; display: flex; align-items: center; gap: 6px; border: 0; background: transparent; color: var(--text); border-radius: 6px; padding: 4px 6px; font-size: 12px; text-align: left; cursor: pointer; }
    .lang-item:hover { background: var(--table-head); }
    .lang-item img { width: 14px; height: 14px; display: block; }
    .theme-dropdown { position: relative; width: fit-content; min-width: 0; }
    .theme-toggle { display: inline-flex; align-items: center; gap: 4px; border: 1px solid var(--border); border-radius: 8px; background: var(--card); color: var(--text); padding: 2px 7px; min-height: 26px; font-size: 12px; cursor: pointer; }
    .theme-toggle img { width: 14px; height: 14px; display: block; }
    .theme-menu { position: absolute; right: 0; top: calc(100% + 6px); min-width: 0; border: 1px solid var(--border); border-radius: 8px; background: var(--card); box-shadow: 0 6px 20px rgba(0,0,0,.12); display: none; z-index: 30; padding: 3px; }
    .theme-menu.open { display: block; }
    .theme-item { width: 100%; white-space: nowrap; display: flex; align-items: center; gap: 6px; border: 0; background: transparent; color: var(--text); border-radius: 6px; padding: 4px 6px; font-size: 12px; text-align: left; cursor: pointer; }
    .theme-item:hover { background: var(--table-head); }
    .theme-item img { width: 14px; height: 14px; display: block; }
    .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); border: 0; }
    .ico-inline { width: 14px; height: 14px; vertical-align: -2px; margin-right: 4px; opacity: .95; }
    .th-hint { color: var(--muted); font-size: 11px; font-weight: normal; }
    .control select { border: 1px solid var(--border); border-radius: 8px; background: var(--card); color: var(--text); padding: 4px 8px; font-size: 12px; }
    .control input { border: 1px solid var(--border); border-radius: 8px; background: var(--card); color: var(--text); padding: 4px 8px; font-size: 12px; width: 80px; }
    .control button { border: 1px solid var(--border); border-radius: 8px; background: var(--card); color: var(--text); padding: 4px 8px; font-size: 12px; cursor: pointer; }
    @media (max-width: 760px) {
      th:nth-child(5), td:nth-child(5) { display: none; }
      .bar-wrap { width: 80px; }
      .topbar { flex-direction: column; }
      .controls { justify-content: flex-start; }
    }
  </style>
</head>
<body>
  <div class="topbar">
    <div>
      <h1>MikroTik Traffic Monitor</h1>
      <div class="subtitle" id="subtitle">Day / Month / Year aggregation, updated hourly.</div>
    </div>
    <div class="controls">
      <label class="control" for="theme">
        <span class="control-icon" id="theme-icon" aria-hidden="true">
          <img id="theme-icon-img" src="/images/ui/theme-auto.svg" alt="" />
        </span>
        <span id="theme-label">Theme</span>
        <div class="theme-dropdown" id="theme-dropdown">
          <button type="button" class="theme-toggle" id="theme-toggle" aria-haspopup="listbox" aria-expanded="false">
            <img id="theme-current-icon" src="/images/ui/theme-auto.svg" alt="" />
            <span id="theme-current-label">Auto</span>
          </button>
          <div class="theme-menu" id="theme-menu" role="listbox" aria-label="Theme options"></div>
          <select id="theme" class="sr-only" tabindex="-1" aria-hidden="true">
            <option value="auto" id="theme-opt-auto">Auto</option>
            <option value="light" id="theme-opt-light">Light</option>
            <option value="dark" id="theme-opt-dark">Dark</option>
          </select>
        </div>
      </label>
      <label class="control" for="poll-interval">
        <span id="poll-label">Poll</span>
        <div class="theme-dropdown" id="poll-dropdown">
          <button type="button" class="theme-toggle" id="poll-toggle" aria-haspopup="listbox" aria-expanded="false">
            <img src="/images/ui/interval.svg" alt="" />
            <span id="poll-current-label">1 hour</span>
          </button>
          <div class="theme-menu" id="poll-menu" role="listbox" aria-label="Poll interval options"></div>
          <select id="poll-interval" class="sr-only" tabindex="-1" aria-hidden="true">
            <option value="1h" id="poll-interval-1h">1 hour</option>
            <option value="3h" id="poll-interval-3h">3 hours</option>
            <option value="6h" id="poll-interval-6h">6 hours</option>
            <option value="12h" id="poll-interval-12h">12 hours</option>
          </select>
        </div>
      </label>
      <label class="control" for="lang">
        <span class="control-icon" aria-hidden="true">
          <img id="lang-icon-img" src="/images/lang/en.svg" alt="" />
        </span>
        <span id="lang-label">Language</span>
        <div class="lang-dropdown" id="lang-dropdown">
          <button type="button" class="lang-toggle" id="lang-toggle" aria-haspopup="listbox" aria-expanded="false">
            <img id="lang-current-icon" src="/images/lang/en.svg" alt="" />
            <span id="lang-current-label">EN</span>
          </button>
          <div class="lang-menu" id="lang-menu" role="listbox" aria-label="Language options"></div>
          <select id="lang" class="sr-only" tabindex="-1" aria-hidden="true">
            <option value="en">EN</option>
            <option value="ro">RO</option>
          </select>
        </div>
      </label>
    </div>
  </div>

  <div class="kpis">
    <div class="kpi">
      <div class="label" id="label-day">Total Today</div>
      <div class="val" id="kpi-day">0.000 GiB</div>
      <div class="sub"><span id="kpi-day-rx">RX: 0.000 GiB</span> | <span id="kpi-day-tx">TX: 0.000 GiB</span></div>
    </div>
    <div class="kpi">
      <div class="label" id="label-month">Current Month Total</div>
      <div class="val" id="kpi-month">0.000 GiB</div>
      <div class="sub"><span id="kpi-month-rx">RX: 0.000 GiB</span> | <span id="kpi-month-tx">TX: 0.000 GiB</span></div>
    </div>
    <div class="kpi">
      <div class="label" id="label-year">Current Year Total</div>
      <div class="val" id="kpi-year">0.000 GiB</div>
      <div class="sub"><span id="kpi-year-rx">RX: 0.000 GiB</span> | <span id="kpi-year-tx">TX: 0.000 GiB</span></div>
    </div>
  </div>

  <div class="card">
    <div class="tabs">
      <button class="tab active" data-tab="day" id="tab-day">Day</button>
      <button class="tab" data-tab="month" id="tab-month">Month</button>
      <button class="tab" data-tab="year" id="tab-year">Year</button>
    </div>

    <table>
      <thead>
        <tr>
          <th id="th-period">Period</th>
          <th class="num" id="th-total">Total (GiB)</th>
          <th class="num" id="th-rx">RX (GiB)</th>
          <th class="num" id="th-tx">TX (GiB)</th>
          <th id="th-visual">Visual</th>
        </tr>
      </thead>
      <tbody id="rows"></tbody>
    </table>

    <div class="meta" id="meta">Loading...</div>
  </div>

<script>
const DEFAULT_LANGUAGES = [
  { code: 'en', label: 'EN', flag: '\uD83C\uDDFA\uD83C\uDDF8', file: '/i18n/en.json', icon: '/images/lang/en.svg' },
  { code: 'ro', label: 'RO', flag: '\uD83C\uDDF7\uD83C\uDDF4', file: '/i18n/ro.json', icon: '/images/lang/ro.svg' }
];
const I18N = {};
const I18N_FALLBACK = {
  theme: 'Theme',
  auto: 'Auto',
  light: 'Light',
  dark: 'Dark',
  poll: 'Poll',
  pollInterval: 'Poll interval',
  secondsSingular: 'second',
  secondsPlural: 'seconds',
  minutesSingular: 'minute',
  minutesPlural: 'minutes',
  hoursSingular: 'hour',
  hoursPlural: 'hours',
  pollSaved: 'Poll interval saved',
  pollInvalid: 'Invalid interval (allowed: 1h, 3h, 6h, 12h)',
  save: 'Save',
  language: 'Language',
  subtitleBase: 'Day / Month / Year aggregation, updated every',
  totalToday: 'Total Today',
  totalMonth: 'Current Month Total',
  totalYear: 'Current Year Total',
  day: 'Day',
  month: 'Month',
  year: 'Year',
  period: 'Period',
  total: 'Total (GiB)',
  download: 'Download',
  upload: 'Upload',
  visual: 'Visual',
  visualHint: '(relative to max Total in current tab)',
  loading: 'Loading...',
  tab: 'Tab',
  samples: 'Samples',
  lastUpdate: 'Last update',
  loadError: 'Load error'
};

const TAB_LABEL_KEY = { day: 'day', month: 'month', year: 'year' };
const state = {
  activeTab: 'day',
  lang: 'en',
  theme: 'auto',
  pollInterval: '',
  rows: { day: [], month: [], year: [] },
  details: { monthDays: [], yearMonths: [] },
  expanded: { month: null, year: null },
  info: {},
  languages: DEFAULT_LANGUAGES.slice()
};
const prefersDarkQuery = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
const MONTH_NAMES = {
  en: ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
  ro: ['Ian', 'Feb', 'Mar', 'Apr', 'Mai', 'Iun', 'Iul', 'Aug', 'Sep', 'Oct', 'Noi', 'Dec']
};
const THEME_ITEMS = [
  { value: 'auto', labelKey: 'auto', icon: '/images/ui/theme-auto.svg' },
  { value: 'light', labelKey: 'light', icon: '/images/ui/theme-light.svg' },
  { value: 'dark', labelKey: 'dark', icon: '/images/ui/theme-dark.svg' }
];
const POLL_ITEMS = [
  { value: '1h', amount: 1 },
  { value: '3h', amount: 3 },
  { value: '6h', amount: 6 },
  { value: '12h', amount: 12 }
];

function themeIconSvg(mode, resolved) {
  if (mode === 'auto') return '/images/ui/theme-auto.svg';
  if (resolved === 'dark') return '/images/ui/theme-dark.svg';
  return '/images/ui/theme-light.svg';
}

function toNum(v) { const n = parseFloat(v || '0'); return Number.isFinite(n) ? n : 0; }
function fmtGiB(v) { return `${toNum(v).toFixed(3)} GiB`; }
function t(key) {
  return (I18N[state.lang] && I18N[state.lang][key]) || (I18N.en && I18N.en[key]) || I18N_FALLBACK[key] || key;
}

function uiIcon(name) {
  return `<img class="ico-inline" src="/images/ui/${name}.svg" alt="" />`;
}

function esc(v) {
  return String(v == null ? '' : v)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
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
    const icon = String(x.icon || `/images/lang/${code}.svg`).trim();
    if (!/^[a-z][a-z0-9_-]{1,15}$/.test(code)) return;
    if (!file || file[0] !== '/') return;
    out.push({ code, label: label || code.toUpperCase(), flag, file, icon });
  });
  if (!out.find(l => l.code === 'en')) {
    out.unshift(DEFAULT_LANGUAGES[0]);
  }
  return out.length ? out : DEFAULT_LANGUAGES.slice();
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
}
function themeIconByMode(mode) {
  if (mode === 'light') return '/images/ui/theme-light.svg';
  if (mode === 'dark') return '/images/ui/theme-dark.svg';
  return '/images/ui/theme-auto.svg';
}

function updateLanguageButton() {
  const langDef = getLanguageDef(state.lang) || getLanguageDef('en');
  const icon = document.getElementById('lang-current-icon');
  const label = document.getElementById('lang-current-label');
  if (icon) icon.setAttribute('src', (langDef && langDef.icon) ? langDef.icon : '/images/lang/en.svg');
  if (label) label.textContent = (langDef && langDef.label) ? langDef.label : 'EN';
}

function closeLanguageMenu() {
  const menu = document.getElementById('lang-menu');
  const toggle = document.getElementById('lang-toggle');
  if (menu) menu.classList.remove('open');
  if (toggle) toggle.setAttribute('aria-expanded', 'false');
}

function toggleLanguageMenu() {
  const menu = document.getElementById('lang-menu');
  const toggle = document.getElementById('lang-toggle');
  if (!menu || !toggle) return;
  const open = menu.classList.toggle('open');
  toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
}

function renderThemeMenu() {
  const menu = document.getElementById('theme-menu');
  if (!menu) return;
  menu.innerHTML = '';
  THEME_ITEMS.forEach((x) => {
    const item = document.createElement('button');
    item.type = 'button';
    item.className = 'theme-item';
    item.setAttribute('role', 'option');
    item.setAttribute('data-theme', x.value);
    item.innerHTML = `<img src="${x.icon}" alt="" /><span>${t(x.labelKey)}</span>`;
    item.addEventListener('click', () => {
      closeThemeMenu();
      setTheme(x.value);
    });
    menu.appendChild(item);
  });
  updateThemeButton();
}

function updateThemeButton() {
  const icon = document.getElementById('theme-current-icon');
  const label = document.getElementById('theme-current-label');
  if (icon) icon.setAttribute('src', themeIconByMode(state.theme));
  if (label) label.textContent = t(state.theme === 'light' ? 'light' : state.theme === 'dark' ? 'dark' : 'auto');
}

function closeThemeMenu() {
  const menu = document.getElementById('theme-menu');
  const toggle = document.getElementById('theme-toggle');
  if (menu) menu.classList.remove('open');
  if (toggle) toggle.setAttribute('aria-expanded', 'false');
}

function toggleThemeMenu() {
  const menu = document.getElementById('theme-menu');
  const toggle = document.getElementById('theme-toggle');
  if (!menu || !toggle) return;
  const open = menu.classList.toggle('open');
  toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
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
    item.innerHTML = `<img src="/images/ui/interval.svg" alt="" /><span>${formatPollInterval(x.value)}</span>`;
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
  if (menu) menu.classList.remove('open');
  if (toggle) toggle.setAttribute('aria-expanded', 'false');
}

function togglePollMenu() {
  const menu = document.getElementById('poll-menu');
  const toggle = document.getElementById('poll-toggle');
  if (!menu || !toggle) return;
  const open = menu.classList.toggle('open');
  toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
}

function formatPollInterval(v) {
  const s = (v || '').trim().toLowerCase();
  if (!s) return '-';
  const m = s.match(/^([0-9]+)([smh]?)$/);
  if (!m) return s;
  const n = parseInt(m[1], 10);
  if (!Number.isFinite(n) || n <= 0) return s;
  const u = m[2] || 'm';
  let unitKey = 'minutesPlural';
  if (u === 's') unitKey = (n === 1) ? 'secondsSingular' : 'secondsPlural';
  if (u === 'm') unitKey = (n === 1) ? 'minutesSingular' : 'minutesPlural';
  if (u === 'h') unitKey = (n === 1) ? 'hoursSingular' : 'hoursPlural';
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
  const poll = formatPollInterval(state.pollInterval || '60m');
  document.getElementById('subtitle').textContent = `${t('subtitleBase')} ${poll}.`;
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
  const langDef = getLanguageDef(state.lang) || getLanguageDef('en');
  document.getElementById('lang-icon-img').setAttribute('src', (langDef && langDef.icon) ? langDef.icon : '/images/lang/en.svg');
  document.getElementById('theme-label').textContent = t('theme');
  document.getElementById('theme-opt-auto').textContent = t('auto');
  document.getElementById('theme-opt-light').textContent = t('light');
  document.getElementById('theme-opt-dark').textContent = t('dark');
  document.getElementById('poll-label').textContent = t('poll');
  document.getElementById('poll-interval-1h').textContent = `1 ${t('hoursSingular')}`;
  document.getElementById('poll-interval-3h').textContent = `3 ${t('hoursPlural')}`;
  document.getElementById('poll-interval-6h').textContent = `6 ${t('hoursPlural')}`;
  document.getElementById('poll-interval-12h').textContent = `12 ${t('hoursPlural')}`;
  document.getElementById('lang').value = state.lang;
  document.getElementById('lang-label').textContent = t('language');
  updateLanguageButton();
  renderThemeMenu();
  renderPollMenu();
  renderSubtitle();
  document.getElementById('label-day').textContent = t('totalToday');
  document.getElementById('label-month').textContent = t('totalMonth');
  document.getElementById('label-year').textContent = t('totalYear');
  document.getElementById('tab-day').textContent = t('day');
  document.getElementById('tab-month').textContent = t('month');
  document.getElementById('tab-year').textContent = t('year');
  document.getElementById('th-period').textContent = t('period');
  document.getElementById('th-total').innerHTML = `${uiIcon('total')}${t('total')}`;
  document.getElementById('th-rx').innerHTML = `${uiIcon('rx')}RX (GiB)`;
  document.getElementById('th-tx').innerHTML = `${uiIcon('tx')}TX (GiB)`;
  document.getElementById('th-visual').innerHTML = `${uiIcon('visual')}${t('visual')} <span class=\"th-hint\">${esc(t('visualHint'))}</span>`;
}

function applyTheme() {
  const resolved = state.theme === 'auto' ? ((prefersDarkQuery && prefersDarkQuery.matches) ? 'dark' : 'light') : state.theme;
  document.documentElement.setAttribute('data-theme', resolved);
  document.getElementById('theme').value = state.theme;
  document.getElementById('theme-icon-img').setAttribute('src', themeIconSvg(state.theme, resolved));
  updateThemeButton();
}

function renderKpis() {
  document.getElementById('kpi-day').textContent = fmtGiB(state.info.today_total_gib);
  document.getElementById('kpi-month').textContent = fmtGiB(state.info.month_total_gib);
  document.getElementById('kpi-year').textContent = fmtGiB(state.info.year_total_gib);
  document.getElementById('kpi-day-rx').innerHTML = `${uiIcon('rx')}RX: ${fmtGiB(state.info.today_rx_gib)}`;
  document.getElementById('kpi-day-tx').innerHTML = `${uiIcon('tx')}TX: ${fmtGiB(state.info.today_tx_gib)}`;
  document.getElementById('kpi-month-rx').innerHTML = `${uiIcon('rx')}RX: ${fmtGiB(state.info.month_rx_gib)}`;
  document.getElementById('kpi-month-tx').innerHTML = `${uiIcon('tx')}TX: ${fmtGiB(state.info.month_tx_gib)}`;
  document.getElementById('kpi-year-rx').innerHTML = `${uiIcon('rx')}RX: ${fmtGiB(state.info.year_rx_gib)}`;
  document.getElementById('kpi-year-tx').innerHTML = `${uiIcon('tx')}TX: ${fmtGiB(state.info.year_tx_gib)}`;
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
    tr.innerHTML = `
      <td>${prefix}${esc(formatPeriod(state.activeTab, r.period))}</td>
      <td class="num">${r.total_gib.toFixed(3)}</td>
      <td class="num">${r.rx_gib.toFixed(3)}</td>
      <td class="num">${r.tx_gib.toFixed(3)}</td>
      <td><div class="bar-wrap"><div class="bar" style="width:${pct.toFixed(2)}%"></div></div></td>
    `;
    tbody.appendChild(tr);

    if (canExpand) {
      const btn = tr.querySelector('.expander');
      if (btn) {
        btn.addEventListener('click', () => {
          if (isMonthTab) state.expanded.month = (state.expanded.month === rowKey) ? null : rowKey;
          if (isYearTab) state.expanded.year = (state.expanded.year === rowKey) ? null : rowKey;
          renderRows();
        });
      }
    }

    if (isExpanded) {
      detailRows.forEach((d) => {
        const dpct = maxTotal > 0 ? (d.total_gib / maxTotal) * 100 : 0;
        const dtr = document.createElement('tr');
        dtr.className = 'detail-row';
        dtr.innerHTML = `
          <td class="detail-period">${esc(formatPeriod(isMonthTab ? 'day' : 'month', d.period))}</td>
          <td class="num">${d.total_gib.toFixed(3)}</td>
          <td class="num">${d.rx_gib.toFixed(3)}</td>
          <td class="num">${d.tx_gib.toFixed(3)}</td>
          <td><div class="bar-wrap"><div class="bar" style="width:${dpct.toFixed(2)}%"></div></div></td>
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
  document.getElementById('meta').innerHTML = `${t('tab')}: ${esc(activeLabel)} | ${uiIcon('samples')}${t('samples')}: ${esc(samples)} | ${uiIcon('updated')}${t('lastUpdate')}: ${esc(updated)} | ${uiIcon('interval')}${t('pollInterval')}: ${esc(poll)}`;
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
  state.theme = (theme === 'dark' || theme === 'light' || theme === 'auto') ? theme : 'auto';
  localStorage.setItem('mtm_theme', state.theme);
  applyTheme();
  saveSettings({ theme: state.theme }).catch(() => {});
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
    const theme = (d && (d.theme === 'light' || d.theme === 'dark' || d.theme === 'auto')) ? d.theme : '';
    const lang = (d && getLanguageDef(String(d.language || '').toLowerCase())) ? String(d.language || '').toLowerCase() : '';
    state.pollInterval = p;
    document.getElementById('poll-interval').value = isAllowedPollInterval(p) ? p : '1h';
    updatePollButton();
    if (theme) {
      state.theme = theme;
      localStorage.setItem('mtm_theme', theme);
      applyTheme();
    }
    if (lang) {
      state.lang = lang;
      localStorage.setItem('mtm_lang', lang);
      applyLanguage();
    }
    renderSubtitle();
    renderRows();
  } catch (_) {}
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
  renderLanguageOptions();
  if (!getLanguageDef(state.lang)) state.lang = 'en';
  document.getElementById('lang').value = state.lang;
}

async function savePollInterval(value) {
  const sel = document.getElementById('poll-interval');
  const v = normalizePollIntervalOption(value || sel.value || '');
  if (!isAllowedPollInterval(v)) {
    document.getElementById('meta').textContent = t('pollInvalid');
    return;
  }

  try {
    await saveSettings({ poll_interval: v });
  } catch (_) {
    document.getElementById('meta').textContent = t('loadError');
    return;
  }
  state.pollInterval = v;
  sel.value = v;
  updatePollButton();
  renderSubtitle();
  renderRows();
  document.getElementById('meta').textContent = `${t('pollSaved')}: ${formatPollInterval(v)}`;
  setTimeout(() => { renderRows(); }, 1200);
}

const storedLang = localStorage.getItem('mtm_lang');
const storedTheme = localStorage.getItem('mtm_theme');
state.lang = (typeof storedLang === 'string' && storedLang) ? storedLang.toLowerCase() : 'en';
state.theme = (storedTheme === 'dark' || storedTheme === 'light' || storedTheme === 'auto') ? storedTheme : 'auto';
applyTheme();
renderLanguageOptions();
applyLanguage();
if (prefersDarkQuery) {
  const onThemePrefChange = () => { if (state.theme === 'auto') applyTheme(); };
  if (prefersDarkQuery.addEventListener) prefersDarkQuery.addEventListener('change', onThemePrefChange);
  else if (prefersDarkQuery.addListener) prefersDarkQuery.addListener(onThemePrefChange);
}
document.getElementById('meta').textContent = t('loading');
document.getElementById('theme-toggle').addEventListener('click', () => toggleThemeMenu());
document.getElementById('poll-toggle').addEventListener('click', () => togglePollMenu());
document.getElementById('lang-toggle').addEventListener('click', () => toggleLanguageMenu());
document.addEventListener('click', (e) => {
  const themeWrap = document.getElementById('theme-dropdown');
  if (!themeWrap || !themeWrap.contains(e.target)) closeThemeMenu();
  const pollWrap = document.getElementById('poll-dropdown');
  if (!pollWrap || !pollWrap.contains(e.target)) closePollMenu();
  const wrap = document.getElementById('lang-dropdown');
  if (!wrap || !wrap.contains(e.target)) closeLanguageMenu();
});
document.querySelectorAll('.tab').forEach(btn => btn.addEventListener('click', () => setActiveTab(btn.dataset.tab)));
loadAll().catch(e => { document.getElementById('meta').textContent = `${t('loadError')}: ${e}`; });
loadLanguageConfig().then(() => {
  loadSettings().catch(() => {});
  loadTranslations().catch(() => {});
}).catch(() => {
  loadSettings().catch(() => {});
  loadTranslations().catch(() => {});
});
setInterval(() => { loadAll().catch(() => {}); }, 60000);
</script>
</body>
</html>
HTML

mkdir -p "$WWW/i18n"
if [ -f "$SCRIPT_DIR/i18n/en.json" ]; then
  cp "$SCRIPT_DIR/i18n/en.json" "$WWW/i18n/en.json"
else
  printf '%s\n' '{}' > "$WWW/i18n/en.json"
fi
if [ -f "$SCRIPT_DIR/i18n/ro.json" ]; then
  cp "$SCRIPT_DIR/i18n/ro.json" "$WWW/i18n/ro.json"
else
  printf '%s\n' '{}' > "$WWW/i18n/ro.json"
fi
if [ -f "$SCRIPT_DIR/i18n/languages.json" ]; then
  cp "$SCRIPT_DIR/i18n/languages.json" "$WWW/i18n/languages.json"
else
  printf '%s\n' '[{"code":"en","label":"EN","flag":"\ud83c\uddfa\ud83c\uddf8","file":"/i18n/en.json","icon":"/images/lang/en.svg"},{"code":"ro","label":"RO","flag":"\ud83c\uddf7\ud83c\uddf4","file":"/i18n/ro.json","icon":"/images/lang/ro.svg"}]' > "$WWW/i18n/languages.json"
fi

mkdir -p "$WWW/images"
if [ -d "$SCRIPT_DIR/images" ]; then
  cp -R "$SCRIPT_DIR/images/." "$WWW/images/"
fi
}

sqlite_exec() {
  sqlite3 "$DB" "$1"
}

init_db() {
  sqlite_exec '
CREATE TABLE IF NOT EXISTS samples (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  in_octets INTEGER NOT NULL,
  out_octets INTEGER NOT NULL,
  delta_bytes INTEGER NOT NULL,
  delta_in_bytes INTEGER,
  delta_out_bytes INTEGER
);
CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);
'

  HAS_DIN="$(sqlite_exec "SELECT COUNT(*) FROM pragma_table_info('samples') WHERE name='delta_in_bytes';")"
  HAS_DOUT="$(sqlite_exec "SELECT COUNT(*) FROM pragma_table_info('samples') WHERE name='delta_out_bytes';")"

  if [ "$HAS_DIN" = "0" ]; then
    sqlite_exec "ALTER TABLE samples ADD COLUMN delta_in_bytes INTEGER;"
  fi
  if [ "$HAS_DOUT" = "0" ]; then
    sqlite_exec "ALTER TABLE samples ADD COLUMN delta_out_bytes INTEGER;"
  fi

  backfill_deltas
}

backfill_deltas() {
  PREV_IN=""
  PREV_OUT=""

  sqlite3 -separator '|' "$DB" "SELECT id,in_octets,out_octets FROM samples ORDER BY id;" | while IFS='|' read -r ID CUR_IN CUR_OUT; do
    if [ -z "$PREV_IN" ]; then
      DIN=0
      DOUT=0
    else
      if [ "$CUR_IN" -ge "$PREV_IN" ]; then DIN=$((CUR_IN - PREV_IN)); else DIN=$CUR_IN; fi
      if [ "$CUR_OUT" -ge "$PREV_OUT" ]; then DOUT=$((CUR_OUT - PREV_OUT)); else DOUT=$CUR_OUT; fi
    fi

    DBYTES=$((DIN + DOUT))
    sqlite3 "$DB" "UPDATE samples SET delta_in_bytes=$DIN, delta_out_bytes=$DOUT, delta_bytes=$DBYTES WHERE id=$ID;"

    PREV_IN=$CUR_IN
    PREV_OUT=$CUR_OUT
  done
}

render_api() {
  BASE="$WWW" IFINDEX_ENV="$ACTIVE_IFINDEX" POLL_INTERVAL_ENV="$ACTIVE_POLL_INTERVAL" POLL_SEC_ENV="$POLL_SLEEP_SEC" python3 - <<'PY'
import csv
import json
import os
from pathlib import Path

base = Path(os.environ["BASE"])
api = base / "api"
api.mkdir(exist_ok=True)


def load_csv(name: str):
    out = []
    path = base / name
    if not path.exists():
        return out
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            out.append({
                "period": row.get("period", ""),
                "total_gib": float(row.get("total_gib") or 0),
                "rx_gib": float(row.get("rx_gib") or 0),
                "tx_gib": float(row.get("tx_gib") or 0),
            })
    return out


def load_detail_csv(name: str):
    out = []
    path = base / name
    if not path.exists():
        return out
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            item = {
                "period": row.get("period", ""),
                "total_gib": float(row.get("total_gib") or 0),
                "rx_gib": float(row.get("rx_gib") or 0),
                "tx_gib": float(row.get("tx_gib") or 0),
            }
            if "month_key" in row:
                item["month_key"] = row.get("month_key", "")
            if "year_key" in row:
                item["year_key"] = row.get("year_key", "")
            out.append(item)
    return out


def load_info():
    info = {}
    p = base / "info.txt"
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                info[k] = v
    return info


def to_num(v):
    try:
        return float(v)
    except Exception:
        return 0.0


def to_int(v):
    try:
        return int(float(v))
    except Exception:
        return 0

info = load_info()
day = load_csv("day.csv")
month = load_csv("month.csv")
year = load_csv("year.csv")
month_days = load_detail_csv("month_days.csv")
year_months = load_detail_csv("year_months.csv")

summary = {
    "updated_local": info.get("updated_local", ""),
    "samples": int(to_num(info.get("samples", "0"))),
    "db_size_bytes": to_int(info.get("db_size_bytes", "0")),
    "kpi": {
        "today_total_gib": to_num(info.get("today_total_gib", "0")),
        "today_rx_gib": to_num(info.get("today_rx_gib", "0")),
        "today_tx_gib": to_num(info.get("today_tx_gib", "0")),
        "month_total_gib": to_num(info.get("month_total_gib", "0")),
        "month_rx_gib": to_num(info.get("month_rx_gib", "0")),
        "month_tx_gib": to_num(info.get("month_tx_gib", "0")),
        "year_total_gib": to_num(info.get("year_total_gib", "0")),
        "year_rx_gib": to_num(info.get("year_rx_gib", "0")),
        "year_tx_gib": to_num(info.get("year_tx_gib", "0")),
    },
    "interface": {"ifindex": os.environ.get("IFINDEX_ENV", "")},
    "poll": {
        "interval": os.environ.get("POLL_INTERVAL_ENV", ""),
        "seconds": int(to_num(os.environ.get("POLL_SEC_ENV", "0"))),
    },
    "windows": {"day": "current_month", "month": "current_year", "year": "all_years"},
    "endpoints": {
        "day": "/api/day.json",
        "month": "/api/month.json",
        "year": "/api/year.json",
        "month_days": "/api/month_days.json",
        "year_months": "/api/year_months.json",
        "summary": "/api/summary.json",
    },
}

(api / "day.json").write_text(json.dumps(day, indent=2), encoding="utf-8")
(api / "month.json").write_text(json.dumps(month, indent=2), encoding="utf-8")
(api / "year.json").write_text(json.dumps(year, indent=2), encoding="utf-8")
(api / "month_days.json").write_text(json.dumps(month_days, indent=2), encoding="utf-8")
(api / "year_months.json").write_text(json.dumps(year_months, indent=2), encoding="utf-8")
(api / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")

ha = '''# Home Assistant example (REST sensor)
rest:
  - resource: "http://192.168.88.1:8088/api/summary.json"
    scan_interval: 120
    sensor:
      - name: "MikroTik Traffic Summary"
        unique_id: mikrotik_traffic_summary
        value_template: "{{ value_json.kpi.today_total_gib }}"
        unit_of_measurement: "GiB"
        json_attributes_path: "$.kpi"
        json_attributes:
          - today_total_gib
          - today_rx_gib
          - today_tx_gib
          - month_total_gib
          - month_rx_gib
          - month_tx_gib
          - year_total_gib
          - year_rx_gib
          - year_tx_gib
'''
(api / "home_assistant_rest_example.yaml").write_text(ha, encoding="utf-8")
PY
}

render_views() {
  sqlite3 -header -csv "$DB" "
    SELECT date(ts,'unixepoch','localtime') AS period,
           ROUND(SUM(delta_bytes)/1073741824.0, 3) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 3) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 3) AS tx_gib
    FROM samples
    WHERE ts >= strftime('%s','now','localtime','start of month','utc')
    GROUP BY period
    ORDER BY period DESC
    LIMIT 31;
  " > "$WWW/day.csv"

  sqlite3 -header -csv "$DB" "
    SELECT strftime('%Y-%m', ts,'unixepoch','localtime') AS period,
           ROUND(SUM(delta_bytes)/1073741824.0, 3) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 3) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 3) AS tx_gib
    FROM samples
    WHERE ts >= strftime('%s','now','localtime','start of year','utc')
    GROUP BY period
    ORDER BY period DESC
    LIMIT 12;
  " > "$WWW/month.csv"

  sqlite3 -header -csv "$DB" "
    SELECT strftime('%Y', ts,'unixepoch','localtime') AS period,
           ROUND(SUM(delta_bytes)/1073741824.0, 3) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 3) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 3) AS tx_gib
    FROM samples
    WHERE ts >= 0
    GROUP BY period
    ORDER BY period DESC;
  " > "$WWW/year.csv"

  sqlite3 -header -csv "$DB" "
    SELECT date(ts,'unixepoch','localtime') AS period,
           strftime('%Y-%m', ts,'unixepoch','localtime') AS month_key,
           ROUND(SUM(delta_bytes)/1073741824.0, 3) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 3) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 3) AS tx_gib
    FROM samples
    WHERE ts >= strftime('%s','now','localtime','start of year','utc')
    GROUP BY period
    ORDER BY period DESC;
  " > "$WWW/month_days.csv"

  sqlite3 -header -csv "$DB" "
    SELECT strftime('%Y-%m', ts,'unixepoch','localtime') AS period,
           strftime('%Y', ts,'unixepoch','localtime') AS year_key,
           ROUND(SUM(delta_bytes)/1073741824.0, 3) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 3) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 3) AS tx_gib
    FROM samples
    WHERE ts >= 0
    GROUP BY period
    ORDER BY period DESC;
  " > "$WWW/year_months.csv"

  cp "$WWW/day.csv" "$WWW/daily.csv"

  TODAY_TOTAL_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of day','utc');")"
  TODAY_RX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_in_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of day','utc');")"
  TODAY_TX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_out_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of day','utc');")"
  MONTH_TOTAL_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of month','utc');")"
  MONTH_RX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_in_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of month','utc');")"
  MONTH_TX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_out_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of month','utc');")"
  YEAR_TOTAL_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of year','utc');")"
  YEAR_RX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_in_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of year','utc');")"
  YEAR_TX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_out_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of year','utc');")"
  SAMPLES="$(sqlite_exec "SELECT COUNT(*) FROM samples;")"
  SAMPLES_DAY="$(sqlite_exec "SELECT COUNT(*) FROM samples WHERE ts >= strftime('%s','now','localtime','start of day','utc');")"
  SAMPLES_MONTH="$(sqlite_exec "SELECT COUNT(*) FROM samples WHERE ts >= strftime('%s','now','localtime','start of month','utc');")"
  SAMPLES_YEAR="$(sqlite_exec "SELECT COUNT(*) FROM samples WHERE ts >= strftime('%s','now','localtime','start of year','utc');")"
  DB_SIZE_BYTES="$(wc -c < "$DB" 2>/dev/null || echo 0)"
  DB_SIZE_BYTES="${DB_SIZE_BYTES//[!0-9]/}"
  [ -n "$DB_SIZE_BYTES" ] || DB_SIZE_BYTES=0
  UPDATED_LOCAL="$(date '+%Y-%m-%d %H:%M:%S %z')"

  {
    echo "today_total_gib=$TODAY_TOTAL_GIB"
    echo "today_rx_gib=$TODAY_RX_GIB"
    echo "today_tx_gib=$TODAY_TX_GIB"
    echo "month_total_gib=$MONTH_TOTAL_GIB"
    echo "month_rx_gib=$MONTH_RX_GIB"
    echo "month_tx_gib=$MONTH_TX_GIB"
    echo "year_total_gib=$YEAR_TOTAL_GIB"
    echo "year_rx_gib=$YEAR_RX_GIB"
    echo "year_tx_gib=$YEAR_TX_GIB"
    echo "samples=$SAMPLES"
    echo "samples_day=$SAMPLES_DAY"
    echo "samples_month=$SAMPLES_MONTH"
    echo "samples_year=$SAMPLES_YEAR"
    echo "db_size_bytes=$DB_SIZE_BYTES"
    echo "updated_local=$UPDATED_LOCAL"
  } > "$WWW/info.txt"

  render_api
}

start_http_server() {
  WWW_DIR="$WWW" HTTP_PORT_ENV="$HTTP_PORT" SETTINGS_PATH_ENV="$SETTINGS_PATH" EFFECTIVE_POLL_INTERVAL_ENV="$ACTIVE_POLL_INTERVAL" python3 - <<'PY' &
import json
import os
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

www = os.environ["WWW_DIR"]
port = int(os.environ["HTTP_PORT_ENV"])
settings_path = Path(os.environ["SETTINGS_PATH_ENV"])
effective_poll_interval = os.environ.get("EFFECTIVE_POLL_INTERVAL_ENV", "")


def read_settings():
    if not settings_path.exists():
        return {}
    try:
        data = json.loads(settings_path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {}


def write_settings(data):
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = settings_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data), encoding="utf-8")
    tmp.replace(settings_path)


def normalize_interval(v):
    if not isinstance(v, str):
        return ""
    v = v.strip().lower()
    if v == "60m":
        return "1h"
    if v == "180m":
        return "3h"
    if v == "360m":
        return "6h"
    if v == "720m":
        return "12h"
    if v.isdigit():
        n = int(v)
        if n == 60:
            return "1h"
        if n == 180:
            return "3h"
        if n == 360:
            return "6h"
        if n == 720:
            return "12h"
    return v


def valid_interval(v):
    return v in ("1h", "3h", "6h", "12h")


def valid_theme(v):
    return isinstance(v, str) and v in ("light", "dark", "auto")


def valid_language(v):
    if not isinstance(v, str):
        return False
    v = v.strip().lower()
    if len(v) < 2 or len(v) > 16:
        return False
    for c in v:
        if not (c.isalnum() or c in ("-", "_")):
            return False
    return v[0].isalpha()


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=www, **kwargs)

    def _send_json(self, code, payload):
        b = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.startswith("/api/settings.json"):
            cfg = read_settings()
            self._send_json(200, {
                "poll_interval": cfg.get("poll_interval", ""),
                "effective_poll_interval": effective_poll_interval,
                "theme": cfg.get("theme", ""),
                "language": cfg.get("language", ""),
            })
            return
        super().do_GET()

    def do_POST(self):
        if self.path != "/api/settings":
            self._send_json(404, {"error": "not_found"})
            return
        try:
            l = int(self.headers.get("Content-Length", "0"))
        except Exception:
            l = 0
        body = self.rfile.read(l) if l > 0 else b"{}"
        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
            self._send_json(400, {"error": "invalid_json"})
            return
        if not isinstance(data, dict):
            self._send_json(400, {"error": "invalid_payload"})
            return

        cfg = read_settings()
        out = {"ok": True}
        changed = False

        if "poll_interval" in data:
            interval = normalize_interval(str(data.get("poll_interval", "")))
            if not valid_interval(interval):
                self._send_json(400, {"error": "invalid_interval"})
                return
            cfg["poll_interval"] = interval
            out["poll_interval"] = interval
            changed = True

        if "theme" in data:
            theme = str(data.get("theme", "")).strip().lower()
            if not valid_theme(theme):
                self._send_json(400, {"error": "invalid_theme"})
                return
            cfg["theme"] = theme
            out["theme"] = theme
            changed = True

        if "language" in data:
            language = str(data.get("language", "")).strip().lower()
            if not valid_language(language):
                self._send_json(400, {"error": "invalid_language"})
                return
            cfg["language"] = language
            out["language"] = language
            changed = True

        if not changed:
            self._send_json(400, {"error": "empty_payload"})
            return

        write_settings(cfg)
        self._send_json(200, out)


ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
PY
}

write_ui
init_db
resolve_poll_interval
start_http_server
resolve_ifindex || true
render_views

while true; do
  resolve_poll_interval
  if ! resolve_ifindex; then
    sleep_poll_interval
    continue
  fi

  TS="$(date +%s)"
  IN="$(snmpget -v2c -c "$MT_COMMUNITY" -Oqv "$MT_HOST" "1.3.6.1.2.1.31.1.1.1.6.$ACTIVE_IFINDEX" 2>/dev/null || true)"
  OUT="$(snmpget -v2c -c "$MT_COMMUNITY" -Oqv "$MT_HOST" "1.3.6.1.2.1.31.1.1.1.10.$ACTIVE_IFINDEX" 2>/dev/null || true)"

  case "$IN" in ''|*[!0-9]*) sleep_poll_interval; continue ;; esac
  case "$OUT" in ''|*[!0-9]*) sleep_poll_interval; continue ;; esac

  PREV="$(sqlite_exec "SELECT in_octets || '|' || out_octets FROM samples ORDER BY id DESC LIMIT 1;" || true)"
  if [ -z "$PREV" ]; then
    DIN=0
    DOUT=0
  else
    PIN="${PREV%%|*}"
    POUT="${PREV#*|}"
    if [ "$IN" -ge "$PIN" ]; then DIN=$((IN - PIN)); else DIN=$IN; fi
    if [ "$OUT" -ge "$POUT" ]; then DOUT=$((OUT - POUT)); else DOUT=$OUT; fi
  fi

  DBYTES=$((DIN + DOUT))
  sqlite_exec "INSERT INTO samples(ts,in_octets,out_octets,delta_bytes,delta_in_bytes,delta_out_bytes) VALUES($TS,$IN,$OUT,$DBYTES,$DIN,$DOUT);"
  sqlite_exec "DELETE FROM samples WHERE ts < strftime('%s','now','-1825 days');"

  render_views
  sleep_poll_interval
done
