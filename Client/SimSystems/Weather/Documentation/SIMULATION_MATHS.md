# Weather Simulation Maths

Reference for the computational models used by the processor scripts and the grid's transition logic. All formulas are designed for SLua's constraints: 64 KB working set, no external libraries, float64 arithmetic.

## 1. Diurnal temperature

Temperature is computed continuously from the time of day, not stored as a static value. The processor computes this each cycle.

### Formula

```
hour = llGetWallclock() / 3600  -- seconds since midnight → hours (0 to 24)
angle = ((hour - temp_phase) / 24) * 2 * math.pi
temp = temp_base + temp_diurnal * math.cos(angle)
```

Where:
- `temp_base` — daily mean temperature (from current target parameters)
- `temp_diurnal` — half the day/night swing amplitude (from current target parameters)
- `temp_phase` — hour of peak temperature (typically 14, as peak heat lags solar noon by ~2 hours)
- `llGetWallclock()` — SL function returning seconds since midnight in SL time

### Verification

- At `hour = temp_phase` (e.g., 14:00): `angle = 0`, `cos(0) = 1`, so `temp = temp_base + temp_diurnal` (peak). Correct.
- At `hour = temp_phase + 12` (e.g., 02:00): `angle = π`, `cos(π) = -1`, so `temp = temp_base - temp_diurnal` (trough). Correct.
- At `hour = temp_phase + 6` (e.g., 20:00): `angle = π/2`, `cos(π/2) = 0`, so `temp = temp_base` (mean). Correct — evening is passing through the mean on the way down.

### Why not sun direction?

`llGetSunDirection()` returns a 3D vector, and its z-component gives sun elevation. However, mapping elevation to time-of-day is not straightforward — elevation is already a sinusoidal function of time, so using it as an input to another sinusoid produces a distorted curve. The relationship between elevation and time also depends on latitude and season.

Using `llGetWallclock()` directly gives a clean linear time input, which produces a correct cosine curve. SL's day is approximately 4 hours of real time for 24 hours of sim time, but `llGetWallclock()` already accounts for this — it returns SL time, not real time.

If a region has a non-standard sun configuration (e.g., eternal noon), the diurnal curve will still produce a value, but it won't track the actual sun. That's acceptable — the temperature model is a function of *time*, not *sun position*, and the two are only loosely coupled in reality anyway (thermal lag means peak temperature is not at solar noon).

## 2. State evolution (relaxation model)

The processor evolves each computed value toward its target each cycle using a relaxation model with stochastic noise.

### Formula

```
new_value = current_value + (target_value - current_value) * rate + noise
```

Where:
- `current_value` — the last computed value (stored in LSD)
- `target_value` — the target parameter (from `<grid_uuid>:targets`)
- `rate` — relaxation rate (0 to 1, from evolution state)
- `noise` — stochastic perturbation

### Relaxation rate

`rate` controls how fast values converge to targets. Higher = faster convergence but less smooth. Lower = more gradual, more natural.

Suggested default: `rate = 0.1` (10% of the gap closed per cycle). With a 7.5-second cycle, this reaches ~95% of target in about 225 seconds (≈30 cycles, since `0.9^30 ≈ 0.04` remaining gap).

For event states (khamsin, storms), a higher rate may be appropriate — these should feel sudden:

```
if event_state then
    rate = 0.3  -- faster convergence for dramatic transitions
else
    rate = 0.1  -- gradual for normal state changes
end
```

### Noise

Noise prevents the evolution from looking mechanical. It should be scaled to the value's natural variability:

```
noise = (math.random() - 0.5) * 2 * noise_scale * variability
```

Where:
- `math.random()` returns 0 to 1, so `(math.random() - 0.5) * 2` gives -1 to 1
- `noise_scale` — from evolution state (suggested default: 0.05, i.e. ±5% of variability)
- `variability` — the field's variability parameter (e.g., `wind_variability` for wind speed)

For wind, which has its own `wind_variability` field:

```
wind_noise = (math.random() - 0.5) * 2 * noise_scale * wind_variability * target_wind_speed
new_wind_speed = current_wind_speed + (target_wind_speed - current_wind_speed) * rate + wind_noise
```

For fields without a specific variability parameter (humidity, pressure, dust, etc.), use a small fixed noise scale:

