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

The system adopts a **hub-and-spoke** model centered on a single processor object. The processor object contains four scripts sharing one LSD: Main (the orchestrator and communication entrypoint), Proc1 (core/macro compute), Proc2 (auxiliary/micro compute), and Proc3 (environmental/global drivers). Grids are detached prims that communicate with Main via region chat. Main is the sole routing authority — all inter-prim messages flow through it.

A key design principle: **grids are the decision makers, processors are the compute engine.** Grids know their own weather state definitions and transition rules (from their notecards). Processors do not — they only know the current target parameters a grid has given them, and they evolve computed values toward those targets. When a grid decides a state transition is warranted (based on polled computed values, RNG with bias, thresholds, etc.), it sends new target parameters to the processor. This keeps the processor's per-grid storage small (one set of targets, not a full state catalogue) and lets each grid define its own state space without the processor needing to understand it.

This trades the resilience of direct point-to-point communication for simplicity: one routing authority, one validation point, one place to debug, and a shared LSD that lets the processor scripts coordinate without inter-script messaging for state.

### Components

- **Processor object** (single prim): Contains four scripts sharing one 128 KB LSD. Inter-script communication uses `llMessageLinked(LINK_THIS, ...)` (link messages work within a single prim, reaching all scripts in it). LSD write events also fire for all scripts in the prim, providing an additional coordination signal. The single-prim structure simplifies rez and distribution — one object, one LSD, no linkset traversal needed.
  - **Main**: The orchestrator and entrypoint for all inter-prim communication. Receives grid registrations via region chat, maintains the `grids` registry in LSD, routes messages between grids and the processor scripts. Main is in the steady-state data path — every message routes through it.
  - **Proc1 (core)**: Handles macro compute — evolves macro-level values (state evolution metadata, pressure trends) toward the targets a grid has provided. Reads all grid namespaces and global drivers, writes only to its own keys within each grid namespace (`grid_uuid:macro:*`). Round-robins through the `grids` registry silently, doing work when there is work to do. Does not know what weather states exist or when to transition — it computes what it's told to compute.
  - **Proc2 (auxiliary)**: Handles micro compute — temperature, humidity, wind, and other computed values, evolved toward grid-provided targets. Same read-all, write-own-keys discipline as Proc1, writing to `grid_uuid:micro:*`. Works independently of Proc1; both read from the shared namespace and global drivers, feeding off each other's results. Stale reads are acceptable because weather is slow.
  - **Proc3 (env)**: Handles global environmental drivers — things computed once per cycle and exposed to all grids. Owns the `drivers:*` write surface. Does not round-robin through `grids` — it has no per-grid work. Runs on its own cycle cadence, which may differ from Proc1/Proc2 (e.g., flood state is a calendar lookup that changes slowly; pressure trends update more frequently). Proc1 and Proc2 read `drivers:*` keys when processing each grid. First implementation: Nile flood state and background atmospheric pressure variation. The pressure driver provides an independent external signal that pushes computed pressure values away from grid-specified targets, giving grids something external to evaluate when deciding state transitions. Future: extreme weather overrides, seasonal event flags, admin-forced conditions.
- **Grid prims**: Detached prims, each representing one weather grid. Each owns its 128 KB LSD, storing its own configuration, weather state definitions (from notecard), and live presentation state. Grids register with Main, poll for computed results at regular intervals, evaluate transition conditions against polled values, and send new target parameters to the processor when a state transition is warranted. Grids also apply visual effects (EEP, particles) based on the current state. Grids do not compute weather values — they compute *transitions* and consume processor results.

### Communication

- Object-to-object communication uses `llRegionSayTo(targetKey, channel, message)` on a shared private channel. This targets specific objects by key with no per-call delay, unlike `llInstantMessage`.
- Messages are **idempotent** — re-sends are safe, which handles SL's occasional message drops without ACK protocols.
- Main routes all communication. Both registration and steady-state traffic flow through it:

```
Registration:  Grid → Main (writes to shared LSD `grids` registry)
Steady state:  Grid → Main → Proc (poll for results)
               Proc → Main → Grid (results response)
               Proc → Main → Grid (metadata request, if missing from namespace)
               Grid → Main → Proc (metadata response)
Transition:    Grid → Main → Proc (new target parameters for next evolution cycle)
```

- Within the processor object, Main communicates with Proc1/Proc2/Proc3 via `llMessageLinked(LINK_THIS, ...)` (link messages reach all scripts in the same prim). The three processors communicate with each other only through shared LSD — no direct messaging. Proc1 and Proc2 read the `grids` registry and round-robin through namespaces independently. Proc3 does not read `grids` — it computes global drivers on its own cycle.

