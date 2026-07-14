# Wind Driver Design

> **Status: IMPLEMENTED (with amendments).** This document was the design
> proposal for moving wind out of Proc2's per-state relaxation. The driver has
> since been implemented in Proc3 with one significant amendment (below).
> Authoritative maths now live in SIMULATION_MATHS.md section 4; this document
> is kept for design rationale.

## Implementation amendments

1. **State modifiers are applied per grid by Proc2, not globally by Proc3.**
   The original design had Proc3 interpolate `wind_speed_mod` /
   `wind_dir_mod` from "the" grid's targets. That breaks with multiple
   registered grids (they would fight over the shared modifiers, and only
   the first grid was ever read). Proc3 now computes only the region-global
   base wind (oscillation, diurnal breeze, gradient wind, wander);
   Proc2 adds each grid's state modifiers on top and gives each grid its own
   direction wander scaled by `wind_variability_mod`. Modifier ramping
   happens through Proc2's per-grid target interpolation over
   `wind_ramp_seconds` — Proc3's modifier-ramp machinery and the
   `ramp_progress` field were removed.
2. **Two-phase transitions** are implemented as designed (grid pushes
   targets, waits `wind_ramp_seconds`, then commits EEP/particles).
3. **Gradient wind** is computed from the driver trend (hPa/min) with
   factor 25 and capped at ±25 kph. (An earlier implementation had a unit
   bug that made it 60× weaker than intended.)
4. `drivers:wind` published fields: `speed`, `direction`, `speed_target`,
   `dir_target`, `variability`, plus internal state for reset recovery
   (`phase`, `current_speed`, `current_dir`, `base_speed`, `base_dir`,
   `gust_factor`, `calm_factor`, `sea_direction`).

Problem-statement item 3 (the noise formula) has also been fixed in Proc2
(`abs(target - current) + 1`).

## Problem Statement

The current wind model has several issues:

1. **Wind speed is locked to state targets** — each state defines a fixed `wind_speed` target, and the relaxation model converges to it with negligible noise. Wind never drops to calm or spikes to gusts within a state.
2. **Wind direction is state-locked** — direction relaxes toward the notecard's `wind_dir` target and stays there (with small noise). Direction only changes on state transitions.
3. **No prolonged calm or gust periods** — the noise formula `(random - 0.5) × 2 × variability × |target - current + 1|` produces only ±variability kph when converged, which is tiny.
4. **No diurnal wind variation** — real coastal locations have sea breeze (day) and land breeze (night) patterns. The sim has none.
5. **No pre-transition buildup** — when a storm is coming, the wind should start picking up *before* the state officially transitions. Currently wind jumps instantly on transition.
6. **Temperature jumps on state transitions** — temperature is computed directly from the diurnal curve using `temp_base` and `temp_diurnal` from the notecard. When a state transitions (e.g. Clear Skies temp_base=27 → Hazy Heat temp_base=30), the temperature jumps instantly by 3°C. There is no interpolation between state temperature profiles. The same issue affects any directly-computed or target value that changes on transition — humidity targets, dust targets, visibility targets all switch instantly.

## Design Overview

Move wind simulation from Proc2 (per-grid relaxation) to Proc3 (global driver), similar to how pressure is already handled. Proc3 computes wind speed and direction as environmental drivers. Proc2 reads these drivers and applies them, rather than relaxing toward fixed notecard targets.

### Architecture

```
Notecard (seasonal wind profile + state modifiers)
    ↓
Grid (reads notecard, pushes wind modifiers to Proc3 on state transition)
    ↓
Proc3 (simulates wind independently: speed oscillation, direction wandering,
       diurnal sea/land breeze, state modifier interpolation)
    ↓
LSD: drivers:wind = { speed_offset, direction, speed_target, dir_target }
    ↓
Proc2 (reads wind driver, applies to computed wind values)
```

### Two-Phase Transitions

When the grid decides to transition to a new state:

1. **Phase 1 (Ramp-up)**: Grid sends a `WIND_TARGET_PUSH` message to Proc3 with the new state's wind modifiers. Proc3 begins interpolating wind speed and direction toward the new targets over a configurable ramp period (e.g. 5-15 minutes). The grid does NOT transition yet — the current state's EEP/particles/values remain active.

