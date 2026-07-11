# Weather Simulation Maths

Reference for the computational models used by the processor scripts and the grid's transition logic. All formulas are designed for SLua's constraints: 64 KB working set, no external libraries, float64 arithmetic.

## 1. Diurnal temperature

Temperature is computed continuously from the sun's position, not stored as a static value. Proc2 computes this each cycle using `ll.GetSunDirection()`.

### Why sun direction, not wallclock?

The system originally used `llGetWallclock()` (seconds since midnight in SL time), but this was replaced with `ll.GetSunDirection()` for two critical reasons:

1. **Custom sun cycles**: Many regions run accelerated day/night cycles, eternal noon, or custom sun configurations. `llGetWallclock()` returns SL time which may not correspond to the actual sun position in these regions. The diurnal temperature curve would be out of sync with the visible sun.
2. **Region restart desync**: `llGetTimeOfDay()` and wallclock can drift after region restarts. The sun direction vector is always authoritative.

`ll.GetSunDirection()` returns a normalized 3D vector pointing toward the sun. SL's sun path: rises in the east (+X), sets in the west (-X), arcs through the sky (+Z at noon, -Z at midnight). We use `atan2(z, x)` to extract the orbital angle and map it to a 24-hour clock.

### Formula

```
-- Get the sun direction vector (parcel-scoped)
sun = ll.GetSunDirection()

-- Derive the orbital angle from the sun's X-Z position.
-- atan2(z, x) gives: 0 at sunrise (east), π/2 at noon, π at sunset (west),
-- 3π/2 at midnight. Normalize to [0, 2π).
angle = math.atan(sun.z, sun.x)
if angle < 0 then angle = angle + 2 * math.pi end

-- Map angle to 24-hour clock:
-- sunrise (angle=0) = 6am, noon = 12, sunset = 18, midnight = 0
hour = (6 + (angle / (2 * math.pi)) * 24) % 24

-- Convert to angular position (0 at midnight, π at noon)
sun_angle = (hour / 24) * 2 * math.pi

-- Phase offset: temp_phase is the hour of peak temperature (default ~14:00)
phase_offset = (temp_phase / 24) * 2 * math.pi

-- Temperature follows a sine wave peaking at temp_phase
temp = temp_base + temp_diurnal * math.sin(sun_angle - phase_offset + math.pi / 2)
```

Where:
- `temp_base` — daily mean temperature (from current target parameters)
- `temp_diurnal` — half the day/night swing amplitude (from current target parameters)
- `temp_phase` — hour of peak temperature (typically 14, as peak heat lags solar noon by ~2 hours)

### Verification

- At `hour = temp_phase` (e.g., 14:00): `sun_angle - phase_offset + π/2 = π/2`, `sin(π/2) = 1`, so `temp = temp_base + temp_diurnal` (peak). Correct.
- At `hour = temp_phase + 12` (e.g., 02:00): `sun_angle - phase_offset + π/2 = π/2 - π = -π/2`, `sin(-π/2) = -1`, so `temp = temp_base - temp_diurnal` (trough). Correct.
- At `hour = temp_phase + 6` (e.g., 20:00): `sin(0) = 0`, so `temp = temp_base` (mean). Correct — evening is passing through the mean on the way down.

### Maritime adjustment

After computing the diurnal temperature, Proc2 applies a maritime cooling/warming effect based on wind direction relative to the sea:

```
computed_temp = temp - maritime * sea_temp_modifier
```

