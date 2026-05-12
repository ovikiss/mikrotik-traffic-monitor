#!/bin/sh
set -eu

: "${MT_HOST:?MT_HOST is required}"
: "${MT_COMMUNITY:?MT_COMMUNITY is required}"
: "${IFINDEX:?IFINDEX is required}"
: "${POLL_SEC:=3600}"
: "${HTTP_PORT:=8080}"
: "${TZ:=Europe/Bucharest}"
: "${DATA_DIR:=/data}"

export TZ

DB="$DATA_DIR/traffic.db"
WWW="$DATA_DIR/www"

mkdir -p "$WWW"

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
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; padding: 12px; }
    .tabs { display: flex; gap: 8px; margin-bottom: 10px; flex-wrap: wrap; }
    .tab { border: 1px solid var(--border); background: var(--card); color: var(--text); border-radius: 999px; padding: 7px 12px; font-size: 13px; cursor: pointer; }
    .tab.active { background: var(--blue); color: #fff; border-color: var(--blue); }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { text-align: left; border-bottom: 1px solid var(--table-border); padding: 8px; }
    th { background: var(--table-head); }
    .num { text-align: right; font-variant-numeric: tabular-nums; }
    .bar-wrap { width: 140px; max-width: 100%; height: 8px; border-radius: 999px; background: var(--bar-bg); overflow: hidden; }
    .bar { height: 8px; background: var(--blue); }
    .meta { margin-top: 8px; color: var(--muted); font-size: 12px; }
    .topbar { display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; }
    .controls { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; justify-content: flex-end; }
    .control { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
    .control select { border: 1px solid var(--border); border-radius: 8px; background: var(--card); color: var(--text); padding: 4px 8px; font-size: 12px; }
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
        <span id="theme-label">Theme</span>
        <select id="theme">
          <option value="light" id="theme-opt-light">Light</option>
          <option value="dark" id="theme-opt-dark">Dark</option>
        </select>
      </label>
      <label class="control" for="lang">
        <span id="lang-label">Language</span>
        <select id="lang">
          <option value="en">EN</option>
          <option value="ro">RO</option>
        </select>
      </label>
    </div>
  </div>

  <div class="kpis">
    <div class="kpi"><div class="label" id="label-day">Total Today</div><div class="val" id="kpi-day">0.000 GiB</div></div>
    <div class="kpi"><div class="label" id="label-month">Current Month Total</div><div class="val" id="kpi-month">0.000 GiB</div></div>
    <div class="kpi"><div class="label" id="label-year">Current Year Total</div><div class="val" id="kpi-year">0.000 GiB</div></div>
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
          <th class="num">RX (GiB)</th>
          <th class="num">TX (GiB)</th>
          <th id="th-visual">Visual</th>
        </tr>
      </thead>
      <tbody id="rows"></tbody>
    </table>

    <div class="meta" id="meta">Loading...</div>
  </div>

<script>
const I18N = {
  en: {
    theme: 'Theme',
    light: 'Light',
    dark: 'Dark',
    language: 'Language',
    subtitle: 'Day / Month / Year aggregation, updated hourly.',
    totalToday: 'Total Today',
    totalMonth: 'Current Month Total',
    totalYear: 'Current Year Total',
    day: 'Day',
    month: 'Month',
    year: 'Year',
    period: 'Period',
    total: 'Total (GiB)',
    visual: 'Visual',
    loading: 'Loading...',
    tab: 'Tab',
    samples: 'Samples',
    lastUpdate: 'Last update',
    loadError: 'Load error'
  },
  ro: {
    theme: 'Temă',
    light: 'Luminos',
    dark: 'Întunecat',
    language: 'Limbă',
    subtitle: 'Agregare pe Zi / Luna / An, update la fiecare oră.',
    totalToday: 'Total azi',
    totalMonth: 'Total luna curentă',
    totalYear: 'Total anul curent',
    day: 'Zi',
    month: 'Lună',
    year: 'An',
    period: 'Perioada',
    total: 'Total (GiB)',
    visual: 'Vizual',
    loading: 'Se încarcă...',
    tab: 'Tab',
    samples: 'Mostre',
    lastUpdate: 'Ultimul update',
    loadError: 'Eroare încărcare'
  }
};

const TAB_LABEL_KEY = { day: 'day', month: 'month', year: 'year' };
const state = { activeTab: 'day', lang: 'en', theme: 'light', rows: { day: [], month: [], year: [] }, info: {} };

function toNum(v) { const n = parseFloat(v || '0'); return Number.isFinite(n) ? n : 0; }
function fmtGiB(v) { return `${toNum(v).toFixed(3)} GiB`; }
function t(key) { return (I18N[state.lang] && I18N[state.lang][key]) || I18N.en[key] || key; }

function parseCsv(txt) {
  const lines = (txt || '').trim().split('\n');
  if (lines.length <= 1) return [];
  return lines.slice(1).map(line => {
    const p = line.split(',');
    return { period: p[0] || '', total_gib: toNum(p[1]), rx_gib: toNum(p[2]), tx_gib: toNum(p[3]) };
  });
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
  document.getElementById('theme-label').textContent = t('theme');
  document.getElementById('theme-opt-light').textContent = t('light');
  document.getElementById('theme-opt-dark').textContent = t('dark');
  document.getElementById('lang').value = state.lang;
  document.getElementById('lang-label').textContent = t('language');
  document.getElementById('subtitle').textContent = t('subtitle');
  document.getElementById('label-day').textContent = t('totalToday');
  document.getElementById('label-month').textContent = t('totalMonth');
  document.getElementById('label-year').textContent = t('totalYear');
  document.getElementById('tab-day').textContent = t('day');
  document.getElementById('tab-month').textContent = t('month');
  document.getElementById('tab-year').textContent = t('year');
  document.getElementById('th-period').textContent = t('period');
  document.getElementById('th-total').textContent = t('total');
  document.getElementById('th-visual').textContent = t('visual');
}

function applyTheme() {
  document.documentElement.setAttribute('data-theme', state.theme);
  document.getElementById('theme').value = state.theme;
}

function renderKpis() {
  document.getElementById('kpi-day').textContent = fmtGiB(state.info.today_total_gib);
  document.getElementById('kpi-month').textContent = fmtGiB(state.info.month_total_gib);
  document.getElementById('kpi-year').textContent = fmtGiB(state.info.year_total_gib);
}

function renderRows() {
  const rows = state.rows[state.activeTab] || [];
  const tbody = document.getElementById('rows');
  const maxTotal = Math.max(0, ...rows.map(r => r.total_gib));
  tbody.innerHTML = '';

  rows.forEach(r => {
    const pct = maxTotal > 0 ? (r.total_gib / maxTotal) * 100 : 0;
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>${r.period}</td>
      <td class="num">${r.total_gib.toFixed(3)}</td>
      <td class="num">${r.rx_gib.toFixed(3)}</td>
      <td class="num">${r.tx_gib.toFixed(3)}</td>
      <td><div class="bar-wrap"><div class="bar" style="width:${pct.toFixed(2)}%"></div></div></td>
    `;
    tbody.appendChild(tr);
  });

  const samples = state.info.samples || '0';
  const updated = state.info.updated_local || '-';
  const activeLabel = t(TAB_LABEL_KEY[state.activeTab] || state.activeTab);
  document.getElementById('meta').textContent = `${t('tab')}: ${activeLabel} | ${t('samples')}: ${samples} | ${t('lastUpdate')}: ${updated}`;
}

function setActiveTab(tab) {
  state.activeTab = tab;
  document.querySelectorAll('.tab').forEach(btn => btn.classList.toggle('active', btn.dataset.tab === tab));
  renderRows();
}

function setLanguage(lang) {
  state.lang = (lang === 'ro') ? 'ro' : 'en';
  localStorage.setItem('mtm_lang', state.lang);
  applyLanguage();
  renderRows();
}

function setTheme(theme) {
  state.theme = (theme === 'dark') ? 'dark' : 'light';
  localStorage.setItem('mtm_theme', state.theme);
  applyTheme();
}

async function loadAll() {
  const q = `?_=${Date.now()}`;
  const [d, m, y, i] = await Promise.all([
    fetch('/day.csv' + q).then(r => r.text()),
    fetch('/month.csv' + q).then(r => r.text()),
    fetch('/year.csv' + q).then(r => r.text()),
    fetch('/info.txt' + q).then(r => r.text())
  ]);

  state.rows.day = parseCsv(d);
  state.rows.month = parseCsv(m);
  state.rows.year = parseCsv(y);
  state.info = parseInfo(i);

  renderKpis();
  renderRows();
}

const storedLang = localStorage.getItem('mtm_lang');
const storedTheme = localStorage.getItem('mtm_theme');
state.lang = (storedLang === 'ro') ? 'ro' : 'en';
state.theme = (storedTheme === 'dark') ? 'dark' : 'light';
applyTheme();
applyLanguage();
document.getElementById('meta').textContent = t('loading');
document.getElementById('theme').addEventListener('change', (e) => setTheme(e.target.value));
document.getElementById('lang').addEventListener('change', (e) => setLanguage(e.target.value));
document.querySelectorAll('.tab').forEach(btn => btn.addEventListener('click', () => setActiveTab(btn.dataset.tab)));
loadAll().catch(e => { document.getElementById('meta').textContent = `${t('loadError')}: ${e}`; });
setInterval(() => { loadAll().catch(() => {}); }, 60000);
</script>
</body>
</html>
HTML
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
  BASE="$WWW" IFINDEX_ENV="$IFINDEX" python3 - <<'PY'
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

info = load_info()
day = load_csv("day.csv")
month = load_csv("month.csv")
year = load_csv("year.csv")

summary = {
    "updated_local": info.get("updated_local", ""),
    "samples": int(to_num(info.get("samples", "0"))),
    "kpi": {
        "today_total_gib": to_num(info.get("today_total_gib", "0")),
        "month_total_gib": to_num(info.get("month_total_gib", "0")),
        "year_total_gib": to_num(info.get("year_total_gib", "0")),
    },
    "interface": {"ifindex": os.environ.get("IFINDEX_ENV", "")},
    "windows": {"day": "90d", "month": "24m", "year": "5y"},
    "endpoints": {
        "day": "/api/day.json",
        "month": "/api/month.json",
        "year": "/api/year.json",
        "summary": "/api/summary.json",
    },
}

(api / "day.json").write_text(json.dumps(day, indent=2), encoding="utf-8")
(api / "month.json").write_text(json.dumps(month, indent=2), encoding="utf-8")
(api / "year.json").write_text(json.dumps(year, indent=2), encoding="utf-8")
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
          - month_total_gib
          - year_total_gib
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
    WHERE ts >= strftime('%s','now','localtime','start of day','-89 days','utc')
    GROUP BY period
    ORDER BY period DESC
    LIMIT 90;
  " > "$WWW/day.csv"

  sqlite3 -header -csv "$DB" "
    SELECT strftime('%Y-%m', ts,'unixepoch','localtime') AS period,
           ROUND(SUM(delta_bytes)/1073741824.0, 3) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 3) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 3) AS tx_gib
    FROM samples
    WHERE ts >= strftime('%s','now','localtime','start of month','-23 months','utc')
    GROUP BY period
    ORDER BY period DESC
    LIMIT 24;
  " > "$WWW/month.csv"

  sqlite3 -header -csv "$DB" "
    SELECT strftime('%Y', ts,'unixepoch','localtime') AS period,
           ROUND(SUM(delta_bytes)/1073741824.0, 3) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 3) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 3) AS tx_gib
    FROM samples
    WHERE ts >= strftime('%s','now','localtime','start of year','-4 years','utc')
    GROUP BY period
    ORDER BY period DESC
    LIMIT 5;
  " > "$WWW/year.csv"

  cp "$WWW/day.csv" "$WWW/daily.csv"

  TODAY_TOTAL_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of day','utc');")"
  MONTH_TOTAL_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of month','utc');")"
  YEAR_TOTAL_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_bytes)/1073741824.0,3),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of year','utc');")"
  SAMPLES="$(sqlite_exec "SELECT COUNT(*) FROM samples;")"
  UPDATED_LOCAL="$(date '+%Y-%m-%d %H:%M:%S %Z')"

  {
    echo "today_total_gib=$TODAY_TOTAL_GIB"
    echo "month_total_gib=$MONTH_TOTAL_GIB"
    echo "year_total_gib=$YEAR_TOTAL_GIB"
    echo "samples=$SAMPLES"
    echo "updated_local=$UPDATED_LOCAL"
  } > "$WWW/info.txt"

  render_api
}

write_ui
init_db
python3 -m http.server "$HTTP_PORT" --directory "$WWW" >/dev/null 2>&1 &
render_views

while true; do
  TS="$(date +%s)"
  IN="$(snmpget -v2c -c "$MT_COMMUNITY" -Oqv "$MT_HOST" "1.3.6.1.2.1.31.1.1.1.6.$IFINDEX" 2>/dev/null || true)"
  OUT="$(snmpget -v2c -c "$MT_COMMUNITY" -Oqv "$MT_HOST" "1.3.6.1.2.1.31.1.1.1.10.$IFINDEX" 2>/dev/null || true)"

  case "$IN" in ''|*[!0-9]*) sleep "$POLL_SEC"; continue ;; esac
  case "$OUT" in ''|*[!0-9]*) sleep "$POLL_SEC"; continue ;; esac

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
  sleep "$POLL_SEC"
done