2. **Phase 2 (Commit)**: After the ramp period, the grid executes the actual state transition (new EEP, particles, targets). By this point, the wind has already shifted to match the new state, creating a natural buildup.

For rapid transitions (e.g. bootstrap, admin force), the ramp period can be skipped.

## Notecard Changes

### Season-level wind fields (new)

```
{season: Shemu}
  wind_base_speed = 12          # Seasonal average wind speed (kph)
  wind_base_dir = NNW           # Seasonal prevailing wind direction
  wind_variability = 0.3        # General variability (affects noise)
  wind_gust_factor = 0.5        # Gust multiplier: max gust = base * (1 + gust_factor)
  wind_calm_factor = 0.3        # Calm multiplier: min calm = base * (1 - calm_factor)
  wind_diurnal_amplitude = 0.2  # Diurnal speed variation (fraction of base)
  wind_sea_breeze_shift = 30    # Direction shift (degrees) during day vs night
                                 # Positive = clockwise shift during day (sea breeze)
```

### State-level wind fields (modified)

States no longer define absolute wind speed/direction. Instead they define **modifiers** to the seasonal base:

```
[Clear Skies]
  wind_speed_mod = 0            # Additive modifier to seasonal base speed (kph)
  wind_dir_mod = 0              # Direction shift in degrees (0 = no change)
  wind_variability_mod = 0      # Additive modifier to variability
  ...

[Hazy Heat]
  wind_speed_mod = -3           # Slightly less wind
  wind_dir_mod = 0
  ...

[Khamsin]
  wind_speed_mod = +30          # Much stronger wind
  wind_dir_mod = 180            # Shift to opposite direction (S instead of NNW)
  wind_variability_mod = +0.4   # More erratic
  ...
```

### Removed fields

- `wind_speed` — replaced by `wind_base_speed` (season) + `wind_speed_mod` (state)
- `wind_dir` — replaced by `wind_base_dir` (season) + `wind_dir_mod` (state)
- `wind_variability` — replaced by `wind_variability` (season) + `wind_variability_mod` (state)

## Proc3 Wind Driver

### Wind Speed Model

Proc3 maintains a wind speed driver with three components:

1. **Base oscillation** — a slow sinusoidal variation between calm and gust extremes:
   - `speed = base_speed * (1 + gust_factor * sin(phase))`
   - Period: ~2-4 hours (configurable), creating prolonged calm and gust periods
   - Phase seeded from clock on cold boot (like pressure driver)

2. **Diurnal modulation** — sea breeze / land breeze cycle:
   - `diurnal_factor = 1 + diurnal_amplitude * sin(sun_angle - phase_offset)`
   - Uses `ll.GetSunDirection()` for sun position (same as temperature)
   - Daytime: stronger wind (sea breeze), nighttime: weaker wind (land breeze)

3. **State modifier interpolation** — when grid pushes new state modifiers:
   - Proc3 interpolates `current_mod` → `target_mod` over the ramp period
   - `effective_speed = speed + interpolated_speed_mod`

4. **Noise** — scaled by effective variability:
   - `noise = (random - 0.5) * 2 * variability * base_speed * 0.1`
   - Scaled by base_speed so higher winds have more absolute variation

### Wind Direction Model

1. **Base direction** — seasonal prevailing direction from notecard
2. **Diurnal shift** — sea breeze shifts direction during day:
   - `effective_dir = base_dir + diurnal_shift * diurnal_factor`
3. **State modifier interpolation** — same ramp approach as speed
4. **Angular noise** — wandering using the existing `relax_wind_direction` approach:
   - Noise scaled by variability (±60° at variability=1.0, same as current)

### LSD Output

```json
{
  "speed": 14.5,
  "direction": 338.2,
  "speed_target": 15.0,
  "dir_target": 337.5,
  "gust_factor": 0.8,
  "ramp_progress": 1.0
}
```

- `speed` — current computed wind speed (kph)
- `direction` — current computed wind direction (degrees)
- `speed_target` — where speed is heading (for debugging)
- `dir_target` — where direction is heading (for debugging)
- `gust_factor` — current gust/calm factor (-1 to +1, for debugging)
- `ramp_progress` — 0.0 to 1.0, how far through a state transition ramp (1.0 = settled)

### Internal State (persisted in LSD for reset recovery)

