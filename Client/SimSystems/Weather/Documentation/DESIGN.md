# Design document for the Seshat Weather system

## Overview

The Seshat Weather System is intended to be a comprehensive weather suite for Starfall, with support for things like changing seasons over the course of the year, temperature and weather simulation based on real meteorological models (incl. wind, precipitation, etc.), as well as extreme weather.

The system will be able to build model data based off of parameters given to it over notecard, which itself should be in a format easy for the program to understand.

While ideally *based* in full on real meteorological models, there will be some caveats:
- SLua still has only 64 KB of active memory to work with. Linden Lab reports SLua can be up to ~50% more memory-efficient than LSL for equivalent workloads, though "up to" does significant legwork in that claim.
- Linkset Data storage can hold up to 128 KB of passive KVP data per linkset (look at it like an extremely flattened JSON monodimensional object).

Memory itself is of little concern in practice; we can have as many scripts acting as nodes as we want to. The problem lies in the architecturing.
In Second Life, each script lives in its own isolated mini-VM. They cannot share memory, thus eliminating common OOP-like patterns which would have been ideal. This leaves us with three viable options for communication between working scripts:

- Linkset Messages containing script instructions
- Linkset Data containing up to 128 KB of shared state (vars, sim results, etc. etc.)
- Or a detached cluster approach of multiple unlinked objects, each capable of holding multiple Lua scripts and each with its own 128 KB storage capacity.

The two former options are easier to orchestrate. The latter option gives more freedom, but requires significantly more architecturing to make work.

## Architecture

The system adopts a **hybrid** of the above options: centralized processing drivers and decentralized grids, connected via targeted region communication, coordinated by an orchestrator.

### Components

- **Grid prims**: Detached prims, each representing one weather grid. Each owns its 128 KB LSD, storing its own parameters, current state, and configuration. Grids are responsible for maintaining and presenting their weather state, not for computing it.
- **Processor prims**: Detached prims that run the simulation model. Each processor holds a set of assigned grids in its LSD and runs simulation cycles passively, evolving grid states over time. Processors are stateless with respect to the user-facing weather — they compute and store results; grids consume them.
- **Orchestrator**: A coordinator prim that handles grid registration, processor assignment, and load balancing. It acts as a **router**, not a relay: once a grid is assigned to a processor, they communicate directly. The orchestrator is not in the steady-state data path.

### Communication

- Object-to-object communication uses `llRegionSayTo(targetKey, channel, message)` on a shared private channel. This targets specific objects by key with no per-call delay, unlike `llInstantMessage`.
- Messages are **idempotent** — re-sends are safe, which handles SL's occasional message drops without ACK protocols.
- The orchestrator routes registrations and assignments only. Steady-state data flows directly between processors and grids:

```
Registration:  Grid → Orchestrator → Processor (assignment)
Steady state:  Processor → Grid (computed state)
               Grid → Processor (current state / polls)
```

### Why this shape

- **Memory partitioning**: Each grid prim gets its own 128 KB LSD with no sharing or namespace collision. Per-grid parameter data is estimated at ~10-15 KB, leaving substantial headroom for state history, trend data, and event logs.
- **Scalability**: Adding capacity means adding processor prims. The bottleneck is compute time per grid, not memory — and that's solvable by horizontal scaling.
- **Resilience**: The orchestrator can reset without stalling steady-state operation; only new registrations pause. Grids and processors continue communicating directly.

## Grids

### Definition

Grids are defined by a **box-tool** that measures a prim's position and dimensions and writes the resulting grid definition (corner coordinates + altitude band) into the grid prim's LSD. The box-tool is a one-time measurement instrument — rez it, size it, touch it, derez it. The grid definition persists in LSD.

Grids register with the orchestrator by UUID and name. The orchestrator assigns each grid to a processor.

### Multi-grid support

