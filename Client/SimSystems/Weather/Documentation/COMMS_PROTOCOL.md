# Cross-system comms protocol

Rough sketch. See DESIGN.md for the architecture this protocol serves.

## Envelope

Every message is a JSON object with five keys:

```json
{
  "o": [1, 2],
  "f": "object_uuid",
  "s": "script_id",
  "t": [1, 2],
  "p": [payload1, payload2]
}
```

`f` and `s` are split into separate keys because UUID is its own data type in SLua and cannot be typecast to string, so the two cannot be concatenated into a single `"uuid:script_id"` string. `f` carries the raw UUID value (which JSON-encodes to its string form); `s` carries the script id string.

### Keys

- **`o`** — operations. Array of integers, each mapping to an operation via the op table (see below). This is the source of truth for the message: the number of entries in `o` determines the expected length of `t` and `p`. If any array's length does not match `o`, the message is malformed and discarded entirely.
- **`f`** — from. Sender's object UUID (the prim's key). A raw UUID value, not concatenated with anything.
- **`s`** — script. Sender's script id string (e.g., `"MAIN"`, `"PROC1"`, `"PROC2"`, `"PROC3"`, `"GRID"`). Identifies which script inside the sender prim authored the message. Together `f` + `s` identify the sender the way the old single `f` string did.
- **`t`** — to. Array of recipient integers, mapped via the recipient table (see below). Order matches `o`. Main is the routing entrypoint and delegates based on the operations array. If `main` (int 1) appears as a recipient, Main performs that op's internal function itself.
- **`p`** — payload. Array of payloads, one per operation. Order matches `o`. Each payload is a JSON array of the form `[method?, data...]` where `method` is an optional string that names a sub-handler inside the op (e.g., `"full"`, `"delta"`, `"config"`), and `data` is a positional array of values whose layout is fixed per op. If `p[1]` is a string, it is the method and data starts at `p[2]`. If `p[1]` is not a string, there is no method and data starts at `p[1]`. The op ID defines the positional layout — no field names or indices are needed. See "Payload contracts" below.

### Validation

The receiver validates on receipt:

1. Parse JSON. If parse fails, discard.
2. Check `o`, `t`, `p` array lengths match. If not, discard.
3. `f` and `s` must both be present and non-empty. If not, discard.
4. Dispatch each op/target/payload triplet in order.

Discarded messages should produce a debug signal (print or counter), not vanish silently. Silent failure is reserved for idempotent re-sends of recognized messages, not for malformed or incomplete ones.

## Chunking

Before sending, the sender measures the compiled JSON string. If it exceeds the transport limit (link message or region chat string length), the sender carves ops off the end of the array until the message fits, sends it, then checks the remaining ops. This repeats until the queue is empty.

Each carved message is a complete, valid envelope — there is no reassembly on the receiver side. The receiver processes each as a standalone message.

No correlation ID is needed because no single op is ever split across messages. Ops are moved between messages, not fragmented.

## ACKs

Main ACKs every received message via `llRegionSayTo` back to the sender. The ACK means "message received and validated" — nothing more. It does not indicate execution success or failure, and the sender does not act on the result.

**ACK timing is critical: Main ACKs at validation, not at execution.** The sender's round-trip cost is only "did Main receive and parse this," not "did Main finish doing what the message asked for." Main queues ops for execution after ACKing, so a busy Main still ACKs quickly and the sender never stalls on Main's execution backlog.

Sender behavior:

1. Send envelope.
2. Wait briefly for ACK (5 seconds is a generous ceiling — SLua is fast and callbacks are queued, so this only fires if the message or ACK was genuinely lost).
3. If ACK arrives, send the next envelope.
4. If ACK does not arrive within the timeout, send the next envelope anyway.

This provides best-effort ordering: when ACKs come back promptly, sends are naturally serialized. When an ACK is missing (message lost, or ACK lost), the sender proceeds after timeout — at the cost of possible out-of-order delivery. Combined with idempotency, any late-arriving duplicate from a re-send is safe.

The ACK is a bare signal. It carries no payload and no status. The sender is responsible for constructing valid messages; if a message is malformed and discarded by Main, the sender will not know, and should not need to — that is a bug in the sender to fix, not a runtime condition to handle.

## Ordering

No strict ordering guarantee exists across separate messages. The ACK system (above) provides probabilistic ordering: sends are serialized when ACKs return promptly, and may interleave when they don't.

