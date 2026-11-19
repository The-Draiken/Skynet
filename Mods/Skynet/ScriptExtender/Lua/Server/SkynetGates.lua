-- SkynetGates: stops Skynet from wasting actions on effects that are already there (or already on their way).
--
-- Why this is a separate file: Skynet.lua is at Lua's limit of 200 top-level local variables, so new
-- logic lives here and Skynet.lua reaches it through the global table SkynetGates (every call site in
-- Skynet.lua is guarded with `if SkynetGates then`, so a missing file just means the old behaviour).
--
-- Two problems this addresses (both seen live):
--   1. Ensnaring Strike (a concentration spell) was queued three times in one plan. Skynet plans a whole
--      turn in ~130 ms, before the first cast has resolved, so "the caster is concentrating" was still
--      false for the second and third pick and each one just broke the previous restraint.
--      -> noteQueued() remembers that a concentration spell is already queued this turn, and
--         isPendingConcentration() makes Skynet_IsAlreadyConcentrating() answer true for the rest of it.
--   2. A buff or control spell was cast on a target that already had its effect (a Shield of Faith that
--      lasts for ever, recast every turn for a bonus action). HasActiveBuff() relied on
--      props.applyStatuses, which nothing ever fills in, so it could not see any buff.
--      -> statusesFor() works out which statuses a spell applies, and allAffected() / HasActiveBuff()
--         use it to skip a spell whose effect is already present or already queued.
--
-- Nothing here casts anything or changes any game state; it only answers questions.

SkynetGates = SkynetGates or {}
local G = SkynetGates

G.pending = {}         -- casterId -> spellId of a concentration spell queued this turn
G.planned = {}         -- casterId -> the attack Skynet intends to lead with this turn (see skipBuff)
G.queuedStatuses = {}  -- "targetId|STATUS" -> true for effects queued this turn that have not landed yet
G.infoCache = {}       -- spellId -> { concentration = bool, statuses = { ... } }
G.statusCache = {}     -- name -> bool (is a real StatusData stat)

local GUID_PAT = "(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$"

-- Skynet passes ids in several shapes ("S_Name_<guid>", bare guid...). The trailing guid is the identity.
local function norm(id)
  local s = tostring(id or "")
  return (s:match(GUID_PAT) or s):lower()
end
G.norm = norm

local function statusExists(name)
  local cached = G.statusCache[name]
  if cached ~= nil then return cached end
  local exists = false
  local ok, st = pcall(Ext.Stats.Get, name)
  if ok and st ~= nil then
    local okM, modList = pcall(function() return st.ModifierList end)
    if okM and modList == "StatusData" then
      exists = true
    elseif okM and modList == nil then
      local okT, statusType = pcall(function() return st.StatusType end)
      exists = okT and statusType ~= nil
    end
  end
  G.statusCache[name] = exists
  return exists
end

local function flagSet(stat)
  local set = {}
  local ok, flags = pcall(function() return stat.SpellFlags end)
  if ok and flags ~= nil then
    if type(flags) == "string" then
      for f in flags:gmatch("[^;%s]+") do set[f] = true end
    else
      pcall(function() for _, f in pairs(flags) do set[tostring(f)] = true end end)
    end
  end
  return set
end