### Why this shape

- **Memory partitioning**: Each grid prim gets its own 128 KB LSD with no sharing or namespace collision. The processor object's 128 KB LSD holds the `grids` registry, one namespace per registered grid (`grid_uuid:macro:*` and `grid_uuid:micro:*`), and the global drivers area (`drivers:*`). Per-grid namespace data is ~1.2 KB (one set of current targets + computed values, not a full state catalogue), leaving substantial headroom within the processor's LSD for many grids.
- **Scalability**: Capacity is increased by adding scripts to the processor object or by splitting work differently between the three processors. The bottleneck is compute time per grid per script, not memory. Adding a second processor object would require decoupling Main from the processor or introducing a Main-to-Main coordination protocol, which is out of scope for the initial design.
- **Resilience**: The processor object is a single point of failure — if it resets, all communication and simulation pauses until it recovers. Grids retain their last-known state and their own state definitions in their own LSD, so they can resume decision-making once the processor is available again. A future evolution could introduce direct processor↔grid communication for steady-state traffic, removing Main from that path.

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

### Seasons

The system uses the ancient Egyptian calendar with three seasons. Winter is not a distinct season — it is absorbed into Peret (which covers January through May, spanning late winter and spring).

| Season | Meaning | Date range | Days |
|---|---|---|---|
| Akhet | Inundation (flood) | Sept 11 – Jan 9 | ~121 |
| Peret | Emergence (growth) | Jan 10 – May 9 | ~120 |
| Shemu | Harvest (low water) | May 10 – Sept 10 | ~124 |

Season is determined from the SL date (`llGetDate()`) using month/day comparison, which handles leap years naturally — no day-of-year calculation needed for season lookup. See SIMULATION_MATHS.md for the implementation.

**Season blending:** In the last 7 days of each season, the grid gradually biases weather parameters toward the next season's baseline. This prevents a hard snap at the boundary — instead, Clear Skies in late Akhet already trends toward Peret's Clear Skies parameters. The blend is a linear interpolation over the final 7 days, applied to the grid's target parameters before they're sent to the processor.

### Initial state

When a grid boots, it always starts in **Clear Skies** for the current season. It sends Clear Skies target parameters to the processor on registration. The processor begins evolving toward those targets immediately.

On the grid's first poll, if the computed values strongly indicate that a different state is warranted (e.g., pressure has already dropped significantly due to a cyclone), the grid may jump directly to the indicated state, **bypassing the normal progression path**. This is a one-time bootstrap adjustment — after the first poll, normal progression rules apply. This tradeoff accepts one abrupt transition on boot in exchange for not forcing a grid to walk through multiple progression stages when conditions are already well past Clear Skies.

### Polling and compute cadence

| Component | Cadence | Notes |
|---|---|---|
| Proc1 (macro) | 15 seconds | Evolves one grid per cycle, queues next |
| Proc2 (micro) | 15 seconds | Evolves one grid per cycle, queues next |
| Proc3 (drivers) | 5 seconds | More aggressive — pressure driver needs fine-grained updates |
| Grid poll | 30 seconds | ±5s jitter to stagger across grids |

Processor and grid timings drift independently — this is intentional and acceptable. The grid's time-windowed trend computation (5-minute window) is immune to cadence drift: more or fewer polls in the window just changes regression precision, not the result's real-time meaning.

All cadence values are constants defined at the top of each script and are adjustable.

## Notecard format

The notecard is a human-facing authoring format. At parse time, the loader splits it into machine-facing LSD namespaces (sim parameters vs. presentation parameters). The two layouts need not match.

### Format rules

