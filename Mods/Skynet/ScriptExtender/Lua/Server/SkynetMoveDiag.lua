-- SkynetMoveDiag.lua — movement diagnostics (pass #61). Turned on with "Movement diagnostics" in Skynet's MCM.
--
-- Question being answered: in the goblin camp, goblins standing below a ledge appeared next to the party on top of it,
-- during turns Skynet had handed to the base game AI. Was that a real route (ladder / climb point / jump), or a jump
-- in position with no route at all?
--
--   1. PATH CHECK — whenever Skynet hands a turn (or what is left of one) to the base game AI, ask the game's own
--      pathfinder (Ext.Level.BeginPathfindingImmediate) whether this enemy has a route to each party member, and log
--      everything the returned path object exposes (the Script Extender docs don't list its fields, so they are
--      probed and dumped rather than assumed).
--   2. POSITION WATCH — during every non-party combatant's turn, sample its position 4 times a second. A big move
--      in one sample (an instant "teleport") or a fast climb is logged with what the character had cast so far
--      this turn and who was in control (Skynet, or the base AI after a hand-off). A summary line is logged when
--      the turn ends.
--
-- Nothing here moves anyone or changes a decision; it only reads and logs. Lines start with "[Skynet MoveDiag]".
-- Its own file and global table (SkynetMoveDiag), so it doesn't touch Skynet.lua's local-variable budget.

SkynetMoveDiag = SkynetMoveDiag or {}
local D = SkynetMoveDiag

local MOD_UUID = "e883778e-f8ae-9d7c-aa01-e738c7fb1040"
local PREFIX = "[Skynet MoveDiag] "

D.SAMPLE_MS = 250
D.JUMP_STEP_M = 4.0        -- moved further than this between two samples (16 m/s): faster than walking/running
D.RISE_STEP_M = 2.0        -- rose more than this between two samples: faster than a climb animation
D.MAX_WATCH_MS = 120000
D.PATH_TARGETS_MAX = 6
D.DUMP_CHARS = 1500

D.watch = D.watch or {}    -- uuid -> watch record for the current turn
D.generation = D.generation or 0
-- True from the moment the game starts leaving the level until it is running again. While it is set nothing here
-- asks the game about a character: the position watch used to keep calling Osi.GetPosition four times a second
-- while the level was being torn down, and it was the last script running when the game crashed on the way
-- back to the main menu (What Caused the Crash unload trace, 2026-11-11).
D.unloading = false

-- ---------------------------------------------------------------- helpers

local function now()
  local ok, t = pcall(function() return Ext.Utils.MonotonicTime() end)
  return (ok and type(t) == "number") and t or 0
end

local function out(msg) pcall(function() Ext.Utils.Print(PREFIX .. tostring(msg)) end) end

function D.enabled()
  local v = nil
  pcall(function()
    if Mods and Mods.BG3MCM and Mods.BG3MCM.MCMAPI then
      v = Mods.BG3MCM.MCMAPI:GetSettingValue("DiagnoseEnemyMovement", MOD_UUID)
    end
  end)
  return v == true
end

local function guid(x)
  local s = tostring(x or "")
  return (s:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$") or s):lower()
end

local function short(x) return tostring(x or ""):gsub("_%x%x%x%x%x%x%x%x%-.*$", "") end

function D.pos(uuid)
  local ok, x, y, z = pcall(function() return Osi.GetPosition(uuid) end)
  if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return { x, y, z } end
  return nil
end

local function fmtPos(p) return p and string.format("(%.1f, %.1f, %.1f)", p[1], p[2], p[3]) or "(?)" end

local function dist3(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2) end
local function dist2(a, b) return math.sqrt((a[1] - b[1]) ^ 2 + (a[3] - b[3]) ^ 2) end   -- y is up in BG3

function D.partyMembers()
  local list = {}
  pcall(function()
    for _, row in pairs(Osi.DB_Players:Get(nil) or {}) do list[#list + 1] = row[1] end
  end)
  return list
end

function D.isParty(uuid)
  local g = guid(uuid)
  for _, p in ipairs(D.partyMembers()) do if guid(p) == g then return true end end
  return false
end

local function inCombat(uuid)
  local ok, v = pcall(function() return Osi.IsInCombat(uuid) end)
  return ok and v == 1
end

-- ---------------------------------------------------------------- path probe

D.PATH_FIELDS = { "GoalFound", "Error", "Distance", "TotalDistance", "Length", "PathLength", "InUse", "IsInUse",
  "PathType", "SearchHorizon", "CloseEnoughMin", "CloseEnoughMax", "CanUseLadders", "CanUsePortals",
  "CanUseCombatPortals", "UseSmoothing", "UseStandAtDestination", "Id", "PathId", "Flags", "SearchComplete",
  "IsBidirectionalSearch", "MovingBound", "TargetBound", "StepHeight", "Climbing", "UsesPortals" }
D.LIST_FIELDS = { "Nodes", "Checkpoints", "PathNodes", "Waypoints" }
D.NODE_FIELDS = { "Position", "Flags", "Type", "NodeType", "IsPortal", "PortalIndex", "Portal", "PortalId",
  "IsLadder", "Ladder", "IsJump", "Jump", "Climb", "ClimbOn", "IsClimb", "Teleport", "IsTeleport", "Item",
  "ItemHandle", "Entity", "Distance", "Cost" }

local function valueText(v)
  local t = type(v)
  if t == "nil" then return nil end
  if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
  if t == "table" then
    if #v == 3 and type(v[1]) == "number" then return fmtPos(v) end
    local n = 0 for _ in pairs(v) do n = n + 1 end
    return "table[" .. n .. "]"
  end
  local okT, tn = pcall(function() return Ext.Types.GetObjectType(v) end)
  return (okT and tn) and ("<" .. tostring(tn) .. ">") or ("<" .. t .. ">")
end

local function probe(obj, fields)
  local parts = {}
  for _, f in ipairs(fields) do
    local ok, v = pcall(function() return obj[f] end)
    local txt = ok and valueText(v) or nil
    if txt then parts[#parts + 1] = f .. "=" .. txt end
  end
  return parts
end

local function listLen(v)
  local ok, n = pcall(function() return #v end)
  return ok and n or nil
end

local function dump(obj)
  local ok, s = pcall(function() return Ext.DumpExport(obj) end)
  if ok and type(s) == "string" then
    s = s:gsub("%s+", " ")
    if #s > D.DUMP_CHARS then s = s:sub(1, D.DUMP_CHARS) .. " …(cut)" end
    return s
  end
  return nil
end

-- Ask the game for a path from `from` (character) to `targetPos`. Returns a list of log lines.
function D.pathReport(from, targetPos)
  local lines = {}
  local Level = Ext and Ext.Level
  if not (Level and Level.BeginPathfindingImmediate) then
    lines[1] = "pathfinding API not available in this Script Extender version"
    return lines
  end
  local okE, ent = pcall(function() return Ext.Entity.Get(from) end)
  if not okE or not ent then
    lines[1] = "could not read the entity"
    return lines
  end
  local path, err
  local ok1, p1 = pcall(function() return Level.BeginPathfindingImmediate(ent, targetPos) end)
  if ok1 and p1 then path = p1 else
    err = p1
    local ok2, p2 = pcall(function()
      return Level.BeginPathfindingImmediate(ent, { x = targetPos[1], y = targetPos[2], z = targetPos[3] })
    end)
    if ok2 and p2 then path = p2 else err = tostring(err) .. " / " .. tostring(p2) end
  end
  if not path then
    lines[1] = "BeginPathfindingImmediate failed: " .. tostring(err)
    return lines
  end
  if Level.FindPath then
    local okF, found = pcall(function() return Level.FindPath(path) end)
    lines[#lines + 1] = "FindPath -> " .. (okF and tostring(found) or ("error: " .. tostring(found)))
  end
  local okT, typeName = pcall(function() return Ext.Types.GetObjectType(path) end)
  local fields = probe(path, D.PATH_FIELDS)
  lines[#lines + 1] = "path " .. ((okT and typeName) and ("<" .. tostring(typeName) .. "> ") or "") ..
    (#fields > 0 and table.concat(fields, ", ") or "(none of the expected fields readable)")
  for _, lf in ipairs(D.LIST_FIELDS) do
    local okL, list = pcall(function() return path[lf] end)
    local n = okL and list and listLen(list) or nil
    if n then
      lines[#lines + 1] = lf .. ": " .. n
      local prev = nil
      for i = 1, math.min(n, 40) do
        local okN, node = pcall(function() return list[i] end)
        if okN and node then
          local nf = probe(node, D.NODE_FIELDS)
          local okP, np = pcall(function() return node.Position end)
          local p = (okP and type(np) == "table" and #np == 3) and np or nil
          local step = (p and prev) and string.format(" step %.1fm rise %.1fm", dist2(prev, p), p[2] - prev[2]) or ""
          lines[#lines + 1] = string.format("  %s[%d] %s%s", lf, i, table.concat(nf, ", "), step)
          prev = p or prev
        end
      end
      if n > 40 then lines[#lines + 1] = "  …" .. (n - 40) .. " more" end
    end
  end
  local d = dump(path)
  if d then lines[#lines + 1] = "dump: " .. d end
  if Level.ReleasePath then pcall(function() Level.ReleasePath(path) end) end
  return lines
end

-- Called by Skynet.lua whenever it gives a turn (or the rest of one) to the base game AI.
function D.onHandOff(enemyId, reason)
  if D.unloading or not D.enabled() then return end
  -- Skynet's TurnStarted handler may run before this file's own: make sure the turn is being watched.
  if not D.watch[guid(enemyId)] and not D.isParty(enemyId) then D.startWatch(enemyId) end
  local w = D.watch[guid(enemyId)]
  if w then w.handedOffAt = now(); w.handOffReason = reason end
  local from = D.pos(enemyId)
  out(string.format("HAND-OFF %s at %s — %s. Asking the game for a route to each party member:",
    short(enemyId), fmtPos(from), tostring(reason or "")))
  local n = 0
  for _, p in ipairs(D.partyMembers()) do
    if n >= D.PATH_TARGETS_MAX then break end
    local tp = D.pos(p)
    if tp and from then
      n = n + 1
      out(string.format("  to %s at %s (straight %.1fm, height %+.1fm):", short(p), fmtPos(tp), dist2(from, tp), tp[2] - from[2]))
      for _, line in ipairs(D.pathReport(enemyId, tp)) do out("    " .. line) end
    end
  end
end

-- ---------------------------------------------------------------- position watch

function D.startWatch(character)
  if D.unloading then return end
  local key = guid(character)
  local p = D.pos(character)
  if not p then return end
  D.generation = D.generation + 1
  local w = { id = character, key = key, gen = D.generation, startPos = p, last = p, lastAt = now(), startedAt = now(),
              travelled = 0, maxStep = 0, maxRise = 0, jumps = 0, casts = {} }
  D.watch[key] = w
  D.sample(w)
end

function D.sample(w)
  if D.watch[w.key] ~= w then return end
  if D.unloading then D.watch[w.key] = nil return end   -- level going away: drop the watch, read nothing, no new timer
  local t = now()
  if t - w.startedAt > D.MAX_WATCH_MS then D.finish(w, "watch timed out") return end
  local p = D.pos(w.id)
  if p then
    local step = dist2(w.last, p)
    local rise = p[2] - w.last[2]
    w.travelled = w.travelled + dist3(w.last, p)
    if step > w.maxStep then w.maxStep = step end
    if rise > w.maxRise then w.maxRise = rise end
    if step > D.JUMP_STEP_M or rise > D.RISE_STEP_M then
      w.jumps = w.jumps + 1
      local ctrl = w.handedOffAt and ("base game AI (handed off: " .. tostring(w.handOffReason) .. ")") or "Skynet"
      out(string.format("POSITION JUMP %s: %s -> %s, %.1fm across and %+.1fm up in %d ms. In control: %s. Cast so far this turn: %s",
        short(w.id), fmtPos(w.last), fmtPos(p), step, rise, t - w.lastAt, ctrl,
        #w.casts > 0 and table.concat(w.casts, ", ") or "nothing"))
    end
    w.last, w.lastAt = p, t
  end
  Ext.Timer.WaitFor(D.SAMPLE_MS, function() D.sample(w) end)
end

function D.finish(w, why)
  if D.watch[w.key] ~= w then return end
  D.watch[w.key] = nil
  if D.unloading then return end
  local endPos = D.pos(w.id) or w.last
  out(string.format("TURN %s (%s): %s -> %s, straight %.1fm (height %+.1fm), travelled ~%.1fm, biggest single step %.1fm, biggest rise %.1fm, %d jump(s). Control: %s. Cast: %s",
    short(w.id), why, fmtPos(w.startPos), fmtPos(endPos), dist2(w.startPos, endPos), endPos[2] - w.startPos[2], w.travelled,
    w.maxStep, w.maxRise, w.jumps, w.handedOffAt and ("base game AI from hand-off (" .. tostring(w.handOffReason) .. ")") or "Skynet throughout",
    #w.casts > 0 and table.concat(w.casts, ", ") or "nothing"))
end

-- Game state changes: stop everything as soon as the level starts to unload, allow it again once the game runs.
function D.onGameState(toState)
  local to = tostring(toState or "")
  if to == "Running" then
    D.unloading = false
  elseif to:find("Unload", 1, true) or to:find("Disconnect", 1, true) or to:find("Exit", 1, true) or to:find("Menu", 1, true) then
    D.unloading = true
    D.watch = {}
  end
end

function D.onTurnStarted(character)
  if D.unloading or not D.enabled() then return end
  if D.isParty(character) or not inCombat(character) then return end
  D.startWatch(character)
end

function D.onTurnEnded(character)
  local w = D.watch[guid(character)]
  if w then D.finish(w, "turn ended") end
end

function D.onCast(caster, spell)
  local w = D.watch[guid(caster)]
  if w then w.casts[#w.casts + 1] = tostring(spell) end
end

-- ---------------------------------------------------------------- registration

function D.register()
  if D.registered then return end
  D.registered = true
  local function reg(name, arity, timing, fn)
    local ok, err = pcall(function() Ext.Osiris.RegisterListener(name, arity, timing, fn) end)
    if not ok then out("could not listen to " .. name .. "/" .. arity .. ": " .. tostring(err)) end
  end
  -- "before", so the watch starts before Skynet's own TurnStarted handler plans and queues anything
  reg("TurnStarted", 1, "before", function(c) pcall(D.onTurnStarted, c) end)
  reg("TurnEnded", 1, "after", function(c) pcall(D.onTurnEnded, c) end)
  reg("UsingSpell", 5, "after", function(c, spell) pcall(D.onCast, c, spell) end)
  local okS, errS = pcall(function()
    Ext.Events.GameStateChanged:Subscribe(function(e) pcall(D.onGameState, e.ToState) end)
  end)
  if not okS then out("could not listen to game state changes: " .. tostring(errS)) end
end

if Ext and Ext.Osiris then D.register() end

return D
