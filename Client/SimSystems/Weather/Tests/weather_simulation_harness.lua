-- Local deterministic harness for Weather_Grid's transition maths.
-- Run: lua Client/SimSystems/Weather/Tests/weather_simulation_harness.lua
-- The clock is simulated. Sun phase is derived only from an X/Z direction
-- vector matching ll.GetSunDirection's sunrise/noon/sunset/midnight convention.

local NOTECARD = arg[1] or "Client/SimSystems/Weather/Grid/Alexandria_Oasis.notecard"
local STEP_SECONDS = 3600
local ITERATIONS = 72
local OVERDUE_REFERENCE_HOURS = 24
local OVERDUE_MAX_MULTIPLIER = 6

local function trim(value)
    return (value:gsub("^%s*(.-)%s*$", "%1"))
end

local function parse_value(value)
    value = trim(value)
    if value == "true" then return true end
    if value == "false" then return false end
    local number = tonumber(value)
    if number then return number end
    if value:find(",", 1, true) then
        local values = {}
        for part in value:gmatch("[^,]+") do values[#values + 1] = trim(part) end
        return values
    end
    return value
end

local function parse_notecard(path)
    local file, error_message = io.open(path, "r")
    assert(file, error_message)
    local seasons, season, state_name, state = {}, nil, nil, nil
    local function flush()
        if season and state_name then seasons[season][state_name] = state end
        state_name, state = nil, nil
    end
    for raw in file:lines() do
        local line = trim((raw:gsub("#.*$", "")))
        local scope_type, scope_name = line:match("^{%s*(%w+)%s*:%s*(.-)%s*}$")
        local header = line:match("^%[(.-)%]$")
        local key, value = line:match("^(%w[%w_]*)%s*=%s*(.+)$")
        if scope_type == "season" then
            flush()
            season = scope_name
            seasons[season] = seasons[season] or {}
        elseif header then
            flush()
            assert(season, "state declared before a season")
            state_name, state = header, {}
        elseif key and state then
            state[key] = parse_value(value)
        end
    end
    flush()
    file:close()
    return seasons
end

local function as_list(value)
    if type(value) == "table" then return value end
    return value and {value} or {}
end

local function slug(name)
    return (name:gsub("%s+", "_"))
end

local function condition_value(state, path_type, target, field)
    return state[path_type .. "_" .. slug(target) .. "_" .. field]
        or state[path_type .. "_" .. field]
end

local function sun_direction(seconds)
    local hour = (seconds / 3600) % 24
    local angle = ((hour - 6) / 24) * 2 * math.pi
    local x, z = math.cos(angle), math.sin(angle)
    if math.abs(x) < 1e-12 then x = 0 end
    if math.abs(z) < 1e-12 then z = 0 end
    return {x = x, z = z}
end

local function sun_phase(sun)
    if sun.z <= 0 then return "night" end
    if sun.z < 0.5 then return sun.x > 0 and "morning" or "evening" end
    return "day"
end

local function phase_allowed(path_type, state, target, phase)
    local allowed = {
        morning = condition_value(state, path_type, target, "morning") == true,
        day = condition_value(state, path_type, target, "day") == true,
        evening = condition_value(state, path_type, target, "evening") == true,
        night = condition_value(state, path_type, target, "night") == true,
    }
    if not allowed.morning and not allowed.day and not allowed.evening and not allowed.night then return true end
    return allowed[phase]
end

local function all_met(values)
    for _, value in ipairs(values) do if not value then return false end end
    return #values > 0
end

local function any_met(values)
    for _, value in ipairs(values) do if value then return true end end
    return false
end

local function meets_conditions(path_type, state, target, values, phase)
    if not phase_allowed(path_type, state, target, phase) then return false end
    local checks, logic = {}, "and"
    if path_type == "progress" then
        local trend = condition_value(state, path_type, target, "trend_max")
        local humidity = condition_value(state, path_type, target, "humidity_min")
        if trend == nil and humidity == nil then return false end
        if trend ~= nil then checks[#checks + 1] = values.trend < trend end
        if humidity ~= nil then checks[#checks + 1] = values.humidity > humidity end
        logic = condition_value(state, path_type, target, "logic") or "or"
    elseif path_type == "regress" then
        local trend = condition_value(state, path_type, target, "trend_min")
        local humidity = condition_value(state, path_type, target, "humidity_max")
        if trend == nil and humidity == nil then return false end
        if trend ~= nil then checks[#checks + 1] = values.trend > trend end
        if humidity ~= nil then checks[#checks + 1] = values.humidity < humidity end
        logic = condition_value(state, path_type, target, "logic") or "and"
    else
        local fields = {
            {"pressure_max", "pressure", function(a, b) return a < b end},
            {"trend_max", "trend", function(a, b) return a < b end},
            {"humidity_min", "humidity", function(a, b) return a > b end},
            {"humidity_max", "humidity", function(a, b) return a < b end},
            {"temp_min", "temp", function(a, b) return a > b end},
            {"wind_speed_min", "wind_speed", function(a, b) return a > b end},
            {"wind_speed_max", "wind_speed", function(a, b) return a < b end},
        }
        for _, field in ipairs(fields) do
            local threshold = condition_value(state, path_type, target, field[1])
            if threshold ~= nil then checks[#checks + 1] = field[3](values[field[2]], threshold) end
        end
        if #checks == 0 then return false end
        logic = condition_value(state, path_type, target, "logic") or "and"
    end
    return logic == "or" and any_met(checks) or all_met(checks)
end

local function candidates(state)
    local result = {}
    local fields = {
        progress = "progresses_to",
        regress = "regresses_to",
        diverge = "diverges_to",
    }
    for path_type, field in pairs(fields) do
        for _, name in ipairs(as_list(state[field])) do
            result[#result + 1] = {path_type = path_type, name = name}
        end
    end
    return result
end

local function duration_bounds(duration)
    local minimum, maximum = tostring(duration or "1-6"):match("(%d+)%s*-%s*(%d+)")
    if minimum then return tonumber(minimum), tonumber(maximum) end
    local single = tonumber(duration) or 1
    return single, single
end

local function candidate_score(state, name, last_seen, seconds)
    local unseen_hours = (seconds - (last_seen[name] or 0)) / 3600
    local overdue = math.min(1 + unseen_hours / OVERDUE_REFERENCE_HOURS, OVERDUE_MAX_MULTIPLIER)
    return (state.weight or 1) * overdue
end

local function pick(pool)
    local total = 0
    for _, entry in ipairs(pool) do total = total + entry.score end
    local roll, cumulative = math.random() * total, 0
    for _, entry in ipairs(pool) do
        cumulative = cumulative + entry.score
        if roll <= cumulative then return entry end
    end
    return pool[#pool]
end

local function synthetic_values(state, seconds)
    local sun = sun_direction(seconds)
    local cycle = (seconds / 3600) * 2 * math.pi / 18
    -- A coherent synthetic approaching low: pressure falls, humidity rises,
    -- and the negative trend peaks together. This gives the notecard's
    -- storm/divergence thresholds a realistic signal to evaluate.
    local low_signal = math.cos(cycle)
    return {
        temp = (state.temp_base or 25) + (state.temp_diurnal or 3) * sun.z,
        humidity = math.max(0, math.min(100, (state.humidity or 50) - 3 * sun.z + 8 * low_signal)),
        pressure = (state.pressure or 1013) - 5 * low_signal,
        trend = -0.35 * low_signal,
        wind_speed = 18,
        sun = sun,
    }
end

local function simulate(season_name, states)
    local current, seconds, duration, last_seen = "Clear Skies", 0, 0, { ["Clear Skies"] = 0 }
    local counts, history = {["Clear Skies"] = 1}, {}
    assert(states[current], season_name .. " has no Clear Skies")
    for _ = 1, ITERATIONS do
        seconds, duration = seconds + STEP_SECONDS, duration + 1
        local state = states[current]
        local values = synthetic_values(state, seconds)
        local phase = sun_phase(values.sun)
        local ready = {}
        local minimum_duration, maximum_duration = duration_bounds(state.duration)
        if duration >= minimum_duration then
            for _, candidate in ipairs(candidates(state)) do
                local target = assert(states[candidate.name], season_name .. " references missing " .. candidate.name)
                if meets_conditions(candidate.path_type, state, candidate.name, values, phase) then
                    ready[#ready + 1] = {name = candidate.name, state = target, path = candidate.path_type,
                        score = candidate_score(target, candidate.name, last_seen, seconds), reason = "condition"}
                end
            end
        end
        local chosen = #ready > 0 and pick(ready) or nil
        if not chosen and duration >= maximum_duration then
            local pool = {}
            for _, candidate in ipairs(candidates(state)) do
                local target = states[candidate.name]
                if not target.event and phase_allowed(candidate.path_type, state, candidate.name, phase) then
                    pool[#pool + 1] = {name = candidate.name, state = target, path = candidate.path_type,
                        score = candidate_score(target, candidate.name, last_seen, seconds), reason = "duration"}
                end
            end
            if #pool > 0 then chosen = pick(pool) end
        end
        if chosen then
            history[#history + 1] = string.format("%02dh %-7s %s -> %s (%s %s)", seconds / 3600,
                phase, current, chosen.name, chosen.reason, chosen.path)
            last_seen[current], last_seen[chosen.name] = seconds, seconds
            current, duration = chosen.name, 0
            counts[current] = (counts[current] or 0) + 1
        end
    end
    return counts, history
end

local seasons = parse_notecard(NOTECARD)
math.randomseed(20260718)
for hour, expected in pairs({[0] = "night", [7] = "morning", [12] = "day", [17] = "evening", [19] = "night"}) do
    assert(sun_phase(sun_direction(hour * 3600)) == expected, "incorrect synthetic sun phase")
end
for _, season in ipairs({"Akhet", "Peret", "Shemu"}) do
    local states = assert(seasons[season], "missing season " .. season)
    local counts, history = simulate(season, states)
    local names, missing = {}, {}
    for name, state in pairs(states) do
        if not state.event then
            names[#names + 1] = name
            if not counts[name] then missing[#missing + 1] = name end
        end
    end
    table.sort(names)
    local summary = {}
    for _, name in ipairs(names) do summary[#summary + 1] = name .. "=" .. (counts[name] or 0) end
    print(season .. ": " .. #history .. " transitions; " .. table.concat(summary, ", "))
    for _, entry in ipairs(history) do print("  " .. entry) end
    assert(#missing == 0, season .. " did not visit: " .. table.concat(missing, ", "))
end
print("PASS: all normal states visited using synthetic sun-direction cycles.")