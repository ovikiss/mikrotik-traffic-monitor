# Changelog

All notable changes to the MikroTik Traffic Monitor project will be documented in this file.

## [0.8.2] - 2026-05-27
### Changed
- **Unified Table Structure Across All Themes**: Removed the custom Glass theme table headers and row formatting (including the `STATUS` column, which has been completely removed as it served no functional purpose for traffic records). All themes now share the exact same clean table layout, column names, translations, and ordering (`Period`, `Total`, `RX (Download)`, `TX (Upload)`, and `Visual` progress bar), styled beautifully with Glass aesthetics when active.

## [0.8.1] - 2026-05-27
### Fixed
- **Top-Aligned Vertical Expansion**: Repositioned the entire floating glass panel to align to the top of the viewport (`justify-content: flex-start` on body, with a comfortable top margin) instead of centering vertically. This prevents the topbar/dashboard from jumping vertically as table groups are expanded or collapsed, keeping the header fixed at the top while the interface grows naturally downwards.

## [0.8.0] - 2026-05-27
### Fixed
- **Pure Smoky Lead Gray Color Palette**: Replaced all custom property dark variables in the Glass theme with completely neutral zinc and smoky lead grays, eliminating the bluish/indigo tint from the main panel face and text labels.
- **Backdrop-Blur Saturation Muted**: Reduced `saturate` on backdrop-filter to `1.15` (down from `1.7`) to prevent any vibrant blue/cyan colors from the background wallpaper bleeding into the glass panels, achieving a beautiful frosted lead-gray glass look.
- **Monochromatic Progress Bars**: Added `!important` to the matte silver-white relative progress bar gradient styling, successfully overriding the inline theme styles in JavaScript to render the progress bars in elegant monochromatic silver-white, matching the mockup 100%.

## [0.7.9] - 2026-05-27
### Fixed
- **Dynamic Table Header Translation**: Resolved an issue where the Glass theme table header columns (`DATE`, `DOWNLOAD`, `UPLOAD`, `TOTAL`, `STATUS`, `& PROGRESS`) were hardcoded in English. They are now dynamically translated using the localization system (e.g. `DATA`, `DESCĂRCARE`, `ÎNCĂRCARE`, `TOTAL`, `STATUS`, `& PROGRES` in Romanian) and correctly formatted in uppercase to match the design aesthetics.

## [0.7.8] - 2026-05-27
### Added
- **Pulsing Radio Wave Status Icon**: Implemented a highly-detailed SVG wireframe pulsing signal wave `((•))` under the `STATUS` column in the Glass theme, replacing the simple solid green dot.
- **Sparklines Redesign (Bar & Waves)**: Overhauled inline SVG sparkline drawing to render high-fidelity, prominent SVGs (110x36px). "Total Today" displays an elegant 8-bar rounded histogram filled with a white-to-silver gradient, while "Current Month" and "Current Year" render smooth horizontal-tangent cubic bezier curves with gradient area fills. Array padding was added to prevent empty sparklines on fresh databases.
- **Stacked KPI Sub-items**: Reorganized "RX" and "TX" to stack vertically and display user-friendly translated labels "Download" and "Upload", hiding the visual text separators in the Glass theme.

### Fixed
- **Wavy Background Wallpaper**: Loaded the actual high-fidelity wavy abstract dark slate wallpaper (`bg-glass.jpg`) on the `html` element of the page.
- **Glassy Dropdowns & Controls**: Redesigned all topbar controls and dropdown toggles to have custom border-radius, backdrop-blur, and white-silver semi-transparent borders for a premium, frosted glassy appearance.
- **Double-Layering Fix**: Removed the secondary card background and border around the main table grid so it floats directly on the outer glass container, resolving panel layering issues.
- **Translucent Pill Tabs**: Upgraded tabs with semi-transparent borders and glassy light overlays.

## [0.7.6] - 2026-05-27
### Fixed
- **Color Accuracy**: Adjusted card background opacity and colors to use the exact warm slate-blue/charcoal tint (`rgba(28, 35, 51, 0.45)`) from the approved mockup.
- **Muted Progress Bars**: Set relative traffic progress indicators to a sophisticated, non-strident slate-blue color (`#5c6e88`).
- **Pulsing Status Dots & Sparklines**: Realigned colors to achieve absolute visual depth and harmony.

## [0.7.5] - 2026-05-27
### Fixed
- **HTML Nesting Bug**: Fixed a duplicate closing tag (`</div>`) after the topbar in `index.html` that caused `.dashboard-container` to close prematurely. The outer glass frame now correctly wraps the entire page (Topbar + Divider + Sidebar + Data Table) as a single centered floating panel on desktop, restoring the proper side-by-side layout.

## [0.7.4] - 2026-05-27
### Changed
- **Topbar Controls Labels**: Restored the visibility of descriptive text labels (`Temă`, `Mod`, `Mărime font`, `Interval`, `Limbă`) in the Glass theme, maintaining exact visual and functional parity with Modern and Classic layouts.

## [0.7.3] - 2026-05-27
### Added
- **Enclosing Glass Container**: Implemented a floating, outer glass frame (`.dashboard-container`) wrapping the entire dashboard.
- **Dynamic Live Sparklines**: Added inline SVG sparkline trend charts inside the KPI cards, dynamically drawing the last 10 days, months, or years of traffic directly from your live database.
- **Rearranged Table Columns**: Custom table column layout specifically for the Glass Dashboard theme: `DATE` | `DOWNLOAD` | `UPLOAD` | `TOTAL` | `STATUS` (live pulsing emerald dot) | `& PROGRESS` (thin muted bar).
### Changed
- Both Classic and Modern themes styled with reset blocks to be completely untouched by the new enclosing container.

## [0.7.1] - 2026-05-27
### Added
- **Minimalist Glass Dashboard Style**: Introduced the third theme option with an alternative side-by-side responsive layout (KPI sidebar on the left, table on the right).

## [0.6.1] - 2026-05-26
### Fixed
- **Hotfix for Container Crash**: Restored the missing `render_views` function in `mt-traffic.sh` which was accidentally dropped during the Go server migration. This prevents container startup crashes (exit status 127).

## [0.6.0] - 2026-05-26
### Added
- **High-Performance Go Server**: Replaced Python with a compiled static Go web server (`server.go`), reducing idle RAM from ~30MB to ~2MB.
- **Native SQLite JSON API**: Migrated CSV-to-JSON parsing directly inside SQLite using native JSON functions, reducing page generation time to <1ms.
- **Multi-Stage Build**: Reduced container size from ~85MB to <15MB by removing Python dependencies.

## [0.5.0] - 2026-05-16
### Added
- Native SQLite window functions and sleep loop optimisations.
