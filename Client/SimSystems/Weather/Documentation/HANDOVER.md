# Weather Simulation — Handover Document

## System Goals
- Create a realistic weather simulation where the weather changes dynamically based on time of day, season, and environmental factors.
- Weather is chosen based on a feedback loop of atmospheric conditions, time of day, and seasonal patterns as defined by the ancient Egyptian calendar, and the data in the notecard.
- Previously the weather was decided largerly by RNG and some limiting factors, but that is not the goal here; we want the weather to be organic, with highs and lows, and natural progressions.
- Every registered grid owns its own environment, and can be customized to have different weather patterns.
- If the notecard has to be modified or refactored to achieve this, that is acceptable.
- If the math or logic needs to be adjusted or refactored to achieve this, that is acceptable.
- It is important that, even if rare, we are able to achieve all weather conditions defined in the notecard.
- For now, we exist in the Alexandria biome IRL but the system needs to be configurable for other climates.
- Grid objects are separate objects (NOT linked). Processor scripts (Main, Proc1-3) are all in the same object.

### Notes on SLua
- LSL functions are almost identical but namespaced to the ll namespace, e.g ll.OwnerSay()
- - These functions also use identical arguments.
- UUIDs are their own variable type. Keys/UUIDs are effectively the same thing and can no longer be typecast.
- SLua is built on top of Luau.
- SLua scripts are islands; they do not share memory and live in isolated VMs inside their object. Their only shared points of contact in-linkset are: linkset message, and Linkset Data. RegionSayTo() is preferred communication for linkset-to-linkset messaging.
- UUIDs can be empty but never nil. Most Second Life functions will not accept a nil value.

### SLua references:
https://slua.dev/reference/library/llevents/ (events)
https://slua.dev/reference/library/lltimers/ (timers)
https://slua.dev/reference/library/ll/ (LSL namespace)
https://slua.dev/reference/library/lljson/ (LL's JSON implementation, use instead of standard Luau JSON funcs)
https://slua.dev/reference/library/llcompat/ (LSL provides a compatibility option where SLua maybe comes up short)


## What This System Does

A region-scale weather simulation for Second Life, built around a single oasis
biome at Alexandria, Egypt. The system simulates temperature, humidity,
atmospheric pressure, wind speed/direction, dust, visibility, and
precipitation, then drives EEP environmental presets and particle effects to
make the in-world weather match the model.

Weather evolves continuously via a relaxation model toward state-defined
targets, with diurnal temperature curves, maritime influence from the
Mediterranean, Nile flood-cycle modifiers, a stochastic pressure driver, and
a global wind driver with diurnal sea/land breeze variation. A state machine
in each grid prim transitions between weather states (Clear Skies, Hazy Heat,
Heat Wave, Coastal Mist, Sirocco, Khamsin, Storm, etc.) based on pressure
trends, humidity, temperature, wind, and time of day.

Seasons follow the ancient Egyptian calendar: Akhet (inundation), Peret
(emergence), Shemu (harvest), each with its own state graph and climate
parameters.

## Architecture

Hub-and-spoke. A central processor object holds four scripts (Main, Proc1,
Proc2, Proc3). Detached grid prims register with the processor and poll for
computed values every 15 seconds. The processor computes in round-robin
every 7.5 seconds, writing results to shared LSD (linkset data) keys that
the grid reads on poll.

```
Grid prim (Weather_Grid.slua)
  |
  |  REGISTER / STATE_POLL / TARGET_PUSH / META_REQ  (RegionSayTo)
  |  STATE_RESP / BEACON / ADMIN_*                   (RegionSayTo)
  v
Processor object
  +-- Weather_Main.slua   -- orchestrator, message relay, admin commands
  +-- Weather_Proc1.slua  -- macro evolution, STATE_RESP assembly
  +-- Weather_Proc2.slua  -- micro evolution (temp, humidity, wind, dust, ...)
  +-- Weather_Proc3.slua  -- global drivers (pressure, wind, flood state)
```

Grids are the decision makers: they evaluate transition conditions and choose
the next state. Processors are the compute engine: they evolve values and
return them. This separation keeps each script within the 64 KB memory limit.

