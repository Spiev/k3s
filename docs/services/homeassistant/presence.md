# Home Assistant — Presence

Part of [Home Assistant](README.md).

Automations live on the PVC, not in git (see [Configuration](README.md#configuration)). This doc describes the pattern, not the concrete entities.

Presence automations only change **helpers** (`input_number.soll_temp_<room>`) for heating. They never touch thermostats directly; that is the job of the [heating reconciler](heating.md). They do switch lights, scenes and covers themselves.

---

## Two kinds of presence automation

| Automation | Scope | Inputs |
|---|---|---|
| Per person (blueprint `blueprints/automation/local/anwesenheit.yaml`) | the person's own room | `person.<name>`, optional distance/direction sensor, optional "leave zone" |
| Shared rooms (one automation) | bathroom, kitchen, hallway | `zone.home` (number of people home), proximity distance/direction of the nearest person |

### Per person (blueprint)

| Trigger | Action |
|---|---|
| Approaching (distance below threshold **and** direction `towards`/`arrived`), or person → `home` | `soll_temp_<room>` = home temperature |
| Leaving (distance above threshold), person → `not_home`, or entering a configured leave zone | `soll_temp_<room>` = away temperature, room lights off, optional extra actions (e.g. AC off) |

### Shared rooms

| Trigger | Condition | Action |
|---|---|---|
| Nearest person approaching (< 500 m) | direction `towards`/`arrived` | target temperature = home, evening scene after sunset |
| **Any** `zone.home` change | `zone.home > 0` | target temperature = home; evening scene only after sunset, before 22:00 **and** on a real arrival (`from: 0`) |
| `zone.home` = 0 **for 2 min**, or nearest > 500 m for 2 min | `zone.home` still 0 | target temperature = away, lights off, roof window closed |

`mode: queued`.

### Evening scene ownership

| Case | Owner |
|---|---|
| Arriving home after sunset (before 22:00) | Shared rooms automation (above) |
| Sunset while somebody is home | Light automation (sunset → `scene.abend_modus` if `zone.home > 0`; sunrise + 45 min → lights off) |

The light automation must not trigger on `zone.home` itself — it has no sun check and would switch on the evening scene on any daytime arrival (incident 2026-11-02).

### Guest mode

Guests are not tracked, so `zone.home` = 0 while only a guest is home. `input_boolean.gaestemodus` (dashboard *Übersicht*, next to *Sommerbetrieb*) counts as "occupied" for the shared rooms.

| Automation | Guest mode effect |
|---|---|
| Shared rooms | Switched on → target temperature = home (no evening scene). *Leaving* only acts if guest mode is off. Switched off while `zone.home` = 0 → *Leaving* runs at once (away temperature, lights off, roof window closed) |
| Light automation | Sunset → evening scene if `zone.home > 0` **or** guest mode on |
| `Gästemodus Erinnerung` | On switch-on stores `input_datetime.gaestemodus_seit`; every 3 days at 18:00 pushes a reminder to Stefan's phone with a *Gästemodus beenden* button that switches it off |

Per-person rooms and the door alert ignore guest mode.

---

## Design rules

- **Use the current state, not a single trigger.** Every `zone.home` change re-checks "anyone home?" and sets the matching target. If one event is lost, the next presence change corrects the state.
- **Debounce leaving.** GPS/WLAN presence flaps for a few minutes. Leaving only acts after `zone.home` has been 0 for 2 min. Arriving acts immediately.
- **No `mode: single`** when dropped triggers matter. A run that is still busy (e.g. `cover.close_cover`) makes `single` **discard** new triggers (`Already running` in the log). `queued` processes them in order.
- **Setting the same value is harmless.** `input_number.set_value` with an unchanged value creates no state change, so the reconciler does not fire.

## Incident 2026-11-01 (why the rules exist)

Person A arrived → shared rooms set to 18 °C. Three minutes later, A's presence flapped to `not_home` for about three minutes (`zone.home` 1 → 0), which triggered *Leaving* → 16 °C. One second later, person B arrived (`zone.home` 0 → 1). That *Approaching* trigger was dropped because the *Leaving* run was still busy and the automation used `mode: single`. Later changes (1 → 2) did not cross the `above: 0` threshold, so the rooms stayed at 16 °C. The lights looked correct because a separate light automation handled them.

Fix: the three design rules above.

---

## Debugging

```bash
# "Already running" = dropped trigger in mode: single
kubectl -n homeassistant logs deploy/homeassistant --since=2h | grep -E "<automation alias>|Already running"
```

State history (presence, helpers, thermostats) is in the recorder DB `/config/home-assistant_v2.db` (`states` joined with `states_meta`). Open it read-only (`?mode=ro`).
