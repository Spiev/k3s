# Home Assistant — Heating Control

Part of [Home Assistant](README.md).

Automations live on the PVC (`/config/automations.yaml`), **not in git**. This doc describes the pattern, not the concrete entities.

---

## Pattern: desired state + reconciler

Same idea as a Kubernetes controller: helpers hold the **desired state**, one automation (`Heizung Regler`) compares it with the **actual state** of the thermostats and corrects differences.

```
Intent (helpers)              Facts                     Reconciler
input_number.soll_temp_<room> window sensors per room   Heizung Regler
input_boolean.sommerbetrieb   (open ≥ delay)        ──► per room: summer → off
        ▲                                                         window → 5 °C/off
        │ set by                                                  else   → heat @ soll
presence automations (blueprint)                        sends only if actual ≠ desired
```

**Rule:** only the reconciler touches heating thermostats. Other automations change helpers, never thermostats and never other automations (`automation.turn_on/off/trigger`).

---

## Rules

| Situation | Action |
|---|---|
| Summer mode on | All thermostats off; re-checked when a thermostat changes and every 15 min |
| Window open ≥ room delay | Room thermostats 5 °C / off; optional one-shot `window_off` devices (e.g. AC) off |
| All room windows closed | Heat at `soll_temp_<room>` |
| Otherwise | Heat at `soll_temp_<room>` |
| Manual change at valve | Reverted at the next hourly run (not immediately) |
| Thermostat / helper unavailable | Skipped |
| Window sensor unavailable | Treated as closed |

## Triggers → scope

| Trigger | Rooms reconciled |
|---|---|
| `soll_temp_<room>` changed (10 s debounce) | that room |
| window open (for delay) / closed | that room |
| summer mode toggled, hourly, manual run | all |
| thermostat switched on, every 15 min | all — **only in summer mode** |

---

## Configuration

One room table in the automation's `variables.rooms`:

```yaml
rooms:
  <room>:
    climates: [climate.<trv>, ...]      # all thermostats of the room (also non-master TRVs,
                                        # room sync over HomeKit is not guaranteed)
    windows: [binary_sensor.<window>]   # binary_sensor (on) or cover (open)
    window_delay: 120                   # seconds
    window_off: [climate.<ac>]          # optional, switched off once on window open
```

**Add a room/window:** extend `rooms` **and** the matching trigger lists (triggers can't read variables). Window-open trigger `for:` must equal `window_delay`.

## Dependencies

- `input_number.soll_temp_<room>` per room — key `<room>` must match the helper suffix
- `input_boolean.sommerbetrieb`
- Thermostats via `homekit_controller` (Tado cloud API too limited)
- Presence automations (blueprint `blueprints/automation/stefan/anwesenheit.yaml`) only set `soll_temp_*`

---

## Change procedure

Backup, `check_config`, reload — see [Configuration](README.md#configuration). Rollback: copy a `.bak.*` back and reload.