## File Map

### Scripts (`.slua`)

| File | Lines | Role |
|------|-------|------|
| `Weather_Main.slua` | 877 | Orchestrator. Grid registration, namespace scaffolding, message routing, reset pipeline, admin commands, beacon broadcast. No maths. |
| `Weather_Proc1.slua` | 333 | Macro processor. Evolves macro:evolution metadata (relaxation rate, noise scale, pressure trend/offset). Assembles STATE_RESP from all micro fields. Round-robin every 7.5s. |
| `Weather_Proc2.slua` | 516 | Micro processor. The core weather maths: relaxation, diurnal temperature, maritime influence, flood modifiers, pressure driver coupling, target interpolation during transitions. Writes all `micro:*` LSD keys. Round-robin every 7.5s. |
| `Weather_Proc3.slua` | 811 | Environment driver. Computes global pressure variation (sinusoidal + noise + cyclone dips + thermal/moisture coupling), wind driver (oscillation + diurnal breeze + pressure gradient), and Nile flood state (deterministic from calendar). Writes `drivers:*` LSD keys. |
| `Grid/Weather_Grid.slua` | 1761 | Grid controller. Notecard parsing, registration, polling, pressure history, transition evaluation (progress/regress/diverge with sun-phase gating and per-target conditions), bootstrap evaluation, display, admin command handling. |

### Data files

| File | Role |
|------|------|
| `Grid/Alexandria_Oasis.notecard` | The actual weather model. Defines the grid (biome, coordinates, maritime modifiers, wind config), three seasons, and all weather states with their target values, transition edges, and conditions. This is what you edit to tune the weather. |

### Documentation

| File | Role |
|------|------|
| `Documentation/DESIGN.md` | Architecture overview. Hub-and-spoke model, memory partitioning rationale, communication patterns, implementation phases. |
| `Documentation/NOTECARD_FORMAT.md` | Reference for the notecard format. Every field in `{grid}`, `{season}`, and `[State]` sections, including transition edge and condition field syntax. Read this when editing the notecard. |
| `Documentation/SIMULATION_MATHS.md` | All the maths: relaxation model, diurnal temperature, maritime influence, target interpolation, wind speed/direction, pressure driver, flood modifiers, transition evaluation. Formulas with explanation. |
| `Documentation/WIND_DRIVER_DESIGN.md` | Design doc for the Proc3 wind driver. Covers the problems with the old per-grid wind model and the rationale for the global driver with diurnal breeze and pressure-gradient coupling. |
| `Documentation/COMMS_PROTOCOL.md` | Message envelope format, integer op/recipient mappings, payload contracts for every operation (REGISTER, STATE_POLL, STATE_RESP, TARGET_PUSH, META_REQ/RESP, ADMIN_*, BEACON). |
| `Documentation/ADMIN_COMMANDS.md` | Owner chat commands on channel -88888: reset, target, force, unlock, dump, history, debug. |
| `Documentation/CLIMATE_DATA.md` | Sourced climate data for Alexandria (NOAA, Wikipedia, academic studies). Monthly temp/humidity/pressure/wind/precipitation averages, Khamsin characteristics, Nile flood cycle. Used to parameterize the notecard. |

## Where the Maths Lives