```json
{
  "speed_phase": 2.34,
  "current_speed_mod": 0,
  "current_dir_mod": 0,
  "current_var_mod": 0,
  "target_speed_mod": 0,
  "target_dir_mod": 0,
  "target_var_mod": 0,
  "ramp_remaining": 0
}
```

## Proc2 Changes

Proc2 no longer relaxes wind toward notecard targets. Instead it reads the wind driver from Proc3:

```lua
-- Read wind from Proc3 driver
local wind_driver = lsd_read_json("drivers:wind")
local computed_wind_speed = wind_driver.speed
local computed_wind_dir = wind_driver.direction
```

The maritime influence calculation stays in Proc2 — it reads `computed_wind_dir` and applies the temperature/humidity target adjustments as currently implemented.

## Grid Changes

### Target Push

When the grid decides to transition, it sends the new state's wind modifiers to Proc3 via a new `WIND_TARGET_PUSH` op (or reuses `TARGET_PUSH` with wind modifier fields). The grid then waits for the ramp period before executing the full state transition.

### New Message: WIND_TARGET_PUSH (op 15)

```
| Field | Type | Description |
|---|---|---|
| 1 | grid_uuid | string | Object UUID of the grid prim |
| 2 | wind_modifiers | object | { speed_mod, dir_mod, variability_mod, ramp_seconds } |
```

### Two-Phase Transition Flow

1. Grid's `evaluate_progression` decides to transition
2. Grid sends `WIND_TARGET_PUSH` to Proc3 with new state's wind modifiers
3. Grid sets a timer for `ramp_seconds` (e.g. 300s = 5 minutes)
4. During ramp: grid stays in current state, Proc3 interpolates wind
5. Timer fires: grid executes `execute_state_transition` (EEP, particles, other targets)
6. Proc2 receives TARGET_PUSH for non-wind values, wind already shifted from driver

### Skip Ramp Cases

- **Bootstrap transition** — no ramp, immediate
- **Admin force** — no ramp, immediate
- **Duration expiry with no condition met** — short ramp (30s) since there's no "storm building" narrative

## Target Interpolation During Ramp

The two-phase transition isn't just for wind — it solves the temperature jump problem too. During the ramp period, Proc2 interpolates *all* state-dependent parameters from the old state's values to the new state's values:

### Interpolated parameters

| Parameter | Current behavior | With ramp |
|---|---|---|
| `temp_base` | Instant switch | Linear interpolation over ramp period |
| `temp_diurnal` | Instant switch | Linear interpolation over ramp period |
| `humidity` target | Instant switch (relaxation catches up) | Target interpolated, relaxation follows |
| `dust` target | Instant switch | Target interpolated |
| `visibility` target | Instant switch | Target interpolated |
| `pressure` target | Instant switch | Target interpolated |
| `wind_speed` / `wind_dir` | Instant switch | Handled by Proc3 wind driver (see above) |
| `eep_preset` | Instant switch | Switch at commit (phase 2) |
| `particle` | Instant switch | Switch at commit (phase 2) |

### How it works

1. Grid decides to transition, sends `TARGET_PUSH` with new state's parameters AND a `ramp_seconds` field
2. Proc2 receives the new targets but doesn't switch immediately — it stores both old and new targets with a ramp timer
3. Each compute cycle during the ramp, Proc2 interpolates: `effective_target = old_target + (new_target - old_target) * (elapsed / ramp_seconds)`
4. Temperature: `effective_temp_base = old_base + (new_base - old_base) * progress`, same for `temp_diurnal`
5. At ramp completion, Proc2 switches fully to new targets and clears the old ones
6. Grid commits the state transition (EEP, particles) at ramp completion

### EEP and particles

