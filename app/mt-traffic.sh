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

LAST_SETTINGS_MOD=""
LAST_POLL_INTERVAL=""

read_runtime_poll_interval() {
  if [ ! -f "$SETTINGS_PATH" ]; then
    return 1
  fi

  MOD_TIME="$(stat -c %Y "$SETTINGS_PATH" 2>/dev/null || echo "")"
  if [ -n "$MOD_TIME" ] && [ "$MOD_TIME" = "$LAST_SETTINGS_MOD" ]; then
    if [ -n "$LAST_POLL_INTERVAL" ]; then
      printf '%s\n' "$LAST_POLL_INTERVAL"
      return 0
    fi
  fi

  V="$(sed -n 's/.*"poll_interval"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SETTINGS_PATH" 2>/dev/null || true)"
  if [ -n "$V" ]; then
    LAST_SETTINGS_MOD="$MOD_TIME"
    LAST_POLL_INTERVAL="$V"
    printf '%s\n' "$V"
    return 0
  fi
  return 1
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
# Static UI assets are served from /app/www. Keep /data/www for generated files only.
rm -rf "$WWW/index.html" "$WWW/images" "$WWW/common" "$WWW/i18n"
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
  # Verificăm dacă este nevoie de backfill
  NEED_BACKFILL="$(sqlite_exec "SELECT COUNT(*) FROM samples WHERE delta_in_bytes IS NULL OR delta_out_bytes IS NULL;")"
  if [ "$NEED_BACKFILL" = "0" ]; then
    return 0
  fi

  # Executăm actualizarea bulk în mod ultra-rapid într-o singură tranzacție
  sqlite_exec "
    WITH lagged AS (
      SELECT id,
             in_octets,
             out_octets,
             LAG(in_octets) OVER (ORDER BY id) as prev_in,
             LAG(out_octets) OVER (ORDER BY id) as prev_out
      FROM samples
    )
    UPDATE samples
    SET delta_in_bytes = CASE WHEN prev_in IS NULL THEN 0 WHEN samples.in_octets >= prev_in THEN samples.in_octets - prev_in ELSE samples.in_octets END,
        delta_out_bytes = CASE WHEN prev_out IS NULL THEN 0 WHEN samples.out_octets >= prev_out THEN samples.out_octets - prev_out ELSE samples.out_octets END,
        delta_bytes = (CASE WHEN prev_in IS NULL THEN 0 WHEN samples.in_octets >= prev_in THEN samples.in_octets - prev_in ELSE samples.in_octets END) +
                      (CASE WHEN prev_out IS NULL THEN 0 WHEN samples.out_octets >= prev_out THEN samples.out_octets - prev_out ELSE samples.out_octets END)
    FROM lagged
    WHERE samples.id = lagged.id
      AND (samples.delta_in_bytes IS NULL OR samples.delta_out_bytes IS NULL);
  "
}