| Concept | File | Function(s) |
|---------|------|-------------|
| Relaxation model | `Weather_Proc2.slua` | `relax_value()` -- `new = current + (target - current) * 0.05 + noise` |
| Diurnal temperature | `Weather_Proc2.slua` | `compute_diurnal_temperature()` -- sine wave from `ll.GetSunDirection()` with phase offset |
| Maritime influence | `Weather_Proc2.slua` | `compute_maritime_influence()` -- `cos(wind_dir - sea_dir)`, scaled by `sea_temp_modifier` / `sea_humidity_modifier` |
| Flood modifiers | `Weather_Proc2.slua` | `apply_flood_modifier()` -- adds season/flood-state bonuses to temp, humidity, dust |
| Target interpolation | `Weather_Proc2.slua` | Inside `evolve_grid_micro()` -- linear ramp over `ramp_cycles` when targets change |
| Pressure driver | `Weather_Proc3.slua` | `compute_pressure_driver_cycle()` — layered model: synoptic systems (`spawn_synoptic_system`/`advance_synoptic_system`) + mesoscale wave + noise + anomaly coupling (`compute_coupling_offset`) |
| Pressure trend | `Weather_Proc3.slua`, `Weather_Grid.slua` | `compute_pressure_trend()` — both regress over timestamped samples, 5-minute window, **hPa/min** |
| Wind driver | `Weather_Proc3.slua` | `compute_wind_driver_cycle()` — global BASE wind only; per-grid state modifiers applied in Proc2 (`evolve_grid_micro`, wind section) |
| Diurnal wind factor | `Weather_Proc3.slua` | `compute_diurnal_wind_factor()` -- sun elevation mapped to -1..+1 for sea/land breeze |
| Flood state | `Weather_Proc3.slua` | `get_flood_state()` -- deterministic from day-of-year (low/rising/peak/receding) |
| Transition conditions | `Weather_Grid.slua` | `check_progression_condition()` -- evaluates trend, humidity, pressure, temp, wind thresholds with AND/OR logic and sun-phase gating |
| Sun phase detection | `Weather_Grid.slua` | `get_sun_phase()` -- morning/day/evening/night from `ll.GetSunDirection()` z and x components |
| Bootstrap evaluation | `Weather_Grid.slua` | `bootstrap_evaluate()` -- first-poll state selection from pressure delta vs baseline |
| Weighted pick | `Weather_Grid.slua` | `pick_among_ready()` -- weight-proportional random selection among multiple ready candidates |
| Per-season event-state list | `Weather_Grid.slua` | `flush_season_events()` -- written to `season_events:<season>` during notecard parsing, consumed by `bootstrap_evaluate()` |

## LSD Key Map

### Global driver keys (written by Proc3, read by Proc2/Proc1/Grid)

| Key | Writer | Contents |
|-----|--------|----------|
| `drivers:pressure` | Proc3 | `{offset, trend (hPa/min), system_offset, meso_phase, system?, refractory_until, samples, coupling}` |
| `drivers:wind` | Proc3 | `{speed, direction, speed_target, dir_target, variability, + internal reset-recovery fields}` |
| `drivers:conditions` | Proc2 | Current temp/humidity (written by Proc2, read by Proc3 for coupling) |
| `drivers:flood_state` | Proc3 | `{state, day_of_year}` |

### Per-grid keys (prefix `<grid_uuid>:`)

