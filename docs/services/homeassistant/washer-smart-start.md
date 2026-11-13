# Home Assistant — Washer Smart-Start

Part of [Home Assistant](README.md).

Automations/templates live on the PVC, not in git (see [Configuration](README.md#configuration)). This doc describes the pattern, not the concrete entity dump.

---

## Goal

Start the washer automatically at the cheapest Tibber price window within the next 48 h, once remote control has been armed at the machine (program selected, door closed).

## Entities (`lg_thinq` core integration)

| Entity | Role |
|---|---|
| `binary_sensor.waschmaschine_fernstart` | Remote control armed at the machine |
| `sensor.waschmaschine_aktueller_status` | Enum; trigger state `initial` = program selected, waiting to start |
| `sensor.waschmaschine_gesamtdauer` | Selected program duration (minutes) |
| `select.waschmaschine_betrieb` | Options `start / stop / power_off / wake_up` — **direct remote start**, confirmed via source of `thinqconnect.devices.washer.WasherSubDevice.set_washer_operation_mode()` |
| `number.waschmaschine_verzogertes_ende` | Separate, coarser mechanism (`relativeHourToStop`, 1 h steps) — *not* used here; direct start via `select` is more precise (matches the Tibber 15-min slot grid) |

Known limitation: the integration does not expose program/course selection — it must be set at the machine itself before arming remote control.

## Price basis

Own `tibber.get_prices` call with explicit `start`/`end` (today 00:00 → +2 days) feeding `sensor.waschmaschine_preise_heute_und_morgen`, deliberately **separate** from `sensor.tibber_preise_heute` (used by the "08 Keller" dashboard's price overview) so that view stays untouched. Tibber publishes tomorrow's prices roughly 13:00–15:00; the hourly refresh (+1 min offset) picks it up once available.

## Calculation

`sensor.waschmaschine_gunstigste_startzeit` (timestamp): sliding window search over all **future** quarter-hour slots, window length = `ceil(gesamtdauer / 15min)`, lowest average price wins. Recalculated hourly, on price/duration change, and every 5 min.

## Automation

`Waschmaschine Smart-Start (günstigster Strompreis)`:

1. Trigger: `sensor.waschmaschine_aktueller_status` → `initial`, or `binary_sensor.waschmaschine_fernstart` → `on`
2. Condition: both must currently hold
3. `delay` until the computed target timestamp
4. Re-check the same condition (door may have been reopened / fernstart cancelled meanwhile)
5. `select.select_option` on `select.waschmaschine_betrieb` → `start`
6. Mobile push notification

## Dashboard

"08 Keller" (`dashboard_waschkuche`), Waschmaschine section: tile card showing `sensor.waschmaschine_gunstigste_startzeit` ("Geplanter Smart-Start"), purely additive next to the existing status/remaining-time/cycles tiles.

---

## Lessons learned (apply beyond this automation)

- **No browser session available for a one-off service call:** generate a temporary admin Long-Lived Access Token in the HA UI (Profile → Security), use it once against the REST API, then delete it. Never ask for or store a permanent token.
- **Lovelace storage dashboards (`.storage/lovelace.*`) must not be edited by overwriting the file on disk while HA is running.** HA keeps the dashboard in memory and flushes that (now stale) in-memory copy back to disk on shutdown — a direct file edit is silently reverted on the next restart. Use the `lovelace/config/save` WebSocket command instead (keeps memory and disk in sync, survives restarts). `automations.yaml`/`templates.yaml` are different: those are re-read from disk via the `automation.reload` / `template.reload` services, which work fine as a plain file edit + reload.
