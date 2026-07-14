# Alexandria Notecard Format

This document describes the format of the Alexandria weather notecard (`Alexandria_Oasis.notecard`). The notecard is parsed by the grid script at startup and defines the grid's configuration, seasons, and weather states.

## File structure

The notecard is divided into sections. Each section starts with a scope header and contains key-value pairs. Comments start with `#` and run to the end of the line.

```
{grid: Alexandria Oasis}
  # Global configuration (bounding box, climate, wind defaults, etc.)

{season: Akhet}
  # Season-level fields (seasonal wind overrides, etc.)

  [Clear Skies]
    # State-level fields for Clear Skies in Akhet

  [Partly Cloudy]
    # State-level fields for Partly Cloudy in Akhet

  ...

{season: Peret}
  # Season-level fields
  ...

{season: Shemu}
  # Season-level fields
  ...
```

## `{grid}` section — global configuration

Required fields:

| Field | Type | Description |
|---|---|---|
| `biome` | string | Biome identifier (e.g. `desert_coast`) |
| `climate` | string | Climate identifier (e.g. `mediterranean_arid`) |
| `lat` | number | Latitude in degrees (e.g. `31.2`) |
| `eep_enabled` | boolean | Whether to apply EEP presets (`true`/`false`) |
| `nile_adjacent` | boolean | Whether the grid is affected by Nile flood modifiers (`true`/`false`) |
| `sea_direction` | cardinal | Direction of the sea from the grid (e.g. `N`, `NW`, `S`) — used for maritime influence and diurnal sea breeze |
| `sea_temp_modifier` | number | How many °C the sea wind cools / land wind warms the air at full alignment (default: `1.0`) |
| `sea_humidity_modifier` | number | How many percentage points the sea wind humidifies / land wind dries the air at full alignment (default: `8.0`) |
| `min_x`, `min_y`, `min_z` | number | Bounding box minimum corner in region coordinates |
| `max_x`, `max_y`, `max_z` | number | Bounding box maximum corner in region coordinates |

Optional global wind fields (annual defaults, can be overridden per season):

| Field | Type | Description |
|---|---|---|
| `wind_base_speed` | number | Annual average wind speed in kph |
| `wind_base_dir` | cardinal | Annual prevailing wind direction |
| `wind_variability` | number | Annual wind variability (0.0 to 1.0) |
| `wind_gust_factor` | number | Gust multiplier for calm/gust oscillation |
| `wind_calm_factor` | number | Calm multiplier for calm/gust oscillation |

## `{season}` section — season-level fields

Each `{season}` block begins with season-level fields and is followed by one or more `[State Name]` blocks.

Required fields:

| Field | Type | Description |
|---|---|---|
| `wind_base_speed` | number | Seasonal average wind speed in kph (overrides annual default) |
| `wind_base_dir` | cardinal | Seasonal prevailing wind direction (overrides annual default) |
| `wind_variability` | number | Seasonal wind variability (overrides annual default) |

Optional fields:

| Field | Type | Description |
|---|---|---|
| `wind_gust_factor` | number | Seasonal gust multiplier |
| `wind_calm_factor` | number | Seasonal calm multiplier |

## `[State Name]` section — state-level fields

Each state block defines a single weather state for the current season. State names must be unique within a season.

### Baseline conditions

| Field | Type | Required | Description |
|---|---|---|---|
| `temp_base` | number | yes | Daily mean temperature (°C) |
| `temp_diurnal` | number | yes | Half the day/night temperature swing amplitude (°C) |
| `temp_phase` | number | yes | Hour of peak temperature (typically `14`) |
| `humidity` | number | yes | Target humidity (%) |
| `pressure` | number | yes | Target pressure (hPa) |
| `precipitation` | number | yes | Target precipitation intensity (0-100) |
| `dust` | number | yes | Target dust intensity (0-100) |
| `visibility` | number | yes | Target visibility in km (typically 0-50) |

### Wind modifiers

These modifiers are applied **per grid** on top of the region-global base wind
computed by Proc3, so two grids in different states experience different wind
from the same base driver. They ramp smoothly during state transitions via
Proc2's target interpolation over `wind_ramp_seconds`.