| Key | Writer | Contents |
|-----|--------|----------|
| `<uuid>:meta` | Main | Grid config from notecard `{grid}` section (biome, sea_direction, modifiers, wind config, bounds) |
| `<uuid>:targets` | Main (from Grid's TARGET_PUSH) | Current state's target values (temp_base, humidity, pressure, wind mods, dust, visibility, etc.) |
| `<uuid>:macro:evolution` | Proc1 | Relaxation rate, noise scale, pressure trend/offset |
| `<uuid>:micro:temp` | Proc2 | Computed temperature (deg C) |
| `<uuid>:micro:humidity` | Proc2 | Computed humidity (%) |
| `<uuid>:micro:pressure` | Proc2 | Computed pressure (hPa) |
| `<uuid>:micro:wind_speed` | Proc2 | Computed wind speed (kph) |
| `<uuid>:micro:wind_dir` | Proc2 | Computed wind direction (degrees) |
| `<uuid>:micro:precipitation` | Proc2 | Precipitation intensity |
| `<uuid>:micro:dust` | Proc2 | Dust level |
| `<uuid>:micro:visibility` | Proc2 | Visibility (m) |
| `<uuid>:micro:eep` | Proc2 | EEP preset name |
| `<uuid>:micro:particle` | Proc2 | Particle config name |

### Grid-local keys (in Weather_Grid.slua's own LSD)

| Key | Contents |
|-----|----------|
| `config` | Parsed notecard `{grid}` section |
| `state` | Current state name and def |
| `transition` | Duration timer, cooldown, target bias, pending transition |
| `processor_key` | UUID of registered processor |
| `transition_history` | Last 10 transitions with timestamps and reasons |
| `season:<name>` | State definitions for that season |
| `<season>:<state_name>` | Individual state definition |
| `season_events:<name>` | List of states with `event = true` for that season (consumed by `bootstrap_evaluate()`) |

## Data Flow (one poll cycle)

```
1. Grid timer fires (every 15s + jitter)
2. Grid sends STATE_POLL to Main
3. Main forwards STATE_POLL to Proc1 (link message)
4. Proc1 calls evolve_grid_macro():
   - Reads drivers:pressure from Proc3's LSD
   - Writes macro:evolution with trend/offset/rate/noise
5. Proc1 calls assemble_state_response():
   - Reads macro:evolution + all micro:* keys
   - Sends STATE_RESP to Main (link message)
6. Main forwards STATE_RESP to Grid (RegionSayTo)
7. Grid handle_state_resp():
   - Records pressure reading, computes local trend
   - Updates display (floating text)
   - Calls evaluate_progression():
     - Gathers progress/regress/diverge candidates
     - Checks each candidate's conditions (trend, humidity, temp, wind, sun phase)
     - If one ready: transition. If multiple: weighted pick. If none: check duration expiry.
   - If transition chosen:
     - execute_state_transition() -- updates state LSD, records history
     - send_target_push() -- sends new targets to Main
8. Main handle_target_push():
   - Writes new targets to <uuid>:targets LSD
9. Proc2 (next 7.5s tick):
   - evolve_grid_micro() reads new targets
   - Detects target change, starts interpolation ramp
   - Relaxes all micro values toward new targets
   - Writes micro:* keys
```

Meanwhile, Proc3 runs independently on its own timer:
- Updates `drivers:pressure` (sinusoidal + noise + cyclones + coupling)
- Updates `drivers:wind` (oscillation + diurnal breeze + pressure gradient)
- Updates `drivers:flood_state` (calendar-based, changes rarely)
- Updates `drivers:conditions` (seasonal averages for coupling)

## Current State of the Shemu Season

The Shemu season (May 10 - Sept 10) has five states:

| State | Weight | Duration | Trigger |
|-------|--------|----------|---------|
| Clear Skies | 10 | 7-14h | Default / regress target |
| Hazy Heat | 5 | 3-7h | Progress from Clear (humidity >= 72, evening/night only) |
| Heat Wave | 3 | 4-12h | Diverge from Clear (temp >= 28, day only) |
| Coastal Mist | 4 | 1-3h | Diverge from Clear (humidity >= 70, morning only) |
| Sirocco | 2 | 3-8h | Diverge from Clear (humidity <= 60, pressure <= 1006, any time) |

Sun-phase gating was added to prevent progress and diverge paths from
competing in the weighted pick. Before this fix, the system was stuck in a
Clear Skies <-> Hazy Heat loop because progress (humidity >= 72, no time gate)
fired almost immediately and outweighed the diverge paths in the weighted
random selection.

## Known Issues / Pending Work

1. **Phase 6: Extreme weather emergence** -- not yet implemented. The
   framework for event states exists (Khamsin, Storm, Sirocco), and the new
   synoptic system driver is a natural foundation: an escalation layer could
   key off `drivers:pressure.system` (kind/magnitude) to intensify active
   states.

2. **Sirocco reachability** -- `humidity_max = 60` requires sustained offshore
   wind. The maritime modifier (8.0) means onshore wind pushes humidity to
   ~73 and offshore pulls it to ~57. Sirocco only fires when wind is
   consistently offshore AND pressure is low (<= 1006). Synoptic lows now
   hold low pressure for 10-40 minutes (vs 100-second dips), giving humidity
   time to relax below 60 during offshore wind. Still needs in-world
   observation.

3. **Multi-grid `drivers:conditions`** -- multi-grid support improved
   (per-grid interpolation, per-grid wind modifiers) but `drivers:conditions`
   is still last-writer-wins across grids; Proc3's coupling EMAs smooth over
   the flip-flopping, and the wind/seasonal base config is still read from
   the first registered grid. Fine for one region-wide grid set; revisit if
   grids ever span very different biomes.

## Recent Work (This Session)

1. **Pressure driver redesign (Proc3)**: replaced the 20-minute ±5 hPa
   sinusoid + near-continuous cyclone dips with layered synoptic systems
   (rare 1-3 h lows/highs with cosine envelopes), a 1-hour ±1.5 hPa mesoscale
   wave, ±0.3 hPa noise, and EMA-anomaly thermal/moisture coupling. Weather
   now has genuine, organic highs and lows.

2. **Trend units standardized**: Proc3 trend is now hPa/min over a 5-minute
   timestamped window (was hPa/cycle over 25 s), matching the grid.

3. **Gradient wind fixed**: unit conversion bug made it 60× weaker than
   designed; now uses the hPa/min trend directly, factor 25, capped ±25 kph.

4. **Wind split into global base + per-grid modifiers**: Proc3 computes the
   shared base wind; Proc2 applies each grid's `wind_speed_mod` /
   `wind_dir_mod` / `wind_variability_mod` (ramped via target interpolation).
   Removes the multi-grid conflict where Proc3 only honored the first grid.

5. **Relaxation noise formula fixed** (`abs(target-current)+1`), and stored
   dust/precipitation/visibility clamped ≥ 0 — negative dust resolved at the
   source.

6. **Per-grid interpolation state in Proc2** — transition ramps no longer
   thrash when more than one grid is registered.

7. **Bootstrap fixes (Grid)**: the event-state bootstrap path never fired
   because it read the trend from the wrong payload; now uses the driver
   trend from `evolution`. Event states are discovered from the notecard
   (`event = true` → `season_events:<season>`) instead of a hardcoded list;
   Cloudy/Partly Cloudy bootstrap results are properly named.

8. **Duration accuracy**: `CYCLES_PER_HOUR` is derived from the actual poll
   interval (including the boot-rolled jitter), so state durations no longer
   run up to ±33% fast/slow. Removed the dead `SEASON_BLEND_DAYS` constant
   (blending remains unimplemented/planned).

9. **Float precision in trend regressions** (Grid + Proc3): both now offset
   timestamps from the first sample before squaring, avoiding ~10% slope
   distortion from squaring raw unix times.

## Prior Session Work

1. **Time-of-day conditions**: Added sun-phase gating to transition
   conditions using `ll.GetSunDirection()` (not wallclock, to respect custom
   sun cycles). States can now specify `progress_morning`, `progress_day`,
   `progress_evening`, `progress_night` and equivalent `regress_*` / `diverge_*`
   flags. Per-target variants (e.g. `diverge_Heat_Wave_day`) are supported.

2. **Per-target conditions**: Diverge conditions can now be specified per
   target state (e.g. `diverge_Heat_Wave_temp_min` instead of a single
   `diverge_temp_min` shared across all diverge targets). Implemented via
   `slugify()` and `get_condition_value()` in Weather_Grid.slua.

3. **Shemu season expansion**: Added Heat Wave, Coastal Mist, and Sirocco
   states to the Alexandria notecard with sun-phase-gated diverge conditions.

4. **Maritime modifiers as grid config**: `sea_temp_modifier` and
   `sea_humidity_modifier` moved from Proc2 constants into the notecard
   `{grid}` section, wired through Main's `grid_uuid:meta` to Proc2. This
   allows per-grid tuning of maritime influence.

5. **Reload race bugfix**: Added a guard in `handle_state_resp` to ignore
   responses until the notecard is fully loaded and registered, preventing
   "State definition not found" warnings during reloads.

6. **Sun-phase gating fix for Shemu**: Gated progress-to-Hazy-Heat to
   evening/night only, giving diverge paths exclusive morning/day windows.
   Lowered Coastal Mist humidity threshold (72 -> 70) and raised Sirocco
   humidity_max (55 -> 60) for reachability.

7. **Documentation cleanup**: SIMULATION_MATHS.md was reviewed and refined
   to remove filler, tighten prose, and eliminate AI-isms.