Within a single envelope, ops are processed in array order.

### Register operations

If a `REGISTER` (or `UNREGISTER`) op is present in the operations array, the receiver processes it before any other ops in the same envelope.

By convention, senders should place register ops first in the array. This ensures they survive chunking intact (the chunking algorithm carves from the end, so first-position ops stay with the first chunk). The receiver-side rule exists as a fallback for cases where the sender did not order them first.

In practice, register/unregister are deliberate, controlled actions and will almost always be sent as standalone messages. The ordering rule is future-proofing for cases where ops get enqueued or batched unexpectedly.

## Int mappings

Three things are mapped to integers on the wire: operations, recipients, and payload field names. Each script defines the same tables. Copy-paste is the distribution mechanism. All three follow the same rules:

- Tables must be identical across all scripts.
- Ints are never reused. If an entry is deprecated, its int stays reserved.
- Sequential numbering is not required — ints can be spaced out to leave room for future additions grouped by domain.
- Tables are treated as immutable once deployed. Changing a mapping after scripts are in-world breaks every script using the old mapping, silently.

### Op table

```lua
local op = {
    REGISTER       = 1,
    UNREGISTER     = 2,
    STATE_POLL     = 3,
    STATE_RESP     = 4,
    META_REQ       = 5,
    META_RESP      = 6,
    TARGET_PUSH    = 7,
    ADMIN_TARGET   = 8,   -- Main → Grid: set target bias
    ADMIN_FORCE    = 9,   -- Main → Grid: force/lock state
    ADMIN_UNLOCK   = 10,  -- Main → Grid: release lock
    ADMIN_DUMP     = 11,  -- Main → Grid: dump state to owner chat
    ADMIN_DEBUG    = 12,  -- Main → Grid: toggle debug mode
    BEACON         = 13,  -- Main → all grids: discovery broadcast with processor key
}
```

Sender uses `op.REGISTER` (→ `1`) when building the `o` array. Receiver uses the int directly as a dispatch key — no reverse lookup needed, the int goes straight to the handler:

```lua
local ops = {
    [1] = function(payload) ... end,  -- REGISTER
    [2] = function(payload) ... end,  -- UNREGISTER
    [3] = function(payload) ... end,  -- STATE_POLL
    -- etc
}
```

The name is a comment, not a runtime value.

### Recipient table

```lua
local rcpt = {
    main  = 1,
    proc1 = 2,
    proc2 = 3,
    proc3 = 4,
    grid  = 5,
}
```

`t` carries the role int (which kind of script). When routing to a specific grid prim, the grid's object UUID — which is the grid's identity in SL — is carried in the payload, not in `t`. Main looks up the object UUID from its registry and routes via `llRegionSayTo`.

Example: a `STATE_RESP` bound for grid `abc123`:

```json
{
  "o": [4],
  "f": "proc_uuid",
  "s": "PROC1",
  "t": [5],
  "p": [["abc123", {"temp": 24, "humidity": 35, "pressure": 1012, "wind_speed": 15, "wind_dir": 315, "precipitation": 5, "dust": 0, "visibility": 50}, {"pressure_trend": -0.08, "pressure_driver_offset": -2.3}]]
}
```

`t: [5]` means "for a grid." Payload `p[1]` is the grid UUID — Main routes via `llRegionSayTo` to that object. The rest of the payload array is the op's positional data, consumed by the grid on receipt.

### Payload contracts

Each op defines its own positional payload layout. The receiver knows what to expect based on the op ID alone — no field dictionary, no key lookup. If `p[1]` is a string, it is a method (sub-handler inside the op); otherwise data starts at `p[1]`.

#### REGISTER (1) — Grid → Main

Grid registers with the orchestrator and sends its initial targets.

```
p = [grid_uuid, config, targets]
```

| Position | Name | Type | Description |
|---|---|---|---|
| 1 | grid_uuid | string | Object UUID of the grid prim |
| 2 | config | object | Grid metadata: `{biome, climate, lat, eep_enabled, nile_adjacent, sea_direction, min_x, min_y, min_z, max_x, max_y, max_z}`. `sea_direction` is the cardinal direction of maritime influence (optional, omit for landlocked). The `min_*`/`max_*` fields define the grid's zone bounding box in region coordinates. |
| 3 | targets | object | Initial target parameters (Clear Skies for current season): `{temp_base, temp_diurnal, temp_phase, humidity, pressure, wind_speed, wind_dir, wind_variability, precipitation, dust, visibility, eep_preset, particle, flood_*}` |