| Field | Type | Required | Description |
|---|---|---|---|
| `wind_speed_mod` | number | yes | Additive modifier to seasonal `wind_base_speed` (kph) |
| `wind_dir_mod` | number | yes | Direction shift in degrees applied to seasonal `wind_base_dir` |
| `wind_variability_mod` | number | yes | Additive modifier to seasonal `wind_variability`; controls the grid's extra direction wander relative to the base wind |

### Presentation

| Field | Type | Required | Description |
|---|---|---|---|
| `eep_preset` | string | yes | EEP preset name to apply for this state |
| `particle` | string | yes | Particle system to activate (`none`, `light_haze`, `moderate_rain`, `heavy_rain`, `dust_storm_heavy`, etc.) |

### State machine metadata

| Field | Type | Required | Description |
|---|---|---|---|
| `weight` | number | yes | Weight used when multiple progression candidates are ready simultaneously (higher = more likely) |
| `duration` | string | yes | Expected duration range in minutes, e.g. `"4-9"` or `"6-24"` for events |
| `event` | boolean | no | If `true`, the state is an event and will regress when `duration` expires |

### Transition edges

| Field | Type | Required | Description |
|---|---|---|---|
| `progresses_to` | string | no* | Name of the state to transition to when progress conditions are met |
| `regresses_to` | string | no* | Name of the state to transition to when regress conditions are met |
| `diverges_to` | string | no* | Name of an event state to jump to when divergence conditions are met |

*At least one transition edge should normally be defined, otherwise the state is terminal.

A single state can have multiple progression/divergence targets as a comma-separated list:

```
progresses_to = Cloudy, Light Rain
diverges_to = Khamsin, Dust Devil
```

When multiple targets are listed, each candidate is evaluated independently. If more than one is ready, the grid uses the target state's `weight` as a tiebreaker.

### Progression conditions

All progression conditions are checked on the **current** state (the state transitioning FROM). Conditions are combined with `progress_logic`.

| Field | Type | Description |
|---|---|---|
| `progress_trend_max` | number | Trigger if pressure trend (hPa/min) is below this value (more negative) |
| `progress_humidity_min` | number | Trigger if humidity is above this value |
| `progress_morning` | boolean | If `true`, path is only active in the morning (sun rising, low in the east) |
| `progress_day` | boolean | If `true`, path is only active during mid-day (sun high) |
| `progress_evening` | boolean | If `true`, path is only active in the evening (sun setting, low in the west) |
| `progress_night` | boolean | If `true`, path is only active at night (sun below horizon) |
| `progress_logic` | string | `"and"` or `"or"` — how to combine trend/humidity conditions (default: `"or"`). Sun-phase flags are always ANDed with the other conditions. |

### Regression conditions

| Field | Type | Description |
|---|---|---|
| `regress_trend_min` | number | Trigger if pressure trend (hPa/min) is above this value (rising) |
| `regress_humidity_max` | number | Trigger if humidity is below this value |
| `regress_morning` | boolean | If `true`, path is only active in the morning |
| `regress_day` | boolean | If `true`, path is only active during mid-day |
| `regress_evening` | boolean | If `true`, path is only active in the evening |
| `regress_night` | boolean | If `true`, path is only active at night |
| `regress_logic` | string | `"and"` or `"or"` — how to combine trend/humidity conditions (default: `"and"`). Sun-phase flags are always ANDed with the other conditions. |

### Divergence conditions (event emergence)

Divergence is used for extreme/special states that break the normal progression tree (e.g. Khamsin, Sirocco, Coastal Mist). Conditions can include pressure, trend, humidity, temperature, wind speed, and sun phase.

| Field | Type | Description |
|---|---|---|
| `diverge_pressure_max` | number | Trigger if absolute pressure is below this value |
| `diverge_trend_max` | number | Trigger if pressure trend (hPa/min) is below this value (rapid drop) |
| `diverge_humidity_min` | number | Trigger if humidity is above this value |
| `diverge_humidity_max` | number | Trigger if humidity is below this value |
| `diverge_temp_min` | number | Trigger if temperature is above this value (°C) |
| `diverge_wind_speed_min` | number | Trigger if wind speed is above this value (kph) |
| `diverge_wind_speed_max` | number | Trigger if wind speed is below this value (kph) |
| `diverge_morning` | boolean | If `true`, path is only active in the morning |
| `diverge_day` | boolean | If `true`, path is only active during mid-day |
| `diverge_evening` | boolean | If `true`, path is only active in the evening |
| `diverge_night` | boolean | If `true`, path is only active at night |
| `diverge_logic` | string | `"and"` or `"or"` — how to combine divergence conditions (default: `"and"`). Sun-phase flags are always ANDed with the other conditions. |

