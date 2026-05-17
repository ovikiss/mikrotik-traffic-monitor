#!/bin/sh
set -eu

: "${MT_COMMUNITY:?MT_COMMUNITY is required}"
: "${MT_HOST:=auto}"
: "${IFINDEX:=auto}"
: "${IFNAME_PATTERN:=pppoe}"
: "${POLL_INTERVAL:=1h}"
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
LAST_FORCED_SAMPLE_SLOT=""

default_gateway_ip() {
  [ -r /proc/net/route ] || return 1
  GW_HEX="$(awk '$2 == "00000000" { print $3; exit }' /proc/net/route 2>/dev/null || true)"
  case "$GW_HEX" in
    ????????) ;;
    *) return 1 ;;
  esac

  B1="$(printf '%s' "$GW_HEX" | cut -c7-8)"
  B2="$(printf '%s' "$GW_HEX" | cut -c5-6)"
  B3="$(printf '%s' "$GW_HEX" | cut -c3-4)"
  B4="$(printf '%s' "$GW_HEX" | cut -c1-2)"
  printf '%d.%d.%d.%d\n' "$((0x$B1))" "$((0x$B2))" "$((0x$B3))" "$((0x$B4))"
}

resolve_mt_host() {
  case "${MT_HOST:-auto}" in
    ''|auto|AUTO)
      DETECTED_MT_HOST="$(default_gateway_ip || true)"
      if [ -z "$DETECTED_MT_HOST" ]; then
        echo "MT_HOST auto-detect failed; set MT_HOST explicitly" >&2
        exit 1
      fi
      MT_HOST="$DETECTED_MT_HOST"
      ;;
  esac
}

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

  POLL_SLEEP_SEC="3600"
  ACTIVE_POLL_INTERVAL="1h"
}

forced_sample_slot_now() {
  HM="$(date '+%H%M')"
  case "$HM" in
    2359|0001) date "+%Y-%m-%d-$HM" ;;
    *) return 1 ;;
  esac
}

has_pending_forced_sample() {
  SLOT="$(forced_sample_slot_now || true)"
  [ -n "$SLOT" ] || return 1
  [ "$SLOT" != "$LAST_FORCED_SAMPLE_SLOT" ] || return 1
  return 0
}

mark_forced_sample_slot() {
  SLOT="$(forced_sample_slot_now || true)"
  [ -n "$SLOT" ] || return 0
  LAST_FORCED_SAMPLE_SLOT="$SLOT"
}