local function addUnique(list, seen, name)
  if name and name ~= "" and not seen[name] then
    seen[name] = true
    list[#list + 1] = name
  end
end

-- "ShieldOfFaith" -> "SHIELD_OF_FAITH"
local function camelToSnake(s)
  local r = s:gsub("(%l)(%u)", "%1_%2")
  r = r:gsub("(%u)(%u%l)", "%1_%2")
  return r:upper()
end

local SPELL_PREFIXES = { "Target_", "Shout_", "Projectile_", "Zone_", "Rush_", "Throw_", "Teleportation_", "Wall_" }

-- Statuses a spell applies to its TARGET (ApplyStatus(SELF, ...) is the caster's own and is skipped).
-- Read from the spell's functors first; if that yields nothing, fall back to the naming convention used by
-- vanilla and most mods (Target_EnsnaringStrike -> ENSNARING_STRIKE, Target_PLA_ShieldOfFaith_SwordOfJustice
-- -> SHIELD_OF_FAITH), keeping only names that really are statuses.
local function findStatuses(spellId, stat)
  local out, seen = {}, {}

  for _, field in ipairs({ "SpellProperties", "SpellSuccess" }) do
    local ok, value = pcall(function() return stat[field] end)
    if ok and value ~= nil then
      if type(value) == "string" then
        for args in value:gmatch("ApplyStatus%(([^%)]*)%)") do
          local first, second = args:match("^%s*([%w_]+)%s*,?%s*([%w_]*)")
          if first == "SELF" or first == "OWNER" then
            -- applied to the caster, not the target
          elseif first == "TARGET" and second and second ~= "" then
            if statusExists(second) then addUnique(out, seen, second) end
          elseif first and statusExists(first) then
            addUnique(out, seen, first)
          end
        end
      else
        pcall(function()
          for _, functor in pairs(value) do
            for _, key in ipairs({ "StatusId", "Status", "StatusName", "StatusID" }) do
              local v = functor[key]
              if type(v) == "string" and v ~= "" and statusExists(v) then addUnique(out, seen, v) end
            end
          end
        end)
      end
    end
  end
  if #out > 0 then return out end

  local base = tostring(spellId or "")
  for _, p in ipairs(SPELL_PREFIXES) do
    if base:sub(1, #p) == p then base = base:sub(#p + 1) break end
  end
  local parts = {}
  for part in base:gmatch("[^_]+") do parts[#parts + 1] = camelToSnake(part) end
  for i = 1, #parts do
    for j = i, #parts do
      local name = table.concat(parts, "_", i, j)
      if statusExists(name) then addUnique(out, seen, name) end
    end
  end
  return out
end

--- { concentration = bool, statuses = { "STATUS", ... } } for a spell id (cached; empty when unknown).
function G.spellInfo(spellId)
  local id = tostring(spellId or "")
  local cached = G.infoCache[id]
  if cached then return cached end
  local info = { concentration = false, statuses = {} }
  local ok, stat = pcall(Ext.Stats.Get, id)
  if ok and stat ~= nil then
    info.concentration = flagSet(stat)["IsConcentration"] == true
    local okS, statuses = pcall(findStatuses, id, stat)
    if okS and statuses then info.statuses = statuses end
  end
  G.infoCache[id] = info
  return info
end

--- Statuses a spell applies to its target (used by HasActiveBuff, which never had this data).
function G.statusesFor(spellId)
  return G.spellInfo(spellId).statuses
end

local function hasStatus(target, status)
  local ok, v = pcall(function() return Osi.HasActiveStatus(target, status) end)
  if ok and (v == 1 or v == true) then return true end
  local ok2, v2 = pcall(function() return Osi.HasStatus(target, status) end)
  return ok2 and (v2 == 1 or v2 == true)
end

--- True if `target` already has one of the statuses `spellId` applies, or one is queued for it this turn.
function G.targetAffected(target, spellId)
  local statuses = G.spellInfo(spellId).statuses
  if #statuses == 0 then return false end
  local key = norm(target)
  for _, st in ipairs(statuses) do
    if G.queuedStatuses[key .. "|" .. st] or hasStatus(target, st) then return true end
  end
  return false
end

--- Concentration spells only: true when EVERY target already has the effect (or has it queued), so casting
--- again would do nothing except break it. `targets` is a list of entries with a .uuid, or plain ids.
function G.allAffected(caster, spellId, targets)
  local info = G.spellInfo(spellId)
  if not info.concentration or #info.statuses == 0 then return false end
  if type(targets) ~= "table" or #targets == 0 then return false end
  for _, t in ipairs(targets) do
    local id = type(t) == "table" and t.uuid or t
    if id == nil or not G.targetAffected(id, spellId) then return false end
  end
  return true
end

--- Skynet just queued `spellId` from `caster` (on `target`, or nil for a self-cast).
function G.noteQueued(caster, target, spellId)
  local info = G.spellInfo(spellId)
  if info.concentration then
    G.pending[norm(caster)] = tostring(spellId)
  end
  if #info.statuses > 0 then
    local key = norm(target ~= nil and target ~= "" and target or caster)
    for _, st in ipairs(info.statuses) do G.queuedStatuses[key .. "|" .. st] = true end
  end
end

--- True while a concentration spell queued by Skynet this turn has not been cleared yet.
function G.isPendingConcentration(uuid)
  return G.pending[norm(uuid)] ~= nil
end

--- Called at the start of every Skynet plan for `caster`: a plan starts from scratch, nothing queued by an
--- earlier plan carries over (by then those casts have resolved and the game's own state shows them).
function G.beginTurn(caster)
  G.pending[norm(caster)] = nil
  G.planned[norm(caster)] = nil
  G.steppedBack[norm(caster)] = nil
  G.queuedStatuses = {}
end

-- ==================== AI ARCHETYPE: SAVE BEFORE BLANKING, RESTORE WHEN HANDING BACK ====================
-- Skynet blanks an enemy's base AI archetype while it plans and queues a turn (so the base AI does not fight
-- its plan) and used to leave it blank for good, so every later piece of base-AI work for that enemy ran
-- with no archetype at all. These helpers remember the enemy's OWN archetype before it is blanked and put a
-- valid one back when Skynet hands the turn to the base game AI, so the base AI can use what is left of the
-- turn properly. Nothing here is a recommendation of a made-up archetype unless the real one is unknown.

G.archetypes = {}  -- casterId -> the enemy's own base archetype, read before Skynet blanked it
G.SUPPRESS = "base"  -- the valid do-nothing archetype used while Skynet acts (see suppressArchetype)

--- Remember `enemy`'s current base archetype. A blank read (already blanked) never overwrites a saved value.
function G.saveArchetype(enemy)
  local key = norm(enemy)
  local ok, a = pcall(function() return Osi.GetBaseArchetype(enemy) end)
  a = ok and tostring(a or "") or ""
  -- a blank, or the suppression archetype Skynet itself set earlier, is never the enemy's own
  if a ~= "" and a ~= G.SUPPRESS then
    G.archetypes[key] = a
    return a
  end
  return G.archetypes[key]
end

-- The archetype names below are the generic ones the base game's own character templates use (read from
-- Shared/Gustav RootTemplates: melee 356, ranged 235, mage 193, melee_smart 36, ranged_smart 24, mage_smart 23,
-- melee_magic(_smart), healer_melee, healer_ranged, rogue, monk_*...). Creature-specific ones (gnoll_melee,
-- goblin_mage, beast, dragon, undead...) carry bespoke behaviour and are never overridden.
local ROLE_OF = {   -- archetype -> role, smart?
  melee = { "melee", false },             melee_smart = { "melee", true },
  ranged = { "ranged", false },           ranged_smart = { "ranged", true },
  mage = { "mage", false },               mage_smart = { "mage", true },
  melee_magic = { "melee_magic", false }, melee_magic_smart = { "melee_magic", true },
  healer_melee = { "healer_melee", false }, healer_ranged = { "healer_ranged", false },
}
local NAME_OF = {   -- role -> smart? -> archetype
  melee = { [false] = "melee", [true] = "melee_smart" },
  ranged = { [false] = "ranged", [true] = "ranged_smart" },
  mage = { [false] = "mage", [true] = "mage_smart" },
  melee_magic = { [false] = "melee_magic", [true] = "melee_magic_smart" },
  healer_melee = { [false] = "healer_melee", [true] = "healer_melee" },
  healer_ranged = { [false] = "healer_ranged", [true] = "healer_ranged" },
}

-- The archetype the designers gave this NPC lives on its template (character instance): Anders is
-- 'melee_smart', Refugee_002 'ranged_smart'. Skynet blanks the ENTITY's archetype, and a save made while it
-- was blank keeps it blank, so the template is the reliable source after loading in the middle of a fight.
local function templateArchetype(enemy)
  local ok, a = pcall(function()
    local ent = Ext.Entity.Get(enemy)
    local tpl = ent and ent.ServerCharacter and ent.ServerCharacter.Template
    return tpl and tpl.Archetype
  end)
  if ok and a ~= nil and tostring(a) ~= "" then return tostring(a) end
  local ok2, a2 = pcall(function()
    local g = tostring(Osi.GetTemplate(enemy) or ""):match(GUID_PAT)
    if not g then return nil end
    local tpl = (Ext.Template.GetTemplate and Ext.Template.GetTemplate(g))
                or (Ext.Template.GetRootTemplate and Ext.Template.GetRootTemplate(g))
    return tpl and tpl.Archetype
  end)
  if ok2 and a2 ~= nil and tostring(a2) ~= "" then return tostring(a2) end
  return nil
end

--- The enemy's own archetype and where it came from: "saved" (read before Skynet blanked it this session),
--- "template" (the NPC's template), "active" (what the engine reports now); nil when nothing is known.
function G.defaultArchetype(enemy)
  local saved = G.archetypes[norm(enemy)]
  if saved and saved ~= "" then return saved, "saved" end
  local tpl = templateArchetype(enemy)
  if tpl then return tpl, "template" end
  local okA, active = pcall(function() return Osi.GetActiveArchetype(enemy) end)
  if okA and active ~= nil and tostring(active) ~= "" then return tostring(active), "active" end
  return nil, "none"
end

G.leftover = {}  -- casterId -> { action, bonus } Skynet's ledger had unspent when it finished planning

function G.noteLedger(enemy, action, bonus)
  G.leftover[norm(enemy)] = { action = action or 0, bonus = bonus or 0 }
end

local function num(fn, ...)
  local ok, v = pcall(fn, ...)
  return ok and tonumber(v) or nil
end

-- The slot names the base game's own scripts pass to GetEquippedItem are 'Melee Main Weapon', 'Melee Offhand
-- Weapon' and 'Ranged Main Weapon' (there is no plain "Weapon" slot).
local function equippedIn(enemy, slot)
  local ok, item = pcall(function() return Osi.GetEquippedItem(enemy, slot) end)
  if ok and item ~= nil and item ~= "" then return item end
  return nil
end

local function hasRangedWeapon(enemy)
  return equippedIn(enemy, "Ranged Main Weapon") ~= nil
end

-- What the enemy has and what is going on around it right now (every field optional).
local function readSituation(enemy)
  local s = { ranged = hasRangedWeapon(enemy), meleeWeapon = equippedIn(enemy, "Melee Main Weapon") ~= nil,
              attackSpells = 0, projectiles = 0, healer = false }
  s.hp = num(function() return Osi.GetHitpointsPercentage(enemy) end)
  local exp = Skynet and Skynet.Export
  if exp and exp.GetAvailableSpells and exp.ClassifySpell then
    local okS, spells = pcall(exp.GetAvailableSpells, enemy)
    if okS and type(spells) == "table" then
      for _, sp in ipairs(spells) do
        local lower = tostring(sp):lower()
        if lower:find("^projectile_") then
          -- arrow specials and other weapon projectiles are an archer's weapon attacks, not caster spells
          s.projectiles = s.projectiles + 1
        elseif not (lower:find("^target_mainhand") or lower:find("^target_offhand") or lower:find("^throw_")) then
          local okC, cat = pcall(exp.ClassifySpell, sp)
          if okC and type(cat) == "table" and (cat.damage or 0) > 0 then s.attackSpells = s.attackSpells + 1 end
        end
      end
    end
  end
  if exp and exp.FindHealSpell then
    local okH, heal = pcall(exp.FindHealSpell, enemy)
    s.healer = okH and heal ~= nil
  end
  local okP, rows = pcall(function() return Osi.DB_Players:Get(nil) end)
  if okP and type(rows) == "table" then
    for _, row in ipairs(rows) do
      local d = num(function() return Osi.GetDistanceTo(enemy, row[1]) end)
      if d and (s.near == nil or d < s.near) then s.near = d end
    end
  end
  return s
end

--- The archetype to give `enemy` back. Returns name, source of the default, reason.
--- situational=false: just the enemy's own (default) archetype. situational=true: the default's role is kept
--- for creature-specific archetypes, healers who can still heal and enemies with nothing left to plan; otherwise
--- the role is picked from what the enemy has and where it stands, keeping the default's smart/plain tier.
function G.recommendArchetype(enemy, situational)
  local default, source = G.defaultArchetype(enemy)
  if default and not ROLE_OF[default] then
    return default, source, "creature-specific archetype kept"
  end
  local info = default and ROLE_OF[default]
  local smart = (info == nil) or info[2]   -- unknown default: Skynet-controlled enemies are smart by design
  local s = readSituation(enemy)

  if not situational and default then return default, source, "default archetype" end

  local left = G.leftover[norm(enemy)]
  if situational and default and left and left.action <= 0 and left.bonus <= 0 then
    return default, source, "nothing left to plan, default kept"
  end
  if info and (info[1] == "healer_melee" or info[1] == "healer_ranged") and s.healer then
    return default, source, "healer who can still heal, default kept"
  end

  -- The designers already gave this NPC the right ROLE (an archer is ranged_smart, a paladin melee_smart), so a
  -- weapon user keeps it; the situation only changes things when the kit no longer fits the role, when the enemy
  -- is hurt enough to need healing, or when nothing is known about it.
  local defRole = info and info[1]
  local canShoot = s.ranged or s.projectiles > 0
  local role, why
  if s.hp and s.hp <= 35 and s.healer then
    role = canShoot and "healer_ranged" or "healer_melee"
    why = string.format("hp %d%% and can heal", math.floor(s.hp))
  elseif defRole == "mage" or defRole == "melee_magic" then
    role = defRole
    why = "a caster stays a caster"
  elseif defRole == "ranged" then
    if canShoot then
      role, why = "ranged", string.format("archer: %s", s.ranged and "bow equipped" or (s.projectiles .. " arrow/projectile spells"))
    else
      role, why = "melee", "no bow and no arrow spells left"
    end
  elseif defRole == "melee" then
    role, why = "melee", "melee fighter"
  elseif canShoot then
    role, why = "ranged", "nothing known about it; it can shoot"
  elseif s.attackSpells >= 3 and not s.meleeWeapon then
    role, why = "mage", string.format("nothing known about it; %d attack spells and no weapon", s.attackSpells)
  else
    role, why = "melee", "nothing known about it"
  end
  if s.near then why = why .. string.format(", nearest enemy %.1f m", s.near) end
  return NAME_OF[role][smart], source, why .. (smart and ", smart tier" or ", plain tier")
end

--- Give `enemy` a valid archetype again. Returns name, source, ok, reason.
function G.restoreArchetype(enemy, situational)
  local name, source, why = G.recommendArchetype(enemy, situational)
  if not name then name, source, why = "melee", "none", "nothing known" end
  local ok = pcall(function() Osi.RequestSetBaseArchetype(enemy, name) end)
  return name, source, ok, why
end

--- The archetype Skynet gives an enemy while it acts. No character in the base game's data has an empty
--- archetype (none of the 1,633 templates that carry one is blank), so the engine's AI has never run with one;
--- a valid do-nothing archetype ('base': objects, helpers and a few simple characters) is used instead of "".
--- With useBase false the old blank value is used.
function G.suppressArchetype(useBase)
  return useBase and G.SUPPRESS or ""
end

--- Skynet_AITurn records the attack it means to lead with. A concentration self-buff that this attack would break
--- is then not cast first (Zephyr Strike followed by Ensnaring Strike breaks the buff for nothing; with the buff
--- skipped she leads with Ensnaring Strike and the arrows follow).
function G.noteBest(enemy, spell)
  G.planned[norm(enemy)] = spell
end

function G.skipBuff(enemy, buffSpell)
  local best = G.planned[norm(enemy)]
  if not best or best == buffSpell then return false end
  return G.spellInfo(buffSpell).concentration and G.spellInfo(best).concentration
end

--- After loading a save made while Skynet had an enemy's archetype blanked, that enemy is still blank and, if its
--- turn is already under way, Skynet does not handle it again until its NEXT turn; the base game AI would play
--- the rest of that turn with no archetype. Give every blank combatant its template archetype back.
--- Returns how many were repaired.
function G.repairBlankArchetypes()
  local okR, rows = pcall(function() return Osi.DB_Is_InCombat:Get(nil, nil) end)
  if not okR or type(rows) ~= "table" then return 0 end
  local fixed, seen, names = 0, {}, {}
  for _, row in ipairs(rows) do
    local ch = row[1]
    local key = ch ~= nil and norm(ch) or nil
    if key and not seen[key] then
      seen[key] = true
      local okP, isPlayer = pcall(function() return Osi.IsPlayer(ch) end)
      local okB, base = pcall(function() return Osi.GetBaseArchetype(ch) end)
      if okB and not (okP and isPlayer == 1) and (base == nil or tostring(base) == "" or tostring(base) == G.SUPPRESS) then
        local tpl = templateArchetype(ch)
        if tpl and tpl ~= G.SUPPRESS and pcall(function() Osi.RequestSetBaseArchetype(ch, tpl) end) then
          G.archetypes[key] = tpl
          fixed = fixed + 1
          names[#names + 1] = tostring(ch):sub(1, 28) .. "=" .. tpl
        end
      end
    end
  end
  if fixed > 0 then
    Ext.Utils.Print("[Skynet] Gave " .. fixed .. " enemy(ies) their archetype back after loading (it was blank in the save): " .. table.concat(names, ", "))
  end
  return fixed
end

-- ==================== INVISIBILITY: STEP AWAY BEFORE A RANGED ATTACK ====================
-- An invisible enemy (Umbral Shroud/Cloak, Invisibility...) can leave a party member who cannot see invisibility
-- without any opportunity attack, so staying next to that member only costs her disadvantage on ranged attacks.
-- If the member CAN see invisibility the usual opportunity-attack logic is untouched.

local SEE_MARKS = { "SEE_INVIS", "TRUE_SEEING", "TRUESIGHT", "TRUE_SIGHT", "BLINDSIGHT" }

local function idListHas(list, marks)
  for _, sid in pairs(list or {}) do
    local up = string.upper(tostring(sid))
    for _, m in ipairs(marks) do
      if up:find(m, 1, true) then return true end
    end
  end
  return false
end

local function statusIds(uuid)
  local ok, list = pcall(function() return Ext.Entity.Get(uuid).StatusContainer.Statuses end)
  return ok and list or nil
end

--- True when `uuid` carries an Invisibility-family status (real StatusType INVISIBLE or SG_Invisible group).
--- Hiding (SNEAKING) does not count: a hidden character can still be seen by anyone who passes a check.
function G.isInvisible(uuid)
  for _, name in ipairs({ "INVISIBLE", "INVISIBILITY", "GREATER_INVISIBILITY" }) do
    local ok, has = pcall(function() return Osi.HasStatus(uuid, name) end)
    if ok and (has == 1 or has == true) then return true end
  end
  for _, sid in pairs(statusIds(uuid) or {}) do
    local id = tostring(sid)
    local up = string.upper(id)
    if not (up:find("WEAPON", 1, true) or up:find("SEE_INVIS", 1, true)) then
      local okT, st = pcall(function() return Ext.Stats.Get(id).StatusType end)
      if okT and st and string.upper(tostring(st)) == "INVISIBLE" then return true end
      local okG, inGroup = pcall(function() return Osi.IsStatusFromGroup(id, "SG_Invisible") end)
      if okG and (inGroup == 1 or inGroup == true) then return true end
    end
  end
  return false
end

--- True when `uuid` can see invisible creatures (See Invisibility, truesight or blindsight in a status or passive).
function G.canSeeInvisible(uuid)
  if idListHas(statusIds(uuid), SEE_MARKS) then return true end
  local okP, passives = pcall(function()
    local out = {}
    for _, p in pairs(Ext.Entity.Get(uuid).PassiveContainer.Passives) do out[#out + 1] = p.Passive and p.Passive.PassiveId or p.PassiveId end
    return out
  end)
  return okP and idListHas(passives, SEE_MARKS) or false
end

--- True when `enemy` is invisible and `target` cannot see invisibility.
function G.invisibleToThreat(enemy, target)
  return G.isInvisible(enemy) and not G.canSeeInvisible(target)
end

G.steppedBack = {}  -- casterId -> true once she has stepped away this plan

--- Before a RANGED attack: if `enemy` is invisible and every party member standing next to her is blind to it, walk
--- away from them first (no opportunity attack) so the ranged attack is not made at disadvantage. Once per plan.
--- `h` = { move = Skynet_MoveToPosition, hazards = Skynet_PathHasHazards, props = GetSpellProperties, adjacent = GetAdjacentThreats }
--- Returns true if a step away was queued.
function G.stepBack(enemy, players, spell, h)
  local key = norm(enemy)
  if G.steppedBack[key] or not spell or not h then return false end
  local okP, props = pcall(h.props, spell, enemy)
  if not okP or not props or props.isMelee or not props.isRanged then return false end
  if not G.isInvisible(enemy) then return false end
  local okA, adjacent = pcall(h.adjacent, enemy, players)
  if not okA or not adjacent or #adjacent == 0 then return false end
  for _, t in ipairs(adjacent) do
    if G.canSeeInvisible(t.id) then
      Ext.Utils.Print("[Skynet] INVISIBLE: " .. tostring(t.id):sub(1, 20) .. " can see invisibility — opportunity attacks apply, not stepping away")
      return false
    end
  end
  local okE, ex, ey, ez = pcall(function() return Osi.GetPosition(enemy) end)
  if not okE or type(ex) ~= "number" then return false end
  local ax, az, n = 0, 0, 0
  for _, t in ipairs(adjacent) do
    local okT, tx, _, tz = pcall(function() return Osi.GetPosition(t.id) end)
    if okT and type(tx) == "number" then ax = ax + (ex - tx); az = az + (ez - tz); n = n + 1 end
  end
  if n == 0 then return false end
  local len = math.sqrt(ax * ax + az * az)
  if len < 0.1 then ax, az, len = 1, 0, 1 end
  for _, dist in ipairs({ 6, 4, 3 }) do
    local x, z = ex + ax / len * dist, ez + az / len * dist
    if not (h.hazards and h.hazards(ex, ey, ez, x, ey, z)) then
      h.move(enemy, x, ey, z)
      G.steppedBack[key] = true
      Ext.Utils.Print(string.format("[Skynet] INVISIBLE: %s steps %dm away from %d party member(s) who cannot see invisibility (no opportunity attack) before %s",
        tostring(enemy):sub(1, 20), dist, n, spell))
      return true
    end
  end
  return false
end

pcall(function()
  Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function()
    Ext.Timer.WaitFor(2000, function() G.repairBlankArchetypes() end)
  end)
end)

Ext.Utils.Print("[Skynet] SkynetGates loaded (concentration + already-affected gates, archetype save/restore)")