No method — this is the only REGISTER variant.

#### UNREGISTER (2) — Grid → Main

Grid deregisters from the orchestrator.

```
p = [grid_uuid]
```

| Position | Name | Type | Description |
|---|---|---|---|
| 1 | grid_uuid | string | Object UUID of the grid prim |

#### STATE_POLL (3) — Grid → Main → Proc1

Grid requests current computed values for its namespace.

```
p = [grid_uuid]
```

| Position | Name | Type | Description |
|---|---|---|---|
| 1 | grid_uuid | string | Object UUID of the grid prim |

Main relays to Proc1. Proc1 reads `macro:evolution` and `micro:*` from LSD, assembles the response, and sends STATE_RESP back through Main.

#### STATE_RESP (4) — Proc1 → Main → Grid

Processor returns computed values and evolution data to the grid.

```
p = [grid_uuid, values, evolution]
```

| Position | Name | Type | Description |
|---|---|---|---|
| 1 | grid_uuid | string | Object UUID of the grid prim |
| 2 | values | object | Computed micro values: `{temp, humidity, pressure, wind_speed, wind_dir, precipitation, dust, visibility}` |
| 3 | evolution | object | Macro/evolution data: `{pressure_trend, pressure_driver_offset}` — the driver trend from Proc3, for grid cross-checking against its local trend |

Optional method: `"full"` (default, all fields) or `"delta"` (only changed fields since last poll — future optimization, not in v1).

#### META_REQ (5) — Proc → Main → Grid

Processor requests metadata from the grid (e.g., full config or state definitions).

```
p = [method, grid_uuid]
```

| Position | Name | Type | Description |
|---|---|---|---|
| 1 | method | string | What metadata to request: `"config"` (grid metadata) or `"states"` (full weather state definitions for the current season) |
| 2 | grid_uuid | string | Object UUID of the grid prim |

Method is required for META_REQ — it tells the grid which data set to assemble.

#### META_RESP (6) — Grid → Main → Proc

Grid responds to META_REQ with the requested data.

```
p = [method, grid_uuid, data]
```

| Position | Name | Type | Description |
|---|---|---|---|
| 1 | method | string | Echoes the method from the matching META_REQ: `"config"` or `"states"` |
| 2 | grid_uuid | string | Object UUID of the grid prim |
| 3 | data | object | The requested data. For `"config"`: `{biome, climate, lat, eep_enabled, nile_adjacent, sea_direction, min_x, min_y, min_z, max_x, max_y, max_z}`. For `"states"`: a table of state definitions keyed by state name. |

#### TARGET_PUSH (7) — Grid → Main → Proc1/Proc2

Grid sends new target parameters after a progression decision. The processor evolves toward these on subsequent cycles.

```
p = [grid_uuid, targets]
```

| Position | Name | Type | Description |
|---|---|---|---|
| 1 | grid_uuid | string | Object UUID of the grid prim |
| 2 | targets | object | New target parameters: `{temp_base, temp_diurnal, temp_phase, humidity, pressure, wind_speed, wind_dir, wind_variability, precipitation, dust, visibility, eep_preset, particle, flood_peak_humidity, flood_receding_humidity, flood_low_dust, flood_rising_humidity}` |

Main writes `targets` to `<grid_uuid>:targets` in LSD. Proc1 and Proc2 pick up the new targets on their next round-robin pass — no explicit notification needed.

### Payload construction example

```lua
-- Building a STATE_POLL message
local msg = {
    o = {3},                              -- STATE_POLL
    f = ll.GetKey(),                      -- object UUID (raw key, no concatenation)
    s = SCRIPT_ID,                        -- "GRID"
    t = {1},                              -- Main
    p = { {my_uuid} },                    -- [grid_uuid], no method
}
llRegionSayTo(main_uuid, channel, llList2Json(JSON_OBJECT, msg))

-- Building a TARGET_PUSH message
local msg = {
    o = {7},                              -- TARGET_PUSH
    f = ll.GetKey(),                      -- object UUID (raw key, no concatenation)
    s = SCRIPT_ID,                        -- "GRID"
    t = {1},                              -- Main
    p = { {my_uuid, new_targets} },       -- [grid_uuid, targets], no method
}
llRegionSayTo(main_uuid, channel, llList2Json(JSON_OBJECT, msg))

-- Building a META_REQ with method
local msg = {
    o = {5},                              -- META_REQ
    f = ll.GetKey(),                      -- object UUID (raw key, no concatenation)
    s = SCRIPT_ID,                        -- "PROC1"
    t = {1},                              -- Main (relays to grid)
    p = { {"config", grid_uuid} },        -- [method, grid_uuid]
}
llRegionSayTo(main_uuid, channel, llList2Json(JSON_OBJECT, msg))
```