sleep_poll_interval() {
  TARGET="$POLL_SLEEP_SEC"
  ELAPSED=0
  while [ "$ELAPSED" -lt "$TARGET" ]; do
    if has_pending_forced_sample; then
      break
    fi

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
    if has_pending_forced_sample; then
      break
    fi

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

prepare_data_dir() {
mkdir -p "$WWW"
# Static UI assets are served from /app. Keep /data/www for generated files only.
rm -rf "$WWW/index.html" "$WWW/images" "$WWW/i18n"
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
        json_attributes:
          - updated_local
          - samples
          - db_size_bytes
          - kpi
          - interface
          - poll

template:
  - sensor:
      - name: "MikroTik Traffic Today"
        unique_id: mikrotik_traffic_today
        unit_of_measurement: "GiB"
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'kpi').today_total_gib | float(0) | round(2) }}"
      - name: "MikroTik Traffic Today RX"
        unique_id: mikrotik_traffic_today_rx
        unit_of_measurement: "GiB"
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'kpi').today_rx_gib | float(0) | round(2) }}"
      - name: "MikroTik Traffic Today TX"
        unique_id: mikrotik_traffic_today_tx
        unit_of_measurement: "GiB"
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'kpi').today_tx_gib | float(0) | round(2) }}"
      - name: "MikroTik Traffic Month"
        unique_id: mikrotik_traffic_month
        unit_of_measurement: "GiB"
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'kpi').month_total_gib | float(0) | round(2) }}"
      - name: "MikroTik Traffic Month RX"
        unique_id: mikrotik_traffic_month_rx
        unit_of_measurement: "GiB"
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'kpi').month_rx_gib | float(0) | round(2) }}"
      - name: "MikroTik Traffic Month TX"
        unique_id: mikrotik_traffic_month_tx
        unit_of_measurement: "GiB"
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'kpi').month_tx_gib | float(0) | round(2) }}"
      - name: "MikroTik Traffic Year"
        unique_id: mikrotik_traffic_year
        unit_of_measurement: "GiB"
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'kpi').year_total_gib | float(0) | round(2) }}"
      - name: "MikroTik Traffic Year RX"
        unique_id: mikrotik_traffic_year_rx
        unit_of_measurement: "GiB"
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'kpi').year_rx_gib | float(0) | round(2) }}"
      - name: "MikroTik Traffic Year TX"
        unique_id: mikrotik_traffic_year_tx
        unit_of_measurement: "GiB"
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'kpi').year_tx_gib | float(0) | round(2) }}"
      - name: "MikroTik Traffic Samples"
        unique_id: mikrotik_traffic_samples
        unit_of_measurement: "samples"
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'samples') | int(0) }}"
      - name: "MikroTik DB Size"
        unique_id: mikrotik_traffic_db_size
        unit_of_measurement: "MB"
        state: "{{ ((state_attr('sensor.mikrotik_traffic_summary', 'db_size_bytes') | float(0)) / 1048576) | round(2) }}"
      - name: "MikroTik DB Size Bytes"
        unique_id: mikrotik_traffic_db_size_bytes
        unit_of_measurement: "B"
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'db_size_bytes') | int(0) }}"
      - name: "MikroTik Poll Interval"
        unique_id: mikrotik_traffic_poll_interval
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'poll').interval | default('unknown', true) }}"
      - name: "MikroTik Last Update"
        unique_id: mikrotik_traffic_last_update
        state: "{{ state_attr('sensor.mikrotik_traffic_summary', 'updated_local') | default('unknown', true) }}"