```
field_noise = (math.random() - 0.5) * 2 * 0.02 * target_value  -- ±2% of target
```

### Per-field application

Each micro field is evolved independently:

```
-- Temperature (special: uses diurnal formula, not pure relaxation)
temp = diurnal_temp(temp_base, temp_diurnal, temp_phase, sun)
-- Then apply relaxation toward the diurnal result (smooths day-to-day transitions)
new_temp = current_temp + (temp - current_temp) * rate + temp_noise

-- Humidity
new_humidity = current_humidity + (target_humidity - current_humidity) * rate + humidity_noise

-- Pressure
new_pressure = current_pressure + (target_pressure - current_pressure) * rate + pressure_noise

-- Wind speed
new_wind_speed = current_wind_speed + (target_wind_speed - current_wind_speed) * rate + wind_noise

-- Wind direction (special: circular interpolation, see below)
new_wind_dir = circular_lerp(current_wind_dir, target_wind_dir, rate)

-- Dust
new_dust = current_dust + (target_dust - current_dust) * rate + dust_noise

-- Precipitation
new_precip = current_precip + (target_precip - current_precip) * rate + precip_noise

-- Visibility
new_visibility = current_visibility + (target_visibility - current_visibility) * rate
```

Temperature is special: the *target* itself changes throughout the day (it's the diurnal curve), so the processor computes the diurnal target each cycle and relaxes toward it. This means temperature is always chasing a moving target, which naturally produces smooth day-night transitions.

### Target interpolation (two-phase transition)

When the grid pushes new targets (via TARGET_PUSH), Proc2 does not apply them instantly. Instead it stores the old targets and interpolates all numeric fields toward the new values over a ramp period. This produces smooth transitions between weather states — temperature, humidity, pressure, and wind modifiers ramp gradually rather than snapping.

```
progress = 1.0 - (ramp_remaining / ramp_total)
effective_target = old_target + (new_target - old_target) * progress
```

Where:
- `old_target` — the target value at the moment the new targets arrived
- `new_target` — the incoming target value from TARGET_PUSH
- `ramp_remaining` — seconds left in the ramp (decremented each cycle)
- `ramp_total` — the ramp duration in seconds (from `wind_ramp_seconds` in the targets, default: 300s)

Each cycle, `ramp_remaining` is decremented by the cycle interval. When it reaches 0, `effective_target` equals `new_target` and the ramp is complete — Proc2 then uses `new_target` directly.

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
- `WIND_DIURNAL_DIR_SHIFT` — maximum shift in degrees at full daytime (e.g., 30)

Daytime (positive `diurnal`) shifts the target toward `sea_direction` (onshore breeze). Nighttime (negative `diurnal`) shifts it away (offshore). The `wind_dir_mod` term is the state-specific direction modifier interpolated by Proc2 (see [Target interpolation](#target-interpolation-two-phase-transition)).

### Direction noise

Stochastic perturbation prevents the direction from looking mechanical:

```
dir_noise = (math.random() - 0.5) * 2 * WIND_DIR_NOISE_DEGREES * variability
```

Where:
- `WIND_DIR_NOISE_DEGREES` — maximum noise swing in degrees (default: 30)
- `variability` — the wind variability factor for the current state

### Direction relaxation

The current direction relaxes toward the computed target using circular interpolation:

```
wind_current_dir = circular_lerp(wind_current_dir, dir_target, WIND_DIR_RELAX_RATE)
```

Where `WIND_DIR_RELAX_RATE` is the per-cycle relaxation rate (default: 0.03). At a 2.5-second cycle this reaches ~95% of target in about 250 seconds (≈100 cycles, since `0.97^100 ≈ 0.048` remaining gap).

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

### Pressure gradient wind

Proc3 reads the pressure trend from `drivers:pressure` (written by its own pressure driver) and converts it into a gradient wind component:

```
gradient_wind = -pressure_trend_hpa_per_min * GRADIENT_WIND_FACTOR
```

Where:
- `pressure_trend_hpa_per_min` — rate of pressure change in hPa per minute (from `drivers:pressure.trend`)
- `GRADIENT_WIND_FACTOR` — conversion constant (default: 50)

Falling pressure (negative trend) produces a positive `gradient_wind` (stronger wind), modelling the increased wind ahead of an approaching low. Rising pressure produces weaker wind.

### State modifier interpolation

When Proc2 pushes new targets (via TARGET_PUSH), the `wind_speed_mod` field may change. Proc3 does not apply the new modifier instantly — it interpolates from the old value to the new value over a ramp period:

```
current_mod = old_mod + (new_mod - old_mod) * (1 - ramp_remaining / ramp_total)
```

Where:
- `old_mod` — the modifier value at the start of the ramp
- `new_mod` — the target modifier from the new targets
- `ramp_remaining` — seconds left in the ramp (decremented each cycle)
- `ramp_total` — the ramp duration in seconds (default: 300s, from `wind_ramp_seconds` in the targets)

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
- `variability` — the wind variability factor for the current state

At a 2.5-second cycle with `WIND_SPEED_RELAX_RATE = 0.03`, the speed reaches ~95% of target in about 250 seconds (≈100 cycles).

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

When Proc2 computes humidity (or any field with flood modifiers), it checks the current flood state and applies the relevant delta:

```
function apply_flood_modifiers(field_value, target, flood_state, nile_adjacent)
    if not nile_adjacent then
        return field_value  -- no modifiers for non-riverine grids
    end

    -- target is the weather state's parameter table
    -- flood modifiers are named flood_<state>_<field> in the target
    local modifier_key = "flood_" .. flood_state .. "_humidity"
    local modifier = target[modifier_key]

    if modifier then
        return field_value + modifier
    end

    return field_value
end
```

The modifier is a delta (e.g., `+15` for `flood_peak_humidity`), applied after the relaxation step but before writing to LSD.

## 6. Background pressure driver (Proc3)

Proc3 generates an independent background pressure signal that Proc2 mixes into its pressure evolution. This provides an external forcing function — pressure systems move through regions independently of local weather — giving the grid something other than its own reflected targets to evaluate when making progression decisions.

### Model

A slow sinusoidal wave with stochastic noise, simulating passing pressure systems:

```
-- Proc3 maintains internal state across cycles:
--   pressure_phase: current phase of the sinusoidal wave (radians)
--   pressure_period: cycles per full wave (e.g., 480 = 20 minutes at 2.5s cycles)

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
    local temp = conditions.temp or 0
    local seasonal_temp_avg = conditions.seasonal_temp_avg or 0
    local thermal_offset = -(temp - seasonal_temp_avg) * TEMP_PRESSURE_FACTOR

    -- Moisture coupling: moist air above seasonal mean → lower pressure
    local humidity = conditions.humidity or 0
    local seasonal_humidity_avg = conditions.seasonal_humidity_avg or 0
    local moisture_offset = -(humidity - seasonal_humidity_avg) * HUMIDITY_PRESSURE_FACTOR

    local total_offset = base_offset + noise + dip_offset
                         + thermal_offset + moisture_offset

    -- Compute trend (rate of change) from last few offsets
    -- Store last 10 offsets for trend computation
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
- `seasonal_temp_avg` — seasonal mean temperature (from `drivers:conditions`)
- `TEMP_PRESSURE_FACTOR` — hPa change per °C above/below the seasonal mean (default: 0.3)

A temperature 10 °C above the seasonal average produces a -3 hPa offset. This couples heat waves and cold snaps to pressure, reinforcing the progression toward storm or clear conditions.

**Moisture coupling** — humid air is less dense and exerts lower surface pressure:

```
moisture_offset = -(humidity - seasonal_humidity_avg) * HUMIDITY_PRESSURE_FACTOR
```

Where:
- `humidity` — current computed humidity (from `drivers:conditions`)
- `seasonal_humidity_avg` — seasonal mean humidity (from `drivers:conditions`)
- `HUMIDITY_PRESSURE_FACTOR` — hPa change per % above/below the seasonal mean (default: 0.05)

A humidity 20 % above the seasonal average produces a -1 hPa offset. This is a smaller effect than thermal coupling but adds realism — humid air masses correlate with lower pressure.

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

Proc1 reads `drivers:pressure` and includes the trend in `<grid_uuid>:macro:evolution` so the grid can evaluate it via STATE_RESP:

```
local pressure_driver = read_lsd("drivers:pressure")
local evolution = read_lsd("<grid_uuid>:macro:evolution")
evolution.pressure_trend = pressure_driver.trend
evolution.pressure_driver_offset = pressure_driver.offset
write_lsd("<grid_uuid>:macro:evolution", evolution)
```

The grid reads `pressure_trend` from the STATE_RESP payload and uses it in progression condition evaluation. This is the independent signal that breaks the circular dependency.

### Trend computation

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

### Interpretation

| Trend (hPa/cycle) | Meaning |
|---|---|
| > +0.1 | Rising pressure — improving conditions, clearing weather |
| -0.1 to +0.1 | Stable — no progression pressure |
| -0.3 to -0.1 | Falling — deterioration, progression toward cloudy/rain likely |
| < -0.3 | Rapidly falling — khamsin or storm divergence likely |

These thresholds are per-cycle at 2.5-second cycles. Scale accordingly for different cycle lengths.

## 7. Grid progression logic

The grid uses a **staged progression model**. Each state defines `progresses_to`, `regresses_to`, and optionally `diverges_to` paths. Progression conditions are evaluated against **time-windowed trends** computed from timestamped pressure history, not poll counts. This makes the system immune to poll cadence and processor cycle timing — the grid measures real elapsed time and real pressure change, not "how many times I looked."

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

### Cross-checking with Proc3's driver trend

The grid also receives `pressure_trend` from Proc3 via `macro:evolution` in each STATE_RESP. This is Proc3's own trend computation from the background pressure driver. The grid can cross-check its local trend against Proc3's trend:

- **Both agree** (same sign, similar magnitude): the signal is real — proceed with progression evaluation.
- **They disagree**: the grid's local trend is more trustworthy because it's computed over a longer window (5 min vs Proc3's rolling 10-cycle window). Use the local trend.
- **Local trend is near zero but Proc3 reports steep trend**: the processor hasn't caught up yet (relaxation lag). Wait — the computed values will shift soon.

This cross-check is advisory, not gating. The grid's local trend is the primary input for progression decisions.

### Progression conditions

Conditions are evaluated against the time-windowed trend (hPa/min) and current values:

```
function check_progression_condition(path_type, candidate, local_trend, current_values)
    local pressure = current_values.pressure or 1013
    local humidity = current_values.humidity or 50

    if path_type == "progress" then
        -- Deterioration: sustained pressure drop over 5 min
        if candidate.name:find("Cloudy") then
            return local_trend < -0.05 or humidity > 70
        elseif candidate.name:find("Rain") then
            return local_trend < -0.1 and humidity > 72
        elseif candidate.name:find("Storm") or candidate.name:find("Thunder") then
            return local_trend < -0.2 and humidity > 75
        end
        return false

    elseif path_type == "regress" then
        -- Clearing: sustained pressure rise over 5 min
        if candidate.name == "Clear Skies" then
            return local_trend > 0.05 and humidity < 65
        elseif candidate.name:find("Partly Cloudy") then
            return local_trend > 0 or humidity < 70
        end
        return false

    elseif path_type == "diverge" then
        -- Event: rapid sustained drop over 5 min + absolute threshold
        if candidate.event and pressure < 1008 and local_trend < -0.3 then
            return true
        end
        return false
    end

    return false
end
```

### Progression evaluation

```
function evaluate_progression(current_state, state_defs, current_values,
                              pressure_history, transition_state)
    -- Don't transition if in cooldown
    if transition_state.cooldown > 0 then
        transition_state.cooldown = transition_state.cooldown - 1
        return nil
    end

    -- Compute time-windowed trend (5 minutes)
    local local_trend = compute_pressure_trend(pressure_history, 300)

    -- Gather all candidate paths from current state
    local candidates = {}
    if current_state.progresses_to then
        for _, name in ipairs(split(current_state.progresses_to, ",")) do
            table.insert(candidates, {type = "progress", name = trim(name)})
        end
    end
    if current_state.regresses_to then
        for _, name in ipairs(split(current_state.regresses_to, ",")) do
            table.insert(candidates, {type = "regress", name = trim(name)})
        end
    end
    if current_state.diverges_to then
        for _, name in ipairs(split(current_state.diverges_to, ",")) do
            table.insert(candidates, {type = "diverge", name = trim(name)})
        end
    end

    -- Check which candidates have their condition met
    local ready = {}
    for _, cand in ipairs(candidates) do
        local def = state_defs[cand.name]
        if def and check_progression_condition(cand.type, def, local_trend, current_values) then
            table.insert(ready, {type = cand.type, name = cand.name, def = def})
        end
    end

    -- If exactly one candidate is ready, transition to it
    if #ready == 1 then
        transition_state.cooldown = 3
        transition_state.duration_timer = 0
        return ready[1].def
    end

    -- If multiple candidates are ready, use weight as tiebreaker
    if #ready > 1 then
        local chosen = pick_among_ready(ready, state_defs)
        transition_state.cooldown = 3
        transition_state.duration_timer = 0
        return chosen
    end

    -- No candidates ready — check duration expiry
    transition_state.duration_timer = (transition_state.duration_timer or 0) + 1
    if transition_state.duration_timer >= (transition_state.duration_target or 999) then
        -- Duration expired — prefer regression, then progression
        for _, cand in ipairs(candidates) do
            if cand.type == "regress" then
                local def = state_defs[cand.name]
                if def then
                    transition_state.cooldown = 3
                    transition_state.duration_timer = 0
                    return def
                end
            end
        end
        for _, cand in ipairs(candidates) do
            if cand.type == "progress" then
                local def = state_defs[cand.name]
                if def then
                    transition_state.cooldown = 3
                    transition_state.duration_timer = 0
                    return def
                end
            end
        end
    end

    return nil
end
```

### Weight as tiebreaker

If multiple progression paths have their conditions met simultaneously, `weight` breaks the tie:

```
function pick_among_ready(ready_candidates, state_defs)
    local total_weight = 0
    for _, cand in ipairs(ready_candidates) do
        total_weight = total_weight + (state_defs[cand.name].weight or 1)
    end

    local roll = math.random() * total_weight
    local cumulative = 0
    for _, cand in ipairs(ready_candidates) do
        cumulative = cumulative + (state_defs[cand.name].weight or 1)
        if roll <= cumulative then
            return state_defs[cand.name]
        end
    end

    return state_defs[ready_candidates[1].name]
end
```

### Why time-windowed trends, not poll counts

The previous design used a counter incremented when a condition was met and decremented when not. Three consecutive hits triggered a transition. This had two problems:

1. **Cadence dependency**: "3 consecutive polls" means different things at different poll rates. At 15s polling, that's 45 seconds of evidence. At 120s polling, that's 6 minutes. The threshold's real-time meaning changed with cadence.
2. **Noise sensitivity**: A brief noise spike lasting 2-3 polls could trigger a transition. The counter didn't distinguish "sustained trend" from "lucky sampling."

The time-windowed approach fixes both: the trend is computed over a fixed 5-minute window regardless of poll cadence, and linear regression averages out noise. More polls in the window just means better precision — the threshold stays the same in real time.

### Extracting target parameters

When a transition is decided, the grid extracts the target parameters from the new state's notecard definition and sends them via TARGET_PUSH:

```
function extract_targets(state_definition, season_config, ramp_seconds)
    return {
        temp_base = state_definition.temp_base,
        temp_diurnal = state_definition.temp_diurnal,
        temp_phase = state_definition.temp_phase,
        humidity = state_definition.humidity,
        pressure = state_definition.pressure,
        wind_speed_mod = state_definition.wind_speed_mod or 0,
        wind_dir_mod = state_definition.wind_dir_mod or 0,
        wind_variability_mod = state_definition.wind_variability_mod or 0,
        wind_base_speed = season_config.wind_base_speed,
        wind_base_dir = season_config.wind_base_dir,
        wind_variability_base = season_config.wind_variability,
        wind_ramp_seconds = ramp_seconds,
        precipitation = state_definition.precipitation,
        dust = state_definition.dust,
        visibility = state_definition.visibility,
        eep_preset = state_definition.eep_preset,
        particle = state_definition.particle,
        -- Flood modifiers included so processor can apply them
        -- based on current flood state from drivers:flood_state
        flood_peak_humidity = state_definition.flood_peak_humidity,
        flood_receding_humidity = state_definition.flood_receding_humidity,
        flood_low_dust = state_definition.flood_low_dust,
        flood_rising_humidity = state_definition.flood_rising_humidity,
    }
end
```

Note: flood modifiers are included in the target set so the processor knows what modifiers to apply for this state. The processor checks `drivers:flood_state` and applies the matching modifier. This keeps the flood logic in the processor (where the driver data lives) while keeping the modifier definitions in the grid (where the state definitions live).

The wind fields use a split base/modifier design: `wind_base_speed`, `wind_base_dir`, and `wind_variability_base` come from the season configuration (the seasonal baseline), while `wind_speed_mod`, `wind_dir_mod`, and `wind_variability_mod` come from the state definition (the weather-state-specific adjustment). Proc3 combines the base and modifier to compute the actual wind (see [Wind speed model](#4-wind-speed-model-proc3)). `wind_ramp_seconds` controls the transition ramp duration for both Proc2's target interpolation and Proc3's wind modifier interpolation.

### Initial state bootstrap

On boot, the grid always starts in Clear Skies for the current season. It sends Clear Skies targets to the processor on registration. On the first poll, the grid evaluates whether the computed values strongly indicate a different state. If so, it jumps directly — bypassing normal progression.

```
function bootstrap_evaluate(current_values, state_defs, season)
    -- Called once on first poll after boot
    -- Returns: state_def to jump to, or nil to stay in Clear Skies

    local pressure = current_values.pressure or 1013
    local humidity = current_values.humidity or 50
    local pressure_trend = current_values.pressure_trend or 0

    -- Strong indicators: pressure well below seasonal Clear Skies baseline
    local clear_skies = state_defs[season .. ":Clear Skies"]
    if not clear_skies then return nil end

    local baseline_pressure = clear_skies.pressure or 1013
    local delta = pressure - baseline_pressure

    -- If pressure is >8 hPa below baseline, jump to the deepest matching state
    if delta < -8 and pressure_trend < -0.2 then
        -- Rapid drop + very low pressure → event state (Khamsin/Storm)
        for name, def in pairs(state_defs) do
            if def.event and string.find(name, season) then
                return def
            end
        end
    elseif delta < -5 then
        -- Moderate drop → Cloudy or Rain
        local cloudy = state_defs[season .. ":Cloudy"]
        if cloudy then return cloudy end
    elseif delta < -2 then
        -- Slight drop → Partly Cloudy
        local partly = state_defs[season .. ":Partly Cloudy"]
        if partly then return partly end
    end

    -- No strong indicator — stay in Clear Skies
    return nil
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
local duration_cycles = chosen_duration * 240
```

## 9. Summary of what runs where

| Computation | Where it runs | Frequency |
|---|---|---|
| Season determination | Grid | On boot, on season change |
| Season blending | Grid | Every poll (in last 7 days of season) |
| Bootstrap state evaluation | Grid | First poll only after boot |
| Diurnal temperature | Proc2 | Every cycle (7.5s) |
| State evolution (relaxation + noise) | Proc1 (macro), Proc2 (micro) | Every cycle (7.5s) |
| Target interpolation (two-phase transition) | Proc2 | On TARGET_PUSH (ramps over wind_ramp_seconds) |
| Wind direction interpolation | Proc2 | Every cycle (7.5s) |
| Wind speed model (calm/gust, diurnal, gradient) | Proc3 | Every cycle (2.5s) |
| Nile flood state | Proc3 | Once per day (or on boot) |
| Flood modifier application | Proc2 | Every cycle (reads flood state from LSD) |
| Background pressure driver | Proc3 | Every cycle (2.5s) |
| Thermal & moisture pressure coupling | Proc3 | Every cycle (reads drivers:conditions) |
| Pressure driver mixing | Proc2 | Every cycle (reads drivers:pressure, adds offset) |
| Pressure trend exposure | Proc1 | Every cycle (reads drivers:pressure, writes to macro:evolution) |
| Pressure history recording | Grid | Every poll (15s ±5s jitter) |
| Time-windowed trend computation | Grid | Every poll (5-min linear regression over history) |
| Driver trend cross-check | Grid | Every poll (compares local trend vs Proc3 trend) |
| Progression condition check | Grid | Every poll (evaluates candidates against local trend) |
| Progression decision (condition + duration) | Grid | Every poll |
| Weight tiebreaker (if multiple paths ready) | Grid | On simultaneous condition met |
| Target parameter extraction | Grid | On progression decision |
| Duration parsing | Grid | On state entry |