EEP (environment presets) and particle effects switch at commit (phase 2), not during the ramp. This is because:
- EEP transitions have their own crossfade in SL
- Particles should match the committed state (e.g. rain shouldn't start before the storm officially arrives)
- The visual transition happens when the weather "arrives", not during the buildup

### Example: Clear Skies → Hazy Heat

- Clear Skies: temp_base=27, temp_diurnal=3.5, humidity=65, dust=0
- Hazy Heat: temp_base=30, temp_diurnal=2.5, humidity=70, dust=15
- Ramp: 5 minutes

Over 5 minutes:
- temp_base gradually rises 27 → 30
- temp_diurnal gradually shrinks 3.5 → 2.5
- humidity target gradually rises 65 → 70
- dust target gradually rises 0 → 15
- At commit: EEP switches to Hazy_Shemu, particles switch to light_haze

The temperature rises naturally as haze builds, instead of jumping 3°C in one poll.

## Climate Data Reference

From CLIMATE_DATA.md:

| Season | Months | Base Speed (kph) | Prevailing Dir | Notes |
|---|---|---|---|---|
| Akhet | Sep–Jan | 18 | NNW | Winter storms, higher wind |
| Peret | Feb–May | 20 | NNW | Spring transition, Khamsin risk |
| Shemu | Jun–Aug | 12 | NNW | Summer, calmer, sea breeze dominant |

- Annual average: ~15 kph
- Storm gusts: up to 46-63 kph
- Khamsin gusts: up to 140 kph
- Calm periods: occur in summer, especially early morning
- Sea breeze: daytime onshore (N/NNW), stronger than nighttime land breeze
- Land breeze: nighttime offshore (S/SSW), weaker

## Implementation Phases

### Phase 0: Cadence Doubling (prerequisite)
Double the compute cadence across all scripts for smoother simulation and more stable feedback loops.

| Constant | Script | Current | New | Notes |
|---|---|---|---|---|
| `COMPUTE_INTERVAL_SECONDS` | Proc3 | 5 | 2.5 | Driver compute cadence |
| `POLL_INTERVAL_SECONDS` | Grid | 30 | 15 | Grid poll interval |
| `CYCLES_PER_HOUR` | Grid | 120 | 240 | Duration conversion (same real-time durations) |
| `PRESSURE_PERIOD_CYCLES` | Proc3 | 240 | 480 | Same 20-min real-time period |
| `CYCLONE_DIP_DURATION_CYCLES` | Proc3 | 20 | 40 | Same ~100s real-time duration |
| `PRESSURE_SEED_DIVISOR` | Proc3 | 1200 | 1200 | In seconds, no change |
| `TRANSITION_COOLDOWN_CYCLES` | Grid | 3 | 6 | Same real-time cooldown |
| `RELAXATION_RATE` | Proc2 | 0.1 | 0.05 | Same real-time convergence speed |
| `PRESSURE_HISTORY_MAX_ENTRIES` | Proc3 | 5 | 10 | Same real-time window (was 25s, now 25s) |
| `PRESSURE_TREND_WINDOW_SECONDS` | Grid | 300 | 300 | In seconds, no change |
| `PRESSURE_HISTORY_RETENTION_SECONDS` | Grid | 600 | 600 | In seconds, no change |

### Phase 1: Proc3 Wind Driver (core)
- Add wind speed oscillation (calm/gust cycles) with near-zero calm floor (~0.5 kph)
- Add wind direction wandering with noise
- Write `drivers:wind` to LSD
- Proc2 reads from driver instead of relaxing toward targets
- Proc2 writes `drivers:conditions` (temp, humidity) for Proc3 to read

### Phase 2: Diurnal Wind Variation
- Add sea breeze / land breeze cycle using `ll.GetSunDirection()`
- Daytime: speed increase + direction shift toward sea
- Nighttime: speed decrease + direction shift toward land

### Phase 3: Pressure-Wind Coupling
- Enhance Proc3 pressure model with temperature and humidity influences
- Add pressure gradient wind (pressure trend → wind speed)
- Create the feedback loop: temp/humidity → pressure → wind → maritime → temp/humidity
- Tune constants with observation

### Phase 4: State Modifiers & Notecard Restructure
- Notecard changes: seasonal wind fields + state modifiers + ramp ranges
- Proc3 reads modifiers from TARGET_PUSH
- Interpolation between modifier sets on transition
- Ramp variance flag for controlled randomness

### Phase 5: Two-Phase Transitions
- Grid sends WIND_TARGET_PUSH before state transition
- Ramp timer before commit
- All state parameters interpolate during ramp (temp, humidity, dust, etc.)
- Skip ramp for bootstrap/force, short ramp for duration expiry

### Phase 6: Extreme Weather Emergence
- Bidirectional Grid ↔ Proc3 hints for extreme weather
- Proc3 can detect emerging patterns and suggest transitions to Grid
- Grid can hint at likely extreme states, Proc3 decides whether to early-lock
- Khamsin/storm conditions emerge naturally from the coupled model
- Pressure-driven wind buildup creates realistic pre-storm conditions

## Open Questions (Resolved)

1. **Ramp duration**: Configurable per state via notecard. A range (e.g. `ramp = 3-8` minutes) that the processor randomly selects from. An optional `ramp_variance` flag allows the selected value to be modified by up to ±50% in either direction (faster or slower), introducing controlled randomness. Both Grid and Proc3 need to know the chosen ramp duration so they stay in sync.

2. **Calm floor**: Wind speed can approach but not reach 0. Minimum of ~0.5 kph to avoid division-by-zero and display issues. Effectively "calm" for all practical purposes.

3. **Khamsin / extreme weather**: Hybrid approach — both Grid and Proc3 can initiate extreme weather transitions:
   - **Grid hints**: When Grid sees pressure conditions trending toward an extreme weather event (e.g. Khamsin), it sends a "soft hint" to Proc3 indicating which extreme state is becoming likely. This is not a commitment — just a heads-up.
   - **Proc3 evaluates**: Proc3 receives the hint and independently evaluates pressure trends. It can decide to:
     - **Early lock**: Commit to the extreme transition and start ramping wind/pressure toward that state
     - **Wait for more data**: Hold off and wait for stronger affirmation from the pressure trend
     - **Reject**: If the trend reverses, abandon the hint
   - **Proc3 can also initiate**: Proc3 monitors pressure trends independently. If it detects conditions favoring extreme weather before Grid sends a hint, it can push a "Proc3 suggestion" to Grid, prompting Grid to evaluate the transition earlier than it normally would.
   - This creates a bidirectional dialogue: Grid hints → Proc3 decides, or Proc3 suggests → Grid evaluates.

4. **Per-grid drivers**: Global for now. Refactor to per-grid when a second climate zone is added.

## Pressure-Wind Coupling

The current pressure driver is a standalone sinusoidal oscillator with random cyclone dips. It should be enhanced to create a realistic pressure-wind feedback loop:

### Physical model (simplified)

- **High pressure** → air descends, warms, dries → clear skies, calm/stable weather, light winds
- **Low pressure** → air rises, cools, condenses → clouds, precipitation, stronger winds, unsettled weather
- **Pressure gradient** → drives wind from high to low → steeper gradient = stronger wind
- **Temperature** → warm air rises (low pressure), cool air sinks (high pressure)
- **Humidity** → moist air is less dense (low pressure), dry air is denser (high pressure)

### Proc3 enhanced pressure model

Instead of a pure sinusoid, Proc3 computes pressure from environmental factors:

```
pressure_offset = 
    seasonal_base                          # From notecard (e.g. 1009 for Shemu)
    + sinusoidal_variation                 # Slow background oscillation (existing)
    + temperature_influence                # Warm → lower pressure, cool → higher
    + humidity_influence                   # Humid → lower pressure, dry → higher
    + cyclone_dip                          # Stochastic extreme events (existing, enhanced)
    + noise                                # Random variation (existing)
```

Where:
- `temperature_influence = -(computed_temp - seasonal_temp_avg) * TEMP_PRESSURE_FACTOR`
  - Above-average temp → pressure drops (thermal low)
  - Below-average temp → pressure rises (thermal high)
- `humidity_influence = -(computed_humidity - seasonal_humidity_avg) * HUMIDITY_PRESSURE_FACTOR`
  - Above-average humidity → pressure drops slightly
  - Below-average humidity → pressure rises slightly

### Wind from pressure gradient

Wind speed is influenced by the pressure trend (rate of change):

```
wind_speed = 
    seasonal_base_speed
    * (1 + gust_factor * sin(oscillation_phase))     # Calm/gust cycle
    * (1 + diurnal_amplitude * diurnal_factor)        # Sea/land breeze
    + pressure_gradient_wind                           # Wind from pressure trend
    + state_speed_mod                                  # State modifier
```

Where:
- `pressure_gradient_wind = pressure_trend * GRADIENT_WIND_FACTOR`
  - Rapidly falling pressure → stronger wind (storm building)
  - Rapidly rising pressure → wind eases (weather clearing)
  - This creates the natural buildup before storms: as pressure drops, wind increases

### Feedback loop

```
Temperature → Pressure (thermal influence)
Humidity → Pressure (moisture influence)
Pressure trend → Wind speed (gradient wind)
Wind direction → Temperature & Humidity (maritime influence, in Proc2)
Temperature & Humidity → Pressure (back to start)
```

This creates a coupled system where:
- A hot, humid day → pressure drops → wind picks up → if wind is from sea, cools and humidifies further → pressure drops more → potential storm
- A cool, dry day → pressure rises → wind calms → stable clear weather persists
- A cyclone dip → pressure drops sharply → strong wind → if conditions are right, extreme weather

### Extreme weather emergence

With the coupled model, extreme weather (Khamsin, storms) can emerge naturally:
1. Pressure trend drops sharply (cyclone dip or thermal low)
2. Proc3 detects steep gradient → increases wind speed
3. If wind shifts to desert direction (S/SW) → Proc2 maritime influence goes negative → temp rises, humidity drops
4. Rising temp + dropping humidity → further pressure drop → feedback loop
5. Grid sees pressure < threshold + trend → evaluates Khamsin transition
6. Two-phase ramp begins: wind builds, temp rises, humidity drops — all driven by the coupled model, not instant switches

Alternatively, Proc3 can detect the emerging pattern and push a suggestion to Grid before Grid's own thresholds are met.

### New constants (tunable)

```
TEMP_PRESSURE_FACTOR = 0.3       # hPa per °C deviation from seasonal avg
HUMIDITY_PRESSURE_FACTOR = 0.05  # hPa per % deviation from seasonal avg
GRADIENT_WIND_FACTOR = 50        # kph per hPa/min of pressure trend
```

These need tuning with observation. The values above are starting guesses:
- A 5°C above-average temp → -1.5 hPa (reasonable thermal low)
- 20% above-average humidity → -1.0 hPa (minor effect, as in reality)
- Pressure dropping at 0.1 hPa/min → +5 kph wind (noticeable but not extreme)

### Data dependencies

Proc3 needs access to computed temperature and humidity to drive the pressure model. Currently Proc3 runs independently. Options:

1. **Proc3 reads Proc2's micro values from LSD** — Proc3 reads `drivers:wind` and `<grid_uuid>:micro:temp` / `<grid_uuid>:micro:humidity` each cycle. Since there's one grid, this is straightforward.

2. **Proc2 pushes a summary to Proc3** — Proc2 writes a `drivers:conditions` key with current temp/humidity that Proc3 reads. Decouples Proc3 from grid-specific keys.

Option 2 is cleaner for the future per-grid refactor. Proc3 reads `drivers:conditions` which contains aggregated environmental data, and writes `drivers:wind` and `drivers:pressure` in return.

## Implementation Status

### Completed Phases

#### Phase 0: Double Cadence
- All scripts compute 2x faster: Proc3 at 2.5s, Proc2/Proc1 at 7.5s, Grid at 15s
- All cycle-based constants doubled to preserve real-time behavior
- **Files**: `Weather_Proc3.slua`, `Weather_Proc2.slua`, `Weather_Proc1.slua`, `Weather_Grid.slua`

#### Phase 1: Proc3 Wind Driver Core + Proc2 Conditions Data Flow
- Proc3 computes wind speed and direction independently using a calm/gust oscillation model
- Calm/gust oscillation: slow sinusoid (20-min period) creating prolonged calm and gust periods
- Wind direction wanders with noise scaled by variability
- Proc2 reads `drivers:wind` from LSD instead of relaxing toward notecard targets
- Proc2 writes `drivers:conditions` (temp, humidity) to LSD for Proc3 feedback
- Proc3 listens for `linkset_data` changes on the `grids` key to re-read wind config when grids register
- **Files**: `Weather_Proc3.slua`, `Weather_Proc2.slua`, `Alexandria_Oasis.notecard`, `COMMS_PROTOCOL.md`

#### Phase 2: Diurnal Wind Variation (Sea/Land Breeze)
- Sea breeze / land breeze cycle using `ll.GetSunDirection()`
- `compute_diurnal_wind_factor()` returns -1 (night) to +1 (midday) based on sun elevation
- Daytime: stronger wind (diurnal speed modulation), direction shifts toward sea (onshore breeze)
- Nighttime: weaker wind, direction shifts away from sea (offshore land breeze)
- Constants: `WIND_DIURNAL_SPEED_AMPLITUDE`, `WIND_DIURNAL_DIR_SHIFT`
- Grid notecard includes `sea_direction` field (e.g. `N` for Alexandria, sea to the north)
- **Files**: `Weather_Proc3.slua`, `Alexandria_Oasis.notecard`

#### Phase 3: Pressure-Wind Coupling (Feedback Loop)
- Pressure driver now incorporates temperature and humidity influences (thermal/moisture coupling)
  - Warm air → lower pressure (`TEMP_PRESSURE_FACTOR = 0.3` hPa per °C deviation)
  - Moist air → lower pressure (`HUMIDITY_PRESSURE_FACTOR = 0.05` hPa per % deviation)
- Wind speed gets a pressure-gradient component (falling pressure → stronger wind)
  - `GRADIENT_WIND_FACTOR = 50` kph per hPa/min of pressure trend
- Full feedback loop: temp/humidity → pressure → wind → maritime influence → temp/humidity
- Seasonal averages (`seasonal_temp_avg`, `seasonal_humidity_avg`) read from grid targets
- **Files**: `Weather_Proc3.slua`

#### Phase 4: State Modifiers & Notecard Restructure
- Notecard restructured: states now use `wind_speed_mod`, `wind_dir_mod`, `wind_variability_mod` instead of absolute `wind_speed`/`wind_dir`/`wind_variability`
- Season-level wind overrides: each season defines `wind_base_speed`, `wind_base_dir`, `wind_variability`
- Grid's notecard parser updated to handle season-level fields (stored as `season:<name>` in grid LSD)
- Grid's `extract_targets_from_state` includes seasonal wind base values in TARGET_PUSH payload
- Proc3 reads seasonal wind base from `<uuid>:targets` (since Proc3 is in a different linkset and can't read grid LSD)
- Proc3's `check_wind_modifier_changes()` detects modifier changes in targets and starts ramp automatically
- **Files**: `Alexandria_Oasis.notecard`, `Weather_Grid.slua`, `Weather_Proc3.slua`

#### Phase 5: Two-Phase Transitions with Target Interpolation
- Grid sends TARGET_PUSH immediately on transition decision (starts wind ramp + target interpolation)
- `wind_ramp_seconds` field in targets tells Proc2 and Proc3 the ramp duration (default 300s = 5 min)
- Proc2 interpolates all numeric targets (temp_base, humidity, dust, visibility, etc.) over the ramp period — no more temperature jumps
- Grid delays EEP/particle switch and transition state update until ramp completes (`pending_transition` mechanism)
- Bootstrap/force transitions skip the ramp (immediate commit, `skip_ramp = true`)
- Grid blocks new transition evaluation while a pending transition is in progress
- **Files**: `Weather_Grid.slua`, `Weather_Proc2.slua`

### Bugfixes Applied
- **Proc3 grids CSV parsing**: Proc3 was reading the `grids` LSD key with `lsd_read_json()`, but Main writes it as a CSV string (not JSON). Added `get_registered_grids()` helper that parses the CSV with `string.gmatch`, matching Proc2's approach.
- **Proc3 `read_conditions` ordering**: `read_conditions()` was defined in the Wind Driver section but called earlier in the Pressure Driver. Moved it to a Shared Utilities section before the Pressure Driver.

### Tuning Applied
- `WIND_NOISE_SCALE`: 0.15 → 0.05 (reduced noise for smoother wind variation)
- `WIND_SPEED_RELAX_RATE`: hardcoded 0.1 → 0.03 (slower convergence to target speed)
- `WIND_DIR_NOISE_DEGREES`: 60 → 30 (reduced direction noise)
- `WIND_DIR_RELAX_RATE`: 0.05 → 0.03 (slower direction changes)

### Remaining Work

#### Phase 6: Extreme Weather Emergence (pending)
- Bidirectional Grid ↔ Proc3 hints
- Proc3 can detect emerging patterns (sustained pressure drop, extreme wind) and suggest transitions
- Khamsin/storm conditions emerge naturally from the coupled model rather than only via notecard divergence rules
- Design needed for the hint mechanism (likely a new `drivers:hint` LSD key or a new op)

#### Cosmetic: Negative Dust Values (pending)
- Raw dust values can go slightly negative when relaxing toward 0 with noise
- Needs clamping in Proc2's dust computation (floor at 0)
