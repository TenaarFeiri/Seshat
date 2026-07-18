# Admin Commands

The Seshat Weather System supports owner-only admin commands via a private chat channel. Commands are typed in local chat on channel **-88888** (the admin channel). Only the object owner can issue commands.

## Usage

Type commands in local chat prefixed with the channel number:

```
/-88888 <command> [arguments]
```

For example:

```
/-88888 dump all
/-88888 history abc123-4567-...
/-88888 force all Khamsin 30
```

The grid UUID can be found in the dump output or Main's registration log. Use `all` to target every registered grid.

## Commands

### `reset [full|soft]`

Resets the processor system. Does not target a specific grid.

- **`soft`** (default): Clears grid registrations and micro LSD keys. Grids re-register on their next poll. Preserves driver state (pressure phase, flood state).
- **`full`**: Clears all weather system LSD including driver state. Proc3 re-seeds its pressure phase from the clock. Use this for a clean restart.

```
/-88888 reset
/-88888 reset full
```

### `target <grid_uuid|all> <state name>`

Sets a target bias on the grid, making transitions toward the specified state more likely. State names may contain spaces (`target all Partly Cloudy`) and are matched case-insensitively against the current season's states. If the state doesn't exist in the current season, the grid rejects the bias and lists the valid states.

For the biased candidate, condition thresholds are eased in the permissive direction (trend thresholds moved halfway toward zero; humidity ±8, pressure ±3 hPa, temperature ±2 °C, wind ±5 kph) and its selection score is multiplied by 10× — in both normal condition-based picks and duration-expiry picks. The bias expires after 30 minutes.

This does not force an immediate transition — it just makes the specified state easier to reach if conditions are close. Use `force` for an immediate lock. Note that Main reports the bias as *sent*; the grid reports it as *set* (or rejected) after validating.

```
/-88888 target all Storm
/-88888 target abc123-4567-... hazy heat
```

### `force <grid_uuid|all> <state name> [minutes]`

Force-locks the grid into a specific state. State names may contain spaces and are matched case-insensitively; unknown states are rejected with the valid list. A trailing numeric token is taken as the lock duration in minutes (default 30).

The grid transitions immediately through the normal transition path — new atmospheric targets are pushed to the processor (so temperature, humidity, pressure, wind, and visuals all follow), and the transition is recorded in history. The lock prevents all condition-based and duration-based transitions. Use `unlock` to release early.

```
/-88888 force all Khamsin 60
/-88888 force abc123-4567-... partly cloudy 45
```

### `unlock <grid_uuid|all>`

Releases a forced lock early. The grid resumes normal progression evaluation on its next poll.

```
/-88888 unlock all
```

### `dump <grid_uuid|all>`

Dumps the grid's current runtime state to owner chat. Shows:

- Current state, season, and all computed weather values (temp, humidity, pressure, wind, dust, visibility, EEP, particle)
- Time since last state change
- Duration timer vs min-max range
- Cooldown status (if active)
- Pressure history entry count and computed trend
- Active target bias or forced lock (if any)
- Recurrence tracking: hours since each of the season's states last occurred

```
/-88888 dump all
/-88888 dump abc123-4567-...
```

### `history <grid_uuid|all>`

Dumps the grid's transition history (last 20 entries) to owner chat. Each entry shows:

- Entry number
- Previous state → new state
- Time since the transition (minutes ago)
- Reason for the transition (e.g. "progress condition met → Hazy Heat", "duration expired, regress → Clear Skies")

```
/-88888 history all
/-88888 history abc123-4567-...
```

### `debug <grid_uuid|all> <on|off>`

Toggles debug mode on the grid. When enabled, the grid may emit additional diagnostic messages to owner chat (implementation-specific).

```
/-88888 debug all on
/-88888 debug abc123-4567-... off
```

## Command Summary

| Command | Target | Arguments | Description |
|---|---|---|---|
| `reset` | system | `[full\|soft]` | Reset processor system |
| `target` | grid | `<state name>` | Bias transitions toward a state (30 min expiry) |
| `force` | grid | `<state name> [minutes]` | Lock grid into a state (default 30 min) |
| `unlock` | grid | — | Release forced lock |
| `dump` | grid | — | Show current state and tracking data |
| `history` | grid | — | Show last 20 transitions with reasons |
| `debug` | grid | `<on\|off>` | Toggle debug mode |

## Transition Reasons

The `history` command reports why each transition occurred. Possible reasons:

| Reason pattern | Meaning |
|---|---|
| `progress condition met → <state>` | A progression condition (trend and/or humidity) was met for the target state |
| `regress condition met → <state>` | A regression condition was met for the target state |
| `diverge condition met → <state>` | A divergence condition (pressure/threshold) was met for an event state |
| `multiple conditions met, weighted pick → <state>` | Multiple candidates were ready; score-based pick (weight × overdue bonus × target bias) chose this one |
| `duration expired, weighted <type> → <state>` | Max duration reached; weighted pick among all legal non-event exits (sun-phase gates still apply; states unseen for a long time score higher) |
| `duration expired, fallback regress → <state>` | Max duration reached but no exit was eligible (e.g. all phase-gated to another time of day); first regress edge taken as escape hatch |
| `duration expired, fallback progress → <state>` | As above, but no regress edge existed; first progress edge taken |
| `admin force` | Owner issued a `force` command |
| `bootstrap: pressure delta from baseline` | Cold-boot evaluation detected conditions warranting a non-Clear-Skies start |