Where `maritime` is the cosine of the angular difference between wind direction and `sea_direction` (see [Maritime influence](#maritime-influence)), and `sea_temp_modifier` is a grid-configurable value (default: 1.0 °C at full alignment).

## 2. State evolution (relaxation model)

Proc2 evolves each computed value toward its target each cycle using a relaxation model with stochastic noise.

### Formula

```
new_value = current_value + (target_value - current_value) * rate + noise
```

Where:
- `current_value` — the last computed value (stored in LSD)
- `target_value` — the target parameter (from `<grid_uuid>:targets`, possibly interpolated — see [Target interpolation](#target-interpolation-two-phase-transition))
- `rate` — relaxation rate (0 to 1, currently 0.05)
- `noise` — stochastic perturbation

### Relaxation rate

`rate` controls how fast values converge to targets. Higher = faster convergence but less smooth. Lower = more gradual, more natural.

Current default: `rate = 0.05` (5% of the gap closed per cycle). With a 7.5-second cycle, this reaches ~95% of target in about 450 seconds (≈60 cycles, since `0.95^60 ≈ 0.046` remaining gap).

### Noise

Noise prevents the evolution from looking mechanical. It is scaled to the distance from the target:

```
noise = (math.random() - 0.5) * 2 * noise_scale * math.abs(target_value - current_value + 1)
```

Where:
- `math.random()` returns 0 to 1, so `(math.random() - 0.5) * 2` gives -1 to 1
- `noise_scale` — stochastic perturbation scale (default: 0.05, i.e. ±5%)
- `math.abs(target_value - current_value + 1)` — scales noise with the remaining gap, so noise diminishes as values converge. The `+1` prevents zero noise when the value is exactly at target.

### Per-field application

Each micro field is evolved independently. **Wind speed and direction are not evolved by Proc2** — they are read from the Proc3 wind driver (see [Wind speed model](#4-wind-speed-model-proc3)).

```
-- Temperature (special: computed from sun position, not relaxed toward a static target)
temp = compute_diurnal_temperature(temp_base, temp_diurnal, temp_phase)
temp = temp - maritime * sea_temp_modifier
temp = apply_flood_modifier("temp", temp, targets, flood_state, nile_adjacent)
-- Note: temperature is NOT relaxed — it follows the sun directly. This is correct
-- because the diurnal curve IS the target. Maritime and flood adjustments are
-- applied as immediate offsets, not relaxation targets.

-- Humidity (relaxed toward maritime-adjusted target)
target_humidity = targets.humidity + maritime * sea_humidity_modifier
target_humidity = apply_flood_modifier("humidity", target_humidity, targets, ...)
new_humidity = relax_value(current_humidity, target_humidity, rate, noise_scale)

-- Pressure (relaxed toward target, then driver offset added)
evolved_pressure = relax_value(current_pressure, target_pressure, rate, noise_scale)
computed_pressure = evolved_pressure + pressure_driver_offset

-- Wind speed and direction: read from Proc3 driver (not relaxed here)
wind_driver = read_lsd("drivers:wind")
computed_wind_speed = wind_driver.speed
computed_wind_dir = wind_driver.direction

-- Dust (relaxed toward flood-modified target)
target_dust = apply_flood_modifier("dust", targets.dust, targets, ...)
new_dust = relax_value(current_dust, target_dust, rate, noise_scale)

-- Precipitation (relaxed toward target)
new_precip = relax_value(current_precip, target_precip, rate, noise_scale)

-- Visibility (relaxed toward target)
new_visibility = relax_value(current_visibility, target_visibility, rate, noise_scale)
```

Temperature is special: the target itself changes throughout the day (it's the diurnal curve), so the processor computes the diurnal target each cycle. There is no relaxation step for temperature — the diurnal curve is the computed value. Maritime and flood adjustments are applied as immediate offsets on top of the diurnal result.

### Maritime influence

The maritime factor modifies the relaxation **target** for humidity, and applies a direct offset to temperature. It does not modify the computed value directly — this way the relaxation model naturally incorporates the maritime effect, and values vary smoothly with wind direction.

```
function compute_maritime_influence(wind_dir_degrees, sea_direction)
    if not sea_direction then return 0 end

    local sea_dir_degrees = cardinal_to_degrees(sea_direction)
    local angular_diff = wind_dir_degrees - sea_dir_degrees

    -- Normalize to -180..180
    while angular_diff > 180 do angular_diff = angular_diff - 360 end
    while angular_diff < -180 do angular_diff = angular_diff + 360 end

    -- Cosine of the angular difference: 1.0 = from sea, -1.0 = from opposite
    return math.cos(angular_diff * math.pi / 180)
end
```

The maritime factor ranges from -1.0 (wind from opposite of sea, i.e. continental/desert) to +1.0 (wind directly from sea). It affects:

- **Temperature**: `computed_temp = diurnal_temp - maritime * sea_temp_modifier` (positive maritime = from sea = cooler)
- **Humidity target**: `target_humidity = targets.humidity + maritime * sea_humidity_modifier` (positive maritime = from sea = more humid)

Both `sea_temp_modifier` and `sea_humidity_modifier` are configurable per-grid in the `{grid}` section of the notecard (defaults: 1.0 °C and 8.0 percentage points at full alignment).

### Target interpolation (two-phase transition)

When the grid pushes new targets (via TARGET_PUSH), Proc2 does not apply them instantly. Instead it stores the old targets and interpolates all numeric fields toward the new values over a ramp period. This produces smooth transitions between weather states — temperature, humidity, pressure, and wind modifiers ramp gradually rather than snapping.

```
progress = 1.0 - (ramp_remaining / ramp_total)
effective_target = old_target + (new_target - old_target) * progress
```

Where:
- `old_target` — the target value at the moment the new targets arrived
- `new_target` — the incoming target value from TARGET_PUSH
- `ramp_remaining` — cycles left in the ramp (decremented each cycle)
- `ramp_total` — the ramp duration in cycles (from `wind_ramp_seconds` in the targets, converted to cycles: `floor(ramp_seconds / 7.5)`)

Each cycle, `ramp_remaining` is decremented. When it reaches 0, `effective_target` equals `new_target` and the ramp is complete — Proc2 then uses `new_target` directly.

Non-numeric fields (`eep_preset`, `particle`) switch instantly at the start of the ramp, since they cannot be meaningfully interpolated. Only numeric fields (temperature, humidity, pressure, wind modifiers, visibility, dust, precipitation) are ramped.

The ramp duration comes from `wind_ramp_seconds` in the targets (default: 300s). This is the same value Proc3 uses for its wind modifier interpolation (see [Wind speed model](#4-wind-speed-model-proc3)), so wind speed and direction transitions are synchronised with the broader state transition.

## 3. Wind direction interpolation

Wind direction is circular (0-360°), so linear interpolation doesn't work — interpolating from 350° to 10° should go through 0°, not backward through 180°.

### Formula

```
function circular_lerp(current, target, rate)
    -- Normalize both to 0-360
    current = current % 360
    target = target % 360

    -- Find the shortest angular distance
    local diff = (target - current + 540) % 360 - 180  -- -180 to +180

    -- Apply relaxation
    local result = current + diff * rate

    -- Normalize back to 0-360
    return result % 360
end
```

The `+ 540) % 360 - 180` trick maps the difference to the range -180 to +180, ensuring we always rotate the short way. Then we apply the relaxation rate to that difference.

### Cardinal to degrees

Wind direction in notecards may be cardinal (NW, NNW, S). Convert before interpolation:

```
local cardinal_to_deg = {
    N   = 0,
    NNE = 22.5,
    NE  = 45,
    ENE = 67.5,
    E   = 90,
    ESE = 112.5,
    SE  = 135,
    SSE = 157.5,
    S   = 180,
    SSW = 202.5,
    SW  = 225,
    WSW = 247.5,
    W   = 270,
    WNW = 292.5,
    NW  = 315,
    NNW = 337.5,
}
```

## 4. Wind speed model (Proc3)

Proc3 generates the wind speed signal independently of Proc2's target parameters. It combines a calm/gust oscillation, diurnal modulation, a pressure-gradient term, and a state-modifier interpolation into a single speed target, then relaxes the current speed toward it with stochastic noise.

### Calm/gust oscillation

A slow sinusoid alternates between calm lulls and gust peaks. The phase is seeded from the clock on cold boot and advances each cycle:

```
speed_multiplier = 1.0 + (sin(phase) > 0 and sin(phase) * gust_factor
                                        or sin(phase) * calm_factor)
```

Where:
- `gust_factor` — amplitude of gust peaks (positive half of the sine)
- `calm_factor` — amplitude of calm lulls (negative half, typically smaller)
- Period: 20 minutes = 480 cycles at 2.5s per cycle
- `phase` — seeded from `llGetUnixTime()` on cold boot, advanced by `2 * math.pi / 480` each cycle

The asymmetric factors mean gusts can be stronger than lulls (or vice versa), producing a more natural oscillation than a symmetric sine.

### Diurnal modulation

Wind strength is modulated by the time of day using the sun's elevation:

```
diurnal = math.max(-1, math.min(1, ll.GetSunDirection().z))  -- -1 (night) to +1 (noon)
diurnal_speed_mod = 1.0 + diurnal * WIND_DIURNAL_SPEED_AMPLITUDE
```

Where:
- `WIND_DIURNAL_SPEED_AMPLITUDE` — fractional change at full day/night (e.g., 0.2 → ±20%)

Daytime (positive `diurnal`) produces stronger wind; nighttime (negative `diurnal`) produces weaker wind. This models the typical afternoon wind maximum driven by thermal turbulence.

### Diurnal sea breeze shift

Proc3 applies a diurnal modulation to wind direction, shifting the target toward a sea breeze during the day and away at night. The diurnal factor is the sun direction's z-component (sun elevation), clamped to -1…+1:

```
diurnal = math.max(-1, math.min(1, ll.GetSunDirection().z))
```

The shift magnitude is proportional to the shortest angular path from the base direction to the configured `sea_direction`:

```
-- sea_delta: shortest angular path from base_dir to sea_direction (-180 to +180)
sea_delta = (sea_direction - base_dir + 540) % 360 - 180

dir_target = base_dir + wind_dir_mod + sea_delta * diurnal * (WIND_DIURNAL_DIR_SHIFT / 180)
```

Where:
- `sea_delta` — shortest angular distance from `base_dir` to `sea_direction` (degrees, -180 to +180)
- `diurnal` — sun elevation factor (-1 at night, +1 at noon)
- `WIND_DIURNAL_DIR_SHIFT` — maximum shift in degrees at full daytime (default: 30)

Daytime (positive `diurnal`) shifts the target toward `sea_direction` (onshore breeze). Nighttime (negative `diurnal`) shifts it away (offshore). The `wind_dir_mod` term is the state-specific direction modifier interpolated by Proc3 (see [State modifier interpolation](#state-modifier-interpolation)).

### Pressure gradient wind

Proc3 reads the pressure trend from `drivers:pressure` (written by its own pressure driver) and converts it into a gradient wind component:

```
gradient_wind = -pressure_trend_hpa_per_min * GRADIENT_WIND_FACTOR
```

Where:
- `pressure_trend_hpa_per_min` — rate of pressure change in hPa per minute (from `drivers:pressure.trend`, converted from hPa/cycle to hPa/min by dividing by `COMPUTE_INTERVAL_SECONDS`)
- `GRADIENT_WIND_FACTOR` — conversion constant (default: 50)

Falling pressure (negative trend) produces a positive `gradient_wind` (stronger wind), modelling the increased wind ahead of an approaching low. Rising pressure produces weaker wind.

### State modifier interpolation

When Proc2 pushes new targets (via TARGET_PUSH), the `wind_speed_mod` and `wind_dir_mod` fields may change. Proc3 does not apply the new modifiers instantly — it interpolates from the old values to the new values over a ramp period:

```
current_mod = old_mod + (new_mod - old_mod) * (1 - ramp_remaining / ramp_total)
```

Where:
- `old_mod` — the modifier value at the start of the ramp
- `new_mod` — the target modifier from the new targets
- `ramp_remaining` — cycles left in the ramp (decremented each cycle)
- `ramp_total` — the ramp duration in cycles (default: 300s / 2.5s = 120 cycles, from `wind_ramp_seconds` in the targets)

When `ramp_remaining` reaches 0, `current_mod` equals `new_mod` and the ramp is complete. This prevents abrupt wind speed jumps when the grid transitions between weather states.

### Speed target

All components are combined into a single target speed:

```
speed_target = base_speed * speed_multiplier * diurnal_speed_mod
               + wind_speed_mod + gradient_wind
speed_target = math.max(speed_target, WIND_CALM_FLOOR_KPH)
```

Where:
- `base_speed` — the seasonal base wind speed (from `wind_base_speed` in the targets)
- `speed_multiplier` — calm/gust oscillation factor
- `diurnal_speed_mod` — diurnal modulation factor
- `wind_speed_mod` — interpolated state modifier (from targets, see above)
- `gradient_wind` — pressure-gradient component
- `WIND_CALM_FLOOR_KPH` — minimum wind speed to prevent dead calm (default: 0.5 km/h)

### Relaxation

The current speed relaxes toward the target with stochastic noise:

```
speed_noise = (math.random() - 0.5) * 2 * WIND_NOISE_SCALE * base_speed * variability
wind_current_speed = wind_current_speed
    + (speed_target - wind_current_speed) * WIND_SPEED_RELAX_RATE
    + speed_noise
```

Where:
- `WIND_SPEED_RELAX_RATE` — per-cycle relaxation rate (default: 0.03)
- `WIND_NOISE_SCALE` — noise amplitude as a fraction of base speed (default: 0.05, i.e. ±5%)
- `variability` — the wind variability factor for the current state (seasonal `wind_variability` + state `wind_variability_mod`)

At a 2.5-second cycle with `WIND_SPEED_RELAX_RATE = 0.03`, the speed reaches ~95% of target in about 250 seconds (≈100 cycles).

### Direction noise and relaxation

Stochastic perturbation prevents the direction from looking mechanical:

```
dir_noise = (math.random() - 0.5) * 2 * WIND_DIR_NOISE_DEGREES * variability
```

Where:
- `WIND_DIR_NOISE_DEGREES` — maximum noise swing in degrees (default: 30)
- `variability` — the wind variability factor for the current state

The current direction relaxes toward the computed target using circular interpolation:

```
wind_current_dir = circular_lerp(wind_current_dir, dir_target, WIND_DIR_RELAX_RATE)
```

Where `WIND_DIR_RELAX_RATE` is the per-cycle relaxation rate (default: 0.03). At a 2.5-second cycle this reaches ~95% of target in about 250 seconds (≈100 cycles, since `0.97^100 ≈ 0.048` remaining gap).

## 5. Season and flood state computation

Both season and flood state are deterministic — computed from the SL date, not stochastic. Season uses month/day comparison (handles leap years naturally). Flood state uses day-of-year (requires leap year awareness).

### Season determination

The system uses the ancient Egyptian calendar with three seasons. Determined from month/day directly — no day-of-year calculation needed, so leap years are handled automatically:

```
function get_season(month, day)
    -- Akhet: Sept 11 – Jan 9  (inundation / flood season)
    -- Peret: Jan 10 – May 9   (emergence / growth season)
    -- Shemu: May 10 – Sept 10 (harvest / low water season)

    if (month == 9 and day >= 11) or month == 10 or month == 11
       or month == 12 or (month == 1 and day <= 9) then
        return "Akhet"
    elseif (month == 1 and day >= 10) or month == 2 or month == 3
           or month == 4 or (month == 5 and day <= 9) then
        return "Peret"
    else  -- (month == 5 and day >= 10) or month == 6 or month == 7
           -- or month == 8 or (month == 9 and day <= 10)
        return "Shemu"
    end
end
```

### Season blending

In the last 7 days of each season, the grid gradually biases target parameters toward the next season's baseline. This prevents a hard snap at the boundary.

```
function get_season_blend(month, day)
    -- Returns: current_season, blend_factor (0.0-1.0), next_season
    -- blend_factor is 0 except in the last 7 days of a season

    local BLEND_DAYS = 7
    local season = get_season(month, day)

    -- Determine days remaining in current season
    local days_to_boundary

    if season == "Akhet" then
        -- Boundary: Jan 9 → Peret starts Jan 10
        if month == 1 then
            days_to_boundary = 9 - day
        else
            days_to_boundary = 999  -- not near boundary
        end
    elseif season == "Peret" then
        -- Boundary: May 9 → Shemu starts May 10
        if month == 5 then
            days_to_boundary = 9 - day
        else
            days_to_boundary = 999
        end
    else  -- Shemu
        -- Boundary: Sept 10 → Akhet starts Sept 11
        if month == 9 then
            days_to_boundary = 10 - day
        else
            days_to_boundary = 999
        end
    end

    if days_to_boundary >= 0 and days_to_boundary <= BLEND_DAYS then
        local blend = 1.0 - (days_to_boundary / BLEND_DAYS)
        local next_season = get_next_season(season)
        return season, blend, next_season
    end

    return season, 0.0, nil
end

function get_next_season(season)
    if season == "Akhet" then return "Peret"
    elseif season == "Peret" then return "Shemu"
    else return "Akhet" end
end
```

When blending is active, the grid interpolates target parameters between the current season's Clear Skies baseline and the next season's Clear Skies baseline:

```
function apply_season_blend(targets, current_season, next_season, blend, state_defs)
    if blend <= 0 or not next_season then
        return targets  -- no blending needed
    end

    local current_clear = state_defs[current_season .. ":Clear Skies"]
    local next_clear = state_defs[next_season .. ":Clear Skies"]

    if not current_clear or not next_clear then
        return targets  -- can't blend if either is missing
    end

    -- Blend only the baseline params (temp_base, humidity, pressure, wind)
    -- Don't blend event-specific params (dust, visibility, eep, particle)
    local blended = {}
    for k, v in pairs(targets) do
        local next_val = next_clear[k]
        if type(v) == "number" and type(next_val) == "number" then
            blended[k] = v + (next_val - v) * blend
        else
            blended[k] = v
        end
    end

    return blended
end
```

### Nile flood state

The flood state is deterministic — computed from the day of year. Unlike season lookup, this requires day-of-year calculation, which must handle leap years.

```
function is_leap_year(year)
    return (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
end

function get_day_of_year()
    local date = llGetDate()  -- "YYYY-MM-DD"
    local year = tonumber(string.sub(date, 1, 4))
    local month = tonumber(string.sub(date, 6, 7))
    local day = tonumber(string.sub(date, 9, 10))

    local days_in_month = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if is_leap_year(year) then
        days_in_month[2] = 29
    end

    local doy = day
    for i = 1, month - 1 do
        doy = doy + days_in_month[i]
    end

    return doy
end

function get_flood_state(day_of_year)
    -- Returns: "low", "rising", "peak", or "receding"

    if day_of_year >= 60 and day_of_year <= 151 then
        return "low"       -- Mar 1 – Jun 1: river lowest, dry delta
    elseif day_of_year >= 152 and day_of_year <= 212 then
        return "rising"    -- Jun 1 – Jul 31: flood arriving
    elseif day_of_year >= 213 and day_of_year <= 304 then
        return "peak"      -- Aug 1 – Oct 31: maximum inundation
    else
        return "receding"  -- Nov 1 – Feb 28/29: water draining
    end
end
```

Note: The flood state boundaries use fixed day-of-year ranges. In a leap year, days after Feb 29 are shifted by 1, but the boundaries are approximate enough (the flood doesn't change on an exact date) that this is acceptable. The season lookup avoids this issue entirely by using month/day comparison.

### Applying flood modifiers

When Proc2 computes humidity (or any field with flood modifiers), it checks the current flood state and applies the relevant delta to the **target** before relaxation:

```
function apply_flood_modifier(field_name, field_value, target, flood_state, nile_adjacent)
    if not nile_adjacent then
        return field_value  -- no modifiers for non-riverine grids
    end

    -- flood modifiers are named flood_<state>_<field> in the target
    local modifier_key = "flood_" .. flood_state .. "_" .. field_name
    local modifier = target[modifier_key]

    if modifier then
        return field_value + modifier
    end

    return field_value
end
```

The modifier is a delta (e.g., `+15` for `flood_peak_humidity`), applied to the target before the relaxation step. This way the relaxation model naturally smooths the transition when flood state changes.

## 6. Background pressure driver (Proc3)

Proc3 generates an independent background pressure signal that Proc2 mixes into its pressure evolution. This provides an external forcing function — pressure systems move through regions independently of local weather — giving the grid something other than its own reflected targets to evaluate when making progression decisions.

### Model

A slow sinusoidal wave with stochastic noise, simulating passing pressure systems:

```
-- Proc3 maintains internal state across cycles:
--   pressure_phase: current phase of the sinusoidal wave (radians)
--   pressure_period: cycles per full wave (480 = 20 minutes at 2.5s cycles)

function compute_pressure_driver(state)
    -- Advance phase
    state.pressure_phase = state.pressure_phase + (2 * math.pi / state.pressure_period)

    -- Base sinusoidal amplitude: ±5 hPa (typical synoptic variation)
    local amplitude = 5
    local base_offset = amplitude * math.sin(state.pressure_phase)

    -- Stochastic noise: ±1 hPa
    local noise = (math.random() - 0.5) * 2

    -- Occasionally inject a deeper pressure dip (simulates a cyclone passage)
    -- ~5% chance per cycle, creates a -8 to -15 hPa dip that decays over ~40 cycles
    if not state.dip_active and math.random() < 0.05 then
        state.dip_active = true
        state.dip_magnitude = -8 - math.random() * 7  -- -8 to -15
        state.dip_timer = 40
    end

    local dip_offset = 0
    if state.dip_active then
        state.dip_timer = state.dip_timer - 1
        -- Linear decay from full magnitude to 0
        dip_offset = state.dip_magnitude * (state.dip_timer / 40)
        if state.dip_timer <= 0 then
            state.dip_active = false
        end
    end

    -- Thermal coupling: warm air above seasonal mean → lower pressure
    local conditions = read_lsd("drivers:conditions")  -- written by Proc2
    local temp = conditions.temp or seasonal_temp_avg
    local thermal_offset = -(temp - seasonal_temp_avg) * TEMP_PRESSURE_FACTOR

    -- Moisture coupling: moist air above seasonal mean → lower pressure
    local humidity = conditions.humidity or seasonal_humidity_avg
    local moisture_offset = -(humidity - seasonal_humidity_avg) * HUMIDITY_PRESSURE_FACTOR

    local total_offset = base_offset + noise + dip_offset
                         + thermal_offset + moisture_offset

    -- Compute trend (rate of change) from last few offsets
    -- Store last 10 offsets for trend computation (25-second window)
    if not state.offset_history then state.offset_history = {} end
    table.insert(state.offset_history, total_offset)
    if #state.offset_history > 10 then table.remove(state.offset_history, 1) end

    local trend = compute_trend(state.offset_history)

    return {
        offset = total_offset,  -- hPa to add to computed pressure
        trend = trend,          -- hPa/cycle rate of change
        phase = state.pressure_phase,
    }
end
```

### Thermal and moisture coupling

In addition to the synoptic sinusoid and cyclone dips, the pressure driver responds to local conditions. Proc3 reads `drivers:conditions` (written by Proc2) each cycle and applies two coupling terms:

**Thermal coupling** — warm air is less dense and exerts lower surface pressure:

```
thermal_offset = -(temp - seasonal_temp_avg) * TEMP_PRESSURE_FACTOR
```

Where:
- `temp` — current computed temperature (from `drivers:conditions`)
- `seasonal_temp_avg` — seasonal mean temperature (updated from grid targets' `temp_base` field)
- `TEMP_PRESSURE_FACTOR` — hPa change per °C above/below the seasonal mean (default: 0.3)

A temperature 10 °C above the seasonal average produces a -3 hPa offset. This couples heat waves and cold snaps to pressure, reinforcing the progression toward storm or clear conditions.

**Moisture coupling** — humid air is less dense and exerts lower surface pressure:

```
moisture_offset = -(humidity - seasonal_humidity_avg) * HUMIDITY_PRESSURE_FACTOR
```

Where:
- `humidity` — current computed humidity (from `drivers:conditions`)
- `seasonal_humidity_avg` — seasonal mean humidity (updated from grid targets' `humidity` field)
- `HUMIDITY_PRESSURE_FACTOR` — hPa change per % above/below the seasonal mean (default: 0.05)

A humidity 20 % above the seasonal average produces a -1 hPa offset. This is a smaller effect than thermal coupling but adds realism — humid air masses correlate with lower pressure.

The seasonal averages are updated by Proc3 when it reads grid targets: `seasonal_temp_avg` is set to `targets.temp_base` and `seasonal_humidity_avg` is set to `targets.humidity`. This means the coupling responds to the current season's baseline, not a fixed constant.

The total offset combines all terms:

```
total_offset = base_offset + noise + dip_offset + thermal_offset + moisture_offset
```

### How Proc2 uses it

Proc2 reads `drivers:pressure` from LSD each cycle and adds the offset to its computed pressure:

```
local pressure_driver = read_lsd("drivers:pressure")
local target_pressure = targets.pressure  -- from <grid_uuid>:targets
local evolved_pressure = current_pressure + (target_pressure - current_pressure) * rate + noise
local final_pressure = evolved_pressure + pressure_driver.offset
write_lsd("<grid_uuid>:micro:pressure", {current = final_pressure})
```

The result: computed pressure oscillates around the grid's target, but the background driver pushes it away in patterns the grid didn't specify. When a cyclone dip occurs, pressure drops 8-15 hPa below target — enough to trigger khamsin or storm progression conditions in the grid.

### How Proc1 exposes the trend

Proc1 reads `drivers:pressure` and includes the trend in `<grid_uuid>:macro:evolution` so the grid can cross-check it via STATE_RESP:

```
local pressure_driver = read_lsd("drivers:pressure")
local evolution = read_lsd("<grid_uuid>:macro:evolution")
evolution.pressure_trend = pressure_driver.trend
evolution.pressure_driver_offset = pressure_driver.offset
write_lsd("<grid_uuid>:macro:evolution", evolution)
```

The grid reads `pressure_trend` from the STATE_RESP payload for cross-checking, but uses its own time-windowed trend (computed from actual pressure readings) for transition decisions. See [Cross-checking with Proc3's driver trend](#cross-checking-with-proc3s-driver-trend).

### Trend computation (Proc3)

Proc3 computes trend from a rolling 10-entry offset history (25-second window at 2.5s cycles) using linear regression:

```
function compute_trend(history)
    local n = #history
    if n < 2 then return 0 end

    local sum_x, sum_y, sum_xy, sum_x2 = 0, 0, 0, 0
    for i = 1, n do
        sum_x = sum_x + i
        sum_y = sum_y + history[i]
        sum_xy = sum_xy + i * history[i]
        sum_x2 = sum_x2 + i * i
    end

    local slope = (n * sum_xy - sum_x * sum_y) / (n * sum_x2 - sum_x * sum_x)
    return slope  -- hPa change per cycle
end
```

This trend is in hPa/cycle. Proc3 converts it to hPa/min for the gradient wind calculation by dividing by `COMPUTE_INTERVAL_SECONDS` (2.5s).

### Feedback loop

The pressure-wind coupling creates a feedback loop:

```
temp/humidity → pressure (thermal/moisture coupling)
            → pressure trend
            → gradient wind
            → wind direction
            → maritime influence
            → temp/humidity
```

This feedback is self-regulating: a heat wave raises temperature, which lowers pressure, which increases wind, which (if from the sea) cools and humidifies the air, which brings the temperature back down. The loop operates on a timescale of minutes to tens of minutes, producing natural weather oscillations.

## 7. Grid progression logic

The grid uses a **data-driven progression model**. Each state defines `progresses_to`, `regresses_to`, and optionally `diverges_to` paths with conditions specified as notecard fields. Progression conditions are evaluated against **time-windowed trends** computed from timestamped pressure history, not poll counts. This makes the system immune to poll cadence and processor cycle timing — the grid measures real elapsed time and real pressure change, not "how many times I looked."

### Pressure history

The grid maintains a rolling window of `(timestamp, pressure)` pairs from each STATE_RESP. The trend is computed over a fixed time window (default: 5 minutes), regardless of how many polls fall within that window.

```
function record_pressure(history, timestamp, pressure)
    -- Append new reading
    table.insert(history, {ts = timestamp, val = pressure})

    -- Prune entries older than the window (10 min retention, 5 min eval window)
    local cutoff = timestamp - 600
    while #history > 0 and history[1].ts < cutoff do
        table.remove(history, 1)
    end

    return history
end
```

### Time-windowed trend computation

```
function compute_pressure_trend(history, window_seconds)
    local now = llGetUnixTime()
    local cutoff = now - window_seconds

    -- Filter to readings within the evaluation window
    local recent = {}
    for _, entry in ipairs(history) do
        if entry.ts >= cutoff then
            table.insert(recent, entry)
        end
    end

    if #recent < 2 then return 0 end

    -- Linear regression: timestamp vs pressure
    local n = #recent
    local sum_x, sum_y, sum_xy, sum_x2 = 0, 0, 0, 0
    for i, entry in ipairs(recent) do
        local x = entry.ts
        local y = entry.val
        sum_x = sum_x + x
        sum_y = sum_y + y
        sum_xy = sum_xy + x * y
        sum_x2 = sum_x2 + x * x
    end

    local slope = (n * sum_xy - sum_x * sum_y) / (n * sum_x2 - sum_x * sum_x)
    return slope * 60  -- convert hPa/sec to hPa/min
end
```

This is the **authoritative** trend for transition decisions. It is computed from actual pressure readings (which include the Proc3 driver offset mixed in by Proc2), over a 5-minute window at 15-second poll intervals (≈20 readings).

### Cross-checking with Proc3's driver trend

The grid also receives `pressure_trend` from Proc3 via `macro:evolution` in each STATE_RESP. This is Proc3's own trend computation from the background pressure driver offset history (25-second window). The two trends are independent computations:

| Metric | Grid (compute_pressure_trend) | Proc3 (driver trend) |
|--------|-------------------------------|----------------------|
| Source | Actual pressure readings | Driver offset history |
| Window | 300 seconds (5 min) | 25 seconds (10 cycles) |
| Unit | hPa/min | hPa/cycle |
| Purpose | Transition decisions | Cross-checking + gradient wind |

The grid's local trend is the primary input for progression decisions. The Proc3 trend is advisory — it responds faster (25s vs 5min) but is noisier. The grid uses its own slower, smoother trend for actual transition decisions.

### Sun phase detection

The grid uses `ll.GetSunDirection()` to determine the current sun phase for time-of-day-gated transitions. This respects custom sun cycles, accelerated days, and eternal-noon regions.

```
function get_sun_phase()
    local sun = ll.GetSunDirection()
    local z = sun.z  -- elevation
    local x = sun.x  -- east-west position

    if z <= 0 then
        return "night"     -- sun below horizon
    end

    if z < 0.5 then
        if x > 0 then
            return "morning"   -- sun rising in the east (+X), low elevation
        else
            return "evening"   -- sun setting in the west (-X), low elevation
        end
    end

    return "day"  -- sun high in the sky
end
```

Sun phases:
- `morning`: sun above horizon but low (`z < 0.5`) and in the eastern half (`x > 0`)
- `day`: sun above horizon and high (`z >= 0.5`)
- `evening`: sun above horizon but low and in the western half (`x < 0`)
- `night`: sun below horizon (`z <= 0`)

### Progression conditions

Conditions are **data-driven** — read from the current state's notecard definition, not hardcoded by state name. This makes the progression logic fully configurable without code changes. Each path type has its own condition fields:

**Progress** (deterioration — e.g., Clear → Cloudy):
- `progress_trend_max` — trigger if trend < this value (hPa/min, negative = falling)
- `progress_humidity_min` — trigger if humidity > this value
- `progress_morning` / `progress_day` / `progress_evening` / `progress_night` — sun-phase gates
- `progress_logic` — `"and"` or `"or"` (default: `"or"`). Sun-phase flags are always ANDed.

**Regress** (clearing — e.g., Storm → Rain):
- `regress_trend_min` — trigger if trend > this value (hPa/min, positive = rising)
- `regress_humidity_max` — trigger if humidity < this value
- `regress_morning` / `regress_day` / `regress_evening` / `regress_night` — sun-phase gates
- `regress_logic` — `"and"` or `"or"` (default: `"and"`). Sun-phase flags are always ANDed.

**Diverge** (event emergence — e.g., Clear → Khamsin):
- `diverge_pressure_max` — trigger if absolute pressure < this value
- `diverge_trend_max` — trigger if trend < this value (rapid drop)
- `diverge_humidity_min` / `diverge_humidity_max` — humidity bounds
- `diverge_temp_min` — trigger if temperature > this value
- `diverge_wind_speed_min` / `diverge_wind_speed_max` — wind speed bounds
- `diverge_morning` / `diverge_day` / `diverge_evening` / `diverge_night` — sun-phase gates
- `diverge_logic` — `"and"` or `"or"` (default: `"and"`). Sun-phase flags are always ANDed.

### Per-target condition overrides

When a state has multiple progression or divergence targets (comma-separated), conditions can be set for **each target individually** using slotted keys. The target name has spaces replaced with underscores:

```
diverges_to = Heat Wave, Coastal Mist, Sirocco
diverge_Heat_Wave_temp_min = 30
diverge_Heat_Wave_day = true
diverge_Coastal_Mist_humidity_min = 75
diverge_Coastal_Mist_morning = true
diverge_Sirocco_humidity_max = 55
diverge_Sirocco_pressure_max = 1006
```

If a per-target key exists (e.g., `diverge_Heat_Wave_temp_min`), it overrides the base key (`diverge_temp_min`) for that target. If no per-target key exists, the base key is used. The `*_logic` and sun-phase flags can also be overridden per target. See [NOTECARD_FORMAT.md](NOTECARD_FORMAT.md) for the full schema.

### Condition evaluation

```
function check_progression_condition(path_type, current_state_def, target_name,
                                     local_trend, current_values)
    local pressure = current_values.pressure or 1013
    local humidity = current_values.humidity or 50
    local temp = current_values.temp or 25
    local wind_speed = current_values.wind_speed or 0

    -- Look up condition values, preferring per-target overrides over base keys
    -- e.g. diverge_Heat_Wave_temp_min overrides diverge_temp_min

    if path_type == "progress" then
        local trend_threshold = get_condition_value("progress", target_name, "trend_max")
        local humidity_threshold = get_condition_value("progress", target_name, "humidity_min")
        local logic = get_condition_value("progress", target_name, "logic") or "or"

        if not trend_threshold and not humidity_threshold then return false end

        -- Sun-phase gate (ANDed with other conditions)
        if not sun_phase_allowed("progress", target_name) then return false end

        local trend_met = trend_threshold and local_trend < trend_threshold
        local humidity_met = humidity_threshold and humidity > humidity_threshold

        if logic == "and" then
            return all_defined_conditions_met(trend_met, humidity_met)
        else
            return trend_met or humidity_met
        end

    elseif path_type == "regress" then
        -- Similar structure, using regress_* fields
        -- Default logic: "and" (both conditions must confirm clearing)

    elseif path_type == "diverge" then
        -- Supports: pressure_max, trend_max, humidity_min, humidity_max,
        -- temp_min, wind_speed_min, wind_speed_max, sun-phase flags
        -- Default logic: "and" (all conditions must align for event emergence)
    end
end
```

### Progression evaluation

```
function evaluate_progression(current_state_def, season, current_values, transition_state)
    -- Don't transition if in cooldown (6 cycles = 90 seconds at 15s polls)
    if transition_state.cooldown > 0 then
        transition_state.cooldown = transition_state.cooldown - 1
        return nil
    end

    -- Don't evaluate if minimum duration hasn't been reached
    local duration_timer = (transition_state.duration_timer or 0) + 1
    transition_state.duration_timer = duration_timer
    if duration_timer < (transition_state.duration_min or 0) then
        return nil
    end

    -- Compute time-windowed trend (5 minutes)
    local local_trend = compute_pressure_trend(transition_state.pressure_history, 300)

    -- Gather all candidate paths (progresses_to, regresses_to, diverges_to)
    local candidates = gather_progression_candidates(current_state_def)

    -- Check which candidates have their condition met
    local ready = {}
    for _, cand in ipairs(candidates) do
        local def = get_state_definition(season, cand.name)
        if def then
            local condition_met = check_progression_condition(
                cand.type, current_state_def, cand.name, local_trend, current_values)
            if condition_met then
                table.insert(ready, {def = def, name = cand.name, path_type = cand.type})
            end
        end
    end

    -- If exactly one candidate is ready, transition to it
    if #ready == 1 then
        transition_state.cooldown = 6
        transition_state.duration_timer = 0
        return ready[1].name, ready[1].def

    -- If multiple candidates are ready, use weight as tiebreaker
    elseif #ready > 1 then
        local chosen = pick_among_ready(ready)
        transition_state.cooldown = 6
        transition_state.duration_timer = 0
        return chosen._name, chosen
    end

    -- No candidates ready — check duration expiry
    if duration_timer >= (transition_state.duration_target or 999) then
        -- Duration expired — prefer regression, then progression
        for _, cand in ipairs(candidates) do
            if cand.type == "regress" then
                local def = get_state_definition(season, cand.name)
                if def then
                    transition_state.cooldown = 6
                    transition_state.duration_timer = 0
                    return cand.name, def
                end
            end
        end
        for _, cand in ipairs(candidates) do
            if cand.type == "progress" then
                local def = get_state_definition(season, cand.name)
                if def then
                    transition_state.cooldown = 6
                    transition_state.duration_timer = 0
                    return cand.name, def
                end
            end
        end
    end

    return nil
end
```

### Weight as tiebreaker

If multiple progression paths have their conditions met simultaneously, `weight` breaks the tie using weighted random selection:

```
function pick_among_ready(ready_candidates)
    local total_weight = 0
    for _, cand in ipairs(ready_candidates) do
        total_weight = total_weight + (cand.def.weight or 1)
    end

    local roll = math.random() * total_weight
    local cumulative = 0
    for _, cand in ipairs(ready_candidates) do
        cumulative = cumulative + (cand.def.weight or 1)
        if roll <= cumulative then
            return cand.def
        end
    end

    return ready_candidates[1].def
end
```

### Why time-windowed trends, not poll counts

The previous design used a counter incremented when a condition was met and decremented when not. Three consecutive hits triggered a transition. This had two problems:

1. **Cadence dependency**: "3 consecutive polls" means different things at different poll rates. At 15s polling, that's 45 seconds of evidence. At 120s polling, that's 6 minutes. The threshold's real-time meaning changed with cadence.
2. **Noise sensitivity**: A brief noise spike lasting 2-3 polls could trigger a transition. The counter didn't distinguish "sustained trend" from "lucky sampling."

The time-windowed approach fixes both: the trend is computed over a fixed 5-minute window regardless of poll cadence, and linear regression averages out noise. More polls in the window just means better precision — the threshold stays the same in real time.

### Extracting target parameters

When a transition is decided, the grid extracts the target parameters from the new state's notecard definition and sends them via TARGET_PUSH. This includes seasonal wind base values so Proc3 can configure its wind driver (Proc3 is in a different linkset and can't read the grid's `season:` config keys):

```
function extract_targets_from_state(state_def, season)
    local season_config = read_lsd("season:" .. season) or {}

    return {
        temp_base = state_def.temp_base,
        temp_diurnal = state_def.temp_diurnal,
        temp_phase = state_def.temp_phase,
        humidity = state_def.humidity,
        pressure = state_def.pressure,
        wind_speed_mod = state_def.wind_speed_mod or 0,
        wind_dir_mod = state_def.wind_dir_mod or 0,
        wind_variability_mod = state_def.wind_variability_mod or 0,
        -- Seasonal wind base values (so Proc3 can configure its wind driver)
        wind_base_speed = season_config.wind_base_speed,
        wind_base_dir = season_config.wind_base_dir,
        wind_variability = season_config.wind_variability,
        -- Ramp duration for two-phase transition
        wind_ramp_seconds = ramp_seconds,
        precipitation = state_def.precipitation,
        dust = state_def.dust,
        visibility = state_def.visibility,
        eep_preset = state_def.eep_preset,
        particle = state_def.particle,
        -- Flood modifiers (applied by Proc2 based on current flood state)
        flood_peak_humidity = state_def.flood_peak_humidity,
        flood_receding_humidity = state_def.flood_receding_humidity,
        flood_low_dust = state_def.flood_low_dust,
        flood_rising_humidity = state_def.flood_rising_humidity,
    }
end
```

The wind fields use a split base/modifier design: `wind_base_speed`, `wind_base_dir`, and `wind_variability` come from the season configuration (the seasonal baseline), while `wind_speed_mod`, `wind_dir_mod`, and `wind_variability_mod` come from the state definition (the weather-state-specific adjustment). Proc3 combines the base and modifier to compute the actual wind (see [Wind speed model](#4-wind-speed-model-proc3)). `wind_ramp_seconds` controls the transition ramp duration for both Proc2's target interpolation and Proc3's wind modifier interpolation.

### Initial state bootstrap

On boot, the grid always starts in Clear Skies for the current season. It sends Clear Skies targets to the processor on registration. On the first poll, the grid evaluates whether the computed values strongly indicate a different state. If so, it jumps directly — bypassing normal progression.

```
function bootstrap_evaluate(current_values, season)
    -- Called once on first poll after boot
    -- Returns: state_def to jump to, or nil to stay in Clear Skies

    local pressure = current_values.pressure or 1013
    local pressure_trend = current_values.pressure_trend or 0

    local clear_skies = get_state_definition(season, "Clear Skies")
    if not clear_skies then return nil end

    local baseline_pressure = clear_skies.pressure or 1013
    local delta = pressure - baseline_pressure

    -- If pressure is >8 hPa below baseline AND trend is rapidly falling → event state
    if delta < -8 and pressure_trend < -0.2 then
        -- Find an event state in this season (Khamsin, Storm, Sirocco, etc.)
        local event_names = {"Khamsin", "Storm"}
        for _, name in ipairs(event_names) do
            local def = get_state_definition(season, name)
            if def and def.event then
                return def
            end
        end
    end

    -- Moderate drop → Cloudy
    if delta < -5 then
        local cloudy = get_state_definition(season, "Cloudy")
        if cloudy then return cloudy end
    end

    -- Slight drop → Partly Cloudy
    if delta < -2 then
        local partly = get_state_definition(season, "Partly Cloudy")
        if partly then return partly end
    end

    return nil  -- Stay in Clear Skies
end
```

This is a one-time call. After the first poll, the grid switches to normal `evaluate_progression()` and never calls `bootstrap_evaluate()` again unless it reboots.

## 8. Duration parsing

The `duration` field in notecard states is a min-max range (e.g., `4-9`). Parse it:

```
function parse_duration(duration_str)
    -- "4-9" → min=4, max=9 (hours)
    -- "7" → min=7, max=7
    local min_str, max_str = string.match(duration_str, "(%d+)%s*-%s*(%d+)")
    if min_str and max_str then
        return tonumber(min_str), tonumber(max_str)
    end

    local single = string.match(duration_str, "(%d+)")
    if single then
        return tonumber(single), tonumber(single)
    end

    return 1, 6  -- default fallback
end
```

When a state is entered, pick a random duration within the range:

```
local min_dur, max_dur = parse_duration(state.duration)
local chosen_duration = min_dur + math.random() * (max_dur - min_dur)
```

Convert to cycles: at 15-second polls, 1 hour = 240 cycles.

```
local duration_cycles = math.floor(chosen_duration * 240)
```

The duration is split into `duration_min` (the minimum hours, converted to cycles) and `duration_target` (the randomly chosen duration in cycles). The grid won't evaluate progression conditions until `duration_min` has passed, and will force a regression/progression when `duration_target` expires.

## 9. Summary of what runs where

| Computation | Where it runs | Frequency |
|---|---|---|
| Season determination | Grid | On boot, on season change |
| Season blending | Grid | Every poll (in last 7 days of season) |
| Bootstrap state evaluation | Grid | First poll only after boot |
| Sun phase detection | Grid | Every poll (for time-gated transitions) |
| Diurnal temperature (from sun direction) | Proc2 | Every cycle (7.5s) |
| Maritime influence | Proc2 | Every cycle (reads wind from Proc3 driver) |
| State evolution (relaxation + noise) | Proc2 (micro) | Every cycle (7.5s) |
| Target interpolation (two-phase transition) | Proc2 | On TARGET_PUSH (ramps over wind_ramp_seconds) |
| Flood modifier application | Proc2 | Every cycle (reads flood state from LSD) |
| Pressure driver mixing | Proc2 | Every cycle (reads drivers:pressure, adds offset) |
| Wind speed model (calm/gust, diurnal, gradient) | Proc3 | Every cycle (2.5s) |
| Wind direction (sea breeze, noise, relaxation) | Proc3 | Every cycle (2.5s) |
| Wind state modifier interpolation | Proc3 | On TARGET_PUSH (ramps over wind_ramp_seconds) |
| Nile flood state | Proc3 | Once per day (or on boot) |
| Background pressure driver (sinusoid, noise, dips) | Proc3 | Every cycle (2.5s) |
| Thermal & moisture pressure coupling | Proc3 | Every cycle (reads drivers:conditions) |
| Pressure trend exposure (pass-through) | Proc1 | Every cycle (reads drivers:pressure, writes to macro:evolution) |
| Pressure history recording | Grid | Every poll (15s ±5s jitter) |
| Time-windowed trend computation | Grid | Every poll (5-min linear regression over history) |
| Driver trend cross-check | Grid | Every poll (compares local trend vs Proc3 trend) |
| Progression condition check (data-driven) | Grid | Every poll (evaluates candidates against local trend + sun phase) |
| Progression decision (condition + duration) | Grid | Every poll |
| Weight tiebreaker (if multiple paths ready) | Grid | On simultaneous condition met |
| Target parameter extraction | Grid | On progression decision |
| Duration parsing | Grid | On state entry |
