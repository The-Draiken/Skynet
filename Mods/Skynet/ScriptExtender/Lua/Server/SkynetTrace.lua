-- Turn trace (MCM "Record each turn to a file that survives a crash", off by default).
-- Keeps the last turns in Script Extender/skynet/turn_trace.txt: who took the turn, every line Skynet logged while
-- planning it (spells in the spell book, spells considered, what it queued, "NO SPELL SELECTED", hand-backs to the base
-- game AI), how long the turn took and every freeze during it. The combat record in the same folder is only written
-- every 200 events, so its last part is lost in a crash; this file is rewritten at each turn start and end, at each
-- hand-back to the base game AI and right after each freeze, so it shows what was happening when the game died.
-- Loaded before Skynet.lua: Skynet's log() passes every line here, and the TurnStarted listener below runs before
-- Skynet's own.

SkynetTrace = SkynetTrace or {}
local T = SkynetTrace
local FILE = "skynet/turn_trace.txt"
local KEEP_TURNS = 30
local MAX_LINES = 150         -- lines kept per turn
local FREEZE_MS = 1000        -- a gap between game ticks longer than this is recorded as a freeze
-- lines that are written to disk at once: the moment control passes to the base game AI
local WRITE_NOW = { "HAND BACK", "releasing to base AI", "BASE GAME CONTROL", "FULL CONTROL", "NO SPELL SELECTED", "endTurn", "ends the turn" }

T.turns = {}
T.current = nil
local enabledCache, enabledAt = false, -1e9
local lastTick = nil

local function now()
    local ok, t = pcall(function() return Ext.Utils.MonotonicTime() end)
    return ok and tonumber(t) or 0
end

local function enabled()
    local t = now()
    if t - enabledAt > 2000 then
        enabledAt = t
        local ok, v = pcall(function() return Mods.BG3MCM.MCMAPI:GetSettingValue("RecordTurnTrace", ModuleUUID) end)
        enabledCache = ok and v == true
    end
    return enabledCache
end

local function clock()
    local ok, c = pcall(function() return Ext.Timer.ClockTime() end)
    return ok and tostring(c) or ""
end

local function label(uuid)
    local s = tostring(uuid or "?")
    return s
end

local function write()
    local out = { "SKYNET TURN TRACE - the last " .. KEEP_TURNS .. " turns, newest last. Written " .. clock(),
        "Each turn: who, what Skynet logged while planning it, every freeze (game not responding) during it, and how long it took.",
        "A turn with long freezes and no Skynet lines after a hand-back was being worked out by the base game AI.", "" }
    for _, turn in ipairs(T.turns) do
        out[#out + 1] = string.format("=== TURN %s  (started %.1f s into the session)", turn.who, turn.t0 / 1000)
        for _, l in ipairs(turn.lines) do out[#out + 1] = "  " .. l end
        if turn.dropped > 0 then out[#out + 1] = string.format("  ... %d more line(s) not kept", turn.dropped) end
        if turn.t1 then
            out[#out + 1] = string.format("  --- turn ended after %.1f s; frozen %.1f s in total, longest freeze %.1f s",
                (turn.t1 - turn.t0) / 1000, turn.frozen / 1000, turn.longest / 1000)
        else
            out[#out + 1] = string.format("  --- turn still running %.1f s after it started (frozen %.1f s so far, longest %.1f s)",
                (now() - turn.t0) / 1000, turn.frozen / 1000, turn.longest / 1000)
        end
        out[#out + 1] = ""
    end
    pcall(Ext.IO.SaveFile, FILE, table.concat(out, "\n"), "user")
end

local function addLine(turn, text)
    if #turn.lines < MAX_LINES then
        turn.lines[#turn.lines + 1] = string.format("[+%.1f s] %s", (now() - turn.t0) / 1000, text)
    else
        turn.dropped = turn.dropped + 1
    end
end

-- called from Skynet's log() for every line, whether or not debug logging is on
function T.line(...)
    if not T.current or not enabled() then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local text = table.concat(parts, " ")
    addLine(T.current, text)
    for _, key in ipairs(WRITE_NOW) do
        if text:find(key, 1, true) then write() break end
    end
end

local function startTurn(character)
    if not enabled() then T.current = nil return end
    local who = label(character)
    if T.current and T.current.who == who and not T.current.t1 then return end  -- the same turn reported twice
    if T.current and not T.current.t1 then T.current.t1 = now() end
    T.current = { who = who, t0 = now(), lines = {}, dropped = 0, frozen = 0, longest = 0 }
    T.turns[#T.turns + 1] = T.current
    while #T.turns > KEEP_TURNS do table.remove(T.turns, 1) end
    write()
end

local function endTurn(character)
    if not T.current or not enabled() then return end
    if T.current.who == label(character) and not T.current.t1 then
        T.current.t1 = now()
        write()
    end
end

-- freezes: a long gap between ticks; the file is written right after one, so it is on disk if the next one kills the game
local function onTick()
    local t = now()
    if lastTick and T.current and not T.current.t1 then
        local gap = t - lastTick
        if gap > FREEZE_MS and enabled() then
            T.current.frozen = T.current.frozen + gap
            if gap > T.current.longest then T.current.longest = gap end
            addLine(T.current, string.format("FREEZE: the game did not respond for %.1f s", gap / 1000))
            write()
        end
    end
    lastTick = t
end

pcall(Ext.Osiris.RegisterListener, "TurnStarted", 1, "before", startTurn)
pcall(Ext.Osiris.RegisterListener, "TurnEnded", 1, "after", endTurn)
pcall(function() Ext.Events.Tick:Subscribe(onTick) end)
pcall(function()
    Ext.Events.GameStateChanged:Subscribe(function(e)
        local to = tostring(e.ToState)
        if to:find("Load") or to:find("Menu") then T.current, lastTick = nil, nil end
    end)
end)
