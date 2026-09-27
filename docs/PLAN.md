# Feature Parity Plan

Maps every page of the Bambuddy web UI (v1.2.5.5) to a native screen.
Status: ✅ done · 🚧 in progress · ⏳ planned · ➖ not applicable on iOS

| Web page / feature | Native screen | Status |
|---|---|---|
| Server connection, `/setup`, `/login` (local, 2FA, OIDC, forgot password) | Onboarding | ✅ connection verified; auth flows implemented but untested (test server has auth disabled) |
| **Printers** `/` — cards, live status, progress, temps, AMS, HMS | Printers | ✅ |
| Printer controls — pause/resume/stop, speed, fans, light, jog/home, airduct, extruder, AI options | Printer detail | ✅ |
| AMS — load/unload, RFID refresh, reset slot, drying, backup | Printer detail | ✅ |
| Add / edit / delete printer, test connection, discovery (SSDP & subnet scan) | Printer edit | ✅ |
| Camera (MJPEG + snapshot fallback), full-screen, `/camwall` | Camera | ✅ |
| AMS slot configuration (filament preset, K-profile) | Printer → slot | 🚧 |
| Printer file manager (SD card browse / download / delete / print) | Printer → Files | 🚧 |
| Skip objects, K-profiles, plate detection, smart plug, AMS history, sensor history, diagnostics | Printer → More | 🚧 |
| **Archives** `/archives` — list, search, filters, detail, reprint, timelapse, photos, notes, tags, compare | Archives | 🚧 |
| **Queue** `/queue` — queue list, reorder, add, edit, start, pipelines & runs | Queue | 🚧 |
| **Projects** `/projects`, `/projects/:id` | Projects | 🚧 |
| **Inventory** `/inventory` — spools, filaments, assignments, forecasts, Spoolman | Inventory | 🚧 |
| **Files** `/files`, `/files/trash` — library, folders, upload, print, trash | Files | 🚧 |
| **MakerWorld** `/makerworld` — resolve URL, import | MakerWorld | 🚧 |
| **Profiles** `/profiles` — cloud, local, Orca cloud, K-profiles | Profiles | 🚧 |
| **Maintenance** `/maintenance` | Maintenance | 🚧 |
| **Statistics** `/stats` | Statistics (Swift Charts) | 🚧 |
| **Finance** `/finance` | Finance | 🚧 |
| **Notifications** `/notifications` — per-user email preferences | Notifications | 🚧 |
| **System** `/system` — system info, logs, support bundle | System | 🚧 |
| **Settings** `/settings` — general, notifications providers & templates, smart plugs, virtual printers, backups (local/GitHub), API keys, camera tokens, users & groups, external links, Home Assistant, Spoolman, Obico, cloud accounts, updates | Settings | 🚧 |
| **SpoolBuddy** `/spoolbuddy/*` — kiosk dashboard, AMS, write tag, inventory, calibration | SpoolBuddy | 🚧 |
| External links `/external/:id` | Links section (in-app Safari) | ✅ |
| G-code viewer `/gcode-viewer` (3D toolpath preview) | G-code viewer (Metal) | 🚧 |
| Stream overlay `/overlay/:id` (OBS browser source) | — | ➖ skipped (not useful on iOS) |
| Keyboard shortcuts modal | iPad hardware-keyboard shortcuts (⌘1–9, ⌘,) | ✅ |

## Testing notes

Verified live on a P1S (2026-09-26): chamber light, part fan, bed & nozzle temperature targets,
home all, XY jog, bed jog, HMS clear, and AMS RFID refresh (server correctly refuses while the
external spool is loaded). Not exercised live: pause/resume/stop (implemented against the API),
extruder jog and AMS load/unload (printer had a jammed extruder), and anything that starts a print.