- Multiple grids may exist in a region, potentially at different elevations (skyboxes simulating landmasses).
- Grids may partially overlap horizontally at different altitude bands — they remain independent.
- Altitude is a grid positioning property, not a simulation variable. Each grid is a 2D simulation with a Z offset for placement.
- **Inter-grid coupling is out of scope.** Grids simulate independently; a weather event in one grid does not propagate to another. This contains complexity and memory cost.

### Shared inputs (external drivers)

External drivers are inputs to the evolution function, not outputs of it. They are computed once per cycle and exposed to all grids. Grids may ignore drivers that aren't relevant to them (e.g., a non-riverine grid ignores flood state).

- **Sun position** (provided by the region): serves as the diurnal driver. All grids consume it; none compute it. This offloads the day-night cycle from the weather system entirely.
- **Nile flood state** (computed from calendar): the annual flood cycle, tied to the ancient Egyptian calendar. See "Nile flood" under Simulation model below.

## Notecard format

The notecard is a human-facing authoring format. At parse time, the loader splits it into machine-facing LSD namespaces (sim parameters vs. presentation parameters). The two layouts need not match.

### Format rules

- `{}` denotes scope/context (grid, season). `[]` denotes named entities (weather states). Bare indented lines are key=value data.
- `#` begins a comment, inline or full-line. Strip from `#` to end of line.
- Unknown keys are ignored, not errors. This allows incremental schema evolution and per-biome parameter subsets.
- No line should exceed ~1000 bytes (stays under `llGetNotecardLineSync`'s 1024-byte truncation limit).
- Compound season headers use `/` to denote parallel taxonomies (e.g., `Spring/Akhet` — Mediterranean and ancient Egyptian calendars don't align, and both are relevant to the Alexandria setting).

### Example

```
# Grid/biome definition — could be a separate notecard or a section
{grid: oasis}
  biome = desert_coast
  climate = mediterranean_arid
  lat = 31.2
  eep_enabled = true
  eep_experience = <experience-uuid>
  nile_adjacent = true
  # coordinates set via box-tool, stored in LSD, not here

# Seasonal context. Compound header = parallel taxonomies.
# A weather state under this header belongs to both.
{season: Spring/Akhet}

  [Clear Skies]
    temp_base = 24
    temp_diurnal = 8
    temp_phase = 14
    humidity = 35
    pressure = 1015
    wind_speed = 5
    wind_dir = NW
    wind_variability = 0.3
    precipitation = 0
    dust = 0
    visibility = 50
    weight = 10
    duration = 4-9
    eep_preset = Clear_Spring_Day
    particle = none
    # Nile flood modifiers (only applied if grid is nile_adjacent)
    flood_peak_humidity = +15
    flood_receding_humidity = +8
    flood_low_dust = +10

  [Khamsin]
    temp_base = 38
    temp_diurnal = 6
    temp_phase = 14
    humidity = 8
    pressure = 1008
    wind_speed = 45
    wind_dir = S
    wind_variability = 0.6
    precipitation = 0
    dust = 85
    visibility = 3
    weight = 2
    duration = 6-24
    event = true
    eep_preset = Khamsin_Dust_Storm
    particle = dust_storm_heavy

{season: Summer/Shemu}
  [Clear Skies]
    temp_base = 32
    ...
```

### Field reference

**Per weather state:**

| Field | Type | Purpose |
|---|---|---|
| `temp_base` | number | Base temperature (°C), typically the daily mean |
| `temp_diurnal` | number | Amplitude of day/night temperature swing (±°C) |
| `temp_phase` | hour | Local hour of peak temperature (default ~14) |
| `humidity` | number | Relative humidity (%) |
| `pressure` | number | Sea-level pressure (hPa) |
| `wind_speed` | number | Base wind speed (kph) |
| `wind_dir` | cardinal or degrees | Prevailing direction |
| `wind_variability` | 0-1 | How much wind fluctuates within this state |
| `precipitation` | 0-1 or mm/hr | Rain intensity |
| `dust` | 0-100 | Aerosol/dust load |
| `visibility` | km | Horizontal visibility |
| `weight` | number | Relative selection probability (fallback/override) |
| `duration` | min-max | How long this state tends to persist (hours) |
| `event` | bool | Flags extreme-weather states |
| `eep_preset` | name or UUID | EEP environment preset (optional) |
| `particle` | name/UUID | Particle effect preset (optional) |
| `flood_peak_*` | number (delta) | Modifier applied to base field when Nile flood is at peak (e.g., `flood_peak_humidity = +15`) |
| `flood_receding_*` | number (delta) | Modifier applied when flood is receding |
| `flood_low_*` | number (delta) | Modifier applied when flood is low/baseflow |

**Per grid:**

| Field | Type | Purpose |
|---|---|---|
| `biome` | string | Biome classification |
| `climate` | string | Climate regime identifier |
| `lat` | number | Simulated latitude |
| `eep_enabled` | bool | Whether this grid uses Experience-based EEP |
| `eep_experience` | UUID | Which Experience to apply EEP through |
| `nile_adjacent` | bool | Whether this grid is close enough to the Nile to be affected by flood state |

## Simulation model

### Diurnal temperature

Temperature is computed continuously from sun position, not stored as a static value:

```
temp = temp_base + temp_diurnal * sin(sun_angle - phase_offset)
```

At solar peak, temperature reaches `temp_base + temp_diurnal`. At midnight, it troughs at `temp_base - temp_diurnal`. The `temp_phase` field shifts when the peak occurs (peak heat typically lags solar noon by a couple hours).

A desert-clear state can have `temp_diurnal = 15` (large swings); a coastal-humid state can have `temp_diurnal = 4` (maritime moderation). This naturally models "Alexandria nights aren't as cold as desert nights" — the oasis grid simply has a smaller diurnal amplitude.

**Reserved for future:** explicit night states (`[State Name - Night]`) for cases where nighttime is qualitatively different (e.g., sea breeze reversal, dew formation). This is a drop-in future addition as long as "current temperature" remains the output of a computation, not a stored field. No cost now, no rewrite later.

### Nile flood

The Nile flood is a critical seasonal driver for the Alexandria setting. The ancient Egyptian calendar (Akhet/Peret/Shemu) is directly tied to the flood cycle, and proximity to the Nile affects local weather — particularly humidity, fog, and temperature moderation.

#### What the flood is, meteorologically

The flood is not driven by *local* weather. It is driven by rainfall on the Ethiopian highlands, thousands of kilometers upstream, with a lag of months. The flood arrives in the delta in late summer / early autumn, peaks around September, and recedes through winter. This means the flood is an *external input* to the grid, like the sun — the local weather responds to the flood's presence, but does not produce it.

#### Modeling approach: deterministic from calendar

The flood is computed deterministically from the SL date (day of year), matched to historical records. It is **not stochastic** in its normal behavior — the Nile floods consistently. The day-of-year calculation is already available (the old weather script's `dayOfYear` function provides the pattern).

Flood states:

- **Low / baseflow** (Shemu, late spring through early summer): river at lowest, banks exposed, delta dry.
- **Rising** (early Akhet, summer): flood arriving, water level climbing, lowlands beginning to inundate.
- **Peak inundation** (mid Akhet, early autumn): floodplain underwater, maximum extent.
- **Receding** (Peret, late autumn through winter): water draining back, silt deposits exposed, vegetation emerging.

Each state has implications for local weather: peak inundation means higher local humidity, more morning fog, moderated temperatures (water has high thermal mass). Receding means exposed mud, vegetation, still-high humidity but less fog. Low means dry banks and increased dust availability from exposed riverbed silt.

#### Conditional modifiers

Weather states may specify conditional deltas applied when the flood is in a particular state. These are named `flood_<state>_<field>`:

```
  [Clear Skies]
    humidity = 35
    flood_peak_humidity = +15       # +15% humidity when flood is at peak
    flood_peak_fog = +0.3           # increased fog probability
    flood_receding_humidity = +8
    flood_low_dust = +10            # more dust from exposed riverbed
```

States that don't specify flood modifiers are unaffected. Grids with `nile_adjacent = false` ignore all flood modifiers regardless.

#### Extreme floods (reserved)

Historically, some floods were exceptionally high (destruction) or failed (famine). These are story-relevant events. The normal flood is deterministic; extreme floods are reserved as an optional event layer — stochastically triggered or admin-forced, like the khamsin. Not implemented in the first version, but the flood-state architecture accommodates them as a future addition.

### State evolution

The system **evolves** state over time rather than picking discrete weather states. Weather states in the notecard serve as *attractors* or *target regimes* — the evolved state drifts toward the parameters of the currently-relevant state, rather than snapping to it.

The minimum viable evolution model (to be refined):

- Each grid has a current state vector: temp, humidity, pressure, wind, dust, etc.
- Each cycle, the processor applies drivers to evolve the vector:
  - **Seasonal trend**: slow drift toward seasonal norms.
  - **Diurnal cycle**: sun-position-driven temperature curve (above).
  - **Stochastic perturbation**: random variation within the current state's variability parameters.
  - **Event logic**: pressure gradient exceeds threshold → transition toward event state (e.g., khamsin).
- Relaxation model: `new_value = current_value + (target_value - current_value) * rate + noise`

This is model-agnostic — drivers can be made more sophisticated without changing the architecture.

### Selection logic

`weight` serves as a fallback/override for selection probability. The primary driver of state transitions should be the evolution model itself (pressure trends, seasonal context, etc.), not hand-tuned weights. Weights remain useful for initial distribution and for cases where the model doesn't yet cover a transition.

## Presentation

### EEP (Environment Enhancement Presets)

Weather states may optionally specify an EEP preset, applied via Experience permissions. Enforcement is automatic: only avatars wearing an object belonging to the Experience receive the EEP override; non-members see the region default.

The sim should fail gracefully on EEP application errors (experience not authorized on parcel, permission revoked, etc.) — log and continue with non-EEP weather. Do not let an EEP failure halt the simulation.

### Particles

Particle effects (dust storms, rain, snow) are separate from EEP and specified per weather state via the `particle` field.

## Boot sequence

1. Orchestrator boots, listens for registrations.
2. Grid prims boot, read their parameters from their own LSD (or load from notecard on first boot), register with orchestrator (UUID + grid metadata).
3. Orchestrator assigns grids to processors, notifies processors.
4. Processors pull each assigned grid's initial state (grid pushes on assignment, or processor requests).
5. Processors begin cycling. First cycles produce results from initial state + drivers.
6. Grids poll or receive pushed results, update their state, begin applying visual effects.

Partial boot is functional, not broken. Late-registering grids are picked up on the next assignment round. Processors can begin cycling on whatever grids they have immediately — it does not have to be all at once.

## Failure handling

- **Grid prim deleted**: Processor detects no response within a timeout window, drops the grid from its cycle. Orchestrator cleans up the registry.
- **Processor prim deleted**: Its grids stop getting updates. Orchestrator detects processor non-responsiveness and reassigns grids to other processors.
- **Orchestrator deleted**: Grids and processors continue communicating directly. New registrations fail until it's replaced. Acceptable degradation.

### Timeout mechanism

When a processor begins work on a grid, it polls them and skips grids that don't respond within a few seconds. Every grid response updates a timeout. The timeout must be reset on sim restart so grids don't get accidentally purged. If no reset happens and no response comes within the timeout window, the processor purges the registration.

## Data storage and loading

### JSON as interchange format

The notecard remains in the human-readable bracket format for authoring. JSON is the machine-facing interchange and storage format. The custom bracket-format parser exists only at the load boundary; everything downstream is JSON round-trips through `lljson.encode`/`lljson.decode`.

Data flow:

```
Notecard (bracket format, human-authored)
  → parser (custom, runs once at load)
  → Lua table
  → lljson.encode
  → JSON string
  → LSD storage / inter-script messages
  → lljson.decode
  → Lua table (at consumer)
```

### Streaming loader

The notecard parser is a **streaming loader**: lines are read via async `llGetNotecardLine` (dataserver events), accumulated with `table.concat` (single C-level allocation, no O(n²) concatenation churn), and as each weather state is completed, its params are JSON-encoded and written directly to LSD. No full parameter set is ever held in the 64 KB working set — only the one state being parsed, plus transient line buffers.

This makes the GC concern fully moot: the working set never holds the complete parameter set. The only thing in memory at any time is the current state being parsed and transient buffers that become collectible immediately after each LSD write.

### LSD key scheme

LSD is linkset-specific — one database per prim regardless of link count — so the convention is simple and flat. Keys use `season:weather_state` as the namespace, with JSON values:

```
config                         → {biome, climate, lat, eep_enabled, eep_experience}
Spring/Akhet:Clear Skies       → {temp_base, temp_diurnal, humidity, ...}
Spring/Akhet:Khamsin           → {temp_base, ..., event: true, ...}
Summer/Shemu:Clear Skies       → {...}
...
state                          → {current weather state, computed outputs, ...}
```

- `config` — grid-level configuration, loaded once from the `{grid: ...}` notecard section.
- `season:weather_state` — one key per defined weather state. The JSON value is the full parameter set for that state, decoded on demand when the processor needs it.
- `state` — the grid's live runtime state: current weather state, computed outputs (temperature, wind, etc.), and evolution metadata. Written by processors, read by grids for presentation.

**Key constraints**: season and weather state names cannot contain `/` or `:` (these are delimiters). Spaces in state names are allowed in LSD keys.

In processor prims, which store results for multiple grids, keys are prefixed with the grid UUID: `<grid-uuid>:state`, etc. This is the processor's convention; grid prims use the flat scheme above.

## Open questions

- **Cycle cadence**: Target update interval per grid. Determines max grids per processor, which determines processor count needed. Weather changes slowly, so a 10-30 second cycle is likely sufficient, but the exact target needs deciding.
- **Evolution model detail**: The relaxation-attractor model above is a sketch. Driver specifics, event trigger thresholds, transition dynamics, and the `rate` parameter for relaxation need fleshing out. Questions include: how fast should states transition? What triggers a khamsin beyond a simple pressure threshold? How do seasonal norms interact with per-state parameters?
- **Climate data research**: Hand-author Alexandria parameters from real climate data (NOAA ISD, ERA5, or Wikipedia climate tables for Alexandria station). Document the source of each value in a companion file for future ingestion-pipeline reference. Fields to research: monthly temp means and diurnal ranges, humidity, pressure, prevailing winds, precipitation frequency, khamsin/dust event frequencies.
- **Nile flood calendar mapping**: Pin down which day-of-year ranges correspond to low/rising/peak/receding flood states based on historical Nile flood records for the Alexandria delta. This is a lookup from historical data, not a derivation.
- **State transition logic**: When and how does the target regime change? Initial approach: weight-based selection with model-driven overrides (pressure trends, event triggers). The exact trigger conditions and thresholds need defining.
- **EEP application specifics**: Verify the exact SLua API for applying EEP presets via Experiences (`llReplaceEnvironment` / `llSetEnvironment` family), confirm permission model, and implement graceful failure on permission errors.
- **Comms channel security**: The private channel for processor/grid/orchestrator communication needs a derivation scheme (from experience ID? shared secret in notecard?) that prevents non-system objects from listening.
- **LSD per-key value size limit**: Confirm the exact per-key value size cap for Linkset Data. Weather state JSON values are small (~200-300 bytes), so this is unlikely to be a problem, but the limit should be verified before committing to the storage layout.