- `{}` denotes scope/context (grid, season). `[]` denotes named entities (weather states). Bare indented lines are key=value data.
- `#` begins a comment, inline or full-line. Strip from `#` to end of line.
- Unknown keys are ignored, not errors. This allows incremental schema evolution and per-biome parameter subsets.
- No line should exceed ~1000 bytes (stays under `llGetNotecardLineSync`'s 1024-byte truncation limit).
- Season headers use the ancient Egyptian calendar: `Akhet`, `Peret`, `Shemu`. No compound headers — the system follows one calendar.

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

# Seasonal context. Ancient Egyptian calendar: Akhet, Peret, Shemu.
{season: Akhet}

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
    # Progression graph
    progresses_to = Partly Cloudy
    diverges_to = Khamsin
    # Nile flood modifiers (only applied if grid is nile_adjacent)
    flood_peak_humidity = +15
    flood_receding_humidity = +8
    flood_low_dust = +10

  [Partly Cloudy]
    temp_base = 22
    ...
    progresses_to = Cloudy
    regresses_to = Clear Skies
    diverges_to = Khamsin

  [Cloudy]
    temp_base = 20
    ...
    progresses_to = Cloudy with Rain
    regresses_to = Partly Cloudy

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
    # Events regress to the nearest normal state when duration expires
    regresses_to = Clear Skies

{season: Shemu}
  [Clear Skies]
    temp_base = 27
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
| `weight` | number | Fallback bias when progression conditions are ambiguous |
| `duration` | min-max | How long this state tends to persist (hours) |
| `event` | bool | Flags extreme-weather states (divergent path) |
| `progresses_to` | state name(s) | Next state(s) along deterioration path |
| `regresses_to` | state name(s) | Previous state(s) along clearing path |
| `diverges_to` | state name(s) | Event-triggered path outside normal progression |
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

**The processor evolves values; the grid decides transitions.** The processor does not know what weather states exist. It receives target parameters from the grid and evolves computed values toward them using the relaxation model. The grid, which knows its own state definitions and transition rules, evaluates polled computed values to decide when a state transition is warranted — then sends new target parameters to the processor.

The minimum viable evolution model (to be refined):

- Each grid namespace in the processor holds a current value vector: temp, humidity, pressure, wind, dust, etc., plus the current target parameters.
- Each cycle, the processor applies drivers to evolve the vector toward the targets:
  - **Seasonal trend**: slow drift toward seasonal norms (if the grid provides seasonal targets).
  - **Diurnal cycle**: time-of-day-driven temperature curve (above).
  - **Stochastic perturbation**: random variation within the current state's variability parameters.
  - **Background pressure variation**: Proc3 generates an independent pressure signal that Proc2 mixes into its pressure evolution. This provides an external forcing function — pressure systems move through regions independently of local weather — giving the grid something other than its own reflected targets to evaluate.
- Relaxation model: `new_value = current_value + (target_value - current_value) * rate + noise`
- The grid polls these computed values, evaluates transition conditions against its own state definitions, and sends new targets when a state transition is warranted.

This is model-agnostic — drivers can be made more sophisticated without changing the architecture. The processor's job is always "evolve toward targets"; the grid's job is always "decide what the targets should be."

### Selection logic: staged progression

State transitions follow a **progression graph**, not a flat weighted selection. Each state defines what it can progress to, regress to, and diverge to. This prevents unrealistic jumps (Clear Skies → Storm) and requires sustained evidence before advancing.

**Progression paths:**
- `progresses_to` — the next state(s) along a deterioration path (e.g., Clear Skies → Partly Cloudy → Cloudy → Cloudy+Rain → Storm).
- `regresses_to` — the previous state(s) along a clearing path (e.g., Storm → Cloudy+Rain → Cloudy → Partly Cloudy → Clear Skies).
- `diverges_to` — event-triggered paths outside the normal progression (e.g., Clear Skies →diverges_to→ Khamsin). Events have their own trigger conditions (rapid pressure drop, seasonal window) and regress back to the normal path when their duration expires.

**Transition mechanism:**
- The grid maintains a timestamped pressure history from each STATE_RESP, storing `(unix_time, pressure)` pairs in a rolling 10-minute window.
- Each progression path has a condition evaluated against a **time-windowed trend** — a linear regression over the last 5 minutes of pressure data, producing a slope in hPa/min. This is real sustained evidence, not poll counting.
- When a condition is met (e.g., trend steeper than -0.1 hPa/min for a Cloudy progression), the grid transitions along that path.
- The grid also receives Proc3's driver pressure trend via `macro:evolution.pressure_trend` in each STATE_RESP and can cross-check it against its local trend for confidence.
- A cooldown prevents rapid back-to-back transitions.
- Duration timers ensure states don't persist indefinitely — when a state's duration expires, the grid evaluates regression paths first (returning toward baseline), then progression paths.

This approach is immune to poll cadence and processor cycle timing. Whether the grid polls every 30 seconds or every 2 minutes, the trend is computed over the same 5-minute real-time window. More polls in the window just means better regression precision — the threshold stays the same in real time. Noise from the background pressure driver's stochastic component is averaged out by the regression.

`weight` serves as a tiebreaker when multiple progression paths have their conditions met simultaneously — e.g., both a progress path and a diverge path are eligible and the grid needs to pick one. It is no longer the primary transition driver.

For example, a khamsin is a divergent path from Clear Skies or Partly Cloudy, triggered by a rapid sustained pressure drop (Proc3's background pressure driver pushing below ~1008 hPa with a 5-minute trend steeper than -0.3 hPa/min). When the khamsin's duration expires, the grid regresses to the nearest normal state (typically Clear Skies or Partly Cloudy, depending on computed values at that point). This keeps event triggers in the grid's control (where the state definitions live) while keeping value computation in the processor (where the compute engine lives).

## Presentation

### EEP (Environment Enhancement Presets)

Weather states may optionally specify an EEP preset, applied via Experience permissions. Enforcement is automatic: only avatars wearing an object belonging to the Experience receive the EEP override; non-members see the region default.

**v1 scope: data scaffolding only.** The notecard format and LSD storage include `eep_preset`, `eep_enabled`, and `eep_experience` fields so that state definitions carry the data forward. The actual EEP application functions (`llSetEnvironment` / `llReplaceEnvironment` family) are deferred to a later iteration. The grid controller should read the `eep_preset` field from the current state and store it in its runtime state, but does not need to apply it in v1.

When EEP application is implemented, the sim should fail gracefully on errors (experience not authorized on parcel, permission revoked, etc.) — log and continue with non-EEP weather. Do not let an EEP failure halt the simulation.

### Particles

Particle effects (dust storms, rain, snow) are separate from EEP and specified per weather state via the `particle` field.

**v1 scope: data scaffolding only.** As with EEP, the `particle` field is parsed and stored in LSD but particle application (`llLinkParticleSystem` / `llParticleSystem`) is deferred. The grid controller stores the value; it does not need to render particles in v1.

## Boot sequence

1. Processor object boots. Main starts listening for registrations. Proc1 and Proc2 begin idle — they read the `grids` registry from LSD and round-robin through whatever namespaces exist. Proc3 begins computing global drivers immediately (flood state, background pressure) on its own 5-second cadence.
2. Grid prims boot, read their parameters and weather state definitions from their own LSD (or load from notecard on first boot), determine the current season from the SL date, and select **Clear Skies** for that season as the initial state. They register with Main via region chat (UUID + grid metadata + Clear Skies target parameters).
3. Main writes the grid UUID into the `grids` CSV in the shared LSD, scaffolds the namespace (creates the `<grid_uuid>:macro:*`, `<grid_uuid>:micro:*`, and `<grid_uuid>:targets` keys), and stores the initial targets in `<grid_uuid>:targets`. Proc1 and Proc2 pick it up on their next round-robin pass. No explicit assignment message — the processors follow the registry.
4. Proc1 and Proc2 **populate** the namespace keys created by Main. They do not create keys themselves — Main owns the namespace lifecycle. Proc1 and Proc2 request metadata from the grid via Main if it's not already present in the namespace. Proc3 is unaffected — it computes global drivers, not per-grid data.
5. Processors begin cycling. Proc1 and Proc2 evolve per-grid values toward the grid-provided targets on their 15-second cadence, one grid per cycle, queuing the next. Proc3 computes global drivers to `drivers:*` on its 5-second cadence. Proc1 and Proc2 read `drivers:*` when processing each grid.
6. Grids poll Main for results at 30-second intervals (±5s jitter). Main relays the poll to the processor scripts, which read from the namespace and respond via Main. Grids update their presentation state and apply visual effects.
7. On the **first poll** after boot, the grid evaluates computed values. If conditions strongly indicate a state other than Clear Skies (e.g., pressure already well below Clear Skies baseline), the grid jumps directly to the indicated state, bypassing normal progression. This is a one-time bootstrap adjustment.
8. On subsequent polls, grids evaluate time-windowed pressure trends against their progression graph. If a progression condition is met, the grid sends new target parameters to the processor via Main (TARGET_PUSH). The processor evolves toward the new targets on subsequent cycles.

Partial boot is functional, not broken. Late-registering grids appear in the `grids` registry and are picked up on Proc1/Proc2's next round-robin pass. Processors can begin cycling on whatever grids are in the registry immediately — it does not have to be all at once. Proc3 operates independently of grid registration — it computes drivers regardless of how many grids are registered.

### Namespace ownership

**Main owns the namespace lifecycle.** Main creates, cleans up, and resets per-grid namespace keys in the processor object's LSD. Proc1, Proc2, and Proc3 only read and write values into keys that Main has already scaffolded — they never create or delete namespace keys themselves.

This means:
- On grid registration: Main scaffolds `<grid_uuid>:macro:*`, `<grid_uuid>:micro:*`, and `<grid_uuid>:targets`.
- On grid unregistration/timeout: Main removes those keys from LSD.
- On processor reset: Main runs the reset pipeline (see below), which re-scaffolds all namespaces from the `grids` registry. Procs resume populating.

This separation prevents race conditions where a proc tries to write to a key that doesn't exist yet, and keeps cleanup centralized in one script.

## Reset behavior

### Main reset pipeline

When the processor object resets (script reset, sim restart, object re-rez), Main runs a **reset pipeline**:

1. **Main boots** and reads the `grids` CSV from LSD. If LSD was wiped (object re-rez with no backup), the CSV is empty and grids must re-register from scratch.
2. **Main re-scaffolds** all per-grid namespaces: for each UUID in the `grids` CSV, Main creates `<grid_uuid>:macro:*`, `<grid_uuid>:micro:*`, and `<grid_uuid>:targets` keys if they don't exist. If they already exist (LSD survived the reset), Main leaves them in place — the procs' last-written values are still valid.
3. **Main signals procs** to resume. Proc1 and Proc2 read the `grids` registry and resume their round-robin. Proc3 resumes computing drivers. No proc needs to re-boot or re-initialize — they just start cycling again.
4. **Grids re-register** (if they detect the processor was unavailable) or resume polling. A grid that re-registers sends its current state's targets via REGISTER, which Main writes to `<grid_uuid>:targets`. A grid that resumes polling just picks up where it left off.

If LSD survived the reset (script reset without object deletion), all computed values, targets, and driver data are intact. The procs resume evolving from where they stopped. The only loss is the time elapsed during the reset — values are stale by however long the reset took, but the relaxation model catches up within a few cycles.

If LSD was wiped (object re-rez), Main starts with an empty `grids` CSV. Grids detect no response to polls and re-register. The system cold-boots: all grids start in Clear Skies, procs evolve from scratch. This is the same as a first boot.

### Grid prim reset

When a grid prim resets:

1. The grid re-reads its notecard from inventory (or from LSD if the notecard was cached and LSD survived).
2. The grid determines the current season and selects Clear Skies as initial state.
3. The grid re-registers with Main via REGISTER, sending its config and Clear Skies targets.
4. Main recognizes the UUID (already in `grids` CSV) and updates `<grid_uuid>:targets` with the new Clear Skies values. The namespace keys already exist — Main does not re-scaffold.
5. The grid's `transition` key (pressure history, duration timers) is reset to empty. The grid starts fresh with no pressure history — it will need 5 minutes of polls before its time-windowed trend is meaningful. Until then, progression conditions will return false (trend = 0 with <2 data points), so the grid stays in Clear Skies. This is acceptable — a reset grid should stabilize before transitioning.
6. On the grid's first poll after reset, the bootstrap evaluation runs (same as initial boot). If conditions strongly indicate a different state, the grid jumps directly.

### Proc script reset (individual)

If only one proc script resets (not the whole object):

- **Proc1 or Proc2 resets**: Main's namespace keys are intact (Main owns them, not the procs). The proc re-reads the `grids` registry and resumes round-robin. Its last-written values in `<grid_uuid>:macro:*` or `<grid_uuid>:micro:*` are still in LSD — the proc reads them as current values and continues evolving from there. No data loss.
- **Proc3 resets**: `drivers:*` keys are owned by Main (scaffolded at boot). Proc3 re-reads its internal state from `drivers:*` if Main stored it there, or re-initializes from scratch (flood state from date, pressure driver phase = 0). The pressure driver's sinusoidal phase restarts, which may cause a brief discontinuity in the pressure signal. This is acceptable — the grid's 5-minute trend window will smooth over it within a few minutes.

## Failure handling

- **Grid prim deleted**: Main detects no response within a timeout window, removes the grid UUID from the `grids` registry in LSD and cleans up the namespace keys (`<grid_uuid>:macro:*`, `<grid_uuid>:micro:*`, `<grid_uuid>:targets`). Proc1 and Proc2 pick up the removal on their next round-robin pass and stop processing that namespace. Proc3 is unaffected.
- **Processor script error (Proc1, Proc2, or Proc3)**: The other processors continue working. If Proc1 or Proc2 fails, its per-grid domain goes stale but the other's results continue. If Proc3 fails, global drivers go stale — Proc1 and Proc2 keep working with the last-known driver values, which is acceptable for slow-changing drivers like flood state. Main can detect script non-responsiveness via link message timeouts and signal an alert.
- **Main script error**: Inter-prim communication ceases. Proc1, Proc2, and Proc3 continue working from LSD — Proc1/Proc2 round-robin the `grids` registry, Proc3 computes drivers — but grids can't poll for results (no relay). Grids retain their last-known state in their own LSD. When Main recovers, it runs the reset pipeline (re-scaffold from `grids` CSV, signal procs to resume). Grids re-register or resume polling. The processor scripts do not need to re-boot.
- **Processor object deleted**: All simulation and communication ceases. Grids retain last-known state in their own LSD. On re-rez, Main boots cold (empty `grids` CSV), grids re-register, all three processors start from scratch. This is a full cold boot.

### Timeout mechanism

Main tracks last-response time per registered grid. Grids that don't respond to metadata requests or polls within a timeout window are removed from the `grids` registry. The timeout must be reset on sim restart so grids don't get accidentally purged. If no reset happens and no response comes within the timeout window, Main purges the grid from the registry. Proc1 and Proc2 pick up the removal on their next round-robin pass.

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

### Parser model

The parser treats the notecard as a nested data structure and builds a Lua table from it, then writes each entry to LSD using the same namespace convention as the processor scripts. The mapping is straightforward:

- `{scope: name}` → creates a new table key: `data[name] = {}` (for grid) or `data[season_name] = {}` (for seasons)
- `[State Name]` → creates a state table inside the current season: `data[season]["State Name"] = {}`
- `key = value` → assigns to the current state: `data[season]["State Name"]["key"] = value`

The resulting table structure mirrors the notecard's hierarchy:

```lua
{
    grid = {
        biome = "desert_coast",
        climate = "mediterranean_arid",
        lat = 31.2,
        eep_enabled = true,
        eep_experience = "<experience-uuid>",
        nile_adjacent = true,
    },
    Akhet = {
        ["Clear Skies"] = {
            temp_base = 24,
            temp_diurnal = 4,
            humidity = 67,
            pressure = 1015,
            progresses_to = "Partly Cloudy",
            -- ...
        },
        ["Partly Cloudy"] = { ... },
        ["Cloudy"] = { ... },
        ["Early Storms"] = { ... },
    },
    Peret = {
        ["Clear Skies"] = { ... },
        -- ...
    },
    Shemu = {
        ["Clear Skies"] = { ... },
        ["Hazy Heat"] = { ... },
    },
}
```

As the parser completes each entry, it writes to LSD immediately:

- `config` ← `data.grid` (JSON-encoded)
- `Akhet:Clear Skies` ← `data.Akhet["Clear Skies"]` (JSON-encoded)
- `Peret:Clear Skies` ← `data.Peret["Clear Skies"]` (JSON-encoded)
- etc.

Value parsing rules:
- Numeric values: `tonumber(value)` — handles integers and floats.
- Boolean values: `true` / `false` literal strings → Lua booleans.
- String values: everything else, stored as-is (e.g., `NW`, `Clear_Spring_Day`, `Partly Cloudy`).
- Signed deltas: `+15` or `-8` → tonumber handles the sign; the `+` is valid Lua number syntax.
- Comma-separated lists (e.g., `progresses_to = Partly Cloudy, Cloudy`): split on `,` and trim whitespace, store as a Lua array.
- Comments: strip from `#` to end of line before parsing.
- Empty lines: skip.

### LSD key scheme

LSD is linkset-specific — one database per prim regardless of link count — so the convention is simple and flat. Keys use `season:weather_state` as the namespace, with JSON values:

```
config                         → {biome, climate, lat, eep_enabled, eep_experience}
Akhet:Clear Skies              → {temp_base, temp_diurnal, humidity, ...}
Akhet:Khamsin                  → {temp_base, ..., event: true, ...}
Peret:Clear Skies              → {...}
Shemu:Clear Skies              → {...}
...
state                          → {current weather state, computed outputs, ...}
```

- `config` — grid-level configuration, loaded once from the `{grid: ...}` notecard section.
- `season:weather_state` — one key per defined weather state. The JSON value is the full parameter set for that state, decoded on demand when the processor needs it.
- `state` — the grid's live runtime state: current weather state, computed outputs (temperature, wind, etc.), and evolution metadata. Written by processors, read by grids for presentation.

**Key constraints**: season and weather state names cannot contain `:` (the namespace delimiter). Spaces in state names are allowed in LSD keys.

In the processor object, which stores results for multiple grids in its shared LSD, keys are organized into three areas:

- **`grids`** — a CSV of all registered grid UUIDs. Main writes this; Proc1 and Proc2 read it to determine their round-robin workload. Proc3 does not read it.
- **`<grid-uuid>:macro:*`** — per-grid keys owned by Proc1 (core: state selection, transitions, event triggers).
- **`<grid-uuid>:micro:*`** — per-grid keys owned by Proc2 (auxiliary: temperature, humidity, wind, computed values).
- **`drivers:*`** — global driver keys owned by Proc3 (env: flood state, and future environmental drivers). Proc1 and Proc2 read these when processing each grid; Proc3 writes them on its own cycle cadence.

All three processors read all keys; each writes only to its own surface. The specific key list and ownership map is defined in the comms protocol document.

## Admin and debug controls

Admin commands are issued via owner-only chat on a private channel (configurable, default `-8888`). Commands target either a specific grid prim (when said near that prim) or the processor object (when said near it). Some commands propagate through Main.

### Command reference

| Command | Target | Description |
|---|---|---|
| `target <state>` | Grid | Bias progression toward the named state |
| `force <state> [minutes]` | Grid | Force grid into named state, lock progression, optional timed unlock |
| `unlock` | Grid | Release a forced lock early |
| `reset [full\|soft]` | Main | Reset the system (see below) |
| `dump` | Grid or Proc | Dump current state data to owner say |
| `debug on\|off` | Grid or Proc | Toggle broadcasting all inbound/outbound messages to owner |

### Target bias

`target <state>` nudges the grid toward a specific state without forcing it. Implementation:

- The grid stores a `target_bias` entry in its `transition` LSD key: `{"target_state": "Storm", "expires": <unix_time + 1800>}`
- During progression evaluation, if the biased state is a valid candidate (reachable via `progresses_to`, `regresses_to`, or `diverges_to` from the current state), its condition threshold is halved and its `weight` is multiplied by 10 for tiebreaking.
- If the biased state is **not** directly reachable from the current state, the bias cascades: each step along the progression path toward the target gets its threshold halved. E.g., if currently in Clear Skies and target is Storm, the bias applies to Partly Cloudy (progress), then Cloudy (progress), then Storm (progress) — each step is easier to trigger.
- The bias expires after 30 minutes (configurable). After expiry, normal progression resumes.
- Multiple `target` commands replace the previous bias, not stack.

This is a nudge, not a guarantee. If pressure trends strongly oppose the target (e.g., targeting Storm while pressure is rising), the grid may still not transition. The bias makes it easier, not automatic.

### Force / lock

`force <state> [minutes]` immediately jumps the grid to the named state, bypassing all progression rules. Implementation:

- The grid jumps directly to the forced state, sends TARGET_PUSH with that state's parameters.
- The grid sets a lock in its `transition` LSD key: `{"locked": true, "locked_state": "Storm", "unlock_at": <unix_time + minutes*60>}`. If no duration is given, the lock persists until `unlock` is issued.
- While locked, the grid **ignores all progression conditions** — no transitions fire, no pressure history is evaluated for progression. The grid stays in the forced state.
- **The processor still evolves normally.** It receives the forced state's targets via TARGET_PUSH and evolves computed values toward them using the standard relaxation model: diurnal temperature still swings, pressure driver still oscillates, noise still perturbs. The grid still polls and records pressure history. The only thing frozen is the *transition decision* — not the computed values.
- When the lock expires (timed) or `unlock` is issued:
  - The grid clears the lock from `transition`.
  - Normal progression resumes immediately. The pressure history accumulated during the lock is still valid (it was being recorded), so the grid may transition away quickly if conditions warrant.
  - If the forced state was an event (e.g., Khamsin) and its duration has long passed, the grid's first post-unlock progression evaluation will likely regress (duration expired → regression path).

This is useful for storytelling: force a khamsin for a scene, let it run with full visual and parameter variation, then unlock and let the system recover naturally.

### System reset

`reset [full|soft]` tells Main to reset the weather system. Two modes:

**Soft reset (default):**
- Main writes a reset flag to LSD: `reset_mode = "soft"`.
- Main clears its own runtime state (grid timeout trackers, message queues) but leaves the `grids` CSV and all namespace keys intact.
- Main re-reads the `grids` CSV, re-scaffolds any missing namespace keys, and signals procs to resume.
- Procs continue from last-known values — no data loss.
- Grids are not notified. They continue polling and either get responses (procs are running) or retry (procs haven't resumed yet). No disruption to grids.
- Use case: Main script glitched, need a clean restart without losing computed state.

**Full reset:**
- Main writes a reset flag to LSD: `reset_mode = "full"`.
- Main clears the `grids` CSV, removes all namespace keys (`<grid_uuid>:macro:*`, `<grid_uuid>:micro:*`, `<grid_uuid>:targets` for each grid), and clears `drivers:*`.
- Main signals procs to reinitialize from scratch. Proc3 reinitializes flood state and pressure driver. Proc1/Proc2 start with empty round-robin.
- Grids detect no response to polls (processor has no namespace for them). They re-register via REGISTER, sending Clear Skies targets. Main scaffolds new namespaces. Cold boot.
- Use case: system is in a bad state, parameters are wrong, need a clean restart.

**Reset flag for cross-script coordination:** Main writes `reset_mode` to LSD before executing the reset. If Main itself resets (script reset) during the process, the new Main instance reads `reset_mode` on boot and knows whether to:
- `"soft"` — re-scaffold from `grids` CSV, await procs and grids to resume naturally.
- `"full"` — start with empty CSV, await grid re-registrations.
- absent — normal boot, no reset in progress.

Main clears `reset_mode` after the reset pipeline completes. This flag is how Main communicates reset intent to its own future rebooted instance and to any proc that reads it.

### State dump

`dump` sends the current state data to owner say via `llOwnerSay`. The output depends on which object receives the command:

**Grid dump:**
```
[Grid] UUID: abc-123
  Season: Peret
  Current state: Cloudy
  Duration: 142/360 cycles (35% of 6h target)
  Pressure history: 8 entries, trend: -0.12 hPa/min
  Driver trend (Proc3): -0.08 hPa/min
  Targets: temp_base=14, pressure=1013, humidity=71, ...
  Lock: none
  Bias: none
  Cooldown: 0
```

**Processor dump (Proc1/Proc2):**
```
[Proc1] Grids in registry: 3
  abc-123: macro last evolved 12s ago, pressure_trend=-0.08
  def-456: macro last evolved 4s ago, pressure_trend=0.02
  ghi-789: macro last evolved 8s ago, pressure_trend=-0.15
```

**Processor dump (Proc3):**
```
[Proc3] Drivers:
  flood_state: receding (day 47)
  pressure: offset=-2.3, trend=-0.08, phase=1.42, dip_active=false
```

### Message broadcast (debug mode)

`debug on` enables echoing all inbound and outbound messages to object owner via `llOwnerSay`. `debug off` disables it.

When enabled, each message sent or received is formatted and said to the owner:

```
[DEBUG RX] o=[3] f=abc-123:grid t=[1] p=[["abc-123"]]
[DEBUG TX] o=[4] f=proc:proc1 t=[5] p=[["abc-123",{temp:14,...},{pressure_trend:-0.08}]]
```

This is per-script — `debug on` said near a grid toggles debug for that grid's script only. Said near the processor object, it toggles for whichever proc script hears it (or Main, if said near the root). To toggle all scripts at once, the command can be relayed via link messages — implementation detail for later.

**Warning:** debug mode generates significant owner chat spam (every message in both directions). Use only for active debugging, not routine operation. With 10 grids polling at 30s, that's ~40 messages/min to owner chat.

## Open questions

- **~~Cycle cadence~~**: Resolved. Proc1/Proc2 at 15s, Proc3 at 5s, grid poll at 30s ±5s jitter. All adjustable as constants.
- **~~Evolution model detail~~**: Resolved. Relaxation model with background pressure driver (Proc3), time-windowed trend evaluation, staged progression graph. See SIMULATION_MATHS.md.
- **~~Climate data research~~**: Done. See CLIMATE_DATA.md and Alexandria_Oasis.notecard.
- **~~Nile flood calendar mapping~~**: Resolved. Day-of-year ranges defined in SIMULATION_MATHS.md section 4.
- **~~State transition logic~~**: Resolved. Staged progression with time-windowed pressure trends. See SIMULATION_MATHS.md section 6.
- **EEP application specifics**: Deferred to post-v1. Data scaffolding is in place (eep_preset, eep_enabled, eep_experience fields). When implemented: verify the exact SLua API (`llSetEnvironment` / `llReplaceEnvironment` family), confirm permission model, implement graceful failure on permission errors.
- **Particle application specifics**: Deferred to post-v1. Data scaffolding in place (`particle` field). When implemented: determine `llLinkParticleSystem` vs `llParticleSystem` approach, define particle preset format.
- **Comms channel security**: The private channel for processor/grid/orchestrator communication needs a derivation scheme (from experience ID? shared secret in notecard?) that prevents non-system objects from listening.
- **LSD per-key value size limit**: Confirm the exact per-key value size cap for Linkset Data. Weather state JSON values are small (~200-300 bytes), so this is unlikely to be a problem, but the limit should be verified before committing to the storage layout.
- **Notecard parser implementation**: The parser model is documented (bracket format → nested table → LSD). Implementation needs the actual streaming loader code with `llGetNotecardLine` + dataserver events, state machine for tracking current scope/season/state, and value type coercion (number, boolean, string, comma-list).
