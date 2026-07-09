# Cross-system comms protocol

Rough sketch. See DESIGN.md for the architecture this protocol serves.

## Envelope

Every message is a JSON object with four keys:

```json
{
  "o": [1, 2],
  "f": "object_uuid:script_name",
  "t": [1, 2],
  "p": [payload1, payload2]
}
```

### Keys

- **`o`** — operations. Array of integers, each mapping to an operation via the op table (see below). This is the source of truth for the message: the number of entries in `o` determines the expected length of `t` and `p`. If any array's length does not match `o`, the message is malformed and discarded entirely.
- **`f`** — from. Sender identifier, typically `object_uuid:script_name`.
- **`t`** — to. Array of recipient integers, mapped via the recipient table (see below). Order matches `o`. Main is the routing entrypoint and delegates based on the operations array. If `main` (int 1) appears as a recipient, Main performs that op's internal function itself.
- **`p`** — payload. Array of payloads, one per operation. Order matches `o`. Each payload is a JSON object whose keys are integers mapped via the field dictionary (see below).

### Validation

The receiver validates on receipt:

1. Parse JSON. If parse fails, discard.
2. Check `o`, `t`, `p` array lengths match. If not, discard.
3. `f` must be present and non-empty. If not, discard.
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
    REGISTER    = 1,
    UNREGISTER  = 2,
    STATE_POLL  = 3,
    STATE_RESP  = 4,
    META_REQ    = 5,
    META_RESP   = 6,
    TARGET_PUSH = 7,
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
  "f": "proc_uuid:proc1",
  "t": [5],
  "p": [{"1": "abc123", "2": 24, "3": 35}]
}
```

`t: [5]` means "for a grid." Payload field `1` (the `grid` field) tells Main which grid.

### Field dictionary

Payload field names are mapped to integers. The dictionary is global — one table shared across all ops. A field like `grid` always has the same int regardless of which op's payload it appears in.

```lua
local field = {
    grid       = 1,
    temp       = 2,
    humidity   = 3,
    pressure   = 4,
    wind_speed = 5,
    wind_dir   = 6,
    uuid       = 7,
    biome      = 8,
    -- etc, to be expanded as payload schemas are defined
}
```

Sender uses `field.grid` (→ `1`) when building payloads. Receiver accesses fields by int directly, with a comment indicating the field name for readability:

```lua
local function handle_state_resp(payload)
    local grid_uuid = payload[1]   -- grid
    local temp      = payload[2]   -- temp
    local humidity  = payload[3]   -- humidity
end
```

No reverse lookup needed. The field table is always viewable in code for reference.

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

<grid_uuid>:meta                   → {"biome": "desert_coast", "climate": "mediterranean_arid",
                                      "lat": 31.2, "eep_enabled": true, "eep_experience": "<uuid>",
                                      "nile_adjacent": true}
                                      Writer: Main (scaffolded on registration, filled from grid via META_REQ/META_RESP)
                                      Readers: Proc1, Proc2, Proc3
                                      Grid metadata. Populated on-demand if missing.

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
                                      "lat": 31.2, "eep_enabled": true, "eep_experience": "<uuid>",
                                      "nile_adjacent": true}
                                      Writer: notecard loader (once, on first boot)
                                      Readers: grid controller script, sent to processor via META_RESP

Spring/Akhet:Clear Skies           → {"temp_base": 24, "temp_diurnal": 8, "temp_phase": 14,
                                      "humidity": 35, "pressure": 1015, "wind_speed": 5,
                                      "wind_dir": "NW", "wind_variability": 0.3,
                                      "precipitation": 0, "dust": 0, "visibility": 50,
                                      "weight": 10, "duration": "4-9",
                                      "eep_preset": "Clear_Spring_Day", "particle": "none",
                                      "flood_peak_humidity": 15, "flood_receding_humidity": 8,
                                      "flood_low_dust": 10}
                                      Writer: notecard loader (once)
                                      Readers: grid controller (used for transition decisions and
                                               to extract target parameters for TARGET_PUSH)

Spring/Akhet:Khamsin               → {"temp_base": 38, ..., "event": true,
                                      "eep_preset": "Khamsin_Dust_Storm",
                                      "particle": "dust_storm_heavy"}
                                      Writer: notecard loader (once)
                                      Readers: grid controller

Summer/Shemu:Clear Skies           → {...}
...                                → (one key per defined weather state, per season)

state                              → {"current_state": "Clear Skies", "season": "Spring/Akhet",
                                      "temp": 24.3, "humidity": 35, "pressure": 1015,
                                      "wind_speed": 5, "wind_dir": "NW",
                                      "dust": 0, "precipitation": 0, "visibility": 50,
                                      "eep_preset": "Clear_Spring_Day", "particle": "none",
                                      "last_update": 1709123456}
                                      Writer: grid controller (updated from STATE_RESP data)
                                      Readers: grid controller (for presentation + transition evaluation)
                                      This is the grid's local copy of computed results. Updated on
                                      each poll response. The grid evaluates these values against
                                      its state definitions to decide transitions.

transition                         → {"current": "Clear Skies", "season": "Spring/Akhet",
                                      "pressure_history": [[1709123400, 1014],
                                                           [1709123460, 1012],
                                                           [1709123520, 1011]],
                                      "duration_timer": 120, "duration_target": 480,
                                      "cooldown": 0}
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
```

**Notes:**

- The `config` and `season:weather_state` keys are written once by the notecard streaming loader and never modified at runtime. They are the grid's authored parameters and the source of target values for TARGET_PUSH. Each weather state includes `progresses_to`, `regresses_to`, and optionally `diverges_to` fields defining the progression graph.
- The `state` key is the grid's live runtime state, updated from processor responses. It's a flat object rather than per-field keys because the grid reads it as a whole for presentation and progression evaluation.
- The `transition` key is the grid's progression decision workspace. It holds a timestamped pressure history that the grid uses to compute time-windowed trends (5-minute linear regression). Progression conditions are evaluated against these real-time trends, not poll counts — making the system immune to poll cadence and processor cycle timing. The grid also receives Proc3's driver pressure trend via `macro:evolution.pressure_trend` in each STATE_RESP and can cross-check it against its local trend. When a condition is met, the grid transitions along the corresponding path and sends new targets via TARGET_PUSH.
- Weather state keys use `season:state_name` format. Season names may be compound (`Spring/Akhet`) using `/` as the taxonomy separator. State names and season names cannot contain `:` (the namespace delimiter). Spaces in state names are allowed.
- The grid sends `config` to the processor via META_RESP when requested. Weather state parameters are **not** sent to the processor as a catalogue — the grid extracts the relevant fields from the target state and sends them as a flat target set via TARGET_PUSH. The processor never sees state names or the full state definitions.
- Proc3's background pressure trend is declared to the grid through the normal poll cycle: the grid sends STATE_POLL via Main, Proc1 reads `drivers:pressure` and includes the trend in `macro:evolution`, and the grid receives it in the STATE_RESP payload. No separate query mechanism is needed — the trend rides alongside the computed values in every poll response.
