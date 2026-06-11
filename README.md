# MikroTik Traffic Monitor

MikroTik Traffic Monitor is a lightweight Go container for RouterOS that polls interface traffic through SNMP, stores historical counters in SQLite, and serves a polished local dashboard with shared theming and translations.

Current release: `v0.5.5`

## Highlights
- Low-footprint Go runtime optimized for MikroTik container environments.
- SNMP-based WAN/interface polling with persistent SQLite storage in `/data`.
- Day / Month / Year aggregation dashboard.
- Shared UI system via `mikrotik-ui-shared`:
  - shared header, menus, logos, translations, CSS, and theme assets
  - dynamic theme catalog support for future shared themes
  - consistent `Modern`, `Classic`, and `Glass` presentation
- Settings persistence for:
  - theme
  - theme style
  - language
  - font size
  - poll interval
- RouterOS-friendly install flow with:
  - managed `veth`
  - managed SNMP community scoped to the container IP
  - managed NAT rule for the dashboard
- USB-friendly persistent storage model for historical data and settings.

## Repository Layout
- `app/server.go`
  Go web server for settings APIs and static file delivery.
- `app/www/app.js`
  Frontend dashboard logic, charts, settings persistence, and shared header integration.
- `scripts/sync-ui-shared.sh`
  Pulls shared UI assets from `mikrotik-ui-shared`.
- `mikrotik/install.rsc`
  RouterOS install and redeploy script.
- `scripts/install-to-router.sh`
  Helper that builds, pushes, uploads, imports, and removes stale install scripts from the router.
- `homeassistant/`
  Home Assistant integration examples.

## Local Build
```bash
docker build -t ghcr.io/ovikiss/mikrotik-traffic-monitor:local .
```

If you are working outside Docker, sync shared assets first:

```bash
./scripts/sync-ui-shared.sh
```

## Local Run
```bash
docker run --rm -p 8088:8088 \
  -e MT_COMMUNITY=trafficdb \
  -e IFINDEX=auto \
  -e IFNAME_PATTERN=pppoe \
  -e POLL_INTERVAL=1h \
  -e HTTP_PORT=8088 \
  -e DATA_DIR=/data \
  -v "$PWD/data:/data" \
  ghcr.io/ovikiss/mikrotik-traffic-monitor:local
```

## MikroTik Install
1. Edit the variables at the top of `mikrotik/install.rsc`:
   - `mtmImage`
   - `mtmDataPath`
   - `mtmRootDir`
   - `mtmVeth`
   - `mtmIfIndex`
   - `mtmIfNamePattern`
   - `mtmPollInterval`
   - `mtmSnmpCommunity`
   - `mtmHttpLanPort`
2. Run the helper:

```bash
./scripts/install-to-router.sh admin@192.168.88.1
```

Manual alternative:

```bash
scp mikrotik/install.rsc admin@192.168.88.1:install-traffic-monitor.rsc
ssh admin@192.168.88.1 '/import file-name=install-traffic-monitor.rsc'
```

Default dashboard endpoint:
- `http://<router-lan-ip>:8088/`

## Runtime Notes
- Runtime is a single compiled Go server plus generated static assets.
- Shared theme assets are synced from `mikrotik-ui-shared` during builds.
- Poll interval settings are persisted in `settings.json`.
- Historical samples and SQLite database stay in `/data`, recommended on USB storage.
- The install script scopes the SNMP community to the actual runtime container IP and keeps a single NAT rule with comment `trafficdb-gui`.

## Trademark Notice
MikroTik name and logo are official trademarks of MikroTik.