render_api() {
  mkdir -p "$WWW/api"

  # Generate day.json
  sqlite3 "$DB" "
    SELECT json_group_array(
      json_object(
        'period', period,
        'total_gib', total_gib,
        'rx_gib', rx_gib,
        'tx_gib', tx_gib
      )
    )
    FROM (
      SELECT date(ts,'unixepoch','localtime') AS period,
             ROUND(SUM(delta_bytes)/1073741824.0, 2) AS total_gib,
             ROUND(SUM(delta_in_bytes)/1073741824.0, 2) AS rx_gib,
             ROUND(SUM(delta_out_bytes)/1073741824.0, 2) AS tx_gib
      FROM samples
      WHERE ts >= strftime('%s','now','localtime','start of month','utc')
      GROUP BY period
      ORDER BY period DESC
      LIMIT 31
    );
  " > "$WWW/api/day.json"

  # Generate month.json
  sqlite3 "$DB" "
    SELECT json_group_array(
      json_object(
        'period', period,
        'total_gib', total_gib,
        'rx_gib', rx_gib,
        'tx_gib', tx_gib
      )
    )
    FROM (
      SELECT strftime('%Y-%m', ts,'unixepoch','localtime') AS period,
             ROUND(SUM(delta_bytes)/1073741824.0, 2) AS total_gib,
             ROUND(SUM(delta_in_bytes)/1073741824.0, 2) AS rx_gib,
             ROUND(SUM(delta_out_bytes)/1073741824.0, 2) AS tx_gib
      FROM samples
      WHERE ts >= strftime('%s','now','localtime','start of year','utc')
      GROUP BY period
      ORDER BY period DESC
      LIMIT 12
    );
  " > "$WWW/api/month.json"

  # Generate year.json
  sqlite3 "$DB" "
    SELECT json_group_array(
      json_object(
        'period', period,
        'total_gib', total_gib,
        'rx_gib', rx_gib,
        'tx_gib', tx_gib
      )
    )
    FROM (
      SELECT strftime('%Y', ts,'unixepoch','localtime') AS period,
             ROUND(SUM(delta_bytes)/1073741824.0, 2) AS total_gib,
             ROUND(SUM(delta_in_bytes)/1073741824.0, 2) AS rx_gib,
             ROUND(SUM(delta_out_bytes)/1073741824.0, 2) AS tx_gib
      FROM samples
      WHERE ts >= 0
      GROUP BY period
      ORDER BY period DESC
    );
  " > "$WWW/api/year.json"

  # Generate month_days.json
  sqlite3 "$DB" "
    SELECT json_group_array(
      json_object(
        'period', period,
        'month_key', month_key,
        'total_gib', total_gib,
        'rx_gib', rx_gib,
        'tx_gib', tx_gib
      )
    )
    FROM (
      SELECT date(ts,'unixepoch','localtime') AS period,
             strftime('%Y-%m', ts,'unixepoch','localtime') AS month_key,
             ROUND(SUM(delta_bytes)/1073741824.0, 2) AS total_gib,
             ROUND(SUM(delta_in_bytes)/1073741824.0, 2) AS rx_gib,
             ROUND(SUM(delta_out_bytes)/1073741824.0, 2) AS tx_gib
      FROM samples
      WHERE ts >= strftime('%s','now','localtime','start of year','utc')
      GROUP BY period
      ORDER BY period DESC
    );
  " > "$WWW/api/month_days.json"

  # Generate year_months.json
  sqlite3 "$DB" "
    SELECT json_group_array(
      json_object(
        'period', period,
        'year_key', year_key,
        'total_gib', total_gib,
        'rx_gib', rx_gib,
        'tx_gib', tx_gib
      )
    )
    FROM (
      SELECT strftime('%Y-%m', ts,'unixepoch','localtime') AS period,
             strftime('%Y', ts,'unixepoch','localtime') AS year_key,
             ROUND(SUM(delta_bytes)/1073741824.0, 2) AS total_gib,
             ROUND(SUM(delta_in_bytes)/1073741824.0, 2) AS rx_gib,
             ROUND(SUM(delta_out_bytes)/1073741824.0, 2) AS tx_gib
      FROM samples
      WHERE ts >= 0
      GROUP BY period
      ORDER BY period DESC
    );
  " > "$WWW/api/year_months.json"

  # Generate summary.json
  cat <<EOF > "$WWW/api/summary.json"
{
  "updated_local": "${UPDATED_LOCAL}",
  "samples": ${SAMPLES},
  "db_size_bytes": ${DB_SIZE_BYTES},
  "kpi": {
    "today_total_gib": ${TODAY_TOTAL_GIB},
    "today_rx_gib": ${TODAY_RX_GIB},
    "today_tx_gib": ${TODAY_TX_GIB},
    "month_total_gib": ${MONTH_TOTAL_GIB},
    "month_rx_gib": ${MONTH_RX_GIB},
    "month_tx_gib": ${MONTH_TX_GIB},
    "year_total_gib": ${YEAR_TOTAL_GIB},
    "year_rx_gib": ${YEAR_RX_GIB},
    "year_tx_gib": ${YEAR_TX_GIB}
  },
  "interface": {
    "ifindex": "${ACTIVE_IFINDEX}"
  },
  "poll": {
    "interval": "${ACTIVE_POLL_INTERVAL}",
    "seconds": ${POLL_SLEEP_SEC}
  },
  "windows": {
    "day": "current_month",
    "month": "current_year",
    "year": "all_years"
  },
  "endpoints": {
    "day": "/api/day.json",
    "month": "/api/month.json",
    "year": "/api/year.json",
    "month_days": "/api/month_days.json",
    "year_months": "/api/year_months.json",
    "summary": "/api/summary.json"
  }
}
EOF

  # Generate home_assistant_rest_example.yaml
  cat <<'EOF' > "$WWW/api/home_assistant_rest_example.yaml"
# Home Assistant example (REST sensor)
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
EOF
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
  DB_SIZE_BYTES="$(printf '%s' "$DB_SIZE_BYTES" | tr -cd '0-9')"
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
  SETTINGS_PATH_ENV="$SETTINGS_PATH" WWW_DIR="$WWW" STATIC_DIR_ENV="$SCRIPT_DIR" HTTP_PORT_ENV="$HTTP_PORT" EFFECTIVE_POLL_INTERVAL_ENV="$ACTIVE_POLL_INTERVAL" "$SCRIPT_DIR/server" &
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