'''
(api / "home_assistant_rest_example.yaml").write_text(ha, encoding="utf-8")
PY
}

render_views() {
  sqlite3 -header -csv "$DB" "
    SELECT date(ts,'unixepoch','localtime') AS period,
           ROUND(SUM(delta_bytes)/1073741824.0, 2) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 2) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 2) AS tx_gib
    FROM samples
    WHERE ts >= strftime('%s','now','localtime','start of month','utc')
    GROUP BY period
    ORDER BY period DESC
    LIMIT 31;
  " > "$WWW/day.csv"

  sqlite3 -header -csv "$DB" "
    SELECT strftime('%Y-%m', ts,'unixepoch','localtime') AS period,
           ROUND(SUM(delta_bytes)/1073741824.0, 2) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 2) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 2) AS tx_gib
    FROM samples
    WHERE ts >= strftime('%s','now','localtime','start of year','utc')
    GROUP BY period
    ORDER BY period DESC
    LIMIT 12;
  " > "$WWW/month.csv"

  sqlite3 -header -csv "$DB" "
    SELECT strftime('%Y', ts,'unixepoch','localtime') AS period,
           ROUND(SUM(delta_bytes)/1073741824.0, 2) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 2) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 2) AS tx_gib
    FROM samples
    WHERE ts >= 0
    GROUP BY period
    ORDER BY period DESC;
  " > "$WWW/year.csv"

  sqlite3 -header -csv "$DB" "
    SELECT date(ts,'unixepoch','localtime') AS period,
           strftime('%Y-%m', ts,'unixepoch','localtime') AS month_key,
           ROUND(SUM(delta_bytes)/1073741824.0, 2) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 2) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 2) AS tx_gib
    FROM samples
    WHERE ts >= strftime('%s','now','localtime','start of year','utc')
    GROUP BY period
    ORDER BY period DESC;
  " > "$WWW/month_days.csv"

  sqlite3 -header -csv "$DB" "
    SELECT strftime('%Y-%m', ts,'unixepoch','localtime') AS period,
           strftime('%Y', ts,'unixepoch','localtime') AS year_key,
           ROUND(SUM(delta_bytes)/1073741824.0, 2) AS total_gib,
           ROUND(SUM(delta_in_bytes)/1073741824.0, 2) AS rx_gib,
           ROUND(SUM(delta_out_bytes)/1073741824.0, 2) AS tx_gib
    FROM samples
    WHERE ts >= 0
    GROUP BY period
    ORDER BY period DESC;
  " > "$WWW/year_months.csv"

  cp "$WWW/day.csv" "$WWW/daily.csv"

  TODAY_TOTAL_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_bytes)/1073741824.0,2),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of day','utc');")"
  TODAY_RX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_in_bytes)/1073741824.0,2),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of day','utc');")"
  TODAY_TX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_out_bytes)/1073741824.0,2),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of day','utc');")"
  MONTH_TOTAL_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_bytes)/1073741824.0,2),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of month','utc');")"
  MONTH_RX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_in_bytes)/1073741824.0,2),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of month','utc');")"
  MONTH_TX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_out_bytes)/1073741824.0,2),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of month','utc');")"
  YEAR_TOTAL_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_bytes)/1073741824.0,2),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of year','utc');")"
  YEAR_RX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_in_bytes)/1073741824.0,2),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of year','utc');")"
  YEAR_TX_GIB="$(sqlite_exec "SELECT COALESCE(ROUND(SUM(delta_out_bytes)/1073741824.0,2),0) FROM samples WHERE ts >= strftime('%s','now','localtime','start of year','utc');")"
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
  WWW_DIR="$WWW" STATIC_DIR_ENV="$SCRIPT_DIR" HTTP_PORT_ENV="$HTTP_PORT" SETTINGS_PATH_ENV="$SETTINGS_PATH" EFFECTIVE_POLL_INTERVAL_ENV="$ACTIVE_POLL_INTERVAL" python3 - <<'PY' &
import json
import os
from urllib.parse import unquote, urlsplit
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

www = Path(os.environ["WWW_DIR"]).resolve()
static_root = Path(os.environ["STATIC_DIR_ENV"]).resolve()
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


def safe_join(root, rel):
    root = Path(root).resolve()
    target = (root / rel).resolve()
    if target == root or root in target.parents:
        return target
    return None


class Handler(SimpleHTTPRequestHandler):
    # Silence per-request access logs in RouterOS container logs.
    def log_message(self, format, *args):
        return

    def _send_json(self, code, payload):
        b = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _serve_file(self, path, cache_static=False, send_body=True):
        if not path or not path.is_file():
            self.send_error(404, "File not found")
            return
        try:
            data = path.read_bytes()
        except OSError:
            self.send_error(404, "File not found")
            return

        self.send_response(200)
        self.send_header("Content-Type", self.guess_type(str(path)))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=3600" if cache_static else "no-store")
        self.end_headers()
        if send_body:
            self.wfile.write(data)

    def _static_or_generated_path(self):
        path = unquote(urlsplit(self.path).path)
        if path in ("", "/"):
            return safe_join(static_root, "www/index.html"), True
        if path == "/index.html":
            return safe_join(static_root, "www/index.html"), True
        if path.startswith("/images/"):
            return safe_join(static_root, path.lstrip("/")), True
        if path.startswith("/i18n/"):
            return safe_join(static_root, path.lstrip("/")), True
        if path.startswith("/api/"):
            return safe_join(www, path.lstrip("/")), False
        if path in (
            "/day.csv",
            "/month.csv",
            "/year.csv",
            "/daily.csv",
            "/month_days.csv",
            "/year_months.csv",
            "/info.txt",
        ):
            return safe_join(www, path.lstrip("/")), False
        return None, False

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

        path, cache_static = self._static_or_generated_path()
        self._serve_file(path, cache_static=cache_static)

    def do_HEAD(self):
        path, cache_static = self._static_or_generated_path()
        self._serve_file(path, cache_static=cache_static, send_body=False)

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

prepare_data_dir
init_db
resolve_poll_interval
resolve_mt_host
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
  mark_forced_sample_slot
  sqlite_exec "DELETE FROM samples WHERE ts < strftime('%s','now','-1825 days');"

  render_views
  sleep_poll_interval
done
