# Automatic train repair

**Mod name:** `kris-ick-automatic-train-repair`  
**Version:** 2.1.0  
**Factorio:** 2.0+ (Space Age compatible)  
**License:** MIT  

Fork of [ickputzdirwech/ick-automatic-train-repair](https://github.com/ickputzdirwech/ick-automatic-train-repair) for Factorio 2.0.

When rolling stock is destroyed, the consist is stopped, ghosts are created for reconstruction, and **schedule/group** are restored once the train is whole again. **Automatic mode** is restored when the job finishes — optionally after the train is refueled. Players and bots can both finish the repair.

**Portal / install name must match** `info.json` → folder / zip: `kris-ick-automatic-train-repair_2.1.0/`.

---

## Features

### On destroy
- Stops the remaining train (`speed = 0`, forced **manual** while cars are still missing).
- Creates or reuses an **entity ghost** (position, orientation, quality).
- Optional per-player **alert**.
- Moving trains get a short smoke “emergency brake” effect on non-locomotive cars.

### Ghosts / logistics
- **Fuel** requests via quality-aware `insert_plan` (percent of inventory capacity).
- **Equipment** requests / ghost grid equipment when enabled.
- Merges existing **item-request-proxy** plans when present.
- Saves and restores **cargo wagon filters** and **inventory bar** (limit).

### Repair jobs
- Multi-car damage shares **one job**; rebuild order does not matter.
- Completes when:
  1. All pending ghosts for the job are built (or cancelled),
  2. Live carriage-type counts match the expected layout, and
  3. *(optional)* Every fuel inventory meets the configured fill **percent**.
- Partial rebuilds stay manual/stopped so a lone replaced car cannot drive away.
- When the consist matches but fuel is still low: **schedule/group are restored immediately**; only automatic mode waits for the refuel threshold. Player automatic/manual changes stick while waiting.
- Player can insert fuel by hand (or fast-transfer); the job completes the same as bot delivery and keeps automatic if the player already enabled it.

### Schedule / group identity
- Live registry of trains (`schedule`, group, layout, centroid).
- Empty mid-repair snapshots do **not** erase a richer stored schedule/group.
- **Player schedule edits** are stamped and preferred over older cached/frozen timetables on rebuild.
- Lookup **hard-prefers history entries that still have a schedule** and disregards blank live/rebuild snapshots when a scheduled record exists nearby (same force/surface).
- Open jobs + a nearby **identity cache** (~10 minutes) cover rebuilds and **repeated destroys** (new unit numbers).
- Empty `on_train_schedule_changed` during an active nearby repair no longer wipes inherited timetables (splits/rebuilds were doing that).
- Clearing a schedule outside a repair is still respected (cache cleared). Clearing during an active repair may keep the repair job’s saved timetable until the job finishes.
- Station-based stops and serializable interrupts/groups are restored; rail-only targets are not.

### Automatic mode
- Restored on job complete if the train was automatic and the map setting allows it.
- Trains destroyed **by another train** do not open an automatic-mode repair job (ghost/stop still apply where relevant).

---

## Settings

### Map (runtime-global)

| Setting ID | Default | Meaning |
|---|---|---|
| `ick-automatic-mode` | `true` | Re-enable automatic mode when the repair job finishes |
| `ick-include-equipment` | `true` | Request destroyed equipment on the ghost |
| `ick-include-fuel` | `true` | Request fuel on the ghost |
| `ick-fuel-type` | *(blank)* | Blank = request whatever was in the burner; else that item name |
| `ick-fuel-amount` | `100` | Fuel **request** as % of fuel inventory capacity (0–100) |
| `ick-require-refuel` | `true` | Job waits for fuel fill before finishing (automatic); schedule restores when consist matches |
| `ick-refuel-percent` | `100` | Minimum fuel fill % to complete (0–100); ignored if require-refuel is off |

### Player (runtime-per-user)

| Setting ID | Default | Meaning |
|---|---|---|
| `ick-alert` | `true` | Custom alert when rolling stock is destroyed |

Setting IDs keep the `ick-*` prefix for save compatibility with the original mod lineage.

---

## Limitations

### Coupling / placement
- Ghosts use the **death pose**. Straight rails usually reconnect; **curved rails** often leave a coupler gap so cars rebuild but stay disconnected.
- No reliable curve snap / force-couple yet.
- If another mod keeps the train moving, ghosts stay at the death site.

### Not restored
- Cargo **contents** (filters + bar only).
- Fluid wagon **fluids**.
- Fuel already burned (unless requests/logistics or the player refuel).
- **Rail-target-only** schedule stops (no station name).
- Equipment fulfillment is not required for job completion.

### Identity edge cases
- Cache is by force / surface / nearby centroid; two different trains repaired in the same spot could rare-case share a cached schedule (expected carriage counts reduce this).
- Completion matches **carriage type counts** + proximity, not unique wagon IDs.

### Scope
- Does not rebuild rails, signals, or stations — only rolling-stock ghosts.
- Construction bots / your network must supply rolling stock, fuel, and equipment.

---

## Package layout

```
kris-ick-automatic-train-repair_2.1.0/
  info.json          # name must be kris-ick-automatic-train-repair
  control.lua
  data.lua           # icons use __kris-ick-automatic-train-repair__/...
  settings.lua
  changelog.txt
  thumbnail.png
  graphics/
  locale/
```

Zip the **versioned folder**, not loose files. `info.json` `"name"` must match the `__mod-name__` paths in `data.lua`.

---

## Credits

- Original: **ickputzdirwech**
- Factorio 2.0 fork: **Kristian432** — [kris-ick-automatic-train-repair](https://github.com/Kris-obru/kris-ick-automatic-train-repair)

See `LICENSE.txt` and `changelog.txt` for history.