### Per-target condition overrides

When a state has multiple progression or divergence targets, you can set conditions for **each target individually** by using a slotted key. The target name has spaces replaced with underscores.

Example:

```
[Clear Skies]
  diverges_to = Heat Wave, Coastal Mist, Sirocco
  # Base defaults (apply to any target without its own override)
  diverge_logic = and
  # Per-target conditions
  diverge_Heat_Wave_temp_min = 30
  diverge_Heat_Wave_day = true
  diverge_Coastal_Mist_humidity_min = 75
  diverge_Coastal_Mist_morning = true
  diverge_Sirocco_humidity_max = 55
  diverge_Sirocco_wind_speed_min = 20
```

Rules:
- If a per-target key exists (e.g. `diverge_Heat_Wave_temp_min`), it overrides the base key (`diverge_temp_min`) for that target.
- If no per-target key exists, the base key is used.
- The `*_logic` field can also be overridden per target (e.g. `diverge_Coastal_Mist_logic = and`).
- Sun-phase flags (`*_morning`, `*_day`, etc.) can be set per target the same way.

This lets a single source state branch to several different special states, each with its own entry requirements.

### Flood modifiers

Only applied if the grid has `nile_adjacent = true`.

| Field | Type | Description |
|---|---|---|
| `flood_low_humidity` | number | Humidity delta applied during low flood |
| `flood_rising_humidity` | number | Humidity delta applied during rising flood |
| `flood_peak_humidity` | number | Humidity delta applied during peak flood |
| `flood_receding_humidity` | number | Humidity delta applied during receding flood |
| `flood_low_dust` | number | Dust delta applied during low flood |
| `flood_rising_dust` | number | Dust delta applied during rising flood |
| `flood_peak_dust` | number | Dust delta applied during peak flood |
| `flood_receding_dust` | number | Dust delta applied during receding flood |
| `flood_peak_fog` | number | Visibility/fog modifier applied during peak flood |

Flood state is determined from the SL date:
- `low`: Mar 1 – Jun 1
- `rising`: Jun 1 – Jul 31
- `peak`: Aug 1 – Oct 31
- `receding`: Nov 1 – Feb 28/29

## Time-of-day conditions

The optional `*_morning`, `*_day`, `*_evening`, and `*_night` boolean flags restrict transitions to specific sun phases. This is useful for states that only occur at certain times of day, such as morning coastal mist.

The grid uses `ll.GetSunDirection()` to determine the sun phase, so this works correctly with custom sun cycles, accelerated days, and eternal-noon regions (well, eternal-noon has no morning/evening/night, so only `*_day` paths would ever be active there).

Sun phases:
- `morning`: sun above horizon (`z > 0`) but low (`z < 0.5`) and in the eastern half (`x > 0`)
- `day`: sun above horizon and high (`z >= 0.5`)
- `evening`: sun above horizon but low and in the western half (`x < 0`)
- `night`: sun below horizon (`z <= 0`)

Example:

```
[Coastal Mist]
  ...
  progresses_to = Clear Skies
  progress_humidity_min = 75
  progress_morning = true
  progress_logic = and
```

This means: only progress to Coastal Mist if humidity is above 75% **and** it is currently morning.

## Example state

```
{season: Shemu}
  wind_base_speed = 12
  wind_base_dir = NNW
  wind_variability = 0.2

  [Clear Skies]
    temp_base = 27
    temp_diurnal = 3.5
    temp_phase = 14
    humidity = 65
    pressure = 1009
    wind_speed_mod = 0
    wind_dir_mod = 0
    wind_variability_mod = 0
    precipitation = 0
    dust = 0
    visibility = 50
    weight = 10
    duration = 7-14
    eep_preset = Clear_Shemu_Day
    particle = none
    progresses_to = Hazy Heat
    progress_humidity_min = 72
    progress_logic = or
```
