-- SkynetAutoSave.lua — Skynet's own auto-saving, configured on the "Auto Save" tab of Skynet's MCM page.
--
-- Written for Skynet from scratch (public game APIs only: Osi.AutoSave, Osiris events, Ext.Events.GameStateChanged).
-- It replaces the separate "Combat Auto Saver On End", "Short Rest Auto Saver" and "Trade Auto Saver" mods and covers
-- the interval/postponement idea of Smart Autosaving — run only one of these systems at a time, or you get double saves.
--
-- WHY THE SAFETY RULES EXIST (reported crash): the last enemy in a fight went down (Skynet's Enemy Downed System), so
-- combat ended and a combat-end autosave started. During the save the enemy passed a death saving throw, stood up and
-- combat began again. A save written while combat is starting can never be loaded again (the game crashes on load —
-- a known BG3 bug for saves made while combat is starting or "frozen"). So:
--   * No autosave while ANY non-party character is downed (making death saving throws). The save waits until that
--     character dies or gets back up; if it gets up and a new fight starts, the save waits for that fight to end.
--   * No autosave within a settle window after combat starts or ends, or anyone enters/leaves combat.
--   * Out-of-combat triggers never save while a party member is in combat.
--   * Manual saves cannot be blocked (no game API for that), so Skynet warns: once when an enemy goes down outside
--     combat ("don't save now"), and right after a save that was made at an unsafe moment.
--
-- Everything lives in the global table SkynetAutoSave (separate file = separate 200-local budget from Skynet.lua).

SkynetAutoSave = SkynetAutoSave or {}
local A = SkynetAutoSave

local MOD_UUID = "e883778e-f8ae-9d7c-aa01-e738c7fb1040"
local PREFIX = "[Skynet AutoSave] "

-- Defaults mirror MCM_blueprint.json; used when MCM is missing or a value is unset.
A.DEFAULTS = {
  AutoSaveEnabled = false,
  AutoSaveOnCombatEnd = true,
  AutoSaveOnCombatStart = false,
  AutoSaveOnInterval = true,
  AutoSaveInterval = 10,
  AutoSaveIntervalInSeconds = false,
  AutoSaveAfterDialogue = false,
  AutoSaveAfterTrade = false,
  AutoSaveOnShortRest = true,
  AutoSaveOnLongRest = false,
  AutoSaveSettleSeconds = 3,
  AutoSaveWarnUnsafe = true,
}

A.MIN_INTERVAL_SECONDS = 30     -- floor for the "seconds" mode, so a slider at 1 can't save every second
A.MIN_GAP_MS = 15000            -- two triggers within this window are covered by one save
A.POLL_MS = 1000
A.COMBAT_START_WINDOW_MS = 120000

A.state = {
  generation = 0,
  pending = {},                 -- reason -> true (combatEnd, interval, dialogue, trade, rest)
  pendingCombatStartAt = nil,   -- when a combat-start save was armed
  partyTurnSince = nil,         -- a party member's turn started at this time (nil = not a party turn)
  partyFought = false,          -- a party member entered the current fight (CombatStarted/Ended fire for NPC-only fights too)
  lastCombatChangeAt = -1e12,
  lastSaveAt = -1e12,
  nextIntervalAt = nil,
  ownSaveUntil = 0,
  inTrade = false,
  wasInDialog = false,
  downed = {},                  -- uuid -> status id (non-party characters in a downed / death-save state)
  warnedDownedEpisode = false,
  unsafeManualSave = nil,       -- reason text while a manual save made at an unsafe moment is being written
  lastBlockLogged = nil,
  switchWarned = false,
}

-- ---------------------------------------------------------------- helpers

local function now()
  local ok, t = pcall(function() return Ext.Utils.MonotonicTime() end)
  return (ok and type(t) == "number") and t or 0
end

local function print_(msg)
  pcall(function() Ext.Utils.Print(PREFIX .. tostring(msg)) end)
end

function A.setting(id)
  local v = nil
  pcall(function()
    if Mods and Mods.BG3MCM and Mods.BG3MCM.MCMAPI then
      v = Mods.BG3MCM.MCMAPI:GetSettingValue(id, MOD_UUID)
    end
  end)
  if v == nil then v = A.DEFAULTS[id] end
  return v
end

local function guid(x)
  local s = tostring(x or "")
  return (s:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$") or s):lower()
end

function A.host()
  local ok, h = pcall(function() return Osi.GetHostCharacter() end)
  return ok and h or nil
end

-- Party = player characters (DB_Players). Everyone else (enemies, allied NPCs, summons) is "non-party".
function A.partyMembers()
  local list = {}
  pcall(function()
    for _, row in pairs(Osi.DB_Players:Get(nil) or {}) do list[#list + 1] = row[1] end
  end)
  return list
end

function A.isParty(uuid)
  local g = guid(uuid)
  for _, p in ipairs(A.partyMembers()) do
    if guid(p) == g then return true end
  end
  return false
end

function A.partyInCombat()
  for _, p in ipairs(A.partyMembers()) do
    local ok, v = pcall(function() return Osi.IsInCombat(p) end)
    if ok and v == 1 then return true end
  end
  return false
end

-- A status means "downed, making death saving throws" if its StatusType is DOWNED (vanilla DOWNED and anything copied
-- from it) or it is Skynet's own SKYNET_DOWNED. DEATHDOOR (the "already went down once" marker) and the PRONE_DOWNED
-- animation statuses are deliberately NOT counted. Classification is cached per status id (stat data is static).
A.downedTypeCache = A.downedTypeCache or {}
function A.isDownedStatus(statusId)
  local id = tostring(statusId or "")
  if id == "" then return false end
  local cached = A.downedTypeCache[id]
  if cached ~= nil then return cached end
  local up = id:upper()
  local result = (up == "SKYNET_DOWNED" or up == "DOWNED")
  if not result and not up:find("PRONE", 1, true) and not up:find("DEATHDOOR", 1, true) then
    local ok, t = pcall(function() return Ext.Stats.Get(id).StatusType end)
    result = ok and tostring(t or ""):upper() == "DOWNED"
  end
  A.downedTypeCache[id] = result
  return result
end

local function isDead(uuid)
  local ok, v = pcall(function() return Osi.IsDead(uuid) end)
  return ok and v == 1
end

local function stillDowned(uuid)
  if isDead(uuid) then return nil end
  local okL, list = pcall(function()
    local e = Ext.Entity.Get(uuid)
    return e and e.StatusContainer and e.StatusContainer.Statuses
  end)
  if okL and list then
    for _, sid in pairs(list) do
      if A.isDownedStatus(tostring(sid)) then return tostring(sid) end
    end
    return nil
  end
  -- Entity unreadable: fall back to the explicit ids.
  for _, s in ipairs({ "SKYNET_DOWNED", "DOWNED" }) do
    local ok, v = pcall(function() return Osi.HasStatus(uuid, s) end)
    if ok and v == 1 then return s end
  end
  return nil
end

-- Full check, used right before a save and after a load (Lua state is reset on load, so the event-fed set is empty):
-- every loaded character's statuses are scanned once. Cheap enough at save frequency.
function A.rescanDowned()
  local found = {}
  pcall(function()
    for _, e in pairs(Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter") or {}) do
      local uuid = e.Uuid and e.Uuid.EntityUuid
      if uuid and e.StatusContainer and e.StatusContainer.Statuses then
        for _, sid in pairs(e.StatusContainer.Statuses) do
          if A.isDownedStatus(tostring(sid)) then
            if not A.isParty(uuid) and not isDead(uuid) then found[uuid] = tostring(sid) end
            break
          end
        end
      end
    end
  end)
  for uuid, sid in pairs(found) do A.state.downed[uuid] = sid end
end

-- Prunes characters that died or got up; returns one still-downed non-party character, if any.
function A.downedBlocker()
  for uuid in pairs(A.state.downed) do
    local sid = stillDowned(uuid)
    if sid then return uuid, sid end
    A.state.downed[uuid] = nil
  end
  return nil
end

local function hostInDialog()
  local h = A.host()
  if not h then return false end
  local ok, v = pcall(function() return Ext.Entity.Get(h).ServerCharacter.Flags.InDialog end)
  return ok and v == true
end

local function shortName(uuid)
  local s = tostring(uuid or "")
  local name = nil
  pcall(function() name = Osi.ResolveTranslatedString(Osi.GetDisplayName(uuid)) end)
  if name and name ~= "" then return name end
  return s:gsub("_%x%x%x%x%x%x%x%x%-.*$", "")
end

function A.warn(msg)
  print_("WARNING: " .. msg)
  if not A.setting("AutoSaveWarnUnsafe") then return end
  local h = A.host()
  if h then pcall(function() Osi.OpenMessageBox(h, "Skynet: " .. msg) end) end
end

-- ---------------------------------------------------------------- safety

--- Is it safe to write a save right now?  kind = "outOfCombat" | "combatStart" | "manual"
--- Returns ok, reason-if-not.
function A.isSafeToSave(kind)
  local s = A.state
  local uuid, sid = A.downedBlocker()
  if uuid then
    return false, shortName(uuid) .. " is downed (" .. sid .. ") and making death saving throws"
  end
  local settleMs = math.max(0, tonumber(A.setting("AutoSaveSettleSeconds")) or 3) * 1000
  if now() - s.lastCombatChangeAt < settleMs then
    return false, "combat is starting or ending"
  end
  if kind == "manual" then return true, nil end   -- a player save: only the crash conditions above matter
  if kind == "combatStart" then
    if not s.partyTurnSince then return false, "not a party member's turn" end
    if now() - s.partyTurnSince < settleMs then return false, "the party member's turn has only just started" end
  elseif kind == "outOfCombat" then
    if A.partyInCombat() then return false, "the party is in combat" end
  end
  if hostInDialog() then return false, "a dialogue is open" end
  if s.inTrade then return false, "trading is open" end
  return true, nil
end

-- ---------------------------------------------------------------- saving

function A.doSave(label)
  local s = A.state
  local sw = nil
  pcall(function() sw = Ext.Utils.GetGlobalSwitches() end)
  if sw and sw.CanAutoSave == false and not s.switchWarned then
    s.switchWarned = true
    A.warn("autosaving is turned off in the game's own settings, so Skynet's auto saves can't be written. Turn autosave on in the game options.")
  end
  s.ownSaveUntil = now() + 10000
  local ok, err = pcall(function() Osi.AutoSave() end)
  s.lastSaveAt = now()
  s.pending = {}
  s.pendingCombatStartAt = nil
  A.restartInterval()
  print_(ok and ("Game saved (" .. label .. ")") or ("Osi.AutoSave failed: " .. tostring(err)))
end

function A.restartInterval()
  local v = tonumber(A.setting("AutoSaveInterval")) or 10
  local secs = A.setting("AutoSaveIntervalInSeconds") and v or v * 60
  secs = math.max(A.MIN_INTERVAL_SECONDS, secs)
  A.state.nextIntervalAt = now() + secs * 1000
end

local function logBlockOnce(label, reason)
  local key = label .. "|" .. tostring(reason)
  if A.state.lastBlockLogged ~= key then
    A.state.lastBlockLogged = key
    print_("Holding the " .. label .. " save: " .. tostring(reason))
  end
end

-- One poll step (also called directly by the tests).
function A.tick()
  local s = A.state
  A.checkDownedWarning()
  if not A.setting("AutoSaveEnabled") then
    s.pending = {}
    s.pendingCombatStartAt = nil
    return
  end

  -- dialogue end is detected by polling the host's InDialog flag (no participant list on the Osiris events)
  local inDialog = hostInDialog()
  if s.wasInDialog and not inDialog and A.setting("AutoSaveAfterDialogue") then s.pending.dialogue = true end
  s.wasInDialog = inDialog

  if A.setting("AutoSaveOnInterval") then
    if not s.nextIntervalAt then A.restartInterval() end
    if now() >= s.nextIntervalAt then s.pending.interval = true end
  else
    s.pending.interval = nil
  end

  -- the party's fight is over (checked here, not at the CombatEnded instant)
  if s.combatEndedAt and s.partyFought and not A.partyInCombat() then
    s.partyFought = false
    s.combatEndedAt = nil
    s.pendingCombatStartAt = nil
    if A.setting("AutoSaveOnCombatEnd") then s.pending.combatEnd = true end
  end

  -- a save a moment ago already covers anything that just came due
  if now() - s.lastSaveAt < A.MIN_GAP_MS then
    if next(s.pending) then s.pending = {} end
    return
  end

  -- combat-start save: during a party member's turn, after the fight has settled in
  if s.pendingCombatStartAt then
    if now() - s.pendingCombatStartAt > A.COMBAT_START_WINDOW_MS then
      s.pendingCombatStartAt = nil
    else
      local ok, why = A.isSafeToSave("combatStart")
      if ok then
        A.rescanDowned()
        ok, why = A.isSafeToSave("combatStart")
      end
      if ok then A.doSave("combat start") return end
      logBlockOnce("combat start", why)
    end
  end

  local label = nil
  for k in pairs(s.pending) do label = label and (label .. "+" .. k) or k end
  if label then
    local ok, why = A.isSafeToSave("outOfCombat")
    if ok then
      -- last line of defence: a full status scan of every loaded character, then re-check
      A.rescanDowned()
      ok, why = A.isSafeToSave("outOfCombat")
    end
    if ok then
      A.doSave(label)
    else
      logBlockOnce(label, why)
    end
  end
end

function A.loop(gen)
  if gen ~= A.state.generation then return end
  pcall(A.tick)
  Ext.Timer.WaitFor(A.POLL_MS, function() A.loop(gen) end)
end

function A.start()
  A.state.generation = A.state.generation + 1
  A.state.nextIntervalAt = nil
  A.state.downed = {}
  A.state.partyFought = A.partyInCombat()   -- loaded mid-fight: that fight counts as the party's
  A.rescanDowned()
  local gen = A.state.generation
  Ext.Timer.WaitFor(A.POLL_MS, function() A.loop(gen) end)
end

-- ---------------------------------------------------------------- events

local function combatChanged() A.state.lastCombatChangeAt = now() end

function A.onCombatStarted()
  combatChanged()
end

-- The party joining a fight is what arms the combat-start save (once per fight).
function A.onEnteredCombat(object)
  combatChanged()
  if not A.isParty(object) then return end
  if not A.state.partyFought then
    A.state.partyFought = true
    if A.setting("AutoSaveEnabled") and A.setting("AutoSaveOnCombatStart") then
      A.state.pendingCombatStartAt = now()
    end
  end
end

-- Party membership in combat can still read "in combat" at the instant CombatEnded fires, so the decision is made by
-- the poll (A.tick) once the party is really out.
function A.onCombatEnded()
  combatChanged()
  A.state.partyTurnSince = nil
  if A.state.partyFought then A.state.combatEndedAt = now() end
end

function A.onStatusApplied(target, status)
  if not A.isDownedStatus(status) then return end
  if A.isParty(target) then return end
  A.state.downed[tostring(target)] = tostring(status)
end

-- The dangerous window is a downed enemy while the party is OUT of combat (exactly the reported case: the last enemy
-- went down, so the fight ended). Warn once per episode; runs every poll even with auto save off.
function A.checkDownedWarning()
  local s = A.state
  local uuid = A.downedBlocker()
  if not uuid then s.warnedDownedEpisode = false return end
  if s.warnedDownedEpisode or A.partyInCombat() then return end
  s.warnedDownedEpisode = true
  A.warn(shortName(uuid) .. " is downed and making death saving throws. Don't save until it dies or gets back up — " ..
    "a save made while it stands up and starts a new fight can crash the game on load. Skynet's auto saves will wait.")
end

function A.onStatusRemoved(target, status)
  if not A.isDownedStatus(status) then return end
  local key = tostring(target)
  if not A.state.downed[key] then return end
  if not stillDowned(key) then A.state.downed[key] = nil end
  if next(A.state.downed) == nil then
    A.state.warnedDownedEpisode = false
    print_("No downed enemies left — saving is safe again once combat has settled.")
  end
end

function A.onDied(character)
  A.state.downed[tostring(character)] = nil
  if next(A.state.downed) == nil then A.state.warnedDownedEpisode = false end
end

function A.onTurnStarted(character)
  if A.isParty(character) then A.state.partyTurnSince = now() else A.state.partyTurnSince = nil end
end

function A.onTurnEnded(character)
  if A.isParty(character) then A.state.partyTurnSince = nil end
end

function A.onRequestTrade(character)
  if A.isParty(character) then A.state.inTrade = true end
end

function A.onTradeEnds(character)
  if not A.state.inTrade then return end
  A.state.inTrade = false
  if A.setting("AutoSaveEnabled") and A.setting("AutoSaveAfterTrade") then A.state.pending.trade = true end
end

function A.onShortRested()
  if A.setting("AutoSaveEnabled") and A.setting("AutoSaveOnShortRest") then A.state.pending.rest = true end
end

function A.onLongRestFinished()
  if A.setting("AutoSaveEnabled") and A.setting("AutoSaveOnLongRest") then A.state.pending.rest = true end
end

-- Any save (Skynet's or the player's) restarts the interval; a player save made at an unsafe moment gets a warning
-- once it has been written.
function A.onGameStateChanged(fromState, toState)
  local s = A.state
  local to, from = tostring(toState or ""), tostring(fromState or "")
  if to == "Save" then
    A.restartInterval()
    s.lastSaveAt = now()
    if now() > s.ownSaveUntil then
      local ok, why = A.isSafeToSave("manual")
      s.unsafeManualSave = (not ok) and why or nil
    end
  elseif from == "Save" and s.unsafeManualSave then
    local why = s.unsafeManualSave
    s.unsafeManualSave = nil
    A.warn("that save was made while " .. why .. ". If it crashes when you load it, use an earlier save. " ..
      "Save again once things have settled.")
  end
end

-- ---------------------------------------------------------------- registration

local function reg(name, arity, fn)
  local ok, err = pcall(function() Ext.Osiris.RegisterListener(name, arity, "after", fn) end)
  if not ok then print_("could not listen to " .. name .. "/" .. arity .. ": " .. tostring(err)) end
end

function A.register()
  if A.registered then return end
  A.registered = true
  reg("CombatStarted", 1, function() A.onCombatStarted() end)
  reg("CombatEnded", 1, function() A.onCombatEnded() end)
  reg("EnteredCombat", 2, function(o) A.onEnteredCombat(o) end)
  reg("LeftCombat", 2, function() combatChanged() end)
  reg("TurnStarted", 1, function(c) A.onTurnStarted(c) end)
  reg("TurnEnded", 1, function(c) A.onTurnEnded(c) end)
  reg("StatusApplied", 4, function(t, s) A.onStatusApplied(t, s) end)
  reg("StatusRemoved", 4, function(t, s) A.onStatusRemoved(t, s) end)
  reg("Died", 1, function(c) A.onDied(c) end)
  reg("RequestTrade", 4, function(c) A.onRequestTrade(c) end)
  reg("TradeEnds", 2, function(c) A.onTradeEnds(c) end)
  reg("ShortRested", 1, function() A.onShortRested() end)
  reg("LongRestFinished", 0, function() A.onLongRestFinished() end)
  reg("LevelGameplayStarted", 2, function() A.start() end)
  pcall(function()
    Ext.Events.GameStateChanged:Subscribe(function(e) A.onGameStateChanged(e.FromState, e.ToState) end)
  end)
  print_("loaded (enable it on the Auto Save tab of Skynet's MCM page)")
end

if Ext and Ext.Osiris then
  A.register()
  A.start()
end

return A