### Payload consumption example

```lua
-- Handling a STATE_RESP
local function handle_state_resp(payload)
    -- No method (p[1] is not a string), so data starts at p[1]
    local grid_uuid = payload[1]
    local values    = payload[2]   -- {temp, humidity, pressure, ...}
    local evolution = payload[3]   -- {pressure_trend, pressure_driver_offset}
    -- ...
end

-- Handling a META_REQ
local function handle_meta_req(payload)
    -- p[1] is a string → method
    local method    = payload[1]   -- "config" or "states"
    local grid_uuid = payload[2]
    -- ...
end
```

No field dictionary needed. The op ID is the contract.

## Operation catalogue

Payload schemas are not yet specified. The operations below are the current set.

| Int | Op | Direction | Purpose |
|---|---|---|---|
| 1 | `REGISTER` | Grid → Main | Grid announces itself with UUID + metadata + initial target parameters |
| 2 | `UNREGISTER` | Grid → Main | Grid announces departure |
| 3 | `STATE_POLL` | Grid → Main → Processor | Grid requests current computed values from its processor |
| 4 | `STATE_RESP` | Processor → Main → Grid | Processor responds with computed values |
| 5 | `META_REQ` | Processor → Main → Grid | Processor requests metadata it's missing from a grid's namespace |
| 6 | `META_RESP` | Grid → Main → Processor | Grid returns requested metadata |
| 7 | `TARGET_PUSH` | Grid → Main → Processor | Grid sends new target parameters after deciding a state transition is warranted |
| 8 | `ADMIN_TARGET` | Main → Grid | Admin command: set target bias (eases thresholds, boosts weight for target path) |
| 9 | `ADMIN_FORCE` | Main → Grid | Admin command: force-lock grid into a specific state |
| 10 | `ADMIN_UNLOCK` | Main → Grid | Admin command: release a forced lock early |
| 11 | `ADMIN_DUMP` | Main → Grid | Admin command: dump current state data to owner chat |
| 12 | `ADMIN_DEBUG` | Main → Grid | Admin command: toggle debug message echoing |
| 13 | `BEACON` | Main → all grids (broadcast) | Discovery broadcast: carries the processor object's key so grids can target subsequent messages via `llRegionSayTo` |

Assignment and removal are handled by Main writing directly to the `grids` CSV in the shared LSD. Processors follow the registry silently — no explicit assignment or drop messages are needed.

## LSD structure

There are two LSD stores: the processor object's shared LSD (written to by Main, Proc1, Proc2, Proc3) and each grid prim's own LSD (written to by the grid's own scripts). Both are flat key→JSON-value stores. Colons (`:`) are the namespace delimiter; no key segment may contain a colon.

### Processor object LSD

Shared by Main, Proc1, Proc2, Proc3. 128 KB total.

```
grids                              → "uuid1,uuid2,uuid3" (CSV of registered grid UUIDs)
                                      Writer: Main
                                      Readers: Proc1, Proc2 (round-robin workload list)
                                      Proc3 does not read this.

drivers:flood_state                → {"state": "peak", "day_of_year": 258}
                                      Writer: Proc3
                                      Readers: Proc1, Proc2 (applied per-grid when nile_adjacent=true)
                                      Computed from calendar. States: low, rising, peak, receding.

drivers:pressure                   → {"offset": -3.2, "trend": -0.15, "phase": 1.7}
                                      Writer: Proc3
                                      Readers: Proc2 (mixes into pressure evolution), Proc1 (exposes trend to grid via STATE_RESP)
                                      Background atmospheric pressure variation — an independent external
                                      signal not tied to any grid's targets. Proc3 generates a slow
                                      sinusoidal pressure wave with stochastic noise, simulating passing
                                      pressure systems. Proc2 adds the offset to its computed pressure;
                                      Proc1 includes the trend in macro:evolution so the grid can evaluate
                                      it for progression decisions. This gives the grid an independent
                                      signal to evaluate, preventing the circular dependency where the
                                      grid only sees reflections of its own target decisions.

drivers:extreme_weather            → {"active": false, "type": null, ...}
                                      Writer: Proc3
                                      Readers: Proc1, Proc2
                                      Reserved for future extreme weather overrides. Not implemented in v1.

reset_mode                         → "soft" | "full" | (absent)
                                      Writer: Main (during reset pipeline)
                                      Readers: Main (on boot, to determine reset intent)
                                      Set by Main before executing a system reset. If Main reboots
                                      during the reset, the new instance reads this key to know
                                      whether to re-scaffold from the grids CSV (soft) or start
                                      cold (full). Cleared by Main after the reset pipeline
                                      completes. Absent = normal boot, no reset in progress.

<grid_uuid>:meta                   → {"biome": "desert_coast", "climate": "mediterranean_arid",
                                      "lat": 31.2, "eep_enabled": true,
                                      "nile_adjacent": true, "sea_direction": "N",
                                      "min_x": 0, "min_y": 0, "min_z": 0,
                                      "max_x": 256, "max_y": 256, "max_z": 300}
                                      Writer: Main (scaffolded on registration, filled from grid via META_REQ/META_RESP)
                                      Readers: Proc1, Proc2, Proc3
                                      Grid metadata including zone bounding box. Populated on-demand if missing.

<grid_uuid>:targets                → {"temp_base": 24, "temp_diurnal": 8, "temp_phase": 14,
                                      "humidity": 35, "pressure": 1015, "wind_speed": 5,
                                      "wind_dir": "NW", "wind_variability": 0.3,
                                      "precipitation": 0, "dust": 0, "visibility": 50,
                                      "eep_preset": "Clear_Spring_Day", "particle": "none",
                                      "flood_peak_humidity": 15, "flood_receding_humidity": 8,
                                      "flood_low_dust": 10, "flood_rising_humidity": 5}
                                      Writer: Main (on behalf of grid, via TARGET_PUSH)
                                      Readers: Proc1, Proc2
                                      Current target parameters the processor evolves toward.
                                      Set on registration (initial state) and updated on each
                                      state transition decided by the grid. The processor does
                                      not know what weather state these targets correspond to —
                                      it only evolves computed values toward them.
                                      Flood modifiers (flood_<state>_<field>) are included so
                                      the processor can apply them based on the current flood
                                      state from drivers:flood_state. The modifier definitions
                                      live in the grid's state definitions; the flood state
                                      driver lives in the processor's LSD. Only present for
                                      grids with nile_adjacent=true; omitted otherwise.

<grid_uuid>:macro:evolution        → {"rate": 0.1, "pressure_trend": -0.5, "noise_scale": 0.05}
                                      Writer: Proc1
                                      Readers: Proc2
                                      Evolution model state: relaxation rate, computed trends,
                                      noise scaling. Proc1 evolves macro-level metadata each cycle;
                                      the grid reads this via STATE_RESP to inform transition decisions.

<grid_uuid>:micro:temp             → {"current": 24.3}
                                      Writer: Proc2
                                      Readers: Proc1, grid (via STATE_RESP)
                                      Current computed temperature. Evolved toward targets.temp_base
                                      with diurnal modulation from sun position + targets.temp_diurnal.

<grid_uuid>:micro:humidity         → {"current": 35}
                                      Writer: Proc2
                                      Readers: Proc1, grid (via STATE_RESP)
                                      Current computed humidity, evolved toward targets.humidity.
                                      Flood modifiers from drivers:flood_state applied if
                                      meta.nile_adjacent and the target state specifies flood_* deltas.

<grid_uuid>:micro:pressure         → {"current": 1015}
                                      Writer: Proc2
                                      Readers: Proc1, grid (via STATE_RESP)

<grid_uuid>:micro:wind             → {"speed": 5, "dir": "NW"}
                                      Writer: Proc2
                                      Readers: Proc1, grid (via STATE_RESP)
                                      Evolved toward targets.wind_speed and targets.wind_dir,
                                      with variability from targets.wind_variability.

<grid_uuid>:micro:dust             → {"current": 0}
                                      Writer: Proc2
                                      Readers: Proc1, grid (via STATE_RESP)

<grid_uuid>:micro:precipitation    → {"current": 0}
                                      Writer: Proc2
                                      Readers: Proc1, grid (via STATE_RESP)

<grid_uuid>:micro:visibility       → {"current": 50}
                                      Writer: Proc2
                                      Readers: Proc1, grid (via STATE_RESP)

<grid_uuid>:micro:eep              → {"preset": "Clear_Spring_Day"}
                                      Writer: Proc2
                                      Readers: grid (via STATE_RESP)
                                      EEP preset from targets.eep_preset. Passed through to grid
                                      for application.

<grid_uuid>:micro:particle         → {"preset": "none"}
                                      Writer: Proc2
                                      Readers: grid (via STATE_RESP)
                                      Particle preset from targets.particle. Passed through to grid
                                      for application.
```

**Ownership summary:**

| Key prefix | Writer | Readers |
|---|---|---|
| `grids` | Main | Proc1, Proc2 |
| `drivers:*` | Proc3 | Proc1, Proc2 |
| `<grid_uuid>:meta` | Main | Proc1, Proc2, Proc3 |
| `<grid_uuid>:targets` | Main (on behalf of grid via TARGET_PUSH) | Proc1, Proc2 |
| `<grid_uuid>:macro:*` | Proc1 | Proc2, grid |
| `<grid_uuid>:micro:*` | Proc2 | Proc1, grid |
| `reset_mode` | Main | Main (self, on reboot) |

**Notes:**

- The processor does **not** cache weather state definitions. It only holds the current target parameters (`<grid_uuid>:targets`), which are a flat set of values the grid sends on registration and on each state transition (via TARGET_PUSH). This keeps per-grid storage at ~1.2 KB regardless of how many weather states a grid defines.
- The `<grid_uuid>:micro:*` keys are split per-field rather than one blob. This lets Proc2 write individual fields independently (e.g., update temp every cycle but dust only when it changes) and lets readers pull specific fields without decoding a large JSON object. The tradeoff is more LSD keys (one per field per grid), but each value is small and LSD key count limits are generous.
- The `<grid_uuid>:macro:*` keys are fewer and larger because macro state changes less frequently and is usually read as a whole.
- `drivers:extreme_weather` is a placeholder key showing where future Proc3 outputs live. Its schema is not defined yet.
- `drivers:pressure` provides an independent background pressure signal. Without it, the grid would only see pressure values reflecting its own target decisions (a circular dependency). The pressure driver breaks that circle by injecting an external forcing function that Proc2 mixes into computed pressure and Proc1 exposes as a trend for the grid's progression logic.
- The `eep` and `particle` keys live under `micro:*` because they're presentation values passed through from the grid-provided targets. Proc2 copies them from `<grid_uuid>:targets` into the micro namespace so the grid can read them via STATE_RESP alongside computed values.
- The `<grid_uuid>:targets` key is written by Main on behalf of the grid. When a grid sends a TARGET_PUSH message, Main updates this key in LSD. Proc1 and Proc2 read it on their next cycle and evolve toward the new targets. This means there is a one-cycle delay between a grid deciding to transition and the processor beginning to evolve toward the new targets — acceptable for slow weather.

### Grid prim LSD

Each grid prim has its own 128 KB LSD, independent of the processor. This holds the grid's configuration (from notecard), weather state definitions (from notecard), live presentation state, and transition decision state. The grid is the decision maker — it knows its state space, evaluates polled computed values against transition rules, and sends new targets to the processor when a transition is warranted.

```
config                             → {"biome": "desert_coast", "climate": "mediterranean_arid",
                                      "lat": 31.2, "eep_enabled": true,
                                      "nile_adjacent": true, "sea_direction": "N",
                                      "min_x": 0, "min_y": 0, "min_z": 0,
                                      "max_x": 256, "max_y": 256, "max_z": 300}
                                      Writer: notecard loader (once, on first boot)
                                      Readers: grid controller script, sent to processor via META_RESP
                                      The min_*/max_* fields define the grid's zone bounding box
                                      in region coordinates. min_z/max_z are the altitude band.

Akhet:Clear Skies                  → {"temp_base": 24, "temp_diurnal": 4, "temp_phase": 14,
                                      "humidity": 67, "pressure": 1015, "wind_speed": 15,
                                      "wind_dir": "NW", "wind_variability": 0.3,
                                      "precipitation": 5, "dust": 0, "visibility": 50,
                                      "weight": 8, "duration": "5-10",
                                      "eep_preset": "Clear_Akhet_Day", "particle": "none",
                                      "progresses_to": "Partly Cloudy",
                                      "flood_peak_humidity": 15, "flood_receding_humidity": 8,
                                      "flood_low_dust": 10}
                                      Writer: notecard loader (once)
                                      Readers: grid controller (used for transition decisions and
                                               to extract target parameters for TARGET_PUSH)

Peret:Khamsin                      → {"temp_base": 38, ..., "event": true,
                                      "eep_preset": "Khamsin_Dust_Storm",
                                      "particle": "dust_storm_heavy",
                                      "regresses_to": "Clear Skies"}
                                      Writer: notecard loader (once)
                                      Readers: grid controller

Shemu:Clear Skies                  → {...}
...                                → (one key per defined weather state, per season)

state                              → {"current_state": "Clear Skies", "season": "Akhet",
                                      "temp": 24.3, "humidity": 67, "pressure": 1015,
                                      "wind_speed": 15, "wind_dir": "NW",
                                      "dust": 0, "precipitation": 5, "visibility": 50,
                                      "eep_preset": "Clear_Akhet_Day", "particle": "none",
                                      "last_update": 1709123456}
                                      Writer: grid controller (updated from STATE_RESP data)
                                      Readers: grid controller (for presentation + transition evaluation)
                                      This is the grid's local copy of computed results. Updated on
                                      each poll response. The grid evaluates these values against
                                      its state definitions to decide transitions.

transition                         → {"current": "Clear Skies", "season": "Akhet",
                                      "pressure_history": [[1709123400, 1014],
                                                           [1709123460, 1012],
                                                           [1709123520, 1011]],
                                      "duration_timer": 120, "duration_target": 480,
                                      "cooldown": 0,
                                      "lock": null,
                                      "target_bias": null}
                                      Writer: grid controller
                                      Readers: grid controller
                                      Progression decision state: current state name, timestamped
                                      pressure history (rolling 10-min retention, 5-min eval window),
                                      duration timer (cycles elapsed in current state) vs duration
                                      target (parsed from notecard), cooldown counter. The grid
                                      computes a time-windowed linear regression over pressure_history
                                      to determine sustained trends — not poll counts. This is the
                                      grid's decision-making workspace for the staged progression
                                      model — not sent to the processor.
                                      lock: null or {"locked_state": "Storm", "unlock_at": 1709127000}
                                      — when set, progression is frozen and the grid stays in
                                      locked_state. Set by admin `force` command, cleared by
                                      `unlock` or timer expiry.
                                      target_bias: null or {"target_state": "Cloudy",
                                      "expires": 1709127000} — when set, progression conditions
                                      toward target_state are eased (threshold halved, weight x10).
                                      Set by admin `target` command, cleared by timer expiry.
```

**Notes:**

- The `config` and `season:weather_state` keys are written once by the notecard streaming loader and never modified at runtime. They are the grid's authored parameters and the source of target values for TARGET_PUSH. Each weather state includes `progresses_to`, `regresses_to`, and optionally `diverges_to` fields defining the progression graph.
- The `state` key is the grid's live runtime state, updated from processor responses. It's a flat object rather than per-field keys because the grid reads it as a whole for presentation and progression evaluation.
- The `transition` key is the grid's progression decision workspace. It holds a timestamped pressure history that the grid uses to compute time-windowed trends (5-minute linear regression). Progression conditions are evaluated against these real-time trends, not poll counts — making the system immune to poll cadence and processor cycle timing. The grid also receives Proc3's driver pressure trend via `macro:evolution.pressure_trend` in each STATE_RESP and can cross-check it against its local trend. When a condition is met, the grid transitions along the corresponding path and sends new targets via TARGET_PUSH.
- Weather state keys use `season:state_name` format. Season names may be compound (`Spring/Akhet`) using `/` as the taxonomy separator. State names and season names cannot contain `:` (the namespace delimiter). Spaces in state names are allowed.
- The grid sends `config` to the processor via META_RESP when requested. Weather state parameters are **not** sent to the processor as a catalogue — the grid extracts the relevant fields from the target state and sends them as a flat target set via TARGET_PUSH. The processor never sees state names or the full state definitions.
- Proc3's background pressure trend is declared to the grid through the normal poll cycle: the grid sends STATE_POLL via Main, Proc1 reads `drivers:pressure` and includes the trend in `macro:evolution`, and the grid receives it in the STATE_RESP payload. No separate query mechanism is needed — the trend rides alongside the computed values in every poll response.
