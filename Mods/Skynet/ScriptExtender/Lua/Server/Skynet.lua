-- Skynet: Tactical Smart AI Layer for BG3
-- Goal: Make enemies make human-like smart decisions even when Combat Extender configs give them lots of spells.
-- Analyzes player actions, loadout, positions, and enemy capabilities to pick the best spell/action.
-- Does NOT give free power (no automatic counter statuses by default).
-- Reactive counters are optional behind MCM toggle.

print("[Skynet] Server/Skynet.lua top-level executing")
if Ext and Ext.Utils and Ext.Utils.Print then
    Ext.Utils.Print("[Skynet] Server/Skynet.lua top-level executing (via Ext)")
end

Skynet = Skynet or {}

local MOD_NAME = "Skynet"
local LOG_PREFIX = "[" .. MOD_NAME .. "] "

Ext.Utils.Print(LOG_PREFIX .. "BOOT: Server script loaded. Registering AI hooks...")

-- No custom queue anymore. Osiris listeners are registered directly inside SessionLoaded (reliable pattern).

-- MCM defaults
local Settings = {
    EnableReactiveCounters = false,  -- User wants this off by default / toggleable
    EnableDebugLogging = true,
    AggressionLevel = 1.0,           -- Future: how aggressive the AI should be
    EnableEnemyDownedSystem = false, -- Enemy downed/death save system (excludes undead, constructs)
    EnablePartyDownedSystem = false, -- Party Downed Condition 5E rules via Script Extender (replaces the Downed Condition 5E mod)
    -- Enemy buffs (replaces Tactician Enhanced): extra max HP / actions / bonus actions for enemies fighting the party.
    EnableEnemyBuffs = false,
    EnemyBuffScaling = false,        -- scale the values below by party size (values are for a party of 4)
    EnemyBuffHPPercent = 0,          -- extra max HP, percent (rounded to steps of 5, 0-100)
    EnemyBuffExtraActions = 0,       -- extra Actions per turn (0-3)
    EnemyBuffExtraBonusActions = 0,  -- extra Bonus Actions per turn (0-3)
    -- When false, Skynet never picks Wildshape/Polymorph-type spells for enemies (a crash in a long fight
    -- followed a Ritual Druid casting a modded Wildshape form; casting one stalled the game for seconds).
    EnemyAllowWildshape = false,
    EnablePassiveCapping = 20,      -- Max passives before spell eval is capped (0=disabled, 1-100)
    -- Adaptive targeting (Intelligence/Wisdom tiers) — see Maintenance history pass #21.
    -- Master toggle; when false, PickBestTarget behaves exactly as before this feature existed.
    EnableAdaptiveTargeting = true,
    -- Not configurable, on purpose: Skynet keeps control of an enemy's turn until its queued actions have resolved
    -- (SkynetFC), plays it under the valid 'base' archetype (never a blank one) and then hands the enemy a valid
    -- archetype chosen from its kit and situation (SkynetGates). Turning any of these off brought back the
    -- base-game-AI crash they were built to prevent.
    -- Enemy Intelligence at/above this uses full cross-game per-character learning (AC + HP).
    AdaptiveTargetingIntThreshold = 14,
    -- Enemy Wisdom at/above this (but below the Intelligence threshold) uses this-fight-only
    -- awareness (HP only, no AC) once AdaptiveTargetingSessionRounds have passed.
    AdaptiveTargetingWisThreshold = 12,
    -- Rounds into the current fight before a "wise" (but not "intelligent") enemy starts
    -- reacting to who's dealing damage this fight.
    AdaptiveTargetingSessionRounds = 4,
}

-- Tracking
local AliveEggClusters = {}
local LocatedClusters = {}
local PlayerContext = {}
local SpiderQueenLastAction = nil  -- nil="first turn", "hatch", "attack"
local SpiderQueenControlledBySkynet = true  -- alternates when clusters present
local SpiderQueenBaseGameTimer = nil  -- timeout timer for base game control
local WaitingForTarget = {}  -- creatures released to base game, waiting to find targets
local CombatHistory = {}  -- Recent player actions this combat
local PlayerCastStoryActions = {}  -- [storyActionId] = true for the player's current combat's spell
-- casts this combat (see CastSpell listener). Used by the basic-weapon-attack tracker below to
-- tell "this AttackedBy hit was part of a spell we already counted via CastSpell" from "this hit
-- was a plain, non-spell weapon/unarmed attack (main-hand, off-hand, wildshape natural weapon,
-- etc.) that CastSpell never fires for at all" — see Maintenance history pass #14.
local CurrentCombatId = nil
local CachedPlayerTargets = nil  -- cached {alive, downed} per round
local CachedEnemyList = nil      -- cached list of enemy UUIDs in combat
local Skynet_LiveDamageByPlayer = {}  -- [playerUuid] = damage dealt to enemies this combat only,
-- reset in CombatStarted, populated by a dedicated AttackedBy listener. Feeds adaptive targeting
-- (Skynet_GetPlayerThreatBonus) — see Maintenance history pass #21.
local CurrentCombatRound = 0  -- current round number in the active combat, kept in sync from
-- CombatRoundStarted. Used to gate the "wise" adaptive-targeting tier (session-only awareness)
-- until enough rounds have passed to have a read on who's doing what this fight.

-- Performance caches (declared early so all functions can reference them)
local FactionCache = {}           -- [uuid] = "player"/"enemy"/"ally"/"other"
local AvailableSpellsCache = {}   -- [uuid] = {spell list}
local MinionCache = {}            -- [uuid] = true/false
local PositionCache = {}          -- [uuid] = {x, y, z}
local LOSCache = {}               -- [caster|target] = true/false
local DistanceCache = {}          -- [id1|id2] = distance
local CachedThreats = nil         -- AnalyzePlayerThreats result per turn
local CachedBattlefield = nil     -- GetBattlefieldContext result per turn
local SnapshotCache = {}          -- [uuid] = snapshot per turn

-- ==================== PLAYER BEHAVIOR PROFILE ====================
-- Persistent cross-combat learning: tracks player tendencies to counter them.
local PROFILE_PATH = "Skynet/player_profile.json"

local function DefaultProfile()
    return {
        version = 1,
        combats_analyzed = 0,
        spell_frequency = {},        -- spellName -> total cast count
        element_preference = {       -- element -> total damage spell count
            fire = 0, cold = 0, lightning = 0, poison = 0,
            force = 0, necro = 0, physical = 0, other = 0
        },
        style = {
            melee_count = 0,         -- times player was in melee range
            ranged_count = 0,        -- times player was at range
            avg_distance = 9.0,      -- average distance to enemies
            summon_count = 0,        -- times player used summons
            concentration_count = 0, -- times player used concentration spells
            heal_count = 0,          -- times player used healing
            control_count = 0,       -- times player used CC/control
        },
        favorite_spells = {},        -- top 10 most-used spells (rebuilt periodically)
        last_updated = 0,
        -- Per-character persistent tracking, keyed by character UUID. Powers the "intelligent"
        -- adaptive-targeting tier (Maintenance history pass #21) — cross-game memory of which
        -- specific party member has been the real damage threat, independent of the party-wide
        -- aggregates above. Populated from Skynet_LiveDamageByPlayer in UpdateProfileFromCombat.
        characters = {},
        -- characters[uuid] = {
        --   combats_seen = 0,             -- how many combats this character has dealt damage in
        --   total_damage_dealt = 0,       -- lifetime damage dealt to enemies, across combats
        --   avg_damage_per_combat = 0,    -- running average, updated once per combat this char acted in
        --   melee_count = 0, ranged_count = 0, control_count = 0, heal_count = 0,
        --   last_updated = 0,
        -- }
    }
end

local PlayerProfile = DefaultProfile()

-- Helper
local function log(...)
    -- turn trace (SkynetTrace.lua, MCM toggle): kept whether or not debug logging is on
    if SkynetTrace and SkynetTrace.line then pcall(SkynetTrace.line, ...) end
    if Settings.EnableDebugLogging and Ext and Ext.Utils and Ext.Utils.Print then
        Ext.Utils.Print(LOG_PREFIX, ...)
    end
end

local function LoadProfile()
    local ok, content = pcall(function() return Ext.IO.LoadFile(PROFILE_PATH, "user") end)
    if ok and content and content ~= "" then
        local decodeOk, decoded = pcall(function() return Ext.Json.Parse(content) end)
        if decodeOk and decoded and decoded.version then
            PlayerProfile = decoded
            -- Backfill fields added by later mod versions so an old on-disk profile (saved
            -- before adaptive targeting existed) doesn't crash anything that reads them.
            if not PlayerProfile.characters then PlayerProfile.characters = {} end
            log("Profile loaded: " .. decoded.combats_analyzed .. " combats analyzed")
            return true
        end
    end
    log("No existing profile found, starting fresh")
    return false
end

local function SaveProfile()
    PlayerProfile.last_updated = "save_" .. PlayerProfile.combats_analyzed
    local jsonStr = Ext.Json.Stringify(PlayerProfile)
    local ok, err = pcall(function() Ext.IO.SaveFile(PROFILE_PATH, jsonStr, "user") end)
    if ok then
        log("Profile saved: " .. PlayerProfile.combats_analyzed .. " combats analyzed")
    else
        log("Profile save FAILED: " .. tostring(err))
    end
end

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

-- Safe player check (available to all listeners; copied from bootstrap pattern)
local function IsPlayerCharacterSafe(c)
    if not c or c == "" then return false end
    local cs = tostring(c)
    -- Check cache first. PASS #66: "other" is no longer trusted here — IsActualEnemy writes it too, without
    -- asking whether the character is a player, so a custom avatar could be cached "other" before this ran.
    -- This check keeps its own answer under "pc|<uuid>" (same table, so it is cleared with FactionCache).
    local cached = FactionCache[cs]
    if cached == "player" then return true end
    if cached == "ally" or cached == "enemy" then return false end
    local pk = "pc|" .. cs
    if FactionCache[pk] ~= nil then return FactionCache[pk] end
    -- FAST PATH: string pattern — all BG3 player UUIDs contain "S_Player_" or "S_Gustav"
    local cl = string.lower(cs)
    if cl:find("s_player_") or cl:find("s_gustav") then
        FactionCache[cs] = "player"
        return true
    end
    -- PASS #66: the Osi checks below never ran. Each was wrapped in `if type(Osi.X) == "function"`, which is
    -- always false in this bg3se build (Osi functions are userdata), so only the name pattern above ever
    -- recognised a party member: a custom avatar (Humans_Male_Player_Dev_...) or a modded companion was "not a
    -- player" and Skynet played its turn as an NPC ally. Now called through pcall. The old IsPartyFollower
    -- block is gone: it counted ANY answer (0 or 1) as "player", so once it could run it would have marked
    -- every character a player. Summons are left out on purpose: this function also means "already in the
    -- party target list" (GetNonPlayerHostileTargets and ChooseBestAction skip it as a duplicate of
    -- GetPlayerTargets), and summons are not reliably in that list, so enemies could stop seeing them. Whether the
    -- player controls a summon is Skynet_PlayerControlledReason's question (below).
    local sOk, isSummon = pcall(Osi.IsSummon, cs)
    if not (sOk and isSummon == 1) then
        local ok, res = pcall(Osi.IsPlayer, cs)
        if ok and res == 1 then
            FactionCache[cs] = "player"
            return true
        end
        local ok2, res2 = pcall(Osi.IsPartyMember, cs, 0)
        if ok2 and res2 == 1 then
            FactionCache[cs] = "player"
            return true
        end
    end
    FactionCache[pk] = false
    if cached == nil then FactionCache[cs] = "other" end
    return false
end

-- Combat participant detection (from Logging mod pattern — works when Ext.Entity.GetPartyMembers is nil)
local function safeStr(v) return tostring(v or "") end

-- Extract the canonical 36-char GUID suffix from a UUID/templated string, for dedup
-- purposes only. BG3 sometimes returns the same character as a bare GUID from one Osiris
-- query (e.g. "ad9af97d-75da-406a-ae13-7071c5...") and as "TemplateName_<GUID>" from
-- another (e.g. "S_Player_Gale_ad9af97d-75da-406a-ae13-7071c5..."). Comparing the raw
-- strings treats these as two different characters and double-counts them; comparing the
-- trailing GUID instead correctly recognizes them as the same character.
local function normalizeUuidKey(str)
    local s = tostring(str or "")
    local guid = s:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$")
    return guid or s
end

-- PASS #66: "does the player control this character?" Asked only when deciding whose turn Skynet plays
-- (onTurnStarted, shouldProcessEnemy, shouldProcessAlly). Zerogah's Nexus report and the user's own log showed
-- "TurnStarted for ALLY:" for the player's summons and familiars (XEN_OwlbearCubEvolved_Summon,
-- DogFamiliar_Scratch_Summon, Undead_Zombie_Melee_AnimateDead, QUEST_FOR_QuasitSummon ...), a custom avatar and
-- modded companions: Skynet played them as NPC allies (archetype changed every turn, base AI suppressed and
-- released, and with a target in reach it would have cast for them during the player's turn).
-- A party member (IsPlayerCharacterSafe), a summon in DB_PlayerSummons or in the party, or a summon whose
-- summoner is itself player-controlled counts. Plain party followers (AddPartyFollower, e.g. Spoils of War pets)
-- are AI-controlled allies in the base game and stay Skynet allies. Summons of enemies or NPC allies are
-- untouched. Kept separate from IsPlayerCharacterSafe so enemies still target summons (see the note there).
-- Returns a short reason, or nil.
function Skynet_PlayerControlledReason(uuid, depth)
    local u = tostring(uuid or "")
    if u == "" then return nil end
    depth = depth or 0
    if IsPlayerCharacterSafe(u) then return "party member" end
    local key = normalizeUuidKey(u)
    local dOk, rows = pcall(function() return Osi.DB_PlayerSummons:Get(nil) end)
    if dOk and type(rows) == "table" then
        for _, row in pairs(rows) do
            local s = tostring(row and row[1] or "")
            if s ~= "" and normalizeUuidKey(s) == key then return "player summon" end
        end
    end
    local sOk, isSummon = pcall(Osi.IsSummon, u)
    if not (sOk and isSummon == 1) then return nil end
    local pOk, inParty = pcall(Osi.IsPartyMember, u, 1)
    if pOk and inParty == 1 then return "summon in the party" end
    if depth >= 3 then return nil end
    -- the summoner, as Sensible Ambushing reads it (IsSummon.Summoner); older bg3se names tried after it
    local owner = nil
    for _, field in ipairs({ "Summoner", "Owner", "Owner_M" }) do
        local oOk, o = pcall(function()
            local h = Ext.Entity.Get(u).IsSummon[field]
            return h and h.Uuid and h.Uuid.EntityUuid
        end)
        if oOk and o ~= nil and tostring(o) ~= "" then owner = tostring(o) break end
    end
    if owner and normalizeUuidKey(owner) ~= key and Skynet_PlayerControlledReason(owner, depth + 1) then
        return "summon of " .. owner
    end
    return nil
end

-- Directly scan for Invoke Duplicity duplicate entities, bypassing combat-membership
-- tracking entirely. Across repeated live tests, neither GetPlayerTargets()'s
-- DB_PartyMembers query (despite its own comment claiming it "includes summons, duplicates,
-- etc.") nor Osi.DB_IsCharacterInCombat/Osi.GetCombatantsInCombat ever produced a summoned
-- duplicate's UUID, even though the duplicate demonstrably has its own turn every round
-- (confirmed by its own TurnStarted firing right after the controlled enemy's). Whatever is
-- or isn't populating those combat-tracking sources for a summoned duplicate, the duplicate
-- is unambiguously a real ServerCharacter entity that exists in the level right now — so
-- find it that way instead, the same way ScanForEggClustersNear finds egg clusters directly
-- rather than trusting some intermediary list of "known" objects. Pass originId/maxDist to
-- limit the scan to duplicates near a specific character; omit both to scan the whole level
-- (used by GetPlayerTargets(), which itself has no single "near" reference point).
local function Skynet_FindNearbyDuplicates(originId, maxDist)
    local found = {}
    local ox, oy, oz = nil, nil, nil
    if originId and originId ~= "" then
        local posOk, px, py, pz = pcall(function() return Osi.GetPosition(originId) end)
        if posOk then ox, oy, oz = px, py, pz end
    end
    local ok, entities = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter") end)
    if ok and entities then
        for _, entity in pairs(entities) do
            pcall(function()
                local uuid = tostring(entity.Uuid.EntityUuid)
                if uuid ~= "" and uuid ~= originId then
                    local sc = entity.ServerCharacter
                    local tplName = (sc and sc.Template and tostring(sc.Template.Name or "")) or ""
                    if uuid:find("DWE_UADuplicity_Duplicate_Character") or tplName:find("DWE_UADuplicity_Duplicate") then
                        local include = true
                        if ox and maxDist then
                            local dOk, dx2, dy2, dz2 = pcall(function() return Osi.GetPosition(uuid) end)
                            if dOk and dx2 then
                                local d = math.sqrt((dx2 - ox) ^ 2 + (dz2 - oz) ^ 2)
                                if d > maxDist then include = false end
                            end
                        end
                        if include then
                            found[#found + 1] = uuid
                        end
                    end
                end
            end)
        end
    end
    return found
end

-- Event-tracked Invoke Duplicity duplicates (replaces calling the whole-level scan above every
-- time the player-target cache was rebuilt). Filled by the StatusApplied listener (duplicate
-- init / ID statuses) and by one scan per level load; read by Skynet_GetTrackedDuplicates().
-- NOTE: globals on purpose - this file is at Lua's 200 top-level-local ceiling.
Skynet_TrackedDuplicates = Skynet_TrackedDuplicates or {}

function Skynet_GetTrackedDuplicates()
    local out = {}
    for uuid in pairs(Skynet_TrackedDuplicates) do
        local ok, dead = pcall(function() return Osi.IsDead(uuid) end)
        if ok and dead ~= nil and dead ~= 1 then
            out[#out + 1] = uuid
        else
            Skynet_TrackedDuplicates[uuid] = nil -- dead or gone: stop tracking
        end
    end
    return out
end

-- Enemy Wildshape rules (globals for the same reason as above). Enemies kept re-casting Wildshape every
-- turn even while already transformed (the form shows up as a Polymorph-group status that the old
-- "already has this buff" test never matched), wasting an action each time. Now a Wildshape/Polymorph
-- spell is only allowed when the MCM option is on, the enemy is not already transformed, and it has not
-- already cast one this combat.
Skynet_WildshapeCastCombat = Skynet_WildshapeCastCombat or {}

function Skynet_IsWildshaped(uuid)
    if uuid == nil or uuid == "" then return false end
    local ok, r = pcall(function() return Osi.HasActiveStatusWithGroup(uuid, "SG_Polymorph") end)
    if ok and r == 1 then return true end
    local ok2, statuses = pcall(function() return Osi.GetStatuses(uuid) end)
    if ok2 and type(statuses) == "table" then
        for _, st in pairs(statuses) do
            local name = string.upper(tostring(type(st) == "table" and (st.StatusId or st[1]) or st))
            if name:find("WILDSHAPE", 1, true) then return true end
        end
    end
    return false
end

-- Wildshape-related spell names across the installed mods (vanilla, Druid Wild Shape Overhaul / DWSO and
-- its add-ons, Druid Wildshape Addons, Circle of Thorns, Druid Unleashed, Freja, Starry Form). Only the
-- spells that actually CHANGE the caster into a form are blocked/limited. Many other spells carry
-- "WildShape" in their name but are used while ALREADY transformed (Combat Heal, Shove, Stunning Strike,
-- Spider Jump...) and must stay available, and the Dismiss spells (which drop the form) are never worth
-- an enemy's action.
function Skynet_IsWildshapeFormSpell(spell)
    local s = string.lower(tostring(spell or ""))
    if not s:find("shout_[%w_]*wildshape") then return false end
    if s:find("combat_heal", 1, true) or s:find("dismiss", 1, true) or s:find("revert", 1, true) then return false end
    if s:find("star", 1, true) then return false end -- Starry Form / Star Archer are not beast forms
    return true
end

function Skynet_IsWildshapeDismissSpell(spell)
    local s = string.lower(tostring(spell or ""))
    return s:find("shout_[%w_]*wildshape") ~= nil and (s:find("dismiss", 1, true) ~= nil or s:find("revert", 1, true) ~= nil)
end

--- true when the enemy is currently in a beast/polymorph form (any mod's form status is part of the
--- SG_Polymorph groups; the status-name check covers forms that are not).
function Skynet_IsWildshaped(uuid)
    if uuid == nil or uuid == "" then return false end
    for _, group in ipairs({ "SG_Polymorph_BeastShape", "SG_Polymorph" }) do
        local ok, r = pcall(function() return Osi.HasActiveStatusWithGroup(uuid, group) end)
        if ok and r == 1 then return true end
    end
    local ok2, statuses = pcall(function() return Osi.GetStatuses(uuid) end)
    if ok2 and type(statuses) == "table" then
        for _, st in pairs(statuses) do
            local name = string.upper(tostring(type(st) == "table" and (st.StatusId or st[1]) or st))
            if name:find("WILDSHAPE", 1, true) then return true end
        end
    end
    return false
end

-- With "Allow enemy Wildshape" OFF, Skynet cannot stop the base game AI from casting form spells (it
-- skips characters that are "neither enemy nor ally" and defers to the base AI when no target is
-- visible), so the form spells are removed from non-allied characters when they enter a fight.
-- Returns how many spells were removed. The party, allies and the party's summons are never touched.
Skynet_WildshapeStripped = Skynet_WildshapeStripped or {}

function Skynet_StripEnemyWildshape(guid)
    if guid == nil or guid == "" or Skynet_WildshapeStripped[guid] then return 0 end
    local ok, isChar = pcall(Osi.IsCharacter, guid)
    if not ok or isChar ~= 1 then return 0 end
    local function flag(fn, ...)
        local o, r = pcall(fn, ...)
        return o and r == 1
    end
    local hOk, host = pcall(Osi.GetHostCharacter)
    if not hOk or not host then return 0 end
    if flag(Osi.IsPartyMember, guid, 1) or flag(Osi.IsPlayer, guid) or flag(Osi.IsAlly, guid, host) then return 0 end
    Skynet_WildshapeStripped[guid] = true

    local eOk, entity = pcall(Ext.Entity.Get, guid)
    if not eOk or not entity or not entity.SpellBook or not entity.SpellBook.Spells then return 0 end
    local ids = {}
    for _, sp in ipairs(entity.SpellBook.Spells) do
        local id = sp.Id and sp.Id.OriginatorPrototype
        if id and Skynet_IsWildshapeFormSpell(id) then ids[#ids + 1] = id end
    end
    local removed = 0
    for _, id in ipairs(ids) do
        if pcall(Osi.RemoveSpell, guid, id, 0) then removed = removed + 1 end
    end
    return removed
end

--- true when this spell must NOT be chosen for this enemy right now.
--- Form spells: only when the MCM option is on, the enemy is not already in a form and has not already
--- cast one this combat. Dismiss spells: never. Everything else (in-form attacks, heals): unaffected.
function Skynet_WildshapeBlocked(enemyId, cat, spell)
    if spell ~= nil and Skynet_IsWildshapeDismissSpell(spell) then return true end
    if not (cat and cat.wildshape and cat.wildshape > 0) then return false end
    if spell ~= nil and not Skynet_IsWildshapeFormSpell(spell) then return false end
    if not Settings.EnemyAllowWildshape then return true end
    if enemyId == nil or enemyId == "" then return false end
    if Skynet_IsWildshaped(enemyId) then return true end
    local cid = tostring(CurrentCombatId or "")
    if cid ~= "" and Skynet_WildshapeCastCombat[enemyId] == cid then return true end
    return false
end

-- Party Downed System helpers (globals for the same reason as above).
Skynet_PartyTargetCache = Skynet_PartyTargetCache or {}
Skynet_PendingPartyHP = Skynet_PendingPartyHP or {}

function Skynet_IsPartyDownedTarget(guid)
    if guid == nil or guid == "" then return false end
    local c = Skynet_PartyTargetCache[guid]
    if c == nil then
        local ok, isPlayer = pcall(function() return Osi.IsPlayer(guid) == 1 end)
        c = (ok and isPlayer) and true or false
        Skynet_PartyTargetCache[guid] = c
    end
    return c
end

function Skynet_ApplyPartyDownedPassives(guid)
    pcall(function()
        if Osi.HasPassive(guid, "Downed_TurnTracker") == 0 then
            Osi.AddPassive(guid, "Downed_TurnTracker")
        end
        if Osi.HasPassive(guid, "Downed_TurnTracker2") == 0 then
            Osi.AddPassive(guid, "Downed_TurnTracker2")
        end
    end)
end

-- Check if a character is surprised (should skip their turn)
local function IsSurprised(uuid)
    if not uuid or uuid == "" then return false end
    local ok, hasStatus = pcall(function() return Osi.HasStatus(uuid, "SURPRISED") end)
    return ok and (hasStatus == 1 or hasStatus == true)
end


-- Check if a character cannot act (stunned, paralyzed, incapacitated, etc.)
local INCAPACITATING_STATUSES = {
    -- BG3 Incapacitated status group (cannot act at all)
    BANISHED = true, BLOATED = true, COCOONED = true,
    COMMAND_HALT = true, CURSED_FILLED_WITH_DREAD = true,
    DOWNED = true, FEIGNING_DEATH = true, FROZEN = true,
    GOSSAMER_TOMB = true, GRAPPLED = true, GRAPPLED_TENTACLE = true,
    GRAPPLED_VINE = true, GROTESQUE_DISTENTION = true,
    HEARTFORM_TERROR_CEREMORPHOSIS = true,
    HOLD_MONSTER = true, HOLD_PERSON = true,
    HYPNOTIC_GAZE = true, HYPNOTISED = true,
    INCAPACITATED = true, INFERNAL_STUN = true,
    MAMMONS_HOLD = true,
    -- NOTE: the real BG3/Osiris status ID is "PARALYZED" (American spelling, with a Z) —
    -- confirmed against real game data (the roguetest mod's own compiled stat entries use
    -- HasStatus('SG_Paralyzed', ...)/StatusHasStatusGroup(..., 'SG_Paralyzed') functors, and
    -- this file's own DISABLE_STATUSES table below already uses PARALYZED). Only the *wiki's*
    -- display text is the British "Paralysed." This table previously had "PARALYSED" (with an
    -- S) here, which never matches the real live status ID the engine actually applies — see
    -- Maintenance history pass #23.
    PARALYZED = true, PARALYZED_KARABASANS_GIFT = true,
    PETRIFIED = true, RITUAL_COMPONENT = true,
    SACRIFICIAL_LAMB = true, SAPPED = true, SOUL_CAGED = true,
    STRICKEN_WITH_CRAWLER_MUCUS = true, TURNED_TO_GOLD = true,
    STUNNED = true, UNCONSCIOUS = true,
    SLEEPING = true, SLEEP = true,
    HOOTS_HOOCH_STONED = true,
    CHARMED = true, TAUNTED = true,
    WEBBED = true, ENTANGLED = true, RESTRAINED = true,
    LEVITATED = true, CANT_MOVE = true, CANT_DISARM = true,
    SLOWED = true, DAZED = true, CONFUSED = true,
}

-- BG3 Frightened status group (can act but cannot move)
local FRIGHTENED_STATUSES = {
    FRIGHTENED = true, FEARFUL = true, FRIGHTENED_EFFECT = true,
    FRIGHTENED_MORTAL_REMINDER = true, ABJURE_ENEMY_FRIGHTENED = true,
    MEENLOCK_FEAR = true, MISSING_PETS = true, PHANTASMAL_KILLER = true,
    UNNERVED = true, FEAR = true, TERRIFIED = true,
}

-- Check if a character is Frightened (can act but cannot move)
local function IsFrightened(uuid)
    if not uuid or uuid == "" then return false end
    for status, _ in pairs(FRIGHTENED_STATUSES) do
        local ok, has = pcall(function() return Osi.HasStatus(uuid, status) end)
        if ok and (has == 1 or has == true) then return true end
    end
    -- Fallback: check status names for fear/frighten keywords
    local ok2, statuses = pcall(function() return Osi.GetStatuses(uuid) end)
    if ok2 and statuses then
        for _, status in pairs(statuses) do
            local s = string.lower(tostring(status))
            if s:find("fear") or s:find("frighten") or s:find("fearful") or
               s:find("terrified") or s:find("unnerved") then
                return true
            end
        end
    end
    return false
end

-- Check if a character cannot move (but can still act with ranged attacks)
local MOVEMENT_RESTRICTING_STATUSES = {
    WEBBED = true, ENTANGLED = true, RESTRAINED = true,
    LEVITATED = true, CANT_MOVE = true,
}
local function IsMovementRestricted(uuid)
    if not uuid or uuid == "" then return false end
    -- Check movement-restricting statuses
    for status, _ in pairs(MOVEMENT_RESTRICTING_STATUSES) do
        local ok, has = pcall(function() return Osi.HasStatus(uuid, status) end)
        if ok and (has == 1 or has == true) then return true end
    end
    -- Also check Frightened (can act but cannot move)
    if IsFrightened(uuid) then return true end
    return false
end

-- Check if a character is a Necromite (should use base AI for Apostle encounter)
local function IsNecromite(uuid)
    if not uuid or uuid == "" then return false end
    local ok, template = pcall(function() return Osi.GetTemplate(uuid) end)
    if ok and template and template ~= "" then
        local t = string.lower(tostring(template))
        if t:find("necromite") then return true end
    end
    return false
end

-- ==================== ENEMY DOWNED SYSTEM: CREATURE TYPE FILTERING ====================

local UNDEAD_TAG = "33c625aa-6982-4c27-904f-e47029a9b140"

-- Cache for creature type checks to avoid repeated Osi calls per frame
local CreatureTypeCache = {}  -- [uuid] = boolean (eligible for downed system)

local function ClearCreatureTypeCache()
    CreatureTypeCache = {}
end

local function IsTaggedWith(uuid, tag)
    if not uuid or uuid == "" or not tag then return false end
    local ok, result = pcall(function() return Osi.IsTagged(uuid, tag) end)
    return ok and result == 1
end

local function IsUndead(uuid)
    return IsTaggedWith(uuid, UNDEAD_TAG)
end

local function IsConstruct(uuid)
    if not uuid or uuid == "" then return false end
    local ok, template = pcall(function() return Osi.GetTemplate(uuid) end)
    if ok and template and template ~= "" then
        local t = string.lower(tostring(template))
        if t:find("construct") or t:find("golem") or t:find("automaton")
           or t:find("steelwatcher") or t:find("robot") or t:find("animated_armor")
           or t:find("shield_guardian") or t:find("clay_guardian") then
            return true
        end
    end
    return false
end

local function IsLivingCreature(uuid)
    if not uuid or uuid == "" then return false end
    if Osi.IsCharacter(uuid) ~= 1 then return false end
    if Osi.IsPlayer(uuid) == 1 then return false end
    local deadOk, isDead = pcall(function() return Osi.IsDead(uuid) end)
    if deadOk and isDead == 1 then return false end
    local sumOk, isSummon = pcall(function() return Osi.IsSummon(uuid) end)
    if sumOk and isSummon == 1 then return false end
    if IsUndead(uuid) then return false end
    if IsConstruct(uuid) then return false end
    return true
end

-- ==================== CREATURE-TYPE-RESTRICTED SPELL GATING (pass #20) ====================
-- Some real 5e/BG3 spells (Dispel Evil and Good, Protection from Evil and Good, Turn Undead,
-- Destroy Undead) only do anything against a specific handful of creature types (celestial,
-- elemental, fey, fiend, undead). Nothing elsewhere in the file gated these on whether a
-- qualifying creature is actually present, so an enemy caster with one of these in their kit
-- could "use" it every time it was its highest-scoring reachable option even when literally
-- nothing on the battlefield qualifies — reported as a hostile priest casting "Dispel" with no
-- undead anywhere nearby. We don't have real tag GUIDs for fiend/celestial/elemental the way
-- IsUndead does for UNDEAD_TAG, so this falls back to the same template-name pattern approach
-- IsConstruct already uses successfully elsewhere in this file.
local function IsFiendCelestialOrElemental(uuid)
    if not uuid or uuid == "" then return false end
    local ok, template = pcall(function() return Osi.GetTemplate(uuid) end)
    if ok and template and template ~= "" then
        local t = string.lower(tostring(template))
        if t:find("devil") or t:find("demon") or t:find("cambion") or t:find("imp") or
           t:find("quasit") or t:find("hellhound") or t:find("fiend") or t:find("succubus") or
           t:find("incubus") or t:find("mindflayer") or t:find("mind_flayer") or
           t:find("angel") or t:find("deva") or t:find("solar") or t:find("celestial") or
           t:find("elemental") or t:find("salamander") or t:find("azer") or t:find("genie") or
           t:find("djinni") or t:find("efreet") then
            return true
        end
    end
    return false
end

-- Returns true if spellId is one of these creature-type-restricted spells (by name).
local function Skynet_NeedsSpecialCreatureType(spellId)
    local s = string.lower(spellId or "")
    return (s:find("dispel_evil") or s:find("dispelevil") or s:find("dispel_good") or
            (s:find("dispel") and s:find("evil")) or
            s:find("protection_from_evil") or s:find("protectionfromevil") or
            s:find("turn_undead") or s:find("turnundead") or
            s:find("destroy_undead") or s:find("destroyundead")) or false
end

-- Given the list of reachable player-target entries (each with a .uuid field, per the shape
-- used in Skynet.ChooseBestAction's candidate-building loop), checks whether any of them is
-- actually a creature type these spells care about (an undead/fiend/celestial/elemental party
-- member or summon — e.g. a Warlock's fiend familiar, a raised undead ally, a Druid's elemental
-- Wild Shape).
local function Skynet_HasQualifyingCreatureTypeTarget(targetList)
    if not targetList then return false end
    for _, t in ipairs(targetList) do
        local uuid = (t and (t.uuid or t)) or nil
        if uuid and uuid ~= "" then
            if IsUndead(uuid) or IsFiendCelestialOrElemental(uuid) then
                return true
            end
        end
    end
    return false
end

local function ShouldHaveDownedSystem(uuid)
    if not Settings.EnableEnemyDownedSystem then return false end
    if not uuid or uuid == "" then return false end
    if CreatureTypeCache[uuid] ~= nil then return CreatureTypeCache[uuid] end
    local result = IsLivingCreature(uuid)
    CreatureTypeCache[uuid] = result
    return result
end

-- ==================== ENEMY DOWNED SYSTEM: DOWNED STATE DETECTION ====================

local function IsDowned(uuid)
    if not uuid or uuid == "" then return false end
    local deadOk, isDead = pcall(function() return Osi.IsDead(uuid) end)
    if deadOk and isDead == 1 then return false end
    local ok1, hasDowned = pcall(function() return Osi.HasStatus(uuid, "SKYNET_DOWNED") end)
    if ok1 and hasDowned == 1 then return true end
    local ok2, hasProneDowned = pcall(function() return Osi.HasStatus(uuid, "SKYNET_PRONE_DOWNED") end)
    if ok2 and hasProneDowned == 1 then return true end
    return false
end

-- Best-effort list of everyone currently in combat. Queries the fast Osiris call scoped to
-- CurrentCombatId AND the global DB scan, and MERGES both (deduplicated) rather than treating
-- the DB scan as a fallback used only when the scoped call fails outright.
--
-- PASS #28: merging (instead of "prefer scoped, else DB scan") fixes a real, log-confirmed bug
-- distinct from pass #27's. Pass #27 fixed classification (IsActualEnemy/Osi.IsEnemy) assuming
-- the hostile candidate was at least present in this function's returned list to be classified.
-- A live log showed every ally turn in a fight against a single ogre (MMM_OOF_*) coming back
-- "NO TARGETS FOUND" for the ENTIRE fight — not just after the ogre was Paralyzed, but from the
-- very first ally turn, while the ogre was still fully active and casting spells — even though
-- pass #27's Osi.IsEnemy(candidate, allyUuid) fix was confirmed present in the file. The only
-- way that fix can matter is if the ogre is even a candidate in the first place, i.e. present in
-- Skynet_GetKnownCombatants()'s returned list — and neither "CombatStarted:" nor "EnteredCombat"
-- appears ANYWHERE in that log's ~7000 lines, despite combat clearly having been running well
-- past round 6, and despite a custom forced-combat system (NFT-AutoLeave / EnemyAmbush) visibly
-- still trying, and partly failing ("gave up after 3000ms"), to add specific player characters
-- "to combat against MMM_OOF" throughout. That combination means CurrentCombatId's value was
-- inherited from before this session's log window (a save loaded mid-fight, or a fight that
-- began before logging started) and was NEVER re-validated afterward — EnteredCombat's own
-- opportunistic recovery only fires when CurrentCombatId is nil/empty, so a stale-but-non-empty
-- id from an earlier or differently-scoped combat instance is never revisited once set, and
-- Osi.GetCombatantsInCombat(staleId) can silently return a roster that simply doesn't include
-- the enemy everyone is actually fighting. The old "prefer scoped, else DB scan" logic then
-- trusted that stale-but-successful scoped call completely and never even tried the DB scan,
-- which — being a direct, session-wide read of Osiris's own combat-membership table rather than
-- a cached id — would very likely have still had the ogre.
--
-- `actingCharUuid` (optional) is the specific character whose turn is about to run. If given and
-- the scoped call succeeds but its result doesn't even contain that character, that's a second,
-- independent signal the scoped id is stale for this turn specifically, logged here so a future
-- log makes the failure directly visible instead of requiring code-reading to diagnose.
local function Skynet_GetKnownCombatants(actingCharUuid)
    local seen = {}
    local list = {}
    local function addUuid(raw)
        local uuid = safeStr(raw)
        if uuid ~= "" and not seen[uuid] then
            seen[uuid] = true
            list[#list + 1] = uuid
        end
    end

    local scopedOk, scoped = false, nil
    if CurrentCombatId and CurrentCombatId ~= "" then
        local ok, combatants = pcall(function() return Osi.GetCombatantsInCombat(CurrentCombatId) end)
        if ok and combatants then
            scopedOk = true
            scoped = combatants
            for _, c in ipairs(combatants) do addUuid(c) end
        end
    end

    if scopedOk and actingCharUuid and actingCharUuid ~= "" then
        local actingSeen = false
        for _, c in ipairs(scoped) do
            if safeStr(c) == actingCharUuid then actingSeen = true break end
        end
        if not actingSeen then
            log("Skynet_GetKnownCombatants: CurrentCombatId-scoped list did NOT contain the acting character (" ..
                actingCharUuid:sub(1, 40) .. ") — CurrentCombatId is likely stale for this fight; merging DB scan.")
        end
    end

    -- Always also merge the global DB scan. This used to run only when the scoped call failed
    -- outright; it's cheap (a single Osiris DB read, same query already used session-wide
    -- elsewhere as the reload-recovery fallback) and can only ever ADD real, currently-in-combat
    -- characters the scoped call missed — never remove or override anything the scoped call
    -- already found.
    local dOk, rows = pcall(function() return Osi.DB_IsCharacterInCombat:Get(nil) end)
    if dOk and rows then
        for _, row in pairs(rows) do addUuid(row and row[1]) end
    end

    return list
end

local function GetDownedAllies(enemyId)
    local downed = {}
    local combatants = Skynet_GetKnownCombatants()
    for _, c in ipairs(combatants) do
        local uuid = safeStr(c)
        if uuid ~= "" and uuid ~= enemyId and IsActualAlly(uuid) and IsDowned(uuid) then
            local dist = GetDistanceBetween(enemyId, uuid)
            table.insert(downed, { uuid = uuid, dist = dist })
        end
    end
    table.sort(downed, function(a, b) return a.dist < b.dist end)
    return downed
end

-- Find all player summoner+summon pairs
-- Returns list of {summoner=uuid, summon=uuid, dist=meters}
-- Scans both alive and downed players (downed summoners' summons persist)
local function FindPlayerSummonPairs(alivePlayers, downedPlayers)
    local pairs_list = {}
    local scanned = {}
    local allPlayers = {}
    for _, p in ipairs(alivePlayers or {}) do allPlayers[#allPlayers + 1] = p end
    for _, p in ipairs(downedPlayers or {}) do allPlayers[#allPlayers + 1] = p end

    for _, p in ipairs(allPlayers) do
        local pid = tostring(p)
        if not scanned[pid] then
            scanned[pid] = true
            -- Check if this player has a SummonContainer (entity has summons)
            local ok, entity = pcall(function() return Ext.Entity.Get(pid) end)
            if ok and entity and entity.SummonContainer and entity.SummonContainer.Characters then
                for _, summonHandle in pairs(entity.SummonContainer.Characters) do
                    if summonHandle then
                        local summonOk, summonEntity = pcall(function() return Ext.Entity.Get(summonHandle) end)
                        if summonOk and summonEntity and summonEntity.Uuid and summonEntity.Uuid.EntityUuid then
                            local summonUuid = summonEntity.Uuid.EntityUuid
                            local isSummon = pcall(function() return Osi.IsSummon(summonUuid) end)
                            if isSummon then
                                local dist = 999
                                local pOk, px, py, pz = pcall(function() return Osi.GetPosition(pid) end)
                                local sOk, sx, sy, sz = pcall(function() return Osi.GetPosition(summonUuid) end)
                                if pOk and sOk and px and sx then
                                    local ddx, ddz = px - sx, pz - sz
                                    dist = math.sqrt(ddx*ddx + ddz*ddz)
                                end
                                pairs_list[#pairs_list + 1] = {
                                    summoner = pid,
                                    summon = summonUuid,
                                    dist = dist
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    return pairs_list
end

-- Get player UUIDs: GetHostCharacter + Osi checks (real UUID strings, not TranslatedString handles)
-- Returns two lists: alive players and downed players
local function GetPlayerTargets()
    local allTargets = {}
    local seen = {}

    -- Method 1: GetHostCharacter (most reliable — returns real UUID string)
    local ok, host = pcall(function() return Osi.GetHostCharacter() end)
    if ok and host and host ~= "" then
        local uuid = safeStr(host)
        if uuid ~= "" and not seen[normalizeUuidKey(uuid)] then
            seen[normalizeUuidKey(uuid)] = true
            allTargets[#allTargets + 1] = uuid
        end
    end

    -- Method 2: DB_Players (may return TranslatedString on some SE versions)
    local pOk, rows = pcall(function() return Osi.DB_Players:Get(nil) end)
    if pOk and rows then
        for _, row in pairs(rows) do
            local uuid = safeStr(row and row[1])
            -- Filter: must look like a real UUID (contains hyphens, starts with S_ or is a GUID)
            if uuid ~= "" and not seen[normalizeUuidKey(uuid)] and (uuid:find("S_") or uuid:find("-")) and not uuid:find("TranslatedString") then
                seen[normalizeUuidKey(uuid)] = true
                allTargets[#allTargets + 1] = uuid
            end
        end
    end

    -- Method 3: DB_PartOfTheTeam
    if type(Osi.DB_PartOfTheTeam) == "table" then
        local ok2, teamMembers = pcall(function() return Osi.DB_PartOfTheTeam:Get(nil) end)
        if ok2 and teamMembers then
            for _, row in pairs(teamMembers) do
                local uuid = safeStr(row and row[1])
                if uuid ~= "" and not seen[normalizeUuidKey(uuid)] and (uuid:find("S_") or uuid:find("-")) and not uuid:find("TranslatedString") then
                    seen[normalizeUuidKey(uuid)] = true
                    allTargets[#allTargets + 1] = uuid
                end
            end
        end
    end

    -- Method 4: DB_PartyMembers (includes summons, duplicates, etc. — per its name/intent;
    -- in practice this has NOT reliably included Invoke Duplicity duplicates in testing,
    -- which is what Method 5 below is for)
    if type(Osi.DB_PartyMembers) == "table" then
        local ok3, partyMembers = pcall(function() return Osi.DB_PartyMembers:Get(nil) end)
        if ok3 and partyMembers then
            for _, row in pairs(partyMembers) do
                local uuid = safeStr(row and row[1])
                if uuid ~= "" and not seen[normalizeUuidKey(uuid)] and (uuid:find("S_") or uuid:find("-")) and not uuid:find("TranslatedString") then
                    seen[normalizeUuidKey(uuid)] = true
                    allTargets[#allTargets + 1] = uuid
                end
            end
        end
    end

    -- Method 5: direct entity scan for Invoke Duplicity duplicates (see
    -- Skynet_FindNearbyDuplicates comment — Methods 1-4 above have proven unreliable for
    -- these across repeated live tests, so find them as physical entities instead). This is
    -- what makes duplicates real, attackable targets for every enemy's normal targeting
    -- path, not just the Spider Queen's dedicated quick-check.
    for _, dupUuid in ipairs(Skynet_GetTrackedDuplicates()) do
        local key = normalizeUuidKey(dupUuid)
        if not seen[key] then
            seen[key] = true
            allTargets[#allTargets + 1] = dupUuid
        end
    end

    -- Filter out dead players, separate alive and downed
    local alive = {}
    local downed = {}
    for _, uuid in ipairs(allTargets) do
        local deadOk, isDead = pcall(function() return Osi.IsDead(uuid) end)
        if not deadOk or isDead ~= 1 then
            if IsDowned(uuid) then
                downed[#downed + 1] = uuid
            else
                alive[#alive + 1] = uuid
            end
        end
    end

    return alive, downed
end

-- `allyUuid` (pass #27): the specific ally whose turn this is, used as an EXTRA, direct
-- hostility check alongside IsActualEnemy. Root cause of a reported bug ("Skynet wasn't even
-- really controlling the allies, just the enemies"): a fresh log showed every "TurnStarted for
-- ALLY" followed by total silence from Skynet's own turn logic (no ENV/SPELLS/PHASE/PERF
-- lines at all, unlike the rich trace every enemy turn produced in the same fight) — traced to
-- this function returning an EMPTY target list for a modded raid/ambush encounter
-- (S_DEN_GoblinRaider_* from what looks like a "Dynamic Ambushes"-style mod), silently hitting
-- Skynet_AITurn's very first (and only entirely unlogged) early-return. IsActualEnemy's primary
-- check only tests hostility against the HOST and each Osi.DB_Players row — never against a
-- non-player ally — and its pass #23-hardened combat-group fallback requires a confirmed group
-- MISMATCH before guessing "enemy" at all (deliberately conservative, to fix the Kar'niss/
-- Drider false-positive — see Maintenance history pass #23). A mod-spawned raider whose combat
-- group doesn't cleanly resolve, or whose actual scripted hostility is against the defending
-- ally NPCs rather than explicitly against the host/player characters, could satisfy neither
-- check — even though it's routinely and correctly recognized as hostile from the ENEMY side
-- (GetPlayerTargets never depends on this fuzzy classification at all — it just uses the
-- reliable player list directly), so only ally-side targeting was ever affected. Fixed by also
-- directly asking the game whether this specific candidate is hostile to the SPECIFIC ally
-- whose turn it is (Osi.IsEnemy(uuid, allyUuid)) — just as precise and safe as IsActualEnemy's
-- own host/player checks (a real Osiris relation query, not a heuristic guess), and covers
-- exactly the case where hostility was set relative to the ally being defended rather than the
-- party. See Maintenance history pass #27.
local function GetEnemyTargets(allyUuid)
    local allTargets = {}
    local seen = {}
    local combatants = Skynet_GetKnownCombatants(allyUuid)
    for _, c in ipairs(combatants) do
        local uuid = safeStr(c)
        if uuid ~= "" and not seen[uuid] and not IsPlayerCharacterSafe(uuid) then
            local isHostile = IsActualEnemy(uuid)
            if not isHostile and allyUuid and allyUuid ~= "" and uuid ~= allyUuid then
                local eOk, isEnemyOfAlly = pcall(function() return Osi.IsEnemy(uuid, allyUuid) end)
                if eOk and isEnemyOfAlly == 1 then
                    isHostile = true
                    -- Also feed this back into the shared cache so IsActualEnemy itself (and
                    -- every other caller) benefits from this positive result immediately,
                    -- instead of every other ally having to independently rediscover it.
                    FactionCache[uuid] = "enemy"
                end
            end
            if isHostile then
                seen[uuid] = true
                local deadOk, isDead = pcall(function() return Osi.IsDead(uuid) end)
                if not deadOk or isDead ~= 1 then
                    allTargets[#allTargets + 1] = uuid
                end
            end
        end
    end
    return allTargets
end

-- Helpers modeled after your Logging mod for reliable turn/combat detection on every character
local function resolveUuid(rawId)
  return safeStr(rawId)
end

local function getEntityUuid(rawId)
  local raw = safeStr(rawId)
  if raw == "" then return "" end
  local resolved = safeCall(Osi.GetUUID, raw)
  if type(resolved) == "string" and resolved ~= "" then
    return resolved
  end
  local guid = raw:match("([0-9a-fA-F%-]+)$")
  if guid ~= "" then return guid end
  return raw
end

-- ==================== LIMITED-USE SPELL TRACKING ====================
-- Real 5e-style resources like Action Surge (once per combat), Second Wind (once per short
-- rest), or a boss's legendary/signature ability (once per rest) are meant to be usable only
-- once within their reset window. BG3's own stat data records exactly this: every spell has a
-- Cooldown field (Ext.Stats.Get(spellId).Cooldown) whose value is one of "Default" (per-turn
-- only, no cross-turn limit), "OncePerCombat", "UntilRest" (long rest), "UntilShortRest", or a
-- couple of item-charge variants — confirmed via the bg3se source's SpellCooldownType enum and
-- the SpellData stat class's Cooldown field.
--
-- That alone tells us WHICH spells are limited and to WHAT window, but it doesn't tell us
-- whether one has already been used this window — and per the pattern found repeatedly during
-- action-resource work (passes #8-#10), the live per-entity cooldown state the engine tracks
-- (Ext.Entity.Get(uuid).SpellBookCooldowns) can't be trusted to reflect a cast Skynet forces
-- via Osi.UseSpell the same way it would a normal player-driven cast — the same category of
-- staleness that made ActionResources.Resources unreliable for tracking real-time consumption.
-- So usage is tracked in Skynet's own state instead — but NOT as a plain Lua table like
-- remainingAction/remainingBonusAction are. Per the bg3se docs ("The Lua state and all local
-- variables are reset after each game reload. To persist data across multiple play sessions,
-- use ModVars, UserVars..."), a plain table would silently forget every recorded usage the
-- instant the player saves and reloads mid-combat — which would un-gate a just-used
-- once-per-combat ability right when a player is most likely to trigger it: mid-fight. So this
-- is stored on each character's persistent entity variables (Ext.Vars) instead, which ARE
-- serialized into the savegame and survive a reload correctly.
--
-- Registration must happen every time the Lua context resets (i.e. unconditionally at file
-- load, not inside a function) — hence this call sits directly in the module body, not behind
-- any guard.
pcall(function()
    Ext.Vars.RegisterUserVariable("Skynet_LimitedSpellUsage", {
        Server = true,
        Client = false,
        Persistent = true,
    })
end)

local Skynet_SpellCooldownCache = {}  -- spellId -> Cooldown string, memoized (static stat data, safe to cache for the whole session)

local function Skynet_GetSpellCooldownType(spellId)
    if not spellId or spellId == "" then return "Default" end
    local cached = Skynet_SpellCooldownCache[spellId]
    if cached then return cached end
    local ok, statEntry = pcall(function() return Ext.Stats.Get(spellId) end)
    local cd = (ok and statEntry and statEntry.Cooldown) or "Default"
    if cd == "" then cd = "Default" end
    Skynet_SpellCooldownCache[spellId] = cd
    return cd
end

-- Which bucket (if any) a spell's usage should persist under across turns. "Default" and
-- "OncePerTurn"/"OncePerTurnNoRealtime" reset naturally every turn just by virtue of a new
-- turn starting, so they need no cross-turn bookkeeping at all — only these three genuinely
-- persist PAST the current turn and need to be remembered.
--
-- PASS #50 BUGFIX: this previously checked for "UntilRest"/"UntilPerRestPerItem"/
-- "UntilShortRest"/"OncePerShortRestPerItem" — NONE of which are real SpellData.Cooldown enum
-- values (confirmed against https://github.com/NellsRelo/bg3-schema's SpellData.md). The real
-- enum is only: OncePerTurn, OncePerCombat, OncePerShortRest, OncePerTurnNoRealtime, OncePerRest,
-- or empty. That means this function has never once returned "longRest" or "shortRest" for any
-- real spell — Skynet_HasUsedLimitedSpell has silently returned false for every genuine
-- OncePerRest/OncePerShortRest spell since this was written, so the once-per-rest tracking has
-- never actually gated anything (including Shout_SecondWind, added pass #36 believing it was
-- being shortRest-tracked — it wasn't). Likely origin: confusing this field's enum with the
-- *different* ResetCooldowns(<scope>) stat-functor's own "UntilRest"-style scope argument (a
-- separate enum for a separate system, confirmed via apcs_RestSystem's own apcs_MEDITAT status).
-- Fixed to the real values; "OncePerRest" is confirmed (via apcs_RestSystem's own stat data —
-- Shout_HeroicActionSurge) to mean "once per LONG rest", distinct from the more generous
-- "OncePerShortRest" (Hyper Focus, Dig Deeper — also refreshed by a long rest, same as any
-- short-rest resource would be, since Skynet_ResetAllLongRestLimitedSpells only ever clears the
-- "longRest" bucket today and doesn't touch "shortRest" — a pre-existing gap worth revisiting
-- separately, not fixed here to keep this change minimal). See Maintenance history pass #50.
local function Skynet_GetSpellLimitBucket(spellId)
    -- PASS #56: Dig Deeper is once per LONG rest per the user (apcs_RestSystem's Spell_Shout.txt still says
    -- OncePerShortRest, so the engine itself would allow more; Skynet holds enemies to once per long rest).
    if string.lower(tostring(spellId or "")):find("digdeeper", 1, true) then
        return "longRest"
    end
    local cd = Skynet_GetSpellCooldownType(spellId)
    if cd == "OncePerCombat" then
        return "combat"
    elseif cd == "OncePerRest" then
        return "longRest"
    elseif cd == "OncePerShortRest" then
        return "shortRest"
    end
    return nil
end

-- Returns the entity's persistent Vars object and its resolved uuid, or nil if either the
-- entity or the Vars system is unreachable (registration failed, entity gone, etc.) — every
-- caller treats that as "can't confirm limited-use state" and falls back to the safe default.
local function Skynet_GetLimitedSpellUsageVars(casterUuid)
    local resolved = getEntityUuid(casterUuid)
    if resolved == "" then return nil, resolved end
    local ok, entity = pcall(function() return Ext.Entity.Get(resolved) end)
    if not ok or not entity then return nil, resolved end
    local ok2, vars = pcall(function() return entity.Vars end)
    if not ok2 or not vars then return nil, resolved end
    return vars, resolved
end

local function Skynet_HasUsedLimitedSpell(casterUuid, spellId)
    local bucket = Skynet_GetSpellLimitBucket(spellId)
    if not bucket then return false end
    local vars = Skynet_GetLimitedSpellUsageVars(casterUuid)
    if not vars then return false end
    local ok, data = pcall(function() return vars.Skynet_LimitedSpellUsage end)
    if not ok or not data or not data[bucket] then return false end
    return data[bucket][spellId] == true
end

local function Skynet_MarkLimitedSpellUsed(casterUuid, spellId)
    local bucket = Skynet_GetSpellLimitBucket(spellId)
    if not bucket then return end
    local vars, resolved = Skynet_GetLimitedSpellUsageVars(casterUuid)
    if not vars then return end
    local ok, data = pcall(function() return vars.Skynet_LimitedSpellUsage end)
    data = (ok and data) or {}
    data[bucket] = data[bucket] or {}
    data[bucket][spellId] = true
    -- Writes to sub-properties of a Vars table don't trigger persistence/sync on their own
    -- (per the bg3se docs) — the whole variable must be reassigned to dirty it.
    pcall(function() vars.Skynet_LimitedSpellUsage = data end)
    log("  RESOURCE LIMIT: " .. tostring(spellId) .. " used (" .. bucket .. "-scoped, persisted) by " .. tostring(resolved):sub(1,40))
end

-- Reset all "combat"-scoped (OncePerCombat) usage for a character — called when they enter a
-- NEW combat, so a fresh fight lets them use it again. Does NOT touch longRest/shortRest
-- buckets, which must persist across combats until an actual rest happens.
--
-- combatGuid guards against a subtle regression this persistence fix would otherwise
-- introduce: EnteredCombat can fire again for a character already mid-fight after a save/load
-- (it's how CurrentCombatId recovers post-reload elsewhere in this file) — that does NOT mean
-- a new combat actually started. Wiping the combat bucket on every EnteredCombat would silently
-- re-enable an already-used once-per-combat ability right after a reload, defeating the whole
-- point of persisting it. Only reset when the incoming combat GUID is different from the one
-- last recorded for this character.
local function Skynet_ResetCombatLimitedSpells(casterUuid, combatGuid)
    local vars, resolved = Skynet_GetLimitedSpellUsageVars(casterUuid)
    if not vars then return end
    local ok, data = pcall(function() return vars.Skynet_LimitedSpellUsage end)
    data = (ok and data) or {}
    local newGuid = tostring(combatGuid or "")
    if newGuid ~= "" and data.combatGuid == newGuid then
        return  -- same combat resuming (e.g. post-reload) — not a new fight, don't wipe usage
    end
    data.combatGuid = newGuid
    data.combat = nil
    pcall(function() vars.Skynet_LimitedSpellUsage = data end)
end

-- Reset all "longRest"-scoped usage for every character that has ever recorded any limited-use
-- spell — called on LongRestFinished, which fires globally with no per-character parameter
-- (waking up in the morning restores everyone's rest-gated resources at once).
-- Ext.Vars.GetEntitiesWithVariable enumerates entities carrying this variable, since usage now
-- lives per-entity rather than in one central Lua table Skynet can just iterate directly.
--
-- PASS #50: also clears "shortRest" here — a real long rest refreshes short-rest resources too
-- (5e rules; a long rest is a superset of a short rest), and ShortRested doesn't reliably fire
-- separately for every character on a party-wide long rest. Previously this only cleared
-- longRest, but that gap was never noticed because the bucket-fix above means this is the first
-- pass where "shortRest" was ever populated with anything real to clear.
local function Skynet_ResetAllLongRestLimitedSpells()
    local ok, guids = pcall(function() return Ext.Vars.GetEntitiesWithVariable("Skynet_LimitedSpellUsage") end)
    if not ok or not guids then return end
    for _, guid in ipairs(guids) do
        local vars = Skynet_GetLimitedSpellUsageVars(guid)
        if vars then
            local dOk, data = pcall(function() return vars.Skynet_LimitedSpellUsage end)
            if dOk and data and (data.longRest or data.shortRest) then
                data.longRest = nil
                data.shortRest = nil
                pcall(function() vars.Skynet_LimitedSpellUsage = data end)
            end
        end
    end
end

-- Reset "shortRest"-scoped usage for one character — called on ShortRested(_Character), which
-- fires per-character.
local function Skynet_ResetShortRestLimitedSpells(casterUuid)
    local vars = Skynet_GetLimitedSpellUsageVars(casterUuid)
    if not vars then return end
    local ok, data = pcall(function() return vars.Skynet_LimitedSpellUsage end)
    if ok and data and data.shortRest then
        data.shortRest = nil
        pcall(function() vars.Skynet_LimitedSpellUsage = data end)
    end
end

-- PASS #50: apcs_RestSystem's "Meditate" lets the party simulate a long rest mid-day WITHOUT a
-- real engine long rest ever firing (confirmed via Status_BOOST.txt: apcs_MEDITAT's
-- OnRemoveFunctors calls ResetCooldowns(UntilRest)/ResetCooldowns(UntilRestPerItem) and then
-- applies apsc_DEEPMEDITAT — but that functor is gated to "Character() and Player() and Party()"
-- only, so it NEVER fires for enemies; real LongRestFinished/ShortRested likewise never fire for
-- them either). Per the user's explicit request, enemies should get an equivalent "the world
-- rested" refresh when the party does this, rather than staying locked out of Action Surge /
-- Heroic Action Surge / Hyper Focus / Dig Deeper for the rest of the playthrough just because
-- Skynet's own bookkeeping has no concept of simulated rest.
--
-- Deliberately a BLANKET reset across every tracked entity rather than scoping it to "only
-- enemies the party has fought since the last meditate": apcs_MEDITAT's own trigger conditions
-- already require "not Combat()", so this can only ever fire outside combat, and an enemy not
-- yet encountered has no Skynet_LimitedSpellUsage entry to reset in the first place — so a
-- blanket clear has the exact same practical effect as per-enemy scoping would, without needing
-- a second persisted timestamp (MonotonicTime() isn't safe to persist across a save/reload — it
-- resets to a new epoch each process — and nothing else in this file persists a comparable
-- real-time marker) to compare "last fought" against "last meditated".
function Skynet_ResetAllRestLimitedSpellsForMeditate()
    local ok, guids = pcall(function() return Ext.Vars.GetEntitiesWithVariable("Skynet_LimitedSpellUsage") end)
    if not ok or not guids then return end
    local count = 0
    for _, guid in ipairs(guids) do
        local vars = Skynet_GetLimitedSpellUsageVars(guid)
        if vars then
            local dOk, data = pcall(function() return vars.Skynet_LimitedSpellUsage end)
            if dOk and data and (data.longRest or data.shortRest) then
                data.longRest = nil
                data.shortRest = nil
                pcall(function() vars.Skynet_LimitedSpellUsage = data end)
                count = count + 1
            end
        end
    end
    log("  MEDITATE: apsc_DEEPMEDITAT detected — reset longRest/shortRest limited-spell usage for " .. count .. " tracked entit" .. (count == 1 and "y" or "ies"))
end

local function isInCombat(uuid)
    local resolved = resolveUuid(uuid)
    if resolved == "" then return false end
    -- Use CombatGetGuidFor like Logging mod — more reliable than IsInCombat with story UUIDs
    local ok, combatGuid = pcall(Osi.CombatGetGuidFor, resolved)
    if ok and combatGuid and combatGuid ~= "" and combatGuid ~= "00000000-0000-0000-0000-000000000000" then
        return true
    end
    -- Fallback to IsInCombat
    local ok2, res = pcall(Osi.IsInCombat, resolved)
    return ok2 and res == 1
end

-- ==================== ENVIRONMENTAL AWARENESS ====================

-- Get spell properties from Ext.Stats.Get (range, type, flags, targeting)
-- The generic "basic weapon attack" action spell IDs. Unlike a real spell, their actual range
-- depends entirely on whatever weapon the caster currently has equipped — the static stat data
-- for these just points at a "current weapon" placeholder rather than a literal Melee/Ranged
-- value or a number in meters. GetSpellProperties' generic parser below has no way to resolve
-- that placeholder, so historically it silently fell through to a fixed ~9m/melee-ish guess for
-- EVERY character using their basic attack — including archers with a bow equipped, causing
-- them to walk in far closer than their real ~18m range requires (reported as "archers charging
-- in to melee"). Fixed in pass #20 by resolving the caster's actual equipped weapon instead.
local BASIC_WEAPON_ATTACK_SPELLS = {
    ["target_mainhandattack"] = true,
    ["target_offhandattack"] = true,
}

-- Resolves whether casterId's currently equipped weapon is ranged or melee, using the
-- documented Osiris query GetEquippedItem plus IsRangedWeapon. Both calls are defensively
-- pcall-wrapped: if either is unavailable or errors on this SE build, this returns nil so
-- callers fall back to their previous (pre-pass-#20) behavior rather than breaking anything.
local function Skynet_GetCasterWeaponRangeInfo(casterId)
    if not casterId or casterId == "" then return nil end
    -- PERF (pass #24): this is called from GetSpellProperties for EVERY basic weapon attack
    -- (Target_MainHandAttack etc.) evaluated, which itself is called once per spell per
    -- reachability check — for a caster with a basic attack among many spells that's several
    -- uncached Osiris queries (GetEquippedItem + IsRangedWeapon) repeated identically many
    -- times in the same turn, since a creature's equipped weapon essentially never changes
    -- mid-turn. Cache per turn, piggybacking on LOSCache (reset every turn in Skynet_AITurn)
    -- with a prefixed key rather than a new top-level local — see the identical technique
    -- and rationale just above at the "unreachable" log dedup, pass #24.
    local cacheKey = "__weaponRange__" .. tostring(casterId)
    local cached = LOSCache[cacheKey]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end
    local itemOk, weaponItem = pcall(function() return Osi.GetEquippedItem(casterId, "Weapon") end)
    if not itemOk or not weaponItem or weaponItem == "" then
        -- No weapon equipped at all — unarmed is melee range.
        local result = {isRanged = false, isMelee = true, rangeMeters = 1.5}
        LOSCache[cacheKey] = result
        return result
    end
    local rangedOk, isRangedVal = pcall(function() return Osi.IsRangedWeapon(weaponItem) end)
    if rangedOk and isRangedVal == 1 then
        local result = {isRanged = true, isMelee = false, rangeMeters = 18}
        LOSCache[cacheKey] = result
        return result
    elseif rangedOk and isRangedVal == 0 then
        local result = {isRanged = false, isMelee = true, rangeMeters = 1.5}
        LOSCache[cacheKey] = result
        return result
    end
    LOSCache[cacheKey] = false -- couldn't determine this turn — remember that, don't retry every call
    return nil -- couldn't determine — let the caller fall back to its old behavior
end

local SpellPropertiesCache = {}
local function GetSpellProperties(spellId, casterId)
    -- Basic weapon attacks are caster-dependent (see BASIC_WEAPON_ATTACK_SPELLS above), so
    -- they can't use the shared spellId-only cache below — resolve and return early instead.
    local slBasic = string.lower(spellId or "")
    if BASIC_WEAPON_ATTACK_SPELLS[slBasic] and casterId then
        local weaponInfo = Skynet_GetCasterWeaponRangeInfo(casterId)
        if weaponInfo then
            local stats = safeCall(Ext.Stats.Get, spellId)
            local props = {
                id = spellId,
                spellType = stats and tostring(stats.SpellType or ""):lower() or "target",
                range = weaponInfo.isRanged and "rangedweapon" or "meleeweapon",
                targetRadius = 1.5,
                areaRadius = 0,
                useCosts = stats and tostring(stats.UseCosts or "") or "",
                spellSchool = "",
                verbalIntent = stats and tostring(stats.VerbalIntent or "") or "",
                spellFlags = {},
                isRanged = weaponInfo.isRanged,
                isMelee = weaponInfo.isMelee,
                isAoE = false,
                canTargetObjects = false,
                canTargetTerrain = false,
                ignoresVisionBlock = false,
                isConcentration = false,
                isSelfDamageAoE = false,
                rangeMeters = weaponInfo.rangeMeters,
            }
            return props
        end
        -- weaponInfo unresolved (API unavailable on this SE build) — fall through to the
        -- normal static-stat path below exactly as before pass #20.
    end

    if SpellPropertiesCache[spellId] then return SpellPropertiesCache[spellId] end
    local stats = safeCall(Ext.Stats.Get, spellId)
    if not stats then return nil end

    local props = {
        id = spellId,
        spellType = tostring(stats.SpellType or ""):lower(),
        range = tostring(stats.Range or "Melee"):lower(),
        targetRadius = tonumber(stats.TargetRadius) or 1.5,
        areaRadius = tonumber(stats.AreaRadius) or 0,
        useCosts = tostring(stats.UseCosts or ""),
        spellSchool = tostring(stats.SpellSchool or ""),
        verbalIntent = tostring(stats.VerbalIntent or ""),
        spellFlags = {},
        isRanged = false,
        isMelee = false,
        isAoE = false,
        canTargetObjects = false,
        canTargetTerrain = false,
        ignoresVisionBlock = false,
    }

    -- Parse flags
    if stats.SpellFlags then
        for _, flag in pairs(stats.SpellFlags) do
            local f = tostring(flag)
            props.spellFlags[f] = true
        end
    end

    -- Derived properties
    props.isRanged = props.range:find("ranged") ~= nil or props.range:find("arrow") ~= nil
    props.isMelee = props.range:find("melee") ~= nil or props.range:find("touch") ~= nil
    props.isAoE = props.areaRadius > 0 or props.spellType == "zone"
    props.canTargetObjects = props.spellFlags["CanTargetItems"] == true
    props.canTargetTerrain = props.spellFlags["CannotTargetTerrain"] ~= true
    props.ignoresVisionBlock = props.spellFlags["IgnoreVisionBlock"] == true
    -- "IsConcentration" is the flag the spell data actually uses (Ensnaring Strike, Shield of Faith...); this
    -- only tested "Concentration", so the pass #35 "don't start a second concentration spell" gate never
    -- fired for real concentration spells.
    props.isConcentration = props.spellFlags["IsConcentration"] == true or props.spellFlags["Concentration"] == true or props.spellFlags["HasSavethrow"] == true

    -- Detect if AoE damages the caster (e.g., Fireball hurts caster, Barbarian ground slam does not)
    props.isSelfDamageAoE = false
    if props.isAoE then
        -- Check for flags that indicate self-safety
        local selfSafe = props.spellFlags["SelfDamage"] == false or
                         props.spellFlags["NoSelfDamage"] == true or
                         props.spellFlags["IgnoreCaster"] == true
        -- Check spell name patterns for known self-safe AoE
        local s = string.lower(props.id or "")
        if s:find("cleave") or s:find("ground slam") or s:find("seismic") or
           s:find("whirlwind") or s:find("spin") or s:find("pulverize") or
           s:find("slam") or s:find("stomp") then
            selfSafe = true
        end
        -- Check spell name patterns for known self-damaging AoE
        if s:find("fireball") or s:find("lightning") or s:find("call lightning") or
           s:find("chain lightning") or s:find("blight") or s:find("ice storm") then
            selfSafe = false
            props.isSelfDamageAoE = true
        end
        if not selfSafe then
            props.isSelfDamageAoE = true
        end
    end

    -- Parse range to number (meters)
    local rangeNum = tonumber(props.range:match("(%d+)")) or 0
    if rangeNum == 0 then
        if props.isMelee then rangeNum = 1.5
        elseif props.isRanged then rangeNum = 18
        else
            -- Check if this is a teleport/mobility spell with known range
            local s = string.lower(props.id or "")
            if s:find("ethereal") or s:find("misty") or s:find("teleport") or
               s:find("dimension") or s:find("thunderstep") or s:find("far step") or
               s:find("blink") or s:find("shadow") or s:find("astral") or
               s:find("warp") or s:find("hellcrawl") or s:find("dark currents") or
               s:find("benign transposition") or s:find("fleeting dream") or
               s:find("shifting winds") or s:find("supernatural attraction") or
               s:find("wild magic") or s:find("mobile flourish") then
                rangeNum = 22  -- BG3 standard teleport range
            else
                rangeNum = 9
            end
        end
    end
    props.rangeMeters = rangeNum

    SpellPropertiesCache[spellId] = props
    return props
end

-- Check line of sight between two characters (matches Logging mod pattern)
local function CheckLineOfSight(casterId, targetId)
    local casterResolved = resolveUuid(casterId)
    local targetResolved = resolveUuid(targetId)
    if casterResolved == "" or targetResolved == "" then return false end
    -- Check LOS cache first
    local losKey = casterResolved .. "|" .. targetResolved
    if LOSCache[losKey] ~= nil then return LOSCache[losKey] end
    local ok, result = pcall(Osi.HasLineOfSight, casterResolved, targetResolved)
    local val = ok and result == 1
    LOSCache[losKey] = val
    return val
end

-- Get distance between two characters - uses Ext.Entity.Get for positions
local function GetDistanceBetween(charId1, charId2)
    local r1 = resolveUuid(charId1)
    local r2 = resolveUuid(charId2)
    if r1 == "" or r2 == "" then return 999 end

    -- Check distance cache first
    local distKey = r1 < r2 and (r1 .. "|" .. r2) or (r2 .. "|" .. r1)
    if DistanceCache[distKey] then return DistanceCache[distKey] end

    local function getPosition(uuid, label)
        -- Check position cache first
        if PositionCache[uuid] then
            local c = PositionCache[uuid]
            return c.x, c.y, c.z
        end
        -- Method 1: Ext.Entity.Get → Transform.Transform.Translate (vec3)
        local entityUuid = getEntityUuid(uuid)
        local e = safeCall(Ext.Entity.Get, entityUuid)
        if e and e.Transform then
            local t = e.Transform.Transform
            if t and t.Translate then
                local v = t.Translate
                local px, py, pz = v[1] or 0, v[2] or 0, v[3] or 0
                PositionCache[uuid] = {x = px, y = py, z = pz}
                return px, py, pz
            end
        end
        -- Method 2: Ext.Entity.Get with raw uuid
        if entityUuid ~= uuid then
            local e2 = safeCall(Ext.Entity.Get, uuid)
            if e2 and e2.Transform and e2.Transform.Transform and e2.Transform.Transform.Translate then
                local v = e2.Transform.Transform.Translate
                local px, py, pz = v[1] or 0, v[2] or 0, v[3] or 0
                PositionCache[uuid] = {x = px, y = py, z = pz}
                return px, py, pz
            end
        end
        -- Method 3: Osi.GetPosition
        local ok, x, y, z = pcall(Osi.GetPosition, uuid)
        if ok and type(x) == "number" then
            PositionCache[uuid] = {x = x, y = y or 0, z = z or 0}
            return x, y or 0, z or 0
        end
        return nil
    end

    local x1, y1, z1 = getPosition(r1, "r1")
    local x2, y2, z2 = getPosition(r2, "r2")
    if x1 and x2 then
        local dx = x1 - x2
        local dy = (y1 or 0) - (y2 or 0)
        local dz = z1 - z2
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        DistanceCache[distKey] = dist
        return dist
    end
    return 999
end

local function GetHorizontalDistance(charId1, charId2)
  -- Check distance cache first
  local r1 = resolveUuid(charId1)
  local r2 = resolveUuid(charId2)
  if r1 ~= "" and r2 ~= "" then
    local distKey = r1 < r2 and (r1 .. "|" .. r2) or (r2 .. "|" .. r1)
    if DistanceCache[distKey] then return DistanceCache[distKey] end
  end
  -- Use GetDistanceBetween which already uses position cache
  local d = GetDistanceBetween(charId1, charId2)
  return d
end

-- Get surface statuses on a character (fire, ice, cloud, etc.)
local DANGEROUS_SURFACES = {
    -- Base game surfaces
    "SURFACE", "BURNING", "ACID", "LAVA", "ELECTR", "FROST", "ICE",
    "GREASE", "WEB", "MUD", "CLOUD", "OBSCURED", "SPIKE", "FIRE",
    -- Mod-added surfaces: SurfaceBloodrage (Bloodmist)
    "BLOODCLOUD", "BLOODMIST", "BLOODRAGE",
    -- Mod-added surfaces: Surface_Ectoplasm_Addons (Ectoplasm)
    "ECTOPLASM", "ECTOPLASMIC",
}

local function GetSurroundingSurfaces(uuid)
    local resolved = resolveUuid(uuid)
    if resolved == "" then return {} end
    local surfaces = {}

    -- Check for surface status groups
    local ok, hasSurface = pcall(function() return Osi.HasActiveStatusWithGroup(resolved, "SG_Surface") end)
    if ok and hasSurface == 1 then
        table.insert(surfaces, "surface_present")
    end

    -- Check entity status container for specific surface types
    local eOk, e = pcall(function() return Ext.Entity.Get(resolved) end)
    if eOk and e and e.StatusContainer and e.StatusContainer.Statuses then
        pcall(function()
            for _, st in ipairs(e.StatusContainer.Statuses) do
                local statusId = ""
                if type(st) == "string" then statusId = st
                elseif type(st) == "table" and st.StatusId then statusId = st.StatusId
                else pcall(function() statusId = tostring(st and st.StatusId or "") end) end
                if statusId ~= "" then
                    local upper = string.upper(statusId)
                    for _, marker in ipairs(DANGEROUS_SURFACES) do
                        if upper:find(marker, 1, true) then
                            surfaces[#surfaces + 1] = statusId
                            break
                        end
                    end
                end
            end
        end)
    end

    return surfaces
end

-- Check if there are dangerous surfaces between caster and target
local function HasDangerousSurfacesBetween(casterId, targetId)
    local casterSurfaces = GetSurroundingSurfaces(casterId)
    local targetSurfaces = GetSurroundingSurfaces(targetId)

    -- If caster is standing on dangerous surface, movement is risky
    for _, s in ipairs(casterSurfaces) do
        local upper = string.upper(s)
        -- Base game hazards
        if upper:find("FIRE") or upper:find("BURNING") or upper:find("LAVA") or
           upper:find("ACID") or upper:find("ELECTR") or upper:find("CLOUD") or
           upper:find("SPIKE") or upper:find("WEB") or upper:find("GREASE") then
            return true, "caster_on_hazard"
        end
        -- Mod-added hazards: SurfaceBloodrage (Bloodmist)
        if upper:find("BLOODCLOUD") or upper:find("BLOODMIST") or upper:find("BLOODRAGE") then
            return true, "caster_on_bloodmist"
        end
        -- Mod-added hazards: Surface_Ectoplasm_Addons (Ectoplasm)
        if upper:find("ECTOPLASM") or upper:find("ECTOPLASMIC") then
            return true, "caster_on_ectoplasm"
        end
    end

    return false, "clear"
end

-- Check if a target is currently undetectable (hidden/invisible/sneaking/stealthed) —
-- this is BG3's real Stealth/Perception mechanic, which is entirely separate from raw
-- geometric line of sight. A stealthed character standing under an open gap can pass a
-- pure raycast (Osi.HasLineOfSight) while still being genuinely hidden per game rules —
-- IsValidTarget already checks this list of statuses for other codepaths (Invoke
-- Duplicity duplicate scoring, etc.), but IsTargetReachable and the Spider Queen's own
-- quick visibility scan did not, so a hidden/sneaking party member with clear-ish
-- geometry could get treated as a normal attackable target instead of triggering the
-- expected base-game "search for hidden target" fallback. Centralized here so both
-- codepaths (and IsValidTarget) can share one authoritative list.
-- PASS #55: classify a single status ID as "this makes its bearer hidden/invisible" by what
-- the ENGINE itself uses to decide targetability — the status's real StatusType (SNEAKING or
-- INVISIBLE) and membership in the SG_Invisible status group — instead of only matching a
-- hardcoded list of status-ID names. Per bg3.wiki, the Hiding condition's real ID is
-- SNEAKING, while Invisibility-family conditions (Invisibility, Greater Invisibility, Cloak
-- of Shadows, One with the Shadows, Umbral Shroud, Hide in Plain Sight, ...) live in the
-- SG_Invisible group under IDs like INVISIBILITY/GREATER_INVISIBILITY — none of which is the
-- literal "INVISIBLE" the old list checked. Any mod that re-implements Hide or Invisibility
-- under its own status ID still has to use these types/groups for the engine to honour it,
-- so this catches those too. Stat data is static, so each status ID is classified once and
-- cached for the rest of the session (bare global, no top-level local slot — pass #35
-- technique). "WEAPON"/"SEE_INVIS" IDs are excluded explicitly (Invisible Weapon is in
-- SG_Invisible but doesn't hide the character; See Invisibility is the opposite effect).
Skynet_StealthStatusIdCache = Skynet_StealthStatusIdCache or {}
function Skynet_IsStealthStatusId(statusId)
    if not statusId or statusId == "" then return false end
    local cached = Skynet_StealthStatusIdCache[statusId]
    if cached ~= nil then return cached end
    local up = string.upper(statusId)
    local result = false
    if not (up:find("WEAPON", 1, true) or up:find("SEE_INVIS", 1, true)) then
        local stOk, statusType = pcall(function()
            local s = Ext.Stats.Get(statusId)
            return s and s.StatusType
        end)
        if stOk and statusType then
            local t = string.upper(tostring(statusType))
            if t == "SNEAKING" or t == "INVISIBLE" then result = true end
        end
        if not result then
            local gOk, inGroup = pcall(function() return Osi.IsStatusFromGroup(statusId, "SG_Invisible") end)
            if gOk and (inGroup == 1 or inGroup == true) then result = true end
        end
    end
    Skynet_StealthStatusIdCache[statusId] = result
    return result
end

local function Skynet_IsTargetUndetected(uuid)
    if not uuid or uuid == "" then return false end
    local hOk, hasHidden = pcall(function() return Osi.HasStatus(uuid, "HIDDEN") end)
    if hOk and (hasHidden == 1 or hasHidden == true) then return true end
    local iOk, hasInvisible = pcall(function() return Osi.HasStatus(uuid, "INVISIBLE") end)
    if iOk and (hasInvisible == 1 or hasInvisible == true) then return true end
    local sOk, hasSneaking = pcall(function() return Osi.HasStatus(uuid, "SNEAKING") end)
    if sOk and (hasSneaking == 1 or hasSneaking == true) then return true end
    local scOk, hasSneakingClear = pcall(function() return Osi.HasStatus(uuid, "SNEAKING_CLEAR") end)
    if scOk and (hasSneakingClear == 1 or hasSneakingClear == true) then return true end
    local shoOk, hasSneakingHeavily = pcall(function() return Osi.HasStatus(uuid, "SNEAKING_HEAVILY_OBSCURED") end)
    if shoOk and (hasSneakingHeavily == 1 or hasSneakingHeavily == true) then return true end
    local sloOk, hasSneakingLightly = pcall(function() return Osi.HasStatus(uuid, "SNEAKING_LIGHTLY_OBSCURED") end)
    if sloOk and (hasSneakingLightly == 1 or hasSneakingLightly == true) then return true end
    local stOk, hasStealthed = pcall(function() return Osi.HasStatus(uuid, "STEALTHED") end)
    if stOk and (hasStealthed == 1 or hasStealthed == true) then return true end
    local sthOk, hasStealth = pcall(function() return Osi.HasStatus(uuid, "STEALTH") end)
    if sthOk and (hasStealth == 1 or hasStealth == true) then return true end
    local phOk, hasPassiveHidd = pcall(function() return Osi.HasStatus(uuid, "PASSIVE_HIDD") end)
    if phOk and (hasPassiveHidd == 1 or hasPassiveHidd == true) then return true end
    local unsOk, hasUnseen = pcall(function() return Osi.HasStatus(uuid, "UNSEEN") end)
    if unsOk and (hasUnseen == 1 or hasUnseen == true) then return true end
    -- PASS #55: the real Invisibility-family IDs (the literal "INVISIBLE" above is the
    -- condition's display name, not an ID the game applies).
    local invOk, hasInvisibility = pcall(function() return Osi.HasStatus(uuid, "INVISIBILITY") end)
    if invOk and (hasInvisibility == 1 or hasInvisibility == true) then return true end
    local ginvOk, hasGreaterInv = pcall(function() return Osi.HasStatus(uuid, "GREATER_INVISIBILITY") end)
    if ginvOk and (hasGreaterInv == 1 or hasGreaterInv == true) then return true end
    -- PASS #55: engine-level backstop — scan every status actually on the entity and ask
    -- whether any of them is a SNEAKING/INVISIBLE-type (or SG_Invisible) status, whatever
    -- its ID. This is what closes the gap where a character the game itself treats as
    -- hidden (and won't let vanilla AI target) carried a status ID not on the list above.
    local scanOk, statList, tplName = pcall(function()
        local ent = Ext.Entity.Get(uuid)
        if not ent then return nil, nil end
        local name = nil
        if ent.ServerCharacter and ent.ServerCharacter.Template then
            name = tostring(ent.ServerCharacter.Template.Name or "")
        end
        return ent.StatusContainer and ent.StatusContainer.Statuses, name
    end)
    -- Invoke Duplicity duplicates are decoys, never genuinely stealthed (see pass #13) —
    -- don't let some technical status on the illusion make it untargetable.
    local isDuplicityDecoy = tostring(uuid):find("Duplicity", 1, true) or (tplName and tplName:find("Duplicity", 1, true))
    if scanOk and statList and not isDuplicityDecoy then
        for _, sid in pairs(statList) do
            local sidStr = tostring(sid)
            if Skynet_IsStealthStatusId(sidStr) then
                -- Throttled to once per target+status every 5s: this function runs many times
                -- per turn (every target x every spell), so an unthrottled line would flood.
                Skynet_StealthMatchLogAt = Skynet_StealthMatchLogAt or {}
                local logKey = tostring(uuid) .. "|" .. sidStr
                local nowOk, now = pcall(function() return Ext.Utils.MonotonicTime() end)
                now = (nowOk and type(now) == "number") and now or 0
                local last = Skynet_StealthMatchLogAt[logKey]
                if not last or now == 0 or (now - last) > 5000 then
                    Skynet_StealthMatchLogAt[logKey] = now
                    log("  STEALTH TYPE MATCH: " .. tostring(uuid):sub(1,30) .. " has " .. sidStr .. " (SNEAKING/INVISIBLE type or SG_Invisible) — treated as undetected")
                end
                return true
            end
        end
    end
    return false
end

-- Check if a target is reachable by a spell (range + LOS + surfaces)
local function IsTargetReachable(casterId, targetId, spellId)
    local props = GetSpellProperties(spellId, casterId)
    if not props then return false, "no_spell_data" end

    local casterResolved = resolveUuid(casterId)
    local targetResolved = resolveUuid(targetId)
    if casterResolved == "" or targetResolved == "" then return false, "invalid_ids" end

    -- A genuinely hidden/sneaking/invisible target is not a valid attack target
    -- regardless of raw geometric LOS — let base-game AI search behavior handle them.
    if Skynet_IsTargetUndetected(targetId) then return false, "target_undetected" end

    -- Check line of sight (unless spell ignores it)
    if not props.ignoresVisionBlock then
        local hasLOS = CheckLineOfSight(casterId, targetId)
        if not hasLOS then return false, "no_line_of_sight" end
    end

    -- Check distance vs spell range
    local dist = GetDistanceBetween(casterId, targetId)
    if dist > props.rangeMeters then
        -- High-ground fallback: for ranged spells, use horizontal distance
        -- (vertical drop is traversable by firing arc)
        if props.rangeMeters > 0 and not props.isMelee then
            local hDist = GetHorizontalDistance(casterId, targetId)
            if hDist > props.rangeMeters then return false, "out_of_range" end
        else
            return false, "out_of_range"
        end
    end

    return true, "reachable"
end

-- ==================== INITIATIVE AWARENESS ====================

-- Get initiative roll for a character (higher = acts earlier = more dangerous)
local function GetInitiativeRoll(uuid)
    local entity = safeCall(Ext.Entity.Get, uuid)
    if entity and entity.CombatParticipant then
        local roll = entity.CombatParticipant.InitiativeRoll
        if roll and roll > 0 then return roll end
    end
    return nil
end

-- ==================== GRIT AND GLORY INTEGRATION ====================

-- Grit and Glory injury status prefixes
local GG_INJURY_PREFIXES = {
    "GOON_INJURY_",
    "GOON_INJURY_GRIT_GLORY_",
}

-- Grit and Glory exhaustion statuses
local GG_EXHAUSTION_STATUSES = {
    "GOON_FALL_ASLEEP_EASY",
    "GOON_FALL_ASLEEP_MEDIUM",
    "GOON_FALL_ASLEEP_HARD",
    "GOON_FALL_ASLEEP_EXTREME",
    "GOON_EXHAUSTION",
}

-- Grit and Glory madness statuses
local GG_MADNESS_STATUSES = {
    -- Short-term
    "GOON_MADNESS_5E_SHORTTERM_HALLUCINATIONS",
    "GOON_MADNESS_5E_SHORTTERM_HOMICIDAL",
    "GOON_MADNESS_5E_SHORTTERM_HYSTERIA",
    "GOON_MADNESS_5E_SHORTTERM_INTIMIDATED",
    "GOON_MADNESS_5E_SHORTTERM_PARALYSED",
    "GOON_MADNESS_5E_SHORTTERM_STUNNED",
    "GOON_MADNESS_5E_SHORTTERM_TONGUE_TIED",
    "GOON_MADNESS_5E_SHORTTERM_UNCONSCIOUS",
    -- Long-term
    "GOON_MADNESS_5E_LONGTERM_CODEPENDANT",
    "GOON_MADNESS_5E_LONGTERM_COMATOSED",
    "GOON_MADNESS_5E_LONGTERM_HALLUCINATIONS",
    "GOON_MADNESS_5E_LONGTERM_PANICKY",
    "GOON_MADNESS_5E_LONGTERM_PARANOIA",
    "GOON_MADNESS_5E_LONGTERM_TREMORS",
}

-- Check if a character has any Grit and Glory injury
local function HasGGInjury(uuid)
    if not uuid then return false, 0 end
    local count = 0
    -- Check by prefix pattern
    local entity = safeCall(Ext.Entity.Get, uuid)
    if entity and entity.ServerCharacter and entity.ServerCharacter.StatusManager then
        for _, status in pairs(entity.ServerCharacter.StatusManager.Statuses) do
            local statusId = tostring(status.StatusId or "")
            for _, prefix in ipairs(GG_INJURY_PREFIXES) do
                if statusId:find(prefix) then
                    count = count + 1
                    break
                end
            end
        end
    end
    return count > 0, count
end

-- Get injury severity weight (higher = more severe injuries)
local function GetGGInjurySeverity(uuid)
    if not uuid then return 0 end
    local severityWeights = {
        LOW = 1,
        MEDIUM = 2,
        HIGH = 3,
        EXTREME = 4,
    }
    local totalSeverity = 0
    local entity = safeCall(Ext.Entity.Get, uuid)
    if entity and entity.ServerCharacter and entity.ServerCharacter.StatusManager then
        for _, status in pairs(entity.ServerCharacter.StatusManager.Statuses) do
            local statusId = tostring(status.StatusId or ""):upper()
            for _, prefix in ipairs(GG_INJURY_PREFIXES) do
                if statusId:find(prefix) then
                    for sev, weight in pairs(severityWeights) do
                        if statusId:find(sev) then
                            totalSeverity = totalSeverity + weight
                            break
                        end
                    end
                    break
                end
            end
        end
    end
    return totalSeverity
end

-- Check if character has exhaustion (can fall asleep)
local function HasGGExhaustion(uuid)
    if not uuid then return false end
    for _, status in ipairs(GG_EXHAUSTION_STATUSES) do
        local ok, has = pcall(function() return Osi.HasStatus(uuid, status) end)
        if ok and (has == 1 or has == true) then return true end
    end
    return false
end

-- Check if character has madness
local function HasGGMadness(uuid)
    if not uuid then return false end
    for _, status in ipairs(GG_MADNESS_STATUSES) do
        local ok, has = pcall(function() return Osi.HasStatus(uuid, status) end)
        if ok and (has == 1 or has == true) then return true end
    end
    return false
end

-- Get comprehensive Grit and Glory vulnerability score
local function GetGGVulnerabilityScore(uuid)
    if not uuid then return 0 end
    local score = 0

    -- Injuries: more injuries = more vulnerable
    local hasInjury, injuryCount = HasGGInjury(uuid)
    if hasInjury then
        score = score + (injuryCount * 5)  -- +5 per injury
        -- Severity multiplier
        local severity = GetGGInjurySeverity(uuid)
        score = score + (severity * 3)     -- +3 per severity level
    end

    -- Exhaustion: vulnerable to being finished off
    if HasGGExhaustion(uuid) then
        score = score + 15  -- +15 if exhausted (can fall asleep)
    end

    -- Madness: unpredictable, easier to disable
    if HasGGMadness(uuid) then
        score = score + 10  -- +10 if mad (already impaired)
    end

    return score
end

-- ==================== ADDITIONAL SPELL INTERACTIONS ====================

-- Damage type IDs (matches AdditionalSpellInteractions)
local ASI_DamageTypeId = {
    Physical = 1, Slashing = 2, Piercing = 3, Bludgeon = 4,
    Acid = 5, Thunder = 6, Necrotic = 7, Fire = 8,
    Lightning = 9, Cold = 10, Psychic = 11, Poison = 12,
    Radiant = 13, Force = 14
}

-- Susceptibility conditions → damage type (+25% damage)
local ASI_SusceptibleMap = {
    Acid      = {"OFF_BALANCED"},
    Thunder   = {"DAZED", "OPEN_HAND_NO_REACTIONS", "MAG_ATTACK_DEBUFF", "MAG_PSYCHIC_MENTAL_FATIGUE"},
    Necrotic  = {"SG_Poisoned", "ACID"},
    Fire      = {"MAG_RADIANT_RADIATING_ORB"},
    Lightning = {"MAG_THUNDER_REVERBERATION"},
    Cold      = {"SG_Restrained", "SLOW"},
    Psychic   = {"SG_Charmed", "SG_Confused"},
    Poison    = {"BLEEDING"},
    Radiant   = {"SG_Blinded"},
    Force     = {"MAG_FROST"},
}

-- Exposure conditions → damage type (+50% damage)
local ASI_ExposedMap = {
    Acid      = {"SG_Prone", "PRONE", "PRONE_GREASE", "PRONE_SEWER", "PRONE_ICE", "PRONE_FALLEN", "PRONE_THUNDEROUS_SMITE", "KNOCKED_DOWN", "UNCONSCIOUS", "SHOCKWAVE"},
    Thunder   = {"SG_Sleeping"},
    Necrotic  = {"SG_Disease"},
    Fire      = {"GREASED"},
    Lightning = {"WET"},
    Cold      = {"SG_Stunned"},
    Psychic   = {"SG_Frightened"},
    Poison    = {"GAPING_WOUND"},
    Radiant   = {"TURNED"},
    Force     = {"SG_Paralyzed"},
}

-- Status groups for conversion
local ASI_StatusGroups = {
    "SG_Poisoned", "SG_Restrained", "SG_Charmed", "SG_Confused", "SG_Blinded",
    "SG_Prone", "SG_Sleeping", "SG_Disease", "SG_Stunned", "SG_Frightened", "SG_Paralyzed"
}

-- Convert status to its status group if applicable
local function ASI_ConvertToStatusGroup(status)
    for _, group in ipairs(ASI_StatusGroups) do
        local ok, isFromGroup = pcall(function() return Osi.IsStatusFromGroup(status, group) end)
        if ok and isFromGroup == 1 then return group end
    end
    return status
end

-- Check if character has Susceptibility to a damage type
local function HasSusceptibility(uuid, damageType)
    if not uuid or not damageType then return false end
    local status = "SUSCEPTIBLE_TO_" .. string.upper(damageType)
    local ok, has = pcall(function() return Osi.HasStatus(uuid, status) end)
    return ok and (has == 1 or has == true)
end

-- Check if character has Exposure to a damage type
local function HasExposure(uuid, damageType)
    if not uuid or not damageType then return false end
    local status = "EXPOSED_TO_" .. string.upper(damageType)
    local ok, has = pcall(function() return Osi.HasStatus(uuid, status) end)
    return ok and (has == 1 or has == true)
end

-- Get damage bonus multiplier from susceptibility/exposure
local function GetASIDamageBonus(uuid, damageType)
    if not uuid or not damageType then return 0 end
    if HasExposure(uuid, damageType) then return 0.50 end  -- +50% damage
    if HasSusceptibility(uuid, damageType) then return 0.25 end  -- +25% damage
    return 0
end

-- Check what conditions the target has that would trigger susceptibility/exposure
local function GetASIActiveConditions(uuid)
    if not uuid then return {} end
    local conditions = {}
    -- Check all susceptibility conditions
    for dmgType, statusList in pairs(ASI_SusceptibleMap) do
        for _, status in ipairs(statusList) do
            local group = ASI_ConvertToStatusGroup(status)
            local ok1, has1 = pcall(function() return Osi.HasStatus(uuid, status) end)
            local ok2, has2 = pcall(function() return Osi.HasStatus(uuid, group) end)
            if (ok1 and has1 == 1) or (ok2 and has2 == 1) then
                conditions[status] = {type = "susceptible", damageType = dmgType}
            end
        end
    end
    -- Check all exposure conditions
    for dmgType, statusList in pairs(ASI_ExposedMap) do
        for _, status in ipairs(statusList) do
            local group = ASI_ConvertToStatusGroup(status)
            local ok1, has1 = pcall(function() return Osi.HasStatus(uuid, status) end)
            local ok2, has2 = pcall(function() return Osi.HasStatus(uuid, group) end)
            if (ok1 and has1 == 1) or (ok2 and has2 == 1) then
                conditions[status] = {type = "exposed", damageType = dmgType}
            end
        end
    end
    return conditions
end

-- Get comprehensive ASI vulnerability score for a target
local function GetASIVulnerabilityScore(uuid, damageType)
    if not uuid then return 0 end
    local score = 0
    -- Direct damage type bonus
    local bonus = GetASIDamageBonus(uuid, damageType)
    if bonus > 0 then
        score = score + (bonus * 100)  -- 25 for susceptible, 50 for exposed
    end
    return score
end

-- Check if spell applies conditions that create susceptibility/exposure
local function SpellCreatesVulnerability(spellId)
    if not spellId then return false, nil, 0 end
    local s = string.lower(spellId)
    -- Cold spells → can apply MAG_FROST → Force susceptibility
    if s:find("cold") or s:find("frost") or s:find("ice") or s:find("ray_of_frost") then
        return true, "Force", 1
    end
    -- Fire spells → can apply Burning → various interactions
    if s:find("fire") or s:find("burning") or s:find("flame") then
        return true, "Fire", 1
    end
    -- Lightning spells → better vs WET targets
    if s:find("lightning") or s:find("thunder") or s:find("shock") then
        return true, "Lightning", 1
    end
    -- Psychic spells → can apply Mental Fatigue
    if s:find("psychic") or s:find("mind") or s:find("vicious_mockery") then
        return true, "Psychic", 1
    end
    return false, nil, 0
end

-- Get all damage types a spell deals
local function GetSpellDamageTypes(spellId)
    if not spellId then return {} end
    local types = {}
    local stats = safeCall(Ext.Stats.Get, spellId)
    if stats and stats.DamageType then
        table.insert(types, tostring(stats.DamageType))
    end
    -- Check for multiple damage types in spell properties
    if stats and stats.Damage and type(stats.Damage) == "table" then
        for _, dmg in pairs(stats.Damage) do
            if dmg.DamageType and dmg.DamageType ~= "" then
                table.insert(types, tostring(dmg.DamageType))
            end
        end
    end
    return types
end

-- ==================== CROSS-MOD COMBO AWARENESS (pass #35) ====================
-- PASS #35: the functions below are declared as plain global functions (no "local"),
-- not the usual "local function" every other top-level definition in this file uses.
-- This is deliberate: the file is at Lua's 200-top-level-local ceiling (see pass #23's
-- callout in the File layout section) with exactly one slot free, and a plain
-- `function Name(...)` at chunk scope creates a GLOBAL, which — confirmed directly with
-- `luac5.4 -p` against a synthetic 199-local test file — does NOT consume one of those
-- 200 local-variable slots at all, unlike `local function Name(...)`. This is a real,
-- safe way to keep adding shared top-level helpers without hitting the ceiling, instead
-- of resorting to pass #23's fallback of duplicating a helper as separate nested copies
-- inside each caller. Names are prefixed Skynet_ to avoid collisions inside this file's
-- own global table (each mod's server Lua runs in its own isolated Lua state in bg3se,
-- so there's no cross-mod global collision risk with AdditionalSpellInteractions,
-- DamageCombos, or Damage_Destruction either).

-- Status names (mirrors AdditionalSpellInteractions' own Fire/Cold/Psychic combo logic
-- — see its ApplyFrost/ApplyBurning/ApplyMentalFatigue — plus common BG3 concentration
-- spells) representing an enemy's own concentration effect currently active on the
-- battlefield. Shared so both the hard gate in ChooseBestAction and the pre-existing
-- soft scoring penalty in ScoreSpellForEnemy read the same list instead of drifting.
Skynet_ConcentrationStatusNames = {"FOG_CLOUD", "SILENCE", "SPIRIT_GUARDIANS", "HOLD_PERSON",
    "HOLD_MONSTER", "BANISHMENT", "SLOW", "CONFUSION", "CLOUD_OF_DAGGERS",
    "SPIKE_GROWTH", "WALL_OF_FIRE", "WALL_OF_THORNS", "Sleet_storm",
    "HYPNOTIC_PATTERN", "COLOR_SPRAY", "FAERIE_FIRE", "ENTANGLE", "WEB",
    "LEVITATE", "FLY", "CALL_LIGHTNING", "MOONBEAM", "INVISIBILITY",
    "GREASE", "BLUR", "SHADOW_BLADE", "FLAME_BLADE", "SPIRITUAL_WEAPON"}

-- Skynet_IsAlreadyConcentrating
-- ===========================
-- Returns true if `uuid` is currently maintaining a concentration effect. Reported
-- live bug: an enemy casts Fog Cloud, then later the same turn casts Silence — both
-- require concentration, and in BG3 (as in 5e) starting a new concentration spell
-- automatically breaks any concentration effect already running, so the enemy was
-- silently cancelling its own Fog Cloud. Two independent signals are checked because
-- neither is fully confirmed alone: (1) BG3SE's real ConcentrationComponent ECS
-- component, if present on the entity at all (the authoritative source — would catch
-- ANY concentration spell, not just the ones hardcoded below — but its exact field
-- layout is not confirmed from public docs as of this pass, so this is read
-- defensively and used only as a presence check, never to identify which spell); (2)
-- the hardcoded named-status list above, matched against what was actually reported
-- live (Fog Cloud, Silence). If bg3se's component name/shape turns out wrong, this
-- silently falls back to signal (2) alone, which already covers the exact reported
-- bug. See Maintenance history pass #35.
function Skynet_IsAlreadyConcentrating(uuid)
    if not uuid or uuid == "" then return false end
    -- A concentration spell Skynet queued earlier this same plan has not resolved yet, so neither signal
    -- below can see it; SkynetGates remembers it (see SkynetGates.lua).
    if SkynetGates and SkynetGates.isPendingConcentration(uuid) then return true end
    local compOk, hasComp = pcall(function()
        local ent = Ext.Entity.Get(uuid)
        return ent ~= nil and ent.ConcentrationComponent ~= nil
    end)
    if compOk and hasComp then return true end
    for _, status in ipairs(Skynet_ConcentrationStatusNames) do
        local ok, hasStatus = pcall(function() return Osi.HasStatus(uuid, status) end)
        if ok and hasStatus == 1 then return true end
    end
    return false
end

-- Skynet_IsRealVulnerable
-- ===========================
-- Returns true if `uuid` has a REAL, engine-level Vulnerable resistance flag to
-- damageType — i.e. the game will automatically double damage of that type against
-- them, regardless of which mod granted it. Several installed mods grant this
-- generically via a status's own "Resistance(X, Vulnerable)" boost (DamageCombos:
-- POISONED->Fire, SHOCKED/SHOCKING_GRASP/MAG_THUNDER_REVERBERATION->Radiant/Thunder,
-- PARALYZED/HOLD_PERSON/WEB/ENSNARED->Force, BLEEDING/GAPING_WOUND->Poison/Acid,
-- FRIGHTENED/FEARED->Psychic, RAY_OF_ENFEEBLEMENT->Necrotic; vanilla grants some too)
-- — reading the real Resistances component directly (the same technique
-- AdditionalSpellInteractions' own IsVulnerableTo local function uses internally, and
-- the same ASI_DamageTypeId index table this file already had defined above but had
-- never actually used for anything) means this generalizes automatically to ANY mod or
-- vanilla source of Vulnerable, not just one hardcoded status list per mod. See
-- Maintenance history pass #35.
function Skynet_IsRealVulnerable(uuid, damageType)
    if not uuid or not damageType then return false end
    local idx = ASI_DamageTypeId[damageType]
    if not idx then return false end
    local ok, isVuln = pcall(function()
        local ent = Ext.Entity.Get(uuid)
        if not ent or not ent.Resistances or not ent.Resistances.Resistances then return false end
        local tags = ent.Resistances.Resistances[idx]
        if not tags then return false end
        for _, tag in ipairs(tags) do
            if tag == "VulnerableToMagical" or tag == "VulnerableToNonMagical" then
                return true
            end
        end
        return false
    end)
    return ok and isVuln == true
end

-- Skynet_HasControlAdvantageStatus
-- ===========================
-- Returns true if `uuid` currently has a status that grants attackers real, automatic
-- Advantage on attack rolls against them. Per DamageCombos' own status data, WEB and
-- ENSNARED (both SG_Restrained-grouped) carry "Advantage(AttackTarget)" as an engine
-- boost — the same mechanism Paralyzed/Held already use, which pass #23 already scores
-- for separately via Skynet_IsParalyzed. This covers the Restrained case pass #23
-- didn't, so an ally who Webs/Entangles part of the party gets that setup actually
-- exploited by its allies (the user's request to "coordinate allies to take advantage
-- of the disadvantages placed on the party" by an ally's own control spell), instead
-- of every enemy just scoring targets by plain distance regardless of who's already
-- helpless. See Maintenance history pass #35.
function Skynet_HasControlAdvantageStatus(uuid)
    if not uuid or uuid == "" then return false end
    local ok, isRestrained = pcall(function() return Osi.HasActiveStatusWithGroup(uuid, "SG_Restrained") end)
    if ok and isRestrained == 1 then return true end
    -- Fall back to explicit status names in case HasActiveStatusWithGroup doesn't
    -- recognize WEB/ENSNARED's group membership on the current SE/mod build — these two
    -- are the concretely confirmed sources from DamageCombos' own stat data.
    for _, status in ipairs({"WEB", "ENSNARED"}) do
        local sOk, hasStatus = pcall(function() return Osi.HasActiveStatus(uuid, status) end)
        if sOk and hasStatus == 1 then return true end
    end
    return false
end

local function IsValidTarget(casterId, targetId)
    if not targetId or targetId == "" then return false end
    local uuid = resolveUuid(targetId)
    if uuid == "" then return false end
    -- Must not target self
    local casterUuid = resolveUuid(casterId)
    if uuid == casterUuid then return false end
    local ok, exists = pcall(function() return Osi.Exists(uuid) end)
    if not ok or exists ~= 1 then return false end
    -- Must not be dead
    local deadOk, isDead = pcall(function() return Osi.IsDead(uuid) end)
    if deadOk and isDead == 1 then return false end
    -- Must not have Sanctuary (prevents attacks)
    local sOk, hasSanctuary = pcall(function() return Osi.HasStatus(uuid, "SANCTUARY") end)
    if sOk and (hasSanctuary == 1 or hasSanctuary == true) then return false end
    -- PASS #53: now delegates to the single shared Skynet_IsTargetUndetected (defined above
    -- this function) instead of re-checking the exact same ten status names inline here,
    -- independently. These two lists were confirmed byte-for-byte identical at the time of
    -- this fix, but maintaining them as two separate copies was a pure DRY violation that
    -- risked silent drift the next time either one got a new status name added without the
    -- other — exactly the kind of inconsistency that makes a "is this target hidden" bug
    -- hard to fully stamp out. See Maintenance history pass #53.
    if Skynet_IsTargetUndetected(uuid) then
        if Settings.EnableDebugLogging then
            log("  STEALTH CHECK: " .. uuid:sub(1,20) .. " — Skynet_IsTargetUndetected=true, excluded as a valid target")
        end
        return false
    end
    -- Must not be an ally of the caster
    local allyOk, isAlly = pcall(function() return Osi.IsAlly(uuid, casterUuid) end)
    if allyOk and isAlly == 1 then return false end
    return true
end

-- ==================== INVOKE DUPLICITY DETECTION ====================
local DUPLICATE_TAG = "7c1d7a50-d0b0-4bf2-8be4-6b0148b29f1d"

local function IsInvokeDuplicityDuplicate(uuid)
    if not uuid or uuid == "" then return false end
    local rs = tostring(uuid)
    -- Fast path: check template name prefix (duplicates always have this)
    if rs:find("DWE_UADuplicity_Duplicate_Character") then return true end
    -- Check tag
    local ok, hasTag = pcall(function() return Osi.HasTag(rs, DUPLICATE_TAG) end)
    if ok and hasTag == 1 then return true end
    -- Check duplicate statuses
    local sOk, s1 = pcall(function() return Osi.HasStatus(rs, "DWE_UADUPLICITY_ID_1_DUPLICATE") end)
    if sOk and s1 == 1 then return true end
    local sOk2, s2 = pcall(function() return Osi.HasStatus(rs, "DWE_UADUPLICITY_ID_2_DUPLICATE") end)
    if sOk2 and s2 == 1 then return true end
    local sOk3, s3 = pcall(function() return Osi.HasStatus(rs, "DWE_UADUPLICITY_ID_3_DUPLICATE") end)
    if sOk3 and s3 == 1 then return true end
    local sOk4, s4 = pcall(function() return Osi.HasStatus(rs, "DWE_UADUPLICITY_ID_4_DUPLICATE") end)
    if sOk4 and s4 == 1 then return true end
    -- Check entity template as final fallback
    local tOk, tName = pcall(function()
        local e = Ext.Entity.Get(rs)
        if e and e.ServerCharacter and e.ServerCharacter.Template then
            return tostring(e.ServerCharacter.Template.Name or "")
        end
        return ""
    end)
    if tOk and tName:find("DWE_UADuplicity_Duplicate") then return true end
    return false
end

local function GetDuplicityCaster(duplicateUuid)
    if not duplicateUuid or duplicateUuid == "" then return nil end
    local rs = tostring(duplicateUuid)
    local ok, source = pcall(function() return Osi.GetStatusSource(rs, "DWE_UADUPLICITY_ID_1_DUPLICATE") end)
    if ok and source and source ~= "" then return tostring(source) end
    local ok2, source2 = pcall(function() return Osi.GetStatusSource(rs, "DWE_UADUPLICITY_ID_2_DUPLICATE") end)
    if ok2 and source2 and source2 ~= "" then return tostring(source2) end
    local ok3, source3 = pcall(function() return Osi.GetStatusSource(rs, "DWE_UADUPLICITY_ID_3_DUPLICATE") end)
    if ok3 and source3 and source3 ~= "" then return tostring(source3) end
    local ok4, source4 = pcall(function() return Osi.GetStatusSource(rs, "DWE_UADUPLICITY_ID_4_DUPLICATE") end)
    if ok4 and source4 and source4 ~= "" then return tostring(source4) end
    return nil
end

-- ==================== COMBAT-SCOPED TARGET ELIGIBILITY (pass #38) ====================
-- Shared predicate for "should THIS specific enemy be allowed to consider `uuid` as a
-- target/reachability candidate right now" — used by every player-facing targeting/scoring
-- path (Skynet_AITurn's aliveTargets/downedTargets, Skynet.ChooseBestAction's playerParty
-- overlay, ChooseMinionAction's nearest-player scan) to fix a reported bug: an enemy already
-- fighting real, non-player NPCs (a crash-site creature attacking tiefling refugees, a
-- Waukeen's Rest skirmish, etc.) would still get the party's full, always-on target list —
-- from GetPlayerTargets()/PlayerContext, neither of which have ever checked combat
-- membership at all — so a party merely sneaking nearby, not yet in combat with this enemy
-- (or not in combat at all), could still be scored, targeted, and pathed toward. `uuid` is
-- eligible if it's a member of `combatantSet` (a set built from Skynet_GetKnownCombatants(
-- enemyId) — the same real, live Osiris combat-membership data pass #27/#29 already trust
-- for ally- and non-player-hostile-side targeting) OR is an Invoke Duplicity duplicate,
-- which per GetPlayerTargets' own Method 5 comment has never reliably shown up in
-- DB_IsCharacterInCombat/GetCombatantsInCombat as a real combatant despite being a
-- legitimate, intentional decoy target. See Maintenance history pass #38.
function Skynet_IsEligibleCombatant(uuid, combatantSet)
    if not uuid or uuid == "" then return false end
    if IsInvokeDuplicityDuplicate(uuid) then return true end
    if combatantSet ~= nil and combatantSet[uuid] == true then return true end
    -- PASS #41: combatantSet comes from Skynet_GetKnownCombatants(enemyId), which merges
    -- Osi.GetCombatantsInCombat(CurrentCombatId) with Osi.DB_IsCharacterInCombat:Get(nil) and
    -- then does an exact-string set-membership check against that merged list. A live
    -- user-provided SE log — two reskinned mod-added enemies ("Sailor_Skeleton_VSC_...",
    -- from a third-party creature mod) fighting the full party for an entire multi-round
    -- combat, independently confirmed by a THIRD mod's own turn/round debug logging to share
    -- the party's exact live combat GUID throughout — showed this merged-list check failing
    -- for every single party member on every single one of these enemies' turns: "COMBAT-
    -- SCOPED TARGETING: excluded 4 player(s) not in combat... (not yet engaged)" immediately
    -- followed by "NO TARGETS FOUND", even though the party was demonstrably mid-fight with
    -- them the whole time. Whatever specific combination of CurrentCombatId staleness, or a
    -- UUID-format mismatch between GetCombatantsInCombat/DB_IsCharacterInCombat and the
    -- player UUIDs this function is asked to check, caused the merged list to come back
    -- without them, the net effect was Skynet_AITurn finding zero eligible targets for these
    -- enemies forever — silently ceding their entire turn to base-game AI every round, which
    -- is exactly what the report described: "Skynet here only seems to be recording what
    -- they're doing... I never could find anywhere it's actually controlling what they do."
    -- Fixed with a direct, single-character fallback that doesn't depend on matching UUID
    -- formats across heterogeneous list sources at all: Osi.IsInCombat(uuid), the same
    -- native per-character combat check already trusted elsewhere in this file (e.g.
    -- Skynet_PulseTick's "still in combat" check), is true for a player genuinely mid-fight
    -- and false for one merely sneaking nearby — so this preserves pass #38's original fix
    -- (a party that is not in combat AT ALL stays excluded) while no longer requiring the
    -- player to also appear, in matching string form, inside the enemy's own merged
    -- combatant-list snapshot. See Maintenance history pass #41.
    local icOk, icVal = pcall(function() return Osi.IsInCombat(uuid) end)
    return icOk and icVal == 1
end

-- Check if a UUID is an actual enemy (hostile to all players)
-- FactionCache defined at top of file for visibility

local function IsActualEnemy(uuid)
    if not uuid or uuid == "" then return false end
    local rs = tostring(uuid)
    -- Check cache first (skip "other" so fallback can run). PASS #26: a cached "enemy" result
    -- is deliberately NOT trusted as a short-circuit here (unlike "player"/"ally" below) —
    -- confirmed via a live user-provided SE log that a recruitable companion's real allegiance
    -- can flip from hostile to ally mid-playthrough (Minthara, internally
    -- "S_GOB_DrowCommander_...", still logged as "TurnStarted for ENEMY" and auto-casting on
    -- the party's behalf well after she'd actually joined). Once "enemy" got cached for her —
    -- written by ANY earlier call to this function or IsActualAlly, from before her allegiance
    -- changed — it previously locked in the wrong answer for the rest of that combat, since
    -- neither this function nor IsActualAlly ever re-ran the cheap primary Osi.IsEnemy/IsAlly
    -- check again afterward. That cheap check (1-2 direct Osiris queries, not a loop) is now
    -- always re-run regardless of a prior "enemy" cache entry, so a real allegiance change is
    -- picked up immediately; only the expensive combat-group fallback further below still
    -- benefits from the cache being written, same as it already did for "other". See
    -- Maintenance history pass #26.
    if FactionCache[rs] == "player" or FactionCache[rs] == "ally" then return false end
    local ok, host = pcall(function() return Osi.GetHostCharacter() end)
    if ok and host and host ~= "" then
        local eOk, isEnemy = pcall(function() return Osi.IsEnemy(rs, host) end)
        if eOk and isEnemy == 1 then
            FactionCache[rs] = "enemy"
            return true
        end
    end
    local pOk, rows = pcall(function() return Osi.DB_Players:Get(nil) end)
    if pOk and rows then
        for _, row in pairs(rows) do
            local player = row and row[1]
            if player and player ~= "" then
                local eOk2, isEnemy2 = pcall(function() return Osi.IsEnemy(rs, player) end)
                if eOk2 and isEnemy2 == 1 then
                    FactionCache[rs] = "enemy"
                    return true
                end
            end
        end
    end
    -- Neither the host nor any tracked player currently reads as hostile to this creature —
    -- clear a stale "enemy" cache entry left over from before a real allegiance change (see
    -- pass #26 note above), rather than leaving it to mislead IsActualAlly, which consults
    -- this same cache.
    if FactionCache[rs] == "enemy" then FactionCache[rs] = nil end
    -- FALLBACK: if in combat with spells, not a player, AND on a different combat side than
    -- the party, treat as enemy (handles creatures where Osi.IsEnemy fails due to mod faction
    -- assignments). The combat-group check is required — without it, this fallback used to
    -- fire for ANY spellcasting non-player creature in combat, full stop, including creatures
    -- that are genuinely non-hostile to the player and just happen to be fighting someone
    -- ELSE in the same combat instance. Confirmed as the root cause of a reported bug: an
    -- escort NPC (Kar'niss's Drider escort) ambushed by a third faction, with the party
    -- present in the same combat as non-hostile bystanders, was being misclassified as an
    -- enemy purely because it was "in combat with spells" — nothing checked whether it was
    -- actually on the party's opposing side — and Skynet then armed it against the party.
    -- Mirrors the combat-group technique IsActualAlly's own fallback already uses just above
    -- in this file, inverted: shared group there means ally; here, a confirmed DIFFERENT
    -- group is required before guessing enemy, and if neither side's group can be resolved at
    -- all, this now leaves the creature unclassified rather than guessing hostile — a false
    -- "not handled by Skynet" is much safer than a false "attack the party." See Maintenance
    -- history pass #23.
    local inCombat = false
    local icOk, icVal = pcall(function() return Osi.IsInCombat(rs) end)
    if icOk and icVal == 1 then inCombat = true end
    if inCombat then
        local eOk, e = pcall(function() return Ext.Entity.Get(rs) end)
        if eOk and e and e.SpellBook and e.SpellBook.Spells and #e.SpellBook.Spells > 0 and e.ServerCharacter then
            local myGroup = nil
            local mgOk, mgVal = pcall(function() return Osi.GetCombatGroupID(rs) end)
            if mgOk and mgVal and mgVal ~= "" then myGroup = mgVal end
            local sharesPartyGroup = false
            local anyPlayerGroupResolved = false
            if myGroup then
                local pOk2, pRows = pcall(function() return Osi.DB_Players:Get(nil) end)
                if pOk2 and pRows then
                    for _, row in pairs(pRows) do
                        local player = row and row[1]
                        if player and player ~= "" then
                            local pgOk, pgVal = pcall(function() return Osi.GetCombatGroupID(player) end)
                            if pgOk and pgVal and pgVal ~= "" then
                                anyPlayerGroupResolved = true
                                if pgVal == myGroup then sharesPartyGroup = true end
                            end
                        end
                    end
                end
            end
            if anyPlayerGroupResolved and not sharesPartyGroup then
                FactionCache[rs] = "enemy"
                return true
            elseif sharesPartyGroup then
                -- Same combat side as the party — definitely not hostile, whatever Osi.IsEnemy
                -- said (or failed to say).
                FactionCache[rs] = "other"
                return false
            end
            -- Neither this creature's nor any player's combat group could be resolved at
            -- all — too little signal to safely guess hostile. Fall through to "other" below
            -- rather than risk arming a neutral NPC against the party.
        end
    end
    FactionCache[rs] = "other"
    return false
end

-- Get all party members adjacent to an enemy (within 3m)
local function GetAdjacentThreats(enemyId, players)
    local threats = {}
    for _, p in ipairs(players or {}) do
        local pid = tostring(p)
        if IsValidTarget(enemyId, pid) then
            local dist = GetDistanceBetween(enemyId, pid)
            if dist <= 3.0 then
                threats[#threats + 1] = { id = pid, dist = dist }
            end
        end
    end
    return threats
end

-- Estimate how dangerous an opportunity attack from a party member would be
local function GetOpportunityAttackThreat(enemyId, partyMemberId)
    -- A Surprised character's real, literal effect (per bg3.wiki) is "Cannot take Actions or
    -- Reactions" — an opportunity attack IS a Reaction, so a Surprised party member poses
    -- zero real OA threat no matter their stats. Previously nothing here checked this at all,
    -- so Skynet could needlessly play cautious around an ambush-surprised party member who
    -- was mechanically incapable of punishing the movement. See Maintenance history pass #23.
    if IsSurprised(partyMemberId) then
        return 0
    end
    -- An invisible enemy next to a party member who cannot see invisibility draws no opportunity attack.
    if SkynetGates and SkynetGates.invisibleToThreat and SkynetGates.invisibleToThreat(enemyId, partyMemberId) then
        return 0
    end

    local enemyAC = 10
    local eOk, eEntity = pcall(function() return Ext.Entity.Get(resolveUuid(enemyId)) end)
    if eOk and eEntity and eEntity.Stats then
        local acOk, acVal = pcall(function() return eEntity.Stats.ArmorClass end)
        if acOk and acVal then enemyAC = acVal end
    end

    local pOk, pEntity = pcall(function() return Ext.Entity.Get(resolveUuid(partyMemberId)) end)
    if not pOk or not pEntity then return 0.5 end

    local function safeStat(entity, prop, default)
        if not entity or not entity.Stats then return default end
        local ok, val = pcall(function() return entity.Stats[prop] end)
        if ok and val then return val end
        return default
    end

    local attackAbility = math.max(safeStat(pEntity, "Strength", 10), safeStat(pEntity, "Dexterity", 10))
    local attackMod = math.floor((attackAbility - 10) / 2)

    local isSpellcaster = false
    local spellAbility = safeStat(pEntity, "SpellCastingAbility", 0)
    if spellAbility > 0 then
        isSpellcaster = true
        local castAbility = 10
        if spellAbility == 1 then castAbility = safeStat(pEntity, "Strength", 10)
        elseif spellAbility == 2 then castAbility = safeStat(pEntity, "Dexterity", 10)
        elseif spellAbility == 4 then castAbility = safeStat(pEntity, "Intelligence", 10)
        elseif spellAbility == 5 then castAbility = safeStat(pEntity, "Wisdom", 10)
        elseif spellAbility == 6 then castAbility = safeStat(pEntity, "Charisma", 10)
        end
        local castMod = math.floor((castAbility - 10) / 2)
        attackMod = math.max(attackMod, castMod - 1)
    end

    local profBonus = 3
    local totalAttack = attackMod + profBonus
    local hitChance = math.max(0, math.min(1, (totalAttack + 20 - enemyAC) / 20))

    if isSpellcaster then
        hitChance = hitChance * 0.6
    end

    if enemyAC >= 18 then
        hitChance = hitChance * 0.5
    elseif enemyAC >= 15 then
        hitChance = hitChance * 0.75
    end

    return hitChance
end

-- Check if staying near a party member forces ranged disadvantage
local function IsNearbyRangedDisadvantage(enemyId, partyMemberId)
    local pOk, pEntity = pcall(function() return Ext.Entity.Get(resolveUuid(partyMemberId)) end)
    if not pOk or not pEntity then return false end

    local function safeStat(entity, prop, default)
        if not entity or not entity.Stats then return default end
        local ok, val = pcall(function() return entity.Stats[prop] end)
        if ok and val then return val end
        return default
    end

    if safeStat(pEntity, "SpellCastingAbility", 0) > 0 then
        return true
    end

    local dex = safeStat(pEntity, "Dexterity", 10)
    local str = safeStat(pEntity, "Strength", 10)
    if dex > str then return true end

    return false
end

-- Find nearby egg clusters for utility spells like HatchEggs
local function FindEggClustersNear(casterId, maxDist)
    maxDist = maxDist or 30.0
    local clusters = {}
    local ok, allChars = pcall(function() return Osi.GetAllCharacters() end)
    if not ok or not allChars then return clusters end
    for _, char in pairs(allChars) do
        local charStr = tostring(char or "")
        if charStr ~= "" then
            local isCluster = false
            -- Check tag
            local tagOk, hasTag = pcall(function()
                return Osi.HasTag(charStr, "Spider_Egg_Cluster")
            end)
            if tagOk and hasTag then
                isCluster = true
            else
                -- Check character name (LTS_GEN_Spider_Eggs_Cluster_A_, etc.)
                local nameOk, charName = pcall(function() return Osi.GetDisplayName(charStr) end)
                if nameOk and charName then
                    local nameStr = tostring(charName)
                    if nameStr:find("Spider_Eggs_Cluster") or nameStr:find("Spider_Egg_Cluster") then
                        isCluster = true
                    end
                end
                -- Check template name
                if not isCluster then
                    local tplOk, tpl = pcall(function() return Osi.GetTemplate(charStr) end)
                    if tplOk and tpl then
                        local tplStr = tostring(tpl)
                        if tplStr:find("Spider_Egg") or tplStr:find("SpiderCluster") then
                            isCluster = true
                        end
                    end
                end
            end
            if isCluster then
                local dist = GetDistanceBetween(casterId, charStr)
                if dist <= maxDist then
                    table.insert(clusters, {uuid = charStr, dist = dist})
                end
            end
        end
    end
    -- Sort by distance
    table.sort(clusters, function(a,b) return a.dist < b.dist end)
    return clusters
end

-- ==================== ADAPTIVE TARGETING (Intelligence/Wisdom tiers) ====================
-- Intelligence and Wisdom grant two INDEPENDENT capabilities, not mutually exclusive tiers:
--   - Intelligence >= threshold: persistent, cross-game per-character memory (PlayerProfile.
--     characters) — this enemy "knows" how each party member generally plays — plus an AC
--     bonus (smart enough to notice armor).
--   - Wisdom >= threshold: live, THIS-fight awareness — reacts to who's actually dealing
--     damage right now, regardless of what history predicted — plus an HP bonus (perceptive
--     enough to notice who's hurt, without needing to be book-smart about it).
-- An enemy with only one of the two gets a single-signal tier ("intelligent" = prior-anchored
-- and comparatively easy to throw off by changing tactics mid-fight, matching how real
-- counterplay against a "knows my build" enemy should feel; "wise" = pure in-the-moment
-- reactivity with no memory at all, e.g. goblins). An enemy with BOTH gets "cunning": it
-- starts from its persistent expectation of how this player fights, but its Wisdom lets
-- sustained in-fight evidence increasingly override that expectation — the enemy that both
-- "knows the player" and is sharp enough to notice, and adapt to, the player deliberately
-- playing against what it expects. See Maintenance history pass #21 (base design) and pass
-- #22 (the Intelligence/Wisdom independence + "cunning" tier described here).

local function GetEnemyMentalStats(enemyId)
    local resolved = getEntityUuid(enemyId)
    local e = safeCall(Ext.Entity.Get, resolved)
    local intel, wis = 10, 10
    if e and e.Stats then
        local iOk, iVal = pcall(function() return e.Stats.Intelligence end)
        if iOk and iVal then intel = iVal end
        local wOk, wVal = pcall(function() return e.Stats.Wisdom end)
        if wOk and wVal then wis = wVal end
    end
    return {intelligence = intel, wisdom = wis}
end

-- Returns {hasIntellect, hasWisdom, tier, round}. hasIntellect/hasWisdom are independent
-- booleans (both can be true); `tier` is a human-readable label purely for logging
-- ("cunning"/"intelligent"/"wise"/"base") derived from the same two booleans.
local function Skynet_GetAdaptiveTargetingProfile(enemyId)
    if not Settings.EnableAdaptiveTargeting then
        return {hasIntellect = false, hasWisdom = false, tier = "base", round = CurrentCombatRound or 0}
    end
    local mental = GetEnemyMentalStats(enemyId)
    local hasIntellect = mental.intelligence >= Settings.AdaptiveTargetingIntThreshold
    local hasWisdom = mental.wisdom >= Settings.AdaptiveTargetingWisThreshold
    local tier
    if hasIntellect and hasWisdom then tier = "cunning"
    elseif hasIntellect then tier = "intelligent"
    elseif hasWisdom then tier = "wise"
    else tier = "base" end
    return {hasIntellect = hasIntellect, hasWisdom = hasWisdom, tier = tier, round = CurrentCombatRound or 0}
end

-- Additive score bonus for targetUuid, scaled to be comparable with PickBestTarget's other
-- bonuses (roughly +5 to +40). Returns 0 for "base" (feature off, or neither stat qualifies)
-- so callers never need to special-case that.
local function Skynet_GetPlayerThreatBonus(enemyId, targetUuid)
    local profile = Skynet_GetAdaptiveTargetingProfile(enemyId)
    if not profile.hasIntellect and not profile.hasWisdom then return 0 end

    local bonus = 0

    -- Raw signals: how much of THIS fight's observed damage came from targetUuid (live), and
    -- how much of this character's known LIFETIME average damage they represent relative to
    -- the rest of the tracked party (persistent) — only the latter requires Intelligence.
    local liveDmg = Skynet_LiveDamageByPlayer[targetUuid] or 0
    local totalLiveDmg = 0
    for _, d in pairs(Skynet_LiveDamageByPlayer) do totalLiveDmg = totalLiveDmg + d end
    local dmgShare = (totalLiveDmg > 0) and (liveDmg / totalLiveDmg) or 0

    local persistentShare = 0
    if profile.hasIntellect and PlayerProfile.characters then
        local charProfile = PlayerProfile.characters[targetUuid]
        local totalPersistentAvg = 0
        for _, cp in pairs(PlayerProfile.characters) do
            totalPersistentAvg = totalPersistentAvg + (cp.avg_damage_per_combat or 0)
        end
        if totalPersistentAvg > 0 and charProfile then
            persistentShare = (charProfile.avg_damage_per_combat or 0) / totalPersistentAvg
        end
    end

    -- How much weight goes to the live, this-fight signal vs. the persistent, cross-game
    -- signal is where the two stats actually interact:
    local liveWeight, persistentWeight
    local rounds = math.max(1, Settings.AdaptiveTargetingSessionRounds)

    if profile.hasIntellect and profile.hasWisdom then
        -- CUNNING: starts anchored mostly to the persistent prediction (round 0), then ramps
        -- toward trusting this fight's actual evidence more and more as rounds pass — by
        -- 2x the configured session-rounds window, live evidence dominates (0.85) but the
        -- persistent prior never fully vanishes (0.15 floor), since a genuinely book-smart
        -- enemy doesn't just forget everything it knows the instant one fight looks unusual.
        -- This is the "chess match" tier: the enemy opens with what it knows about the
        -- player, then pivots as the player's actual play this fight proves that expectation
        -- wrong — deliberately switching tactics mid-fight will visibly win out here, just
        -- not on turn 1.
        local ramp = math.min(1, profile.round / (rounds * 2))
        liveWeight = 0.15 + ramp * 0.70   -- 0.15 at round 0 -> 0.85 fully ramped in
        persistentWeight = 1 - liveWeight
    elseif profile.hasIntellect then
        -- INTELLIGENT (no Wisdom): leans heavily on what it knows about the player's general
        -- habits and stays there — book-smart but not quick-witted, so it's comparatively
        -- easy for a player to throw off by deliberately playing against type mid-fight.
        liveWeight = 0.15
        persistentWeight = 0.85
    else
        -- WISE (no Intellect): no persistent memory to draw on at all — purely reactive to
        -- this fight, and only once enough rounds have passed to have a real read on it.
        liveWeight = (profile.round >= Settings.AdaptiveTargetingSessionRounds) and 1 or 0
        persistentWeight = 0
    end

    local blendedShare = dmgShare * liveWeight + persistentShare * persistentWeight
    if blendedShare > 0 then
        local dmgBonus = blendedShare * 25
        bonus = bonus + dmgBonus
        log("  ADAPTIVE(" .. profile.tier .. "): " .. tostring(targetUuid):sub(1,20) .. " damage share=" .. string.format("%.2f", blendedShare) .. " (live=" .. string.format("%.2f", dmgShare) .. "@" .. string.format("%.2f", liveWeight) .. ", persist=" .. string.format("%.2f", persistentShare) .. "@" .. string.format("%.2f", persistentWeight) .. ") +" .. string.format("%.1f", dmgBonus))
    end

    -- HP bonus: either qualifying stat grants this (both a book-smart enemy and a perceptive
    -- one can tell who's wounded) — a more wounded target is a more efficient kill.
    local hpOk, hpPct = pcall(function() return Osi.GetHitpointsPercentage(targetUuid) end)
    if hpOk and type(hpPct) == "number" then
        local hpBonus = (100 - hpPct) * 0.12  -- up to +12 at 0% HP, 0 at full HP
        if hpBonus > 0 then
            bonus = bonus + hpBonus
            log("  ADAPTIVE(" .. profile.tier .. "): " .. tostring(targetUuid):sub(1,20) .. " HP=" .. tostring(hpPct) .. "% +" .. string.format("%.1f", hpBonus))
        end
    end

    -- AC bonus: Intelligence only, regardless of Wisdom. Per design discussion, an enemy
    -- without Intelligence (e.g. a goblin, "wise" tier) isn't meant to weigh armor class at
    -- all, only HP — that stays true whether or not it also has Wisdom.
    if profile.hasIntellect then
        local tEntity = safeCall(Ext.Entity.Get, targetUuid)
        if tEntity and tEntity.Stats then
            local acOk, acVal = pcall(function() return tEntity.Stats.ArmorClass end)
            if acOk and type(acVal) == "number" then
                local acBonus = math.max(0, (16 - acVal)) * 1.2  -- up to ~+19 at AC 0, 0 at AC>=16
                if acBonus > 0 then
                    bonus = bonus + acBonus
                    log("  ADAPTIVE(" .. profile.tier .. "): " .. tostring(targetUuid):sub(1,20) .. " AC=" .. tostring(acVal) .. " +" .. string.format("%.1f", acBonus))
                end
            end
        end
    end

    return bonus
end

-- Pick the best visible, reachable target for a spell
-- Check if a character is genuinely Paralyzed (real status ID is "PARALYZED", American
-- spelling — see the note on INCAPACITATING_STATUSES further down). Also checks the real
-- "SG_Paralyzed" status group via Osi.GetStatuses/IsStatusFromGroup so Hold Person, Hold
-- Monster, and any other paralysis-family status (including modded ones) are all caught, not
-- just a single literal ID. Nested inside PickBestTarget (its only caller) rather than
-- top-level, since the file's top-level local-variable count is already at Lua's 200-local
-- ceiling. See Maintenance history pass #23.
local function PickBestTarget(casterId, spellId, players, summonPairs)
    local function Skynet_IsParalyzed(uuid)
        if not uuid or uuid == "" then return false end
        local ok, hasStatus = pcall(function() return Osi.HasStatus(uuid, "PARALYZED") end)
        if ok and (hasStatus == 1 or hasStatus == true) then return true end
        local sOk, statuses = pcall(function() return Osi.GetStatuses(uuid) end)
        if sOk and statuses then
            for _, status in pairs(statuses) do
                local gOk, isGroup = pcall(function() return Osi.IsStatusFromGroup(tostring(status), "SG_Paralyzed") end)
                if gOk and isGroup == 1 then return true end
            end
        end
        return false
    end

    -- Reject Help — enemies should never free players from conditions
    local sl = string.lower(spellId or "")
    if sl:find("help") then
        return nil
    end
    -- PASS #59: Dip coats a weapon from a surface/burning object; it is never aimed at a creature.
    if Skynet_IsDipSpell and Skynet_IsDipSpell(spellId) then
        return nil
    end
    -- PASS #57: a self-only spell (TargetConditions "Self()": Rage, most class shouts) has no other target, and
    -- End Rage (no Self() restriction, per bg3.wiki) must never be aimed at someone else. Returning nil sends
    -- callers to their own self-cast / next-spell handling instead of casting it "at" a party member.
    if (Skynet_IsSelfOnlySpell and Skynet_IsSelfOnlySpell(spellId)) or (Skynet_IsEndRageSpell and Skynet_IsEndRageSpell(spellId)) then
        return nil
    end

    -- Handle utility spells that target objects (not players)
    -- HatchEggs targets egg clusters, not players
    if sl:find("hatchegg") or sl:find("spiderqueen") and sl:find("hatch") then
        local clusters = FindEggClustersNear(casterId, 30.0)
        if #clusters > 0 then
            log("  UTILITY TARGET: " .. spellId .. " -> egg cluster " .. clusters[1].uuid:sub(1,30) .. " (" .. string.format("%.1f", clusters[1].dist) .. "m)")
            return clusters[1].uuid
        end
        log("  UTILITY TARGET: " .. spellId .. " — no egg clusters found, skipping")
        return nil  -- don't self-cast, skip this spell
    end

    local props = GetSpellProperties(spellId)
    if not props then
        -- Fallback: just pick first existing, alive player
        for _, p in ipairs(players) do
            local pid = tostring(p)
            if IsValidTarget(casterId, pid) then return pid end
        end
        return nil
    end

    -- Use provided summon pairs or detect them
    local mySummonPairs = summonPairs or FindPlayerSummonPairs(players, {})

    local bestTarget = nil
    local bestScore = -999

    -- Check if ANY real party member is visible and reachable
    local hasVisibleRealTarget = false
    for _, p in ipairs(players) do
        local pid = tostring(p)
        if not IsInvokeDuplicityDuplicate(pid) and IsValidTarget(casterId, pid) then
            local reachable, reason = IsTargetReachable(casterId, pid, spellId)
            if reachable then
                hasVisibleRealTarget = true
                break
            end
        end
    end

    for _, p in ipairs(players) do
        local pid = tostring(p)
        -- Handle Invoke Duplicity duplicates — treat as real targets
        if IsInvokeDuplicityDuplicate(pid) then
            if IsValidTarget(casterId, pid) then
                local reachable, reason = IsTargetReachable(casterId, pid, spellId)
                if reachable then
                    local dist = GetDistanceBetween(casterId, pid)
                    local targetScore = 100 - dist
                    if props.isMelee then
                        targetScore = 100 - (dist * 2)
                    elseif props.isRanged then
                        targetScore = 100 - (dist * 0.5)
                    end
                    if not hasVisibleRealTarget then
                        -- No real party member is visible/reachable — the duplicate is all
                        -- there is to go on, so the AI should be fully fooled by it and
                        -- treat it as the priority target over anything else this pass.
                        targetScore = targetScore + 1000
                        log("  DUPLICITY: no real targets visible — attacking duplicate " .. pid:sub(1,20))
                    end
                    if targetScore > bestScore then
                        bestScore = targetScore
                        bestTarget = pid
                    end
                end
            else
                -- Real targets exist: if caster is hidden/OOL but duplicate is visible, score duplicate
                local dupCaster = GetDuplicityCaster(pid)
                if dupCaster then
                    local casterInLOS = CheckLineOfSight(casterId, dupCaster)
                    local dupInLOS = CheckLineOfSight(casterId, pid)
                    local casterHidden = false
                    local hOk, hStatus = pcall(function() return Osi.HasStatus(dupCaster, "HIDDEN") end)
                    if hOk and hStatus == 1 then casterHidden = true end
                    local iOk, iStatus = pcall(function() return Osi.HasStatus(dupCaster, "INVISIBLE") end)
                    if iOk and iStatus == 1 then casterHidden = true end

                    if (casterHidden or not casterInLOS) and dupInLOS and IsValidTarget(casterId, pid) then
                        local reachable, reason = IsTargetReachable(casterId, pid, spellId)
                        if reachable then
                            local dist = GetDistanceBetween(casterId, pid)
                            local targetScore = 100 - dist
                            if props.isMelee then
                                targetScore = 100 - (dist * 2)
                            elseif props.isRanged then
                                targetScore = 100 - (dist * 0.5)
                            end
                            if targetScore > bestScore then
                                bestScore = targetScore
                                bestTarget = pid
                                log("  DUPLICITY: caster hidden/OOL — targeting visible duplicate " .. pid:sub(1,20))
                            end
                        end
                    end
                end
            end
        elseif IsValidTarget(casterId, pid) then
            local reachable, reason = IsTargetReachable(casterId, pid, spellId)
            if reachable then
                local dist = GetDistanceBetween(casterId, pid)
                local targetScore = 100 - dist
                if props.isMelee then
                    targetScore = 100 - (dist * 2)
                elseif props.isRanged then
                    targetScore = 100 - (dist * 0.5)
                end

                if props.isAoE then
                    local nearbyCount = 0
                    for _, other in ipairs(players) do
                        if tostring(other) ~= pid and not IsInvokeDuplicityDuplicate(tostring(other)) then
                            local d = GetDistanceBetween(pid, tostring(other))
                            if d <= props.areaRadius then
                                nearbyCount = nearbyCount + 1
                            end
                        end
                    end
                    targetScore = targetScore + (nearbyCount * 15)
                end

                -- ===== INITIATIVE SCORING =====
                -- Characters with high initiative act first — they're more dangerous
                -- Prioritize killing high-initiative targets before they can act
                local initRoll = GetInitiativeRoll(pid)
                if initRoll then
                    -- Bonus: +5 for every 5 points above average (10), +0 at average, penalty below
                    local initBonus = math.floor((initRoll - 10) / 5) * 5
                    if initBonus > 0 then
                        targetScore = targetScore + initBonus
                        log("  INITIATIVE: " .. tostring(pid) .. " has init=" .. tostring(initRoll) .. " (acts early) +" .. tostring(initBonus))
                    elseif initBonus < 0 then
                        targetScore = targetScore + initBonus  -- negative bonus = penalty
                        log("  INITIATIVE: " .. tostring(pid) .. " has init=" .. tostring(initRoll) .. " (acts late) " .. tostring(initBonus))
                    end
                end

                -- ===== PARALYZED VULNERABILITY SCORING =====
                -- Per bg3.wiki, attacks against a Paralyzed target always have Advantage, and
                -- are automatic critical hits if the attacker is within 3m (10 ft). Nothing
                -- previously made Skynet aware of this at all — a Paralyzed party member (Hold
                -- Person/Monster, etc.) competed for targeting purely on distance like any
                -- other target, missing a huge, guaranteed-value opportunity. Bigger bonus
                -- when already within the guaranteed-crit range. See Maintenance history
                -- pass #23.
                if Skynet_IsParalyzed(pid) then
                    local critRange = dist <= 3.0
                    local paralyzedBonus = critRange and 45 or 20
                    targetScore = targetScore + paralyzedBonus
                    log("  PARALYZED: " .. tostring(pid) .. " is Paralyzed (" .. (critRange and "auto-crit range" or "advantage only, out of crit range") .. ") +" .. tostring(paralyzedBonus))
                end

                -- ===== ALLY COORDINATION: CONTROL-ADVANTAGE SCORING =====
                -- PASS #35: same idea as the Paralyzed bonus just above, but for Restrained
                -- (Web/Ensnared) — a target an ALLY already set up rather than something this
                -- particular caster did itself. Per DamageCombos' own status data, Restrained
                -- targets already grant attackers real Advantage on attack rolls (an engine
                -- boost, not something Skynet has to simulate), so this just makes sure that
                -- setup actually gets exploited by other enemies instead of every caster
                -- scoring targets by plain distance regardless of who's already helpless. This
                -- is the concrete form of "coordinate allies to take advantage of the
                -- disadvantages an ally's control spell already placed on the party" the user
                -- asked for. Smaller than the Paralyzed bonus since Restrained doesn't carry
                -- Paralyzed's automatic-crit clause. See Maintenance history pass #35.
                if Skynet_HasControlAdvantageStatus(pid) then
                    targetScore = targetScore + 20
                    log("  CONTROL ADVANTAGE: " .. tostring(pid) .. " is Restrained (real Advantage on attacks) +20")
                end

                -- ===== ROPE TIE-UP SCORING (pass #47) =====
                -- The user's own apcs_RestSystem mod ties two very different follow-ups to
                -- its apcs_ROPE_TIED_UP status depending on whether the target is also
                -- incapacitated (confirmed by direct read of Shared/TieUpStripSystem.lua
                -- this session). A target that's tied AND already incapacitated (DOWNED/
                -- LIE_DYING/KNOCKED_OUT/etc.) immediately gets the "guaranteed strip"
                -- variant and, per the user's own framing, "is mostly a known factor until
                -- they wake up... and then still has to break out" (apcs_ROPE_TIED_UP's own
                -- passive DC13 Strength save is the only way out) — not a target worth
                -- spending further attack/control investment on while real threats remain,
                -- so this is scored DOWN. A target that's tied but still conscious/standing
                -- gets the weaker 5-stack melee-only apcs_ROPE_STRIP_ATTACK_5 cascade
                -- instead — "every single hit... is going to remove an item they have
                -- equipped" is the user's own description of that cascade, a real bonus
                -- payoff on top of ordinary damage — so this is scored UP to encourage
                -- finishing the strip. See Maintenance history pass #47.
                local ropeTiedOk, ropeTied = pcall(function() return Osi.HasActiveStatus(pid, "apcs_ROPE_TIED_UP") end)
                if ropeTiedOk and ropeTied == 1 then
                    local tieUpIncapStatuses = {
                        "DOWNED", "AD_DEFEATED", "LIE_DYING", "LIE_DYING_VULNERABLE", "KNOCKED_OUT",
                        "PRONE", "KNOCKED_DOWN", "SLEEPING", "SG_Sleeping", "NATURAL_SLEEPING",
                    }
                    local tiedAndIncapacitated = false
                    for _, statusId in ipairs(tieUpIncapStatuses) do
                        local stOk3, hasStatus3 = pcall(function() return Osi.HasActiveStatus(pid, statusId) end)
                        if stOk3 and hasStatus3 == 1 then
                            tiedAndIncapacitated = true
                            break
                        end
                    end
                    if tiedAndIncapacitated then
                        targetScore = targetScore - 25
                        log("  ROPE TIED+INCAPACITATED: " .. tostring(pid) .. " neutralized, low priority -25")
                    else
                        targetScore = targetScore + 25
                        log("  ROPE TIED (strip cascade): " .. tostring(pid) .. " +25")
                    end
                end

                -- ===== GRIT AND GLORY SCORING =====
                -- Injured/exhausted/mad enemies are more vulnerable — prioritize them
                local ggScore = GetGGVulnerabilityScore(pid)
                if ggScore > 0 then
                    targetScore = targetScore + ggScore
                    log("  GRIT&GLORY: " .. tostring(pid) .. " vulnerability=" .. tostring(ggScore) .. " (injured/exhausted/mad) +" .. tostring(ggScore))
                end

                -- ===== ADDITIONAL SPELL INTERACTIONS SCORING =====
                -- Check if target has susceptibility/exposure to spell's damage types
                if props then
                    local spellDmgTypes = GetSpellDamageTypes(spellId)
                    for _, dmgType in ipairs(spellDmgTypes) do
                        local asiBonus = GetASIVulnerabilityScore(pid, dmgType)
                        if asiBonus > 0 then
                            targetScore = targetScore + asiBonus
                            log("  ASI: " .. tostring(pid) .. " vulnerable to " .. tostring(dmgType) .. " +" .. tostring(asiBonus))
                        end
                        -- PASS #35: real, engine-level Vulnerable (double damage) from
                        -- DamageCombos/vanilla/any mod — see Skynet_IsRealVulnerable. Scored
                        -- higher than ASI's own tracked Exposed bonus (50) since this is an
                        -- actual damage-doubling flag the game applies automatically, not a
                        -- manually-added percentage.
                        if Skynet_IsRealVulnerable(pid, dmgType) then
                            targetScore = targetScore + 60
                            log("  REAL VULNERABLE: " .. tostring(pid) .. " is Vulnerable to " .. tostring(dmgType) .. " (2x damage) +60")
                        end
                    end
                    -- Also check if spell creates vulnerabilities for chaining
                    local createsVuln, vulnType, _ = SpellCreatesVulnerability(spellId)
                    if createsVuln and vulnType then
                        -- Check if target already has conditions that would benefit
                        local conditions = GetASIActiveConditions(pid)
                        for status, info in pairs(conditions) do
                            if info.damageType == vulnType then
                                targetScore = targetScore + 10  -- bonus for setting up combos
                                log("  ASI CHAIN: " .. tostring(spellId) .. " can combo with " .. tostring(status) .. " on " .. tostring(pid) .. " +10")
                                break
                            end
                        end
                    end
                end

                -- ===== ADAPTIVE TARGETING SCORING (Intelligence/Wisdom tiers) =====
                -- No-op (returns 0) unless the caster qualifies for the "intelligent" or
                -- "wise" tier — see Skynet_GetPlayerThreatBonus. Applied only to real party
                -- members here, not Invoke Duplicity duplicates (an illusion has no combat
                -- history of its own to react to).
                local adaptiveBonus = Skynet_GetPlayerThreatBonus(casterId, pid)
                if adaptiveBonus > 0 then
                    targetScore = targetScore + adaptiveBonus
                end

                -- ===== SUMMON-AWARE SCORING =====
                for _, pair in ipairs(mySummonPairs) do
                    if pair.summoner == pid then
                        local summonDist = GetDistanceBetween(pid, pair.summon)
                        if summonDist <= 6 then
                            if props.isAoE then
                                local summonerDist = dist
                                local aoEReachesSummoner = summonerDist <= props.rangeMeters
                                local summonReachable = IsTargetReachable(casterId, pair.summon, spellId)
                                if aoEReachesSummoner and summonReachable then
                                    targetScore = targetScore + 40
                                    log("  SUMMON PAIR: " .. pid .. " + " .. pair.summon:sub(1,20) .. " — AoE can hit both! +40")
                                else
                                    targetScore = targetScore + 20
                                    log("  SUMMON PAIR: " .. pid .. " + " .. pair.summon:sub(1,20) .. " — AoE can't reach both, targeting summoner +20")
                                end
                            else
                                targetScore = targetScore + 15
                            end
                        else
                            targetScore = targetScore + 5
                        end
                    end
                end

                if IsDowned(pid) then
                    for _, pair in ipairs(mySummonPairs) do
                        if pair.summoner == pid then
                            targetScore = targetScore + 30
                            log("  DOWNED SUMMONER: " .. pid .. " — finishing to clear summons +30")
                            break
                        end
                    end
                end

                if targetScore > bestScore then
                    bestScore = targetScore
                    bestTarget = pid
                end
            else
                -- PERF (pass #24): a caster with N "other" spells calls PickBestTarget once
                -- per spell, and this same "unreachable" line was firing again from scratch
                -- for the same (pid, reason) on every single one of those N calls — a real
                -- log spotted 14 near-identical repeats of the same 4 lines in a single turn.
                -- Dedup per turn so it only prints once per (pid, reason). Piggybacks on
                -- LOSCache (already reset every turn — see Skynet_AITurn) with a prefixed key
                -- that can never collide with a real "caster|target" UUID pair, rather than
                -- adding a new top-level local — the file is already at/near Lua's 200
                -- top-level-local ceiling (see Maintenance history pass #23).
                local dedupKey = "__loggedUnreachable__" .. pid .. "|" .. tostring(reason)
                if not LOSCache[dedupKey] then
                    LOSCache[dedupKey] = true
                    log("  Target " .. tostring(p) .. " unreachable: " .. tostring(reason))
                end
            end
        end
    end

    -- ===== OPPORTUNITY ATTACK AWARENESS =====
    -- If the best target is far away but there's an adjacent threat, consider staying
    if bestTarget then
        local adjacentThreats = GetAdjacentThreats(casterId, players)
        if #adjacentThreats > 0 then
            local bestDist = GetDistanceBetween(casterId, bestTarget)
            if bestDist > 3.0 then
                -- Find the most dangerous adjacent threat
                local maxThreat = 0
                local bestAdjacent = nil
                local bestAdjacentStayBonus = 0
                for _, threat in ipairs(adjacentThreats) do
                    local threatLevel = GetOpportunityAttackThreat(casterId, threat.id)
                    if threatLevel > maxThreat then
                        maxThreat = threatLevel
                        bestAdjacent = threat.id
                    end
                    -- Bonus for staying near ranged characters (forces disadvantage)
                    if IsNearbyRangedDisadvantage(casterId, threat.id) then
                        bestAdjacentStayBonus = bestAdjacentStayBonus + 8
                    end
                end

                -- Calculate opportunity attack cost of moving to best target
                local opportunityCost = 0
                for _, threat in ipairs(adjacentThreats) do
                    local tLevel = GetOpportunityAttackThreat(casterId, threat.id)
                    opportunityCost = opportunityCost + (tLevel * 15) -- each threat costs up to 15 score
                end

                -- If opportunity cost is high and we have a viable adjacent target, prefer staying
                if opportunityCost > 15 and bestAdjacent then
                    local adjacentScore = 100 - GetDistanceBetween(casterId, bestAdjacent) * 5
                    adjacentScore = adjacentScore + bestAdjacentStayBonus

                    -- Check if adjacent target is low HP (finish them off)
                    -- PASS #56: 0-100 scale from Osiris, normalised (was compared to 0.3 raw — never true).
                    local adjHpOk, adjHp = pcall(function() return Osi.GetHitpointsPercentage(bestAdjacent) / 100 end)
                    if adjHpOk and type(adjHp) == "number" and adjHp < 0.3 then
                        adjacentScore = adjacentScore + 25 -- finish off low HP target
                        log("  OPPORTUNITY AWARENESS: adjacent target low HP — finishing off " .. bestAdjacent:sub(1,20))
                        bestTarget = bestAdjacent
                    elseif opportunityCost > 25 and adjacentScore > 60 then
                        log("  OPPORTUNITY AWARENESS: staying to fight adjacent threat (cost=" .. string.format("%.0f", opportunityCost) .. ")")
                        bestTarget = bestAdjacent
                    else
                        log("  OPPORTUNITY AWARENESS: moving to target despite opportunity attacks (cost=" .. string.format("%.0f", opportunityCost) .. ")")
                    end
                end
            end
        end
    end

    -- ===== INVOKE DUPLICITY SUBSTITUTION =====
    -- If the best target has an active duplicate, consider attacking the duplicate instead
    if bestTarget then
        local casterOfTarget = tostring(bestTarget)
        for _, p in ipairs(players) do
            local pid = tostring(p)
            if IsInvokeDuplicityDuplicate(pid) then
                local dupCaster = GetDuplicityCaster(pid)
                if dupCaster and dupCaster == casterOfTarget then
                    local casterHidden = false
                    local hOk, hStatus = pcall(function() return Osi.HasStatus(casterOfTarget, "HIDDEN") end)
                    if hOk and hStatus == 1 then casterHidden = true end
                    local iOk, iStatus = pcall(function() return Osi.HasStatus(casterOfTarget, "INVISIBLE") end)
                    if iOk and iStatus == 1 then casterHidden = true end

                    local casterInLOS = CheckLineOfSight(casterId, casterOfTarget)
                    local dupInLOS = CheckLineOfSight(casterId, pid)

                    if casterHidden or not casterInLOS then
                        if dupInLOS then
                            log("  DUPLICITY: caster " .. casterOfTarget:sub(1,20) .. " hidden/OOL — targeting duplicate " .. pid:sub(1,20))
                            bestTarget = pid
                        end
                    elseif casterInLOS and dupInLOS then
                        if math.random(100) <= 50 then
                            log("  DUPLICITY: both visible — 50/50 roll → targeting duplicate " .. pid:sub(1,20))
                            bestTarget = pid
                        else
                            log("  DUPLICITY: both visible — 50/50 roll → targeting caster " .. casterOfTarget:sub(1,20))
                        end
                    end
                    break
                end
            end
        end
    end

    return bestTarget
end

-- Check if a character is on high ground relative to another
local function IsOnHighGround(charId, otherId)
    local x1, y1, z1 = safeCall(Osi.GetPosition, resolveUuid(charId))
    local x2, y2, z2 = safeCall(Osi.GetPosition, resolveUuid(otherId))
    if x1 and x2 then
        return (y1 or 0) > (y2 or 0) + 1.5 -- more than ~5 feet higher
    end
    return false
end

-- ==================== OPPORTUNITY ATTACK AWARENESS ====================

local function IsActualAlly(uuid)
    if not uuid or uuid == "" then return false end
    if IsPlayerCharacterSafe(uuid) then return false end
    local rs = tostring(uuid)
    -- Check cache first (skip "other" so fallback can run). PASS #26: no longer blocks on a
    -- cached "enemy" result — mirrors the same fix in IsActualEnemy just above, and for the
    -- same reason: a stale "enemy" cache entry from before a companion's recruitment (or any
    -- other real allegiance change) must not permanently prevent this function from ever
    -- re-checking and correctly recognizing them as an ally for the rest of that combat. See
    -- Maintenance history pass #26.
    if FactionCache[rs] == "ally" then return true end
    if FactionCache[rs] == "player" then return false end
    local ok, host = pcall(function() return Osi.GetHostCharacter() end)
    if ok and host and host ~= "" then
        local aOk, isAlly = pcall(function() return Osi.IsAlly(rs, host) end)
        if aOk and isAlly == 1 then
            FactionCache[rs] = "ally"
            return true
        end
    end
    local pOk, rows = pcall(function() return Osi.DB_Players:Get(nil) end)
    if pOk and rows then
        for _, row in pairs(rows) do
            local player = row and row[1]
            if player and player ~= "" then
                local aOk2, isAlly2 = pcall(function() return Osi.IsAlly(rs, player) end)
                if aOk2 and isAlly2 == 1 then
                    FactionCache[rs] = "ally"
                    return true
                end
            end
        end
    end
    -- FALLBACK: if in combat and shares combat group with a player, treat as ally
    -- (handles allies where Osi.IsAlly fails due to mod faction assignments)
    local inCombat = false
    local icOk, icVal = pcall(function() return Osi.IsInCombat(rs) end)
    if icOk and icVal == 1 then inCombat = true end
    if inCombat then
        local myGroup = nil
        local mgOk, mgVal = pcall(function() return Osi.GetCombatGroupID(rs) end)
        if mgOk and mgVal and mgVal ~= "" then myGroup = mgVal end
        if myGroup then
            local pOk2, pRows = pcall(function() return Osi.DB_Players:Get(nil) end)
            if pOk2 and pRows then
                for _, row in pairs(pRows) do
                    local player = row and row[1]
                    if player and player ~= "" then
                        local pgOk, pgVal = pcall(function() return Osi.GetCombatGroupID(player) end)
                        if pgOk and pgVal and pgVal == myGroup then
                            FactionCache[rs] = "ally"
                            return true
                        end
                    end
                end
            end
        end
    end
    -- SCRIPTED SIDE-TAKERS: in combat, not the party's enemy, but hostile to a character who IS the party's
    -- enemy (Rath vs. the Grove druids, tieflings vs. druids). Treat as an ally so Skynet drives the turn
    -- and targets the party's enemies (GetEnemyTargets) instead of the base AI planning it.
    if inCombat and not IsActualEnemy(rs) then
        local cOk, combatants = pcall(Skynet_GetKnownCombatants, rs)
        if cOk and type(combatants) == "table" then
            for _, c in ipairs(combatants) do
                local u = safeStr(c)
                if u ~= "" and u ~= rs and not IsPlayerCharacterSafe(u) and IsActualEnemy(u) then
                    local eOk, hostile = pcall(function() return Osi.IsEnemy(u, rs) end)
                    if eOk and hostile == 1 then
                        FactionCache[rs] = "ally"
                        return true
                    end
                end
            end
        end
    end
    FactionCache[rs] = "other"
    return false
end

local function shouldProcessEnemy(uuid)
    -- Fast check: skip players
    if IsPlayerCharacterSafe(uuid) then return false end
    if Skynet_PlayerControlledReason(uuid) then return false end   -- PASS #66: the player's summons too
    local rs = tostring(uuid or "")
    if rs == "" then return false end
    -- Must be an actual enemy (faction check)
    if not IsActualEnemy(rs) then return false end
    -- Must be a real character (not a corpse, door, container, decoration)
    local ok, e = pcall(function() return Ext.Entity.Get(rs) end)
    if not ok or not e then return false end
    if not e.ServerCharacter then return false end
    if not e.SpellBook or not e.SpellBook.Spells or #e.SpellBook.Spells == 0 then return false end

    -- Spider Queen: alternate between Skynet and base game when clusters present
    local tplOk, tpl = pcall(function() return Osi.GetTemplate(rs) end)
    if tplOk and tpl then
        local tplStr = tostring(tpl)
        if tplStr:find("SpiderQueen") or tplStr:find("Spider_Queen") or tplStr:find("Matriarch") then
            -- Check if any clusters still exist
            local hasClusters = false
            for _ in pairs(LocatedClusters) do hasClusters = true break end
            if not hasClusters then
                for _ in pairs(AliveEggClusters) do hasClusters = true break end
            end
            if hasClusters then
                -- Clusters present: Skynet always controls
                SpiderQueenControlledBySkynet = true
                log("  Spider Queen — Skynet taking control (clusters present)")
            else
                -- No clusters: Skynet always controls
                SpiderQueenControlledBySkynet = true
                log("  Spider Queen — Skynet taking control (no clusters)")
            end
        end
    end

    -- Note: isInCombat check removed — caller already confirmed combat via DB_IsCharacterInCombat
    return true
end

-- Debug function to list all characters and their templates (call from log)
local function DebugListCharacters()
    local allCharsOk, allChars = pcall(function() return Osi.GetAllCharacters() end)
    if not allCharsOk or not allChars then return end
    log("  DEBUG: Listing all characters:")
    for _, char in pairs(allChars) do
        local charStr = tostring(char or "")
        if charStr ~= "" then
            local tplOk, tpl = pcall(function() return Osi.GetTemplate(charStr) end)
            local nameOk, name = pcall(function() return Osi.GetDisplayName(charStr) end)
            local inCombatOk, inCombat = pcall(function() return Osi.IsInCombat(charStr) end)
            local tplStr = tplOk and tostring(tpl) or "unknown"
            local nameStr = nameOk and tostring(name) or "unknown"
            local combatStr = (inCombatOk and inCombat == 1) and "IN COMBAT" or "not in combat"
            if tplStr:find("Spider") or nameStr:find("Spider") then
                log("    " .. charStr:sub(1,40) .. " | tpl=" .. tplStr:sub(1,40) .. " | name=" .. nameStr:sub(1,30) .. " | " .. combatStr)
            end
        end
    end
end

local function shouldProcessAlly(uuid)
    if IsPlayerCharacterSafe(uuid) then return false end
    if Skynet_PlayerControlledReason(uuid) then return false end   -- PASS #66: the player's summons too
    local rs = tostring(uuid or "")
    if rs == "" then return false end
    if not IsActualAlly(rs) then return false end
    local ok, e = pcall(function() return Ext.Entity.Get(rs) end)
    if not ok or not e then return false end
    if not e.ServerCharacter then return false end
    if not e.SpellBook or not e.SpellBook.Spells or #e.SpellBook.Spells == 0 then return false end
    -- Note: isInCombat check removed — caller already confirmed combat via DB_IsCharacterInCombat
    return true
end

-- Analyze a spell name and categorize its element
local function CategorizeElement(spellName)
    local sl = string.lower(spellName or "")
    if sl:find("fire") or sl:find("flame") or sl:find("burn") or sl:find("scorch") or sl:find("hellfire") then return "fire" end
    if sl:find("cold") or sl:find("frost") or sl:find("ice") or sl:find("blizzard") then return "cold" end
    if sl:find("lightning") or sl:find("shock") or sl:find("thunder") or sl:find("call_lightning") then return "lightning" end
    if sl:find("poison") or sl:find("acid") or sl:find("corrosive") then return "poison" end
    if sl:find("force") or sl:find("eldritch") or sl:find("disintegrate") or sl:find("repell") then return "force" end
    if sl:find("necro") or sl:find("undead") or sl:find("death") or sl:find("ray_of_enfeeblement") then return "necro" end
    if sl:find("slash") or sl:find("pierce") or sl:find("bludgeon") or sl:find("strike") or sl:find("weapon") then return "physical" end
    return "other"
end

-- Categorize a spell by tactical style
local function CategorizeStyle(spellName)
    local sl = string.lower(spellName or "")
    if sl:find("summon") or sl:find("conjure") or sl:find("animate") then return "summon" end
    if sl:find("heal") or sl:find("restoration") or sl:find("cure") or sl:find("mend") then return "heal" end
    -- Note: "freeze"/"frozen", "restrain", "slow", "prone"/"knockdown", and "charm" were added
    -- after a mod user (bababadadadada, Nexus comments) reported their control-spell count
    -- looked too low despite using sleep/entangle/fear (all already matched) and "freeze"
    -- (which wasn't) — see Maintenance history pass #14.
    if sl:find("hold") or sl:find("command") or sl:find("fear") or sl:find("sleep") or sl:find("stun") or sl:find("paralyz") or sl:find("blind") or sl:find("silence") or sl:find("web") or sl:find("entangle") or sl:find("freeze") or sl:find("frozen") or sl:find("restrain") or sl:find("slow") or sl:find("prone") or sl:find("knockdown") or sl:find("charm") then return "control" end
    if sl:find("concentration") or sl:find("bless") or sl:find("shield") or sl:find("glyph") or sl:find("spirit") then return "concentration" end
    return "damage"
end

-- Update profile with data from the current combat
local function UpdateProfileFromCombat()
    if not CombatHistory then
        log("UpdateProfileFromCombat: CombatHistory is nil, skipping")
        return
    end

    local historyCount = 0
    for _ in pairs(CombatHistory) do historyCount = historyCount + 1 end
    log("UpdateProfileFromCombat: CombatHistory has " .. historyCount .. " entries")

    PlayerProfile.combats_analyzed = PlayerProfile.combats_analyzed + 1

    -- Track spell usage
    for spell, count in pairs(CombatHistory) do
        if type(spell) == "string" and not spell:find("^__") then
            PlayerProfile.spell_frequency[spell] = (PlayerProfile.spell_frequency[spell] or 0) + count

            -- Element tracking
            local element = CategorizeElement(spell)
            PlayerProfile.element_preference[element] = (PlayerProfile.element_preference[element] or 0) + count

            -- Style tracking
            local style = CategorizeStyle(spell)
            if style == "summon" then PlayerProfile.style.summon_count = PlayerProfile.style.summon_count + count end
            if style == "heal" then PlayerProfile.style.heal_count = PlayerProfile.style.heal_count + count end
            if style == "control" then PlayerProfile.style.control_count = PlayerProfile.style.control_count + count end
            if style == "concentration" then PlayerProfile.style.concentration_count = PlayerProfile.style.concentration_count + count end
        end
    end

    -- Rebuild favorite spells (top 10)
    local sorted = {}
    for spell, count in pairs(PlayerProfile.spell_frequency) do
        table.insert(sorted, {spell = spell, count = count})
    end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    PlayerProfile.favorite_spells = {}
    for i = 1, math.min(10, #sorted) do
        PlayerProfile.favorite_spells[i] = sorted[i]
    end

    -- Update average distance (running average)
    if PlayerContext then
        for _, snap in pairs(PlayerContext) do
            if snap and snap.position then
                local dist = 9.0
                -- Approximate average distance from position
                if snap.position[1] ~= 0 or snap.position[3] ~= 0 then
                    dist = math.sqrt(snap.position[1]^2 + snap.position[3]^2)
                end
                local n = PlayerProfile.combats_analyzed
                PlayerProfile.style.avg_distance = PlayerProfile.style.avg_distance + (dist - PlayerProfile.style.avg_distance) / n
            end
        end
    end

    -- Save periodically (every combat)
    SaveProfile()
end

-- ==================== CONTEXT GATHERING ====================

local function GetCharacterSnapshot(char)
    if not char then return {} end
    local resolved = getEntityUuid(char)
    -- Check snapshot cache first
    if SnapshotCache[resolved] then return SnapshotCache[resolved] end
    local e = safeCall(Ext.Entity.Get, resolved)
    if not e then return {} end

    -- Use position cache for position
    local px, py, pz
    if PositionCache[resolved] then
        local c = PositionCache[resolved]
        px, py, pz = c.x, c.y, c.z
    else
        px, py, pz = safeCall(Osi.GetPosition, resolved)
        if px and type(px) == "number" then
            PositionCache[resolved] = {x = px, y = py or 0, z = pz or 0}
        end
    end
    local position = (px and type(px) == "number" and {px, py or 0, pz or 0}) or {0,0,0}

    -- Level via Osi if possible, avoid Vars.Level (causes 'Level' not registered)
    local lvl = safeCall(Osi.GetLevel, resolved) or 1

    local snap = {
        uuid = resolved,
        name = "Unknown",
        level = lvl,
        position = position,
        classes = {},
        passives = {},
        statuses = {},
        spells = {},
        keyThreats = {}  -- e.g. high damage buffs, dangerous passives
    }

    -- Wrap ALL component access in one pcall to prevent any proxy __index or "not valid method" errors
    pcall(function()
        if e.DisplayName and e.DisplayName.Name then
            snap.name = tostring(e.DisplayName.Name) or "Unknown"
        end

        -- Classes
        local progs = e.ProgressionContainer and e.ProgressionContainer.Progressions
        if progs then
            for _, item in ipairs(progs) do
                if item then
                    if type(item) == "table" then
                        if item.Class and type(item.Class) == "table" and item.Class.ClassName then
                            table.insert(snap.classes, item.Class.ClassName)
                        elseif type(item.ClassName) == "string" then
                            table.insert(snap.classes, item.ClassName)
                        else
                            for _, sub in ipairs(item) do
                                if sub and sub.Class and sub.Class.ClassName then
                                    table.insert(snap.classes, sub.Class.ClassName)
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Passives
        if e.PassiveContainer and e.PassiveContainer.Passives then
            for _, p in ipairs(e.PassiveContainer.Passives) do
                if p and p.Passive and p.Passive.PassiveId then
                    local pid = p.Passive.PassiveId
                    table.insert(snap.passives, pid)
                    if string.find(pid, "Rogue") or string.find(pid, "Sneak") then
                        table.insert(snap.keyThreats, "stealth")
                    end
                end
            end
        end

        -- Statuses
        if e.StatusContainer and e.StatusContainer.Statuses then
            for _, st in ipairs(e.StatusContainer.Statuses) do
                if type(st) == "string" then
                    table.insert(snap.statuses, st)
                elseif type(st) == "table" and st.StatusId then
                    table.insert(snap.statuses, st.StatusId)
                end
            end
        end

        -- Spells
        if e.SpellBook and e.SpellBook.Spells then
            for _, spell in ipairs(e.SpellBook.Spells) do
                if spell.Id and spell.Id.OriginatorPrototype then
                    local spellId = spell.Id.OriginatorPrototype
                    -- Exclude "Dismiss Summon" here too — this snapshot path is what
                    -- Skynet.ChooseBestAction actually uses first (GetEnemyAvailableSpells
                    -- is only its fallback when this is empty), so the same exclusion has
                    -- to be applied here or it never takes effect in practice. See the
                    -- matching comment in GetEnemyAvailableSpells for why.
                    if not string.lower(spellId):find("dismiss") then
                        table.insert(snap.spells, spellId)
                    end
                end
            end
        end
    end)

    SnapshotCache[resolved] = snap
    return snap
end

local function AnalyzePlayerParty()
    local party = {}
    local chars = GetPlayerTargets() -- returns alive, downed
    for _, char in ipairs(chars) do
        party[char] = GetCharacterSnapshot(char)
    end
    return party
end

local function GetBattlefieldContext()
    local context = {
        playersOnHighGround = 0,
        clusteredEnemies = false,
        averagePlayerHeight = 0
    }
    -- Rough height and clustering analysis - use Osi for safety
    local players = GetPlayerTargets()
    local heights = {}
    for _, p in ipairs(players) do
        local px, py, pz = safeCall(Osi.GetPosition, getEntityUuid(p))
        if px then
            table.insert(heights, py or 0)
        end
    end
    if #heights > 0 then
        local sum = 0
        for _, h in ipairs(heights) do sum = sum + h end
        context.averagePlayerHeight = sum / #heights
    end
    return context
end

-- Get the list of spells the enemy actually has right now (from Combat Extender + base)
-- Capped at 20 to prevent lag from NPCs with excessive spells (e.g. 85+ from mod combinations)
-- All caches (AvailableSpellsCache, PositionCache, LOSCache, etc.) defined at top of file

local function GetEnemyAvailableSpells(enemyId)
    local resolved = getEntityUuid(enemyId)
    if AvailableSpellsCache[resolved] then return AvailableSpellsCache[resolved] end
    local e = safeCall(Ext.Entity.Get, resolved)
    if not e or not e.SpellBook or not e.SpellBook.Spells then return {} end
    -- Passive capping: limit spell count based on passive count (same place as spell list capping)
    local passiveCap = Settings.EnablePassiveCapping
    local maxSpells = 20
    if passiveCap and passiveCap > 0 and e.PassiveContainer and e.PassiveContainer.Passives then
        local passiveCount = #e.PassiveContainer.Passives
        if passiveCount >= passiveCap then
            maxSpells = passiveCap
        end
    end
    local book = {}
    for _, sp in ipairs(e.SpellBook.Spells) do
        if sp.Id and sp.Id.OriginatorPrototype then
            local spellId = sp.Id.OriginatorPrototype
            -- Never let Skynet pick "Dismiss Summon" (the base-game bonus action every
            -- summoned creature gets, letting it end its own summon early) as a combat
            -- action — a hostile summon voluntarily unsummoning itself mid-fight is always
            -- wrong. Filtered here so it's excluded from every downstream picking path
            -- (minion fast path and the full scoring pipeline alike), not just one of them.
            if not string.lower(spellId):find("dismiss") then
                book[#book + 1] = spellId
            end
        end
    end
    -- PASS #62: not "the first maxSpells of the book" any more (for a big book that was all common actions) —
    -- weapon attacks and the character's own spells come first. See Skynet_OrderSpellList.
    local list
    if Skynet_OrderSpellList then
        list = Skynet_OrderSpellList(book, maxSpells)
    else
        list = {}
        for i = 1, math.min(#book, maxSpells) do list[i] = book[i] end
    end
    AvailableSpellsCache[resolved] = list
    return list
end

-- ==================== TACTICAL SCORING ENGINE ====================

-- ==================== ADVANCED TACTICAL SCORING ====================

-- Classify a spell using broad pattern recognition + Ext.Stats.Get for accurate data
local function ClassifySpell(spellId)
    local s = string.lower(spellId or "")
    local cat = { damage = 0, control = 0, utility = 0, selfbuff = 0, mobility = 0, summon = 0, wildshape = 0, aoe = 0, single = 0 }

    -- Get actual spell properties from game data
    local props = GetSpellProperties(spellId)

    -- ==================== LAYER 1: GAME DATA (Ext.Stats.Get) ====================
    -- This is the most reliable source — covers EVERY spell in the game
    if props then
        local vi = props.verbalIntent
        local stype = props.spellType
        local school = props.spellSchool

        -- VerbalIntent is the primary classifier
        if vi == "Damage" then
            cat.damage = 8
        elseif vi == "Healing" then
            cat.selfbuff = 7
        elseif vi == "Buff" then
            cat.selfbuff = 7
        elseif vi == "Debuff" then
            cat.control = 6
        elseif vi == "Control" then
            cat.control = 8
        elseif vi == "Summon" then
            cat.summon = 8
        elseif vi == "Movement" then
            cat.mobility = 7
        elseif vi == "Utility" then
            local sl2 = string.lower(props.id or "")
            if stype == "teleportation" or sl2:find("ethereal") or sl2:find("misty") or
               sl2:find("teleport") or sl2:find("dimension") or sl2:find("blink") or
               sl2:find("shadow") or sl2:find("astral") or sl2:find("warp") then
                cat.mobility = 7
            elseif stype == "shout" then
                cat.selfbuff = 5
            else
                cat.selfbuff = 4
            end
        end

        -- SpellType adds AoE/single details
        if stype == "zone" or stype == "projectilestrike" or stype == "wall" then
            cat.aoe = 7
            if cat.damage == 0 then cat.damage = 5 end
        elseif stype == "projectile" or stype == "target" then
            cat.single = 6
            if cat.damage == 0 then cat.damage = 5 end
        elseif stype == "shout" then
            cat.aoe = 4
            if cat.selfbuff == 0 then cat.selfbuff = 5 end
        elseif stype == "rush" then
            cat.damage = math.max(cat.damage, 5)
            cat.mobility = math.max(cat.mobility, 4)
        elseif stype == "throw" then
            cat.damage = math.max(cat.damage, 6)
        elseif stype == "teleportation" then
            cat.mobility = math.max(cat.mobility, 7)
        end

        -- AreaRadius adds AoE detail
        if props.areaRadius > 2 then
            cat.aoe = math.max(cat.aoe, 6)
        end

        -- SpellSchool fills in when VerbalIntent is empty
        if vi == "" or vi == "None" or vi == nil then
            if school == "Evocation" then cat.damage = math.max(cat.damage, 6)
            elseif school == "Conjuration" then cat.damage = math.max(cat.damage, 5)
            elseif school == "Enchantment" then cat.control = math.max(cat.control, 6)
            elseif school == "Illusion" then cat.control = math.max(cat.control, 5)
            elseif school == "Necromancy" then cat.damage = math.max(cat.damage, 5)
            elseif school == "Abjuration" then cat.selfbuff = math.max(cat.selfbuff, 6)
            elseif school == "Transmutation" then cat.selfbuff = math.max(cat.selfbuff, 5)
            elseif school == "Divination" then cat.utility = math.max(cat.utility, 4)
            end
        end

        -- SpellFlags as last resort
        if cat.damage == 0 and cat.control == 0 and cat.selfbuff == 0 and cat.mobility == 0 then
            if props.spellFlags["IsJump"] then
                cat.mobility = 8
            elseif props.spellFlags["IsAttack"] then
                cat.damage = 6
            elseif props.spellFlags["IsMelee"] then
                cat.damage = 5
            elseif props.spellFlags["IsConcentration"] then
                cat.control = 4
            else
                cat.utility = 3
            end
        end
    end

    -- ==================== LAYER 2: NAME PATTERNS ====================
    -- These ADD detail (AoE/single) or OVERRIDE when game data is empty
    -- They don't overwrite game data — they only set values where cat is still 0

    -- DAMAGE name patterns (add AoE/single hints)
    if s:find("fireball") or s:find("lightning") or s:find("scorching") or s:find("magicmissile") or
       s:find("magic_missile") or s:find("icestorm") or s:find("shatter") or s:find("chain") or
       s:find("smite") or s:find("bolt") or s:find("blast") or s:find("eldritch") or
       s:find("missile") or s:find("arrow") or s:find("spear") or s:find("throw") or
       s:find("strike") or s:find("slash") or s:find("cleave") or s:find("whirlwind") or
       s:find("burn") or s:find("flame") or s:find("frost") or s:find("ice") or
       s:find("thunder") or s:find("acid") or s:find("poison") or s:find("necrot") or
       s:find("radiant") or s:find("psychic") or s:find("force") or s:find("cold") or
       s:find("shock") or s:find("zap") or s:find("bite") or s:find("claw") or
       s:find("punch") or s:find("kick") or s:find("hit") or s:find("attack") or
       s:find("damage") or s:find("drain") or s:find("inflict") or s:find("wound") or
       s:find("hex") or s:find("curse") or s:find("wrath") or
       s:find("fiery") or s:find("rays_of") or s:find("searing") or
       s:find("repulsion") or s:find("lunar_smite") or s:find("grave_repulsion") or
       s:find("electric_arc") or s:find("phase_bolt") or s:find("blazing_dive") or
       s:find("horizon") or s:find("weapon_storm") or s:find("polar_ray") or
       s:find("thunderclap") or s:find("word_of_radiance") or
       s:find("vitriolic") or s:find("dragon_breath") or s:find("dragons_breath") or
       s:find("mind_sliver") or s:find("mind_spike") or s:find("steelwind") or
       s:find("storm_of_radiance") or s:find("synaptic_static") or
       s:find("phantasmal") or s:find("dissonant") or
       s:find("harm") or s:find("fire_bolt") or
       s:find("sacred_flame") or s:find("toll_the_dead") or
       s:find("poison_spray") or s:find("acid_splash") or
       s:find("bone_chill") or s:find("shocking_grasp") or
       s:find("ray_of_frost") or s:find("thorn_whip") or
       s:find("vicious_mockery") or s:find("booming_blade") or
       s:find("bursting_sinew") or s:find("thunderwave") or
       s:find("arms_of_hadar") or s:find("burning_hands") or
       s:find("chromatic_orb") or s:find("colour_spray") or
       s:find("dissonant_whispers") or
       s:find("sunbeam") or s:find("sunburst") or
       s:find("delayed_blast") or s:find("meteor") or
       s:find("blade_barrier") or s:find("cloudkill") or
       s:find("insect") or s:find("call_lightning") or
       s:find("ice_storm") or s:find("sleet_storm") or
       s:find("flame_strike") or s:find("finger_of_death") or
       s:find("circle_of_death") or s:find("power_word") or
       s:find("produced_flame") or s:find("produce_flame") then
        if cat.damage == 0 then cat.damage = 10 end
        -- AoE hints from name
        if s:find("ball") or s:find("storm") or s:find("wave") or s:find("cloud") or
           s:find("cone") or s:find("zone") or s:find("nova") or
           s:find("breath") or s:find("pulse") or s:find("explosion") or
           s:find("burning_hands") or s:find("colour_spray") or s:find("arms_of_hadar") or
           s:find("shatter") or s:find("icestorm") or s:find("sleet_storm") or
           s:find("sunburst") or s:find("meteor") or s:find("blade_barrier") or
           s:find("flame_strike") or s:find("circle") or s:find("storm_of") or
           s:find("cloudkill") or s:find("insect") then
            cat.aoe = math.max(cat.aoe, 6)
        end
        -- Single target hints
        if s:find("bolt") or s:find("ray") or s:find("missile") or s:find("smite") or
           s:find("arrow") or s:find("strike") or s:find("eldritch") or
           s:find("fire_bolt") or s:find("bone_chill") or
           s:find("sacred_flame") or s:find("toll_the_dead") or
           s:find("shocking_grasp") or s:find("ray_of_frost") or
           s:find("vicious_mockery") or s:find("booming_blade") or
           s:find("chromatic_orb") or s:find("mind_sliver") or
           s:find("fiery_bolt") or s:find("dissonant") or
           s:find("lunar_smite") or s:find("searing_smite") or
           s:find("hex") or s:find("finger_of_death") or
           s:find("power_word") then
            cat.single = math.max(cat.single, 7)
        end
    end

    -- CONTROL name patterns
    if s:find("hold") or s:find("command") or s:find("fear") or s:find("entangle") or
       s:find("web") or s:find("silence") or s:find("blind") or s:find("sleep") or
       s:find("stun") or s:find("paraly") or s:find("banish") or s:find("slow") or
       s:find("charm") or s:find("dominate") or
       s:find("confus") or s:find("taunt") or s:find("daze") or s:find("grov") or
       s:find("root") or s:find("snare") or s:find("trap") or s:find("bind") or
       s:find("chains") or s:find("prone") or s:find("knock") and s:find("down") or
       s:find("shove") or s:find("push") or s:find("pull") or s:find("disarm") or
       s:find("deafen") or s:find("obscure") or s:find("darkness") or
       s:find("fog") or s:find("grease") or
       s:find("tasha") or s:find("hypnotic") or s:find("pattern") or s:find("suggestion") or
       s:find("geas") or s:find("compel") or s:find("bane") or
       s:find("petrify") or s:find("frighten") or
       s:find("psionic_suggestion") or
       s:find("wicked_coercion") or s:find("mind_mastery") or
       s:find("hellfire_curse") or s:find("curse_of") or
       s:find("antilife") or s:find("regal_presence") or
       s:find("synaptic_pulse") or s:find("repelling_pulse") then
        if cat.control == 0 then cat.control = 9 end
    end

    -- SELF-BUFF name patterns
    if s:find("shield") or s:find("armor") or s:find("mage") and s:find("armor") or
       s:find("blur") or s:find("mirror") or s:find("invis") or s:find("haste") or
       s:find("herois") or s:find("bless") or s:find("aid") or s:find("false") and s:find("life") or
       s:find("absorb") or s:find("resist") or s:find("protect") or s:find("ward") or
       s:find("barrier") or s:find("barkskin") or s:find("stoneskin") or
       s:find("globe") or s:find("immun") or s:find("freedom") or s:find("longstride") or
       s:find("feather") or s:find("sanctuary") or s:find("rage") or s:find("enrag") or
       s:find("divine_favour") or s:find("divine_favor") or
       s:find("blade_ward") or s:find("armour_of") or s:find("armor_of") or
       s:find("shield_of_faith") or s:find("shield_of_screams") or
       s:find("false_life") or s:find("arcane_vigor") or
       s:find("aura_of") or s:find("circle_of_power") or
       s:find("darkvision") or s:find("friends") or
       s:find("guidance") or s:find("resistance") or
       s:find("thaumaturgy") or s:find("true_strike") or
       s:find("boon_of_servitude") or s:find("sanctuary_of_loss") or
       s:find("corrosive_body") then
        if cat.selfbuff == 0 then cat.selfbuff = 8 end
    end
    -- Healing name patterns
    if s:find("heal") or s:find("cure") or s:find("restor") or s:find("regenerate") or
       s:find("lay_on_hands") or s:find("healing_word") or s:find("mass_healing") or
       s:find("the_dead_wastes") then
        if cat.selfbuff < 7 then cat.selfbuff = 7 end
    end

    -- MOBILITY name patterns
    if s:find("jump") or s:find("leap") or s:find("fly") or s:find("misty") or
       s:find("teleport") or s:find("dash") or s:find("disengage") or s:find("enhance") or
       s:find("longstrid") or s:find("expeditious") or s:find("spiderclimb") or
       s:find("levitat") or s:find("dimension") or s:find("ethereal") or
       s:find("blink") or s:find("shadow") or s:find("burrow") or
       s:find("displace") or s:find("warp") or s:find("hellcrawl") or
       s:find("astral") or s:find("dark currents") or s:find("benign transposition") or
       s:find("fleeting dream") or s:find("shifting winds") or
       s:find("supernatural attraction") or s:find("wild magic") or
       s:find("mobile flourish") or
       s:find("step") and not s:find("thunder") then
        if cat.mobility == 0 then cat.mobility = 8 end
        if cat.selfbuff == 0 then cat.selfbuff = 6 end
    end

    -- SUMMON name patterns
    if s:find("summon") or s:find("conjure") or s:find("familiar") or s:find("animate") or
       s:find("undead") or s:find("skeleton") or s:find("zombie") or s:find("spirit") or
       s:find("totem") or s:find("call_of") or s:find("umbral_ally") or
       s:find("minor_elemental") or s:find("major_elemental") then
        if cat.summon == 0 then cat.summon = 10 end
    end

    -- WILDSHAPE name patterns
    if s:find("wildshape") or s:find("shapechange") or
       s:find("polymorph") or s:find("alterself") or s:find("disguise") or
       s:find("careful_what_you_wish") then
        if cat.wildshape == 0 then cat.wildshape = 10 end
        if cat.selfbuff == 0 then cat.selfbuff = 5 end
    end

    return cat
end

-- ==================== OBSTACLE HANDLING (Globe, Walls, Doors) ====================

local GLOBE_MAIN_TEMPLATE = "d3da7020-9c7a-47bb-84cc-c69e41a758cd"
local GLOBE_RIM_BLOCKER = "OBJ_GlobeOfInvulnurability_Rim_Blocker"
local GLOBE_STATUS = "GOI_GLOBE_VISUAL"

local function FindObstaclesInCombat()
    local obstacles = {
        globes = {},
        walls = {},
        doors = {},
        other = {}
    }

    local ok, allObjects = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("ServerItem") end)
    if not ok or type(allObjects) ~= "table" then return obstacles end

    for _, obj in ipairs(allObjects) do
        if obj then
            -- Get template info via ServerItem component
            local tplId = ""
            local name = ""
            if obj.ServerItem then
                tplId = tostring(obj.ServerItem.TemplateId or "")
            end
            if obj.DisplayName and obj.DisplayName.Name then
                name = tostring(obj.DisplayName.Name)
            end

            -- Find Globe
            if tplId == GLOBE_MAIN_TEMPLATE or string.find(name, "Globe_Of_Invulnurability") or string.find(name, "GlobeOfInvulnurability") then
                table.insert(obstacles.globes, obj)
            end

            -- Check for Globe visual status
            if obj.StatusContainer and obj.StatusContainer.Statuses then
                for _, st in ipairs(obj.StatusContainer.Statuses) do
                    local stId = type(st) == "string" and st or (type(st) == "table" and st.StatusId or "")
                    if stId == GLOBE_STATUS then
                        table.insert(obstacles.globes, obj)
                        break
                    end
                end
            end

            -- General destructible objects (walls, doors)
            if name ~= "" then
                local n = string.lower(name)
                if n:find("wall") or n:find("stone") then
                    table.insert(obstacles.walls, obj)
                elseif n:find("door") or n:find("gate") then
                    table.insert(obstacles.doors, obj)
                end
            end
        end
    end

    return obstacles
end

local function IsGlobeProtectingPlayers(globeObj, playerParty)
    if not globeObj then return false end
    local gpos = nil
    if globeObj.Transform and globeObj.Transform.Transform and globeObj.Transform.Transform.Translate then
        gpos = globeObj.Transform.Transform.Translate
    else
        gpos = {0,0,0}
    end
    for _, p in pairs(playerParty) do
        if p.position then
            local dist = math.sqrt( (p.position[1]-gpos[1])^2 + (p.position[3]-gpos[3])^2 )
            if dist < 6 then return true end  -- roughly inside or near the dome
        end
    end
    return false
end

-- Get detailed player threats (using your data: roguetest passives, Cahoot spells, 5E etc.)
local function AnalyzePlayerThreats(party)
    local threats = {
        hasConcentration = false,
        isStealthHeavy = false,
        lowWisdom = false,
        highGround = false,
        clustered = false,
        recentControl = 0,
        dangerousPassives = {}
    }

    for id, snap in pairs(party) do
        if snap.statuses then
            for _, st in ipairs(snap.statuses) do
                local sl = string.lower(st)
                if sl:find("concentration") then threats.hasConcentration = true end
            end
        end
        if snap.passives then
            for _, p in ipairs(snap.passives) do
                local pl = string.lower(p)
                if pl:find("rogue") or pl:find("sneak") or pl:find("invisible") then 
                    threats.isStealthHeavy = true 
                    table.insert(threats.dangerousPassives, p)
                end
                if pl:find("war") or pl:find("paladin") or pl:find("smite") then
                    threats.dangerousPassives[#threats.dangerousPassives+1] = p
                end
            end
        end
        if snap.classes then
            for _, c in ipairs(snap.classes) do
                if c:lower():find("rogue") then threats.isStealthHeavy = true end
            end
        end
        -- Height
        if snap.position and snap.position[2] > 2 then threats.highGround = true end
    end

    -- Recent actions
    if CombatHistory then
        for spell, count in pairs(CombatHistory) do
            local sl = string.lower(spell)
            if sl:find("hold") or sl:find("command") or sl:find("fear") then
                threats.recentControl = threats.recentControl + count
            end
        end
    end

    return threats
end

local function GetEnemyCapabilities(enemyId)
    local resolved = getEntityUuid(enemyId)
    local e = safeCall(Ext.Entity.Get, resolved)
    if not e then return {strength=10, canJump=false, canFly=false, movement=6} end

    local str = 10
    if e.Stats then
        local strOk, strVal = pcall(function() return e.Stats.Strength end)
        if strOk and strVal then str = strVal end
    end

    local canJump = false
    local canFly = false
    local spells = GetEnemyAvailableSpells(enemyId)
    for _, s in ipairs(spells) do
        local sl = string.lower(s)
        if sl:find("jump") or sl:find("leap") then canJump = true end
        if sl:find("fly") or sl:find("flight") then canFly = true end
    end

    local movement = 6
    if e.Stats then
        local msOk, msVal = pcall(function() return e.Stats.MovementSpeed end)
        if msOk and msVal then movement = msVal / 1.5 end
    end

    return {strength = str, canJump = canJump, canFly = canFly, movement = movement}
end

-- Extend scoring to consider obstacles
-- Call this inside ScoreSpellForEnemy or as additional factor
local function ScoreVsObstacles(spellId, enemyCaps, obstacles, playerParty)
    local score = 0
    local cat = ClassifySpell(spellId)
    local s = string.lower(spellId or "")

    local hasGlobe = #obstacles.globes > 0 and IsGlobeProtectingPlayers(obstacles.globes[1], playerParty)

    if hasGlobe then
        -- Globe is special: immune to physical, resistant to most
        if cat.damage > 0 and not (s:find("bludgeon") or s:find("pierce") or s:find("slash")) then
            score = score + 8  -- Prefer non-physical damage vs Globe
        end
        if s:find("disintegrate") or s:find("force") or s:find("eldritch") then
            score = score + 12  -- Excellent vs Globe
        end
        -- If enemy is weak (low str, no good damage), don't waste
        if enemyCaps.strength < 14 and cat.damage < 5 then
            score = score - 5
        end
    end

    -- General wall/door
    if #obstacles.walls > 0 or #obstacles.doors > 0 then
        if cat.damage > 0 and (s:find("fire") or s:find("force") or s:find("acid") or s:find("lightning")) then
            score = score + 5  -- Good destruction spells
        end
        -- Movement bypass
        if (enemyCaps.canJump or enemyCaps.canFly) and (s:find("jump") or s:find("fly") or s:find("teleport") or s:find("misty")) then
            score = score + 4  -- Better to bypass than smash if capable
        end
        -- Low maneuverability -> prefer smash if strong
        if enemyCaps.strength > 16 and cat.damage > 6 and not (enemyCaps.canJump or enemyCaps.canFly) then
            score = score + 6
        end
    end

    return score
end

-- Score a spell - now very tactical and uses your data + environmental awareness
local function ScoreSpellForEnemy(spellId, enemySnap, playerParty, battlefield, threats, obstacles, enemyCaps)
    local score = 0
    local cat = ClassifySpell(spellId)
    local s = string.lower(spellId or "")
    local props = GetSpellProperties(spellId)

    -- Base damage preference
    score = score + cat.damage * 1.5
    score = score + cat.aoe * 1.2
    score = score + cat.single * 1.0

    -- Concentration check: if enemy is already concentrating, heavily penalize recasting.
    -- PASS #35: now reads the shared Skynet_ConcentrationStatusNames list (plus the real
    -- ConcentrationComponent check) via Skynet_IsAlreadyConcentrating instead of its own
    -- separate copy of the status list, so this and the new hard gate in ChooseBestAction
    -- (Step 2's bucket split) can't drift out of sync. This -50 penalty is now mostly a
    -- backstop for the "desperate, nothing else at all is usable" fallback path, since the
    -- hard gate normally keeps a concentration-conflicting spell out of contention
    -- entirely whenever anything else is available. See Maintenance history pass #35.
    if props and props.isConcentration and enemySnap and enemySnap.uuid then
        if Skynet_IsAlreadyConcentrating(enemySnap.uuid) then
            score = score - 50  -- heavy penalty for recasting concentration
        end
    end

    -- Control good if player has concentration or is threatening
    if cat.control > 0 then
        if threats.hasConcentration then score = score + 8 end
        if threats.recentControl < 2 then score = score + 5 end  -- Don't spam if already doing it
        if #playerParty > 2 then score = score + 3 end -- good vs groups
    end

    -- Self-buff: penalize unless situationally needed
    if cat.selfbuff > 0 and cat.mobility == 0 then
        if threats.highGround and (enemySnap.position[2] or 0) < battlefield.averagePlayerHeight then
            score = score + 4  -- needed to close gap
        else
            score = score - 10  -- usually useless
        end
    end

    -- Mobility: context-dependent (not blindly penalized anymore)
    if cat.mobility > 0 then
        -- Check if mobility is actually useful right now
        local onHazard, hazardReason = HasDangerousSurfacesBetween(enemySnap.uuid, nil)
        local hasObstacles = #obstacles.walls > 0 or #obstacles.doors > 0
        local canBypass = enemyCaps and enemyCaps.canJump or enemyCaps and enemyCaps.canFly

        if onHazard or hasObstacles then
            -- Mobility is GOOD when there are obstacles or hazards to bypass
            score = score + 8
        elseif canBypass then
            -- Already can bypass, no need for more mobility
            score = score - 8
        else
            -- No obstacles, mobility is still usually a waste
            score = score - 5
        end
    end

    -- Summon: good to have one, not worth spamming
    if cat.summon > 0 then
        score = score + 6
    end

    -- Wildshape: situational. Optionally never chosen for enemies (MCM: EnemyAllowWildshape).
    if cat.wildshape > 0 then
        if Skynet_WildshapeBlocked(enemySnap and enemySnap.uuid or nil, cat, spellId) then
            score = score - 1000
        else
            score = score + 3
        end
    end

    -- ===== GRIT AND GLORY SPELL BONUS =====
    -- If target has injuries, prioritize high-damage spells to trigger more injuries
    if enemySnap and enemySnap.uuid and playerParty then
        for _, player in pairs(playerParty) do
            local playerUuid = player.uuid or player
            if HasGGInjury(playerUuid) then
                -- Target has injuries: high-damage spells are more valuable
                if cat.damage >= 3 then
                    score = score + 12  -- big damage = more injury procs
                    log("  GRIT&GLORY SPELL: " .. tostring(spellId) .. " vs injured target +" .. tostring(12))
                elseif cat.damage >= 2 then
                    score = score + 6   -- moderate damage
                end
                -- AoE is extra valuable when enemies are injured
                if cat.aoe > 0 and props and props.areaRadius > 0 then
                    score = score + 8   -- AoE can injure multiple targets
                end
                break  -- only check first player for scoring
            end
        end
    end

    -- ===== ADDITIONAL SPELL INTERACTIONS SPELL BONUS =====
    -- Bonus for spells that exploit susceptibility/exposure on targets
    if props and playerParty then
        local spellDmgTypes = GetSpellDamageTypes(spellId)
        for _, player in pairs(playerParty) do
            local playerUuid = player.uuid or player
            for _, dmgType in ipairs(spellDmgTypes) do
                -- Direct damage bonus from susceptibility/exposure
                local asiBonus = GetASIDamageBonus(playerUuid, dmgType)
                if asiBonus > 0 then
                    local bonusScore = asiBonus * 40  -- 10 for susceptible, 20 for exposed
                    score = score + bonusScore
                    log("  ASI SPELL: " .. tostring(spellId) .. " vs " .. tostring(dmgType) .. " vulnerable target +" .. tostring(bonusScore))
                end
                -- PASS #35: real, engine-level Vulnerable (double damage) from
                -- DamageCombos/vanilla/any mod — see Skynet_IsRealVulnerable. This is what
                -- makes ScoreSpellForEnemy actually PREFER picking a spell of the damage
                -- type a target is really vulnerable to, not just react to it after the
                -- fact via targeting alone.
                if Skynet_IsRealVulnerable(playerUuid, dmgType) then
                    score = score + 25
                    log("  REAL VULNERABLE SPELL: " .. tostring(spellId) .. " vs " .. tostring(dmgType) .. " Vulnerable target +25")
                end
            end
            -- Bonus for spells that create elemental combos
            local createsVuln, vulnType, _ = SpellCreatesVulnerability(spellId)
            if createsVuln and vulnType then
                local conditions = GetASIActiveConditions(playerUuid)
                for status, info in pairs(conditions) do
                    if info.damageType == vulnType then
                        score = score + 15  -- bonus for combo setup
                        log("  ASI COMBO: " .. tostring(spellId) .. " chains with " .. tostring(status) .. " +" .. tostring(15))
                        break
                    end
                end
            end
        end
    end

    -- PASS #43: ROPE TIE-UP GRAPPLE LEAD-IN — for a small/sneaky enemy who's currently
    -- carrying Gray's Bondage's rope (OBJ_Rope_Pier), nudge Target_Grapple a bit higher so
    -- a natural "grapple this turn, tie up next turn" sequence emerges on its own. This
    -- mirrors the user's own apcs_RestSystem design: while grappling a target, the rope
    -- tie-up attempt skips the victim's interrupt/counter-attack entirely (Target_apcs_
    -- Rope_TieUp_Grappled is unconditional), so for an enemy with limited action economy
    -- or that the party can't easily hit back (two-action-point or high-AC enemies), a
    -- grapple first is a genuinely safer setup move. Deliberately a SMALL nudge (+10, well
    -- under the +25 "real vulnerable" bonus above) and NOT a hard-scripted two-turn plan —
    -- Target_Grapple only shows up as a Skynet-scoreable candidate at all when the
    -- enemy's spellbook actually has it (e.g. DrKekyll_GrapplingFramework), and the rope
    -- tie-up action itself remains out of this scoring pipeline entirely (see the
    -- onTurnStarted deferral gate and Skynet_IsSmallRopeTieUpCandidate above — it's a
    -- native AiUseCombatHelper item action, not a spellbook spell). See Maintenance
    -- history pass #43.
    --
    -- PASS #52: extended to medium/large-tier casters too, gated on the same risk-aware
    -- Skynet_ShouldGrappleBeforeTieUp helper Priority 0.75 now uses (see that function's own
    -- comment and Skynet_TryApcsRopeTieUp's big comment for the full reasoning) — unlike
    -- small-tier, grappling first costs a medium/large caster a whole extra turn, so it's
    -- only worth nudging toward when the interrupt risk looks genuinely worth avoiding. This
    -- scoring nudge and Priority 0.75's own 40%-per-turn roll are complementary, not
    -- redundant: this one only matters on the turns (or for the enemies) Priority 0.75's roll
    -- doesn't itself fire, giving Grapple a fair shot at being chosen as the best action on
    -- its own scoring merits too. See Maintenance history pass #52.
    if s == "target_grapple" and enemySnap and enemySnap.uuid then
        local isSmallRopeCandidate = Skynet_IsSmallRopeTieUpCandidate(enemySnap.uuid)
        local shouldLeadIn = isSmallRopeCandidate
        if not shouldLeadIn then
            local tierOkLeadIn, tierLeadIn = pcall(function()
                if Mods and Mods.apcs_RestSystem and Mods.apcs_RestSystem.APCSRopeTieUp
                   and Mods.apcs_RestSystem.APCSRopeTieUp.GetTieUpDCTier then
                    return Mods.apcs_RestSystem.APCSRopeTieUp.GetTieUpDCTier(enemySnap.uuid)
                end
                return nil
            end)
            if tierOkLeadIn and tierLeadIn == "medium_large" then
                shouldLeadIn = Skynet_ShouldGrappleBeforeTieUp(enemySnap.uuid)
            end
        end
        if shouldLeadIn then
            local ropeOk2, ropeItem2 = pcall(function() return Osi.GetItemByTagInInventory("OBJ_Rope_Pier", enemySnap.uuid) end)
            if ropeOk2 and ropeItem2 ~= nil and ropeItem2 ~= "" then
                score = score + 10
                log("  ROPE TIE-UP LEAD-IN: " .. tostring(spellId) .. " sets up a tie-up attempt +10" ..
                    (isSmallRopeCandidate and "" or " (risk-aware: medium/large)"))
            end
        end
    end

    -- Synergy with enemy's own kit (from CE config + Cahoot)
    if enemySnap.passives then
        for _, p in ipairs(enemySnap.passives) do
            local pl = string.lower(p)
            if (pl:find("conquest") or pl:find("aura")) and cat.control > 0 then
                score = score + 6  -- fear/control synergizes with aura
            end
            if (pl:find("paladin") or pl:find("smite")) and cat.damage > 0 and s:find("smite") then
                score = score + 7  -- smite on hit is great
            end
            if pl:find("wizard") or pl:find("mage") and cat.damage > 0 then
                score = score + 4
            end
        end
    end

    -- Player loadout counters (from ModsttoConsider/roguetest/Cahoot data)
    if threats.isStealthHeavy and (s:find("see") or s:find("true") or s:find("blind")) then
        score = score + 9  -- hard counter to roguetest stealth
    end
    if threats.hasConcentration and cat.control > 0 then
        score = score + 5  -- break it
    end

    -- Position/height (your request)
    if threats.highGround and cat.damage > 0 and cat.mobility == 0 then
        score = score + 3  -- punish height with ranged/AoE
    end
    if battlefield and battlefield.clustered and cat.aoe > 0 then
        score = score + 6
    end

    -- Pull/displacement spell bonus: these CREATE clustering for follow-up AoEs
    if s:find("black_hole") or s:find("blackhole") or
       s:find("pull") or s:find("drag") or
       s:find("grasp") or s:find("tentacle") or s:find("displace") then
        -- Bonus scales with how many enemies could be pulled
        local pullTargets = 0
        if enemySnap.uuid and playerParty then
            for uuid, player in pairs(playerParty or {}) do
                if player and (player.uuid or uuid) then
                    local targetUuid = player.uuid or uuid
                    local dist = GetDistanceBetween(enemySnap.uuid, targetUuid)
                    if dist <= (props and props.rangeMeters or 18) + 6 then
                        pullTargets = pullTargets + 1
                    end
                end
            end
        end
        if pullTargets >= 2 then
            score = score + (pullTargets * 10) -- big bonus for multi-target pulls
        elseif pullTargets == 1 then
            score = score + 5
        end
    end

    -- Avoid repeats (memory from CombatHistory)
    if CombatHistory[spellId] and CombatHistory[spellId] > 1 then
        score = score - (CombatHistory[spellId] * 3)
    end

    -- ===== PLAYER BEHAVIOR PROFILE ADAPTATION (pass #14) =====
    -- PlayerProfile has been recorded across combats since early in this mod's history, but
    -- until now nothing ever read it back to actually change enemy behavior — the user
    -- explicitly asked for this to finally be wired in. Guarded on a minimum sample size
    -- (combats_analyzed and total tracked melee/ranged actions) so a single early fight, or a
    -- fresh profile with barely any data, can't overcommit enemies to a bias that doesn't
    -- really reflect how this player plays yet. The signal used here — melee vs. ranged lean —
    -- is party-wide (PlayerProfile has no per-character breakdown, so this can't target a
    -- specific "the healer" character; see the profile's own data shape), but it's a real,
    -- well-justified tactical adaptation: a kiting, ranged-heavy party rewards enemies for
    -- closing distance and locking a target down, while a melee-heavy party rewards enemies
    -- for keeping their own range and using AoE, mirroring genuine 5e counter-play.
    if PlayerProfile.combats_analyzed >= 3 then
        local pStyle = PlayerProfile.style
        local totalStyleActions = (pStyle.melee_count or 0) + (pStyle.ranged_count or 0)
        if totalStyleActions >= 6 then
            local rangedRatio = pStyle.ranged_count / totalStyleActions
            if rangedRatio >= 0.65 then
                -- Party leans heavily ranged/kiting.
                if cat.mobility > 0 then
                    score = score + 4
                end
                if cat.control > 0 and (s:find("web") or s:find("entangle") or s:find("restrain") or s:find("hold") or s:find("grapple") or s:find("root")) then
                    score = score + 4
                end
            elseif rangedRatio <= 0.35 then
                -- Party leans heavily melee.
                if props and props.isRanged then
                    score = score + 4
                end
                if cat.aoe > 0 then
                    score = score + 2
                end
            end
        end
    end

    -- Bias toward damage over pure disable (to avoid "just disabling")
    if cat.damage > 0 and cat.control > 0 then
        score = score + 2  -- hybrid is good
    elseif cat.control > 0 and cat.damage == 0 then
        score = score - 1  -- pure control less preferred unless needed
    end

    -- Obstacle factor (Globe, walls, doors from your Globe mod and base game)
    if obstacles and enemyCaps then
        score = score + ScoreVsObstacles(spellId, enemyCaps, obstacles, playerParty)
    end

    -- ==================== ENVIRONMENTAL FACTORS ====================

    -- Line of sight: check if at least one player is visible and reachable
    if props then
        local anyReachable = false
        local bestReachableDist = 999
        for uuid, player in pairs(playerParty or {}) do
            if player and (player.uuid or uuid) then
                -- PASS #34: this checked raw IsTargetReachable only, which (unlike
                -- IsValidTarget) does NOT exclude Sanctuary'd/hidden/allied targets — a
                -- Sanctuary'd party member sitting in the open could still score as
                -- "reachable" here and inflate/select a spell that no real target actually
                -- exists for once PickBestTarget (which DOES gate on IsValidTarget) runs at
                -- execution time. Scoring-only, so this never caused an actual illegal
                -- attack, but it could misdirect spell selection toward something that turns
                -- out to have zero real targets. See Maintenance history pass #34.
                local pid = player.uuid or uuid
                local reachable, reason = IsValidTarget(enemySnap.uuid, pid) and IsTargetReachable(enemySnap.uuid, pid, spellId)
                if reachable then
                    anyReachable = true
                    local dist = GetDistanceBetween(enemySnap.uuid, player.uuid or uuid)
                    if dist < bestReachableDist then
                        bestReachableDist = dist
                    end
                end
            end
        end

        if not anyReachable then
            -- No player is reachable with this spell — heavy penalty
            score = score - 25
            log("  PENALTY: " .. spellId .. " has no reachable targets (LOS/range)")
        else
            -- Bonus for spells that can reach targets
            score = score + 5

            -- Range fit bonus: spell range closely matches distance to nearest target
            if props.rangeMeters > 0 and bestReachableDist <= props.rangeMeters then
                local rangeFit = bestReachableDist / props.rangeMeters
                if rangeFit > 0.3 and rangeFit < 0.8 then
                    score = score + 4 -- good range utilization
                end
            end
        end

        -- AoE bonus: check if multiple players are clustered within AoE radius
        if props.isAoE and props.areaRadius > 0 then
            local clusteredCount = 0
            for uuid, player in pairs(playerParty or {}) do
                if player and (player.uuid or uuid) then
                    local dist = GetDistanceBetween(enemySnap.uuid, player.uuid or uuid)
                    if dist <= props.areaRadius + props.rangeMeters then
                        clusteredCount = clusteredCount + 1
                    end
                end
            end
            if clusteredCount >= 2 then
                if not props.isSelfDamageAoE then
                    -- Safe AoE (doesn't damage caster): big preference
                    score = score + (clusteredCount * 12)
                    log("  SAFE AOE BONUS: " .. props.id .. " hits " .. clusteredCount .. " targets (no self-damage) +" .. tostring(clusteredCount * 12))
                else
                    -- Self-damaging AoE: smaller bonus, only if caster isn't in the cluster
                    score = score + (clusteredCount * 5)
                end
            end
        end

        -- Melee penalty if target is far away
        if props.isMelee and bestReachableDist > 3 then
            score = score - 15 -- can't reach with melee
        end

        -- Ranged bonus if target is far (better than melee at distance)
        if props.isRanged and bestReachableDist > 6 then
            score = score + 4
        end

        -- Pull/displacement spell bonus: these CREATE clustering for follow-up AoEs
        local sLower = string.lower(props.id or "")
        if sLower:find("black_hole") or sLower:find("blackhole") or
           sLower:find("pull") or sLower:find("drag") or
           sLower:find("grasp") or sLower:find("tentacle") then
            -- Bonus scales with how many enemies could be pulled
            local pullTargets = 0
            for uuid, player in pairs(playerParty or {}) do
                if player and (player.uuid or uuid) then
                    local dist = GetDistanceBetween(enemySnap.uuid, player.uuid or uuid)
                    if dist <= (props.rangeMeters or 18) + 6 then -- within pull range + offset
                        pullTargets = pullTargets + 1
                    end
                end
            end
            if pullTargets >= 2 then
                score = score + (pullTargets * 10) -- big bonus for multi-target pulls
                log("  PULL SYNERGY: " .. props.id .. " can cluster " .. pullTargets .. " targets for follow-up AoE +" .. tostring(pullTargets * 10))
            elseif pullTargets == 1 then
                score = score + 5 -- single target pull still useful
            end
        end
    end

    -- Surface awareness: if caster is on dangerous surface, prefer spells that don't require movement
    local casterOnHazard = HasDangerousSurfacesBetween(enemySnap.uuid, nil)
    if casterOnHazard then
        if props and props.isMelee then
            score = score - 12 -- don't try to move to melee if on fire
        elseif props and props.isRanged then
            score = score + 6 -- ranged is safe from hazards
        end
    end

    -- Height advantage: bonus for ranged spells when caster has high ground
    if props and props.isRanged and IsOnHighGround(enemySnap.uuid, nil) then
        score = score + 3
    end

    return math.max(0, score)
end

-- Detect if a creature is a minion (small, weak, many copies in combat)
-- Minions get a simplified AI path to avoid lag from full spell scoring on every copy
-- MinionCache defined at top of file for visibility
local function IsMinion(enemyId)
    if MinionCache[enemyId] ~= nil then return MinionCache[enemyId] end
    local resolved = getEntityUuid(enemyId)
    local e = safeCall(Ext.Entity.Get, resolved)
    if not e then MinionCache[enemyId] = false; return false end

    local lvl = 1
    local ok, val = pcall(function() return Osi.GetLevel(resolved) end)
    if ok and val then lvl = val end

    local spellCount = 0
    if e.SpellBook and e.SpellBook.Spells then
        for _ in pairs(e.SpellBook.Spells) do spellCount = spellCount + 1 end
    end

    local passiveCount = 0
    if e.PassiveContainer and e.PassiveContainer.Passives then
        for _ in pairs(e.PassiveContainer.Passives) do passiveCount = passiveCount + 1 end
    end

    local name = ""
    if e.DisplayName and e.DisplayName.Name then
        name = tostring(e.DisplayName.Name or ""):lower()
    end

    local templateName = ""
    if e.ServerCharacter and e.ServerCharacter.Template and e.ServerCharacter.Template.Name then
        templateName = tostring(e.ServerCharacter.Template.Name or ""):lower()
    end

    -- Check for summon/helper statuses (Projectile_AiHelper_SpiderlingSpawning applies this)
    local isSummon = false
    if e.StatusContainer and e.StatusContainer.Statuses and type(e.StatusContainer.Statuses) == "table" then
        for _, st in ipairs(e.StatusContainer.Statuses) do
            local statusId = ""
            if type(st) == "string" then statusId = st
            elseif type(st) == "table" and st.StatusId then statusId = st.StatusId end
            local sl = string.lower(statusId)
            if sl:find("ai_helper") or sl:find("summon") or sl:find("conjure") then
                isSummon = true
                break
            end
        end
    end

    -- Minion criteria: (low level OR few spells OR summoned) AND name/template matches
    local isMinion = false
    if lvl <= 3 and spellCount <= 4 then
        local minionPatterns = {"spiderling", "rat", "bat", "mephit", "imp", "zombie", "skeleton", "scout", "cultist", "goblin", "kobold", "gnoll", "spider_spawn", "phase_spider_spawn"}
        for _, pat in ipairs(minionPatterns) do
            if name:find(pat) or templateName:find(pat) then
                isMinion = true
                break
            end
        end
        -- Also treat as minion if very low level and few spells (generic small creature)
        if not isMinion and lvl <= 2 and spellCount <= 2 then
            isMinion = true
        end
    end
    -- Summoned creatures are always minions
    if isSummon and not isMinion then
        isMinion = true
    end

    MinionCache[enemyId] = isMinion
    return isMinion
end

local function ClearMinionCache()
    MinionCache = {}
end

-- Simplified AI for minions: pick the best damage spell, or melee, or dash
local function ChooseMinionAction(enemyId, enemySnap, available)
    local playerParty = PlayerContext or {}
    if next(playerParty) == nil then return nil end

    -- PASS #38: same combat-membership gate as the full (non-minion) path's targetParty
    -- overlay below — a minion should not treat a not-yet-engaged, sneaking party member as
    -- "the nearest player" any more than the full path should. See Maintenance history
    -- pass #38 for the reported bug this closes (also fixed here since a minion-classified
    -- low-tier attacker is just as capable of exhibiting it as any other enemy).
    local minionCombatantsOk, minionCombatants = pcall(Skynet_GetKnownCombatants, enemyId)
    local minionCombatantSet = {}
    if minionCombatantsOk and minionCombatants then
        for _, c in ipairs(minionCombatants) do
            local u = safeStr(c)
            if u ~= "" then minionCombatantSet[u] = true end
        end
    end

    -- Find nearest reachable player
    -- PASS #32: this was raw LOS + distance only, with no BG3 stealth/perception check at
    -- all — unlike the equivalent "nearest reachable" scan in the full (non-minion) path
    -- (Skynet.ChooseBestAction's own reachablePlayers/nearestReachablePlayer loop, which
    -- gates every candidate through IsValidTarget first). A minion enemy could end up
    -- treating a genuinely hidden/sneaking/invisible party member as "the nearest player,"
    -- skewing its distance-based mobility/ranged spell-choice scoring below off a target it
    -- has no in-fiction way to know about. See Maintenance history pass #32.
    local nearestDist = 999
    local nearestPlayer = nil
    for uuid, player in pairs(playerParty) do
        if player and (player.uuid or uuid) then
            local pid = player.uuid or uuid
            if Skynet_IsEligibleCombatant(safeStr(pid), minionCombatantSet) and IsValidTarget(enemyId, pid) then
                local dist = GetDistanceBetween(enemyId, pid)
                local los = CheckLineOfSight(enemyId, pid)
                if los and dist < nearestDist then
                    nearestDist = dist
                    nearestPlayer = pid
                end
            end
        end
    end
    if not nearestPlayer then return nil end

    -- Score spells simply: prefer damage, then utility
    local bestSpell = nil
    local bestScore = -999
    for _, spell in ipairs(available) do
        local cat = ClassifySpell(spell)
        local score = 0
        score = score + cat.damage * 2
        score = score + cat.control * 1.5
        score = score + cat.selfbuff * 0.5
        score = score + cat.aoe * 1.0
        -- Penalize mobility unless far from target
        if cat.mobility > 0 then
            if nearestDist > 9 then
                score = score + 8
            else
                score = score - 5
            end
        end
        -- Bonus for ranged when far
        local props = GetSpellProperties(spell)
        if props and props.isRanged and nearestDist > 6 then
            score = score + 4
        end
        if score > bestScore then
            bestScore = score
            bestSpell = spell
        end
    end

    -- Fallback: if no spell scored well, use dash to close distance
    if not bestSpell or bestScore < 5 then
        for _, spell in ipairs(available) do
            local sl = string.lower(spell)
            if sl:find("dash") then
                return spell
            end
        end
    end

    return bestSpell
end

-- Main smart chooser - ENVIRONMENT FIRST, then spell choice
function Skynet.ChooseBestAction(enemyId)
    local t0 = Ext.Utils.MonotonicTime and Ext.Utils.MonotonicTime() or nil
    local enemySnap = GetCharacterSnapshot(enemyId)
    -- PASS #62: the ordered list (weapon attacks and own spells first) that every other system uses; the raw
    -- snapshot book is only the fallback.
    local available = GetEnemyAvailableSpells(enemyId) or {}
    if #available == 0 then
        available = (enemySnap and enemySnap.spells) or {}
    end
    if #available == 0 then
        return nil
    end

    -- MINION FAST PATH: skip full pipeline for small creatures
    if IsMinion(enemyId) then
        local minionSpell = ChooseMinionAction(enemyId, enemySnap, available)
        if minionSpell then
            log("  MINION FAST PATH: " .. (enemySnap.name or "unknown") .. " -> " .. minionSpell)
            return minionSpell
        end
    end

    local playerPartyOk, playerParty = pcall(function() return PlayerContext or AnalyzePlayerParty() end)
    playerParty = playerPartyOk and playerParty or {}

    -- ==================== NON-PLAYER HOSTILE TARGETING, continued (pass #29) ====================
    -- See GetNonPlayerHostileTargets in Skynet_AITurn for the full write-up of the reported
    -- bug ("enemies gravitate to within ~5m of the player before doing anything logical" —
    -- Cambion Commander abandoning the Mind Flayer fight, goblins abandoning Aradin's party).
    -- That fix alone is NOT sufficient: `playerParty` above is PlayerContext, a table SHARED
    -- and CACHED across every acting character this round, containing ONLY real
    -- player-controlled characters. Step 2 below (reachableView classification) and Priority
    -- 2 below (mobility spell selection) both work exclusively off of it — a spell only
    -- counts as "reachable" here if it can hit a PLAYER, and the mobility fallback explicitly
    -- closes distance on "the nearest reachable player." So even with the Skynet_AITurn-level
    -- fix, a caster standing right next to its real, already-in-range, non-player target
    -- (a rival monster, an allied NPC party) still got told "no spells reach players" here
    -- and picked a mobility spell to chase the literal player down BEFORE PickBestTarget ever
    -- got a say — this reachability/scoring pass is what actually decided a move was needed
    -- at all. Since PlayerContext is shared, it cannot be mutated in place without leaking one
    -- caster's specific hostiles onto every other caster's turn — so build a per-caster
    -- overlay in a new local table instead, leaving PlayerContext itself untouched, and
    -- rebind (not mutate) `playerParty` to that overlay for the rest of this function. Cached
    -- per enemy per turn (piggybacking on LOSCache, which Skynet_AITurn already clears every
    -- turn — same technique as pass #24) since ChooseBestAction is called several times per
    -- turn (Self-Prepare, extra attacks, Phase 1/1.5/2 re-evaluation) and Skynet_GetKnownCombatants
    -- plus an Osi.IsEnemy pcall per combatant is not free. Applies uniformly to ally and enemy
    -- callers alike (Osi.IsEnemy(candidate, enemyId) correctly resolves to "is this an enemy of
    -- THIS caster" either way), which if anything makes an ally's own reachability check more
    -- accurate too (previously judged solely against its own side's player party). See
    -- Maintenance history pass #29.
    do
        local hostileCacheKey = "__hostileParty__" .. tostring(enemyId)
        local targetParty = LOSCache[hostileCacheKey]
        if not targetParty then
            local combatantsOk, combatants = pcall(Skynet_GetKnownCombatants, enemyId)
            combatants = (combatantsOk and combatants) or {}
            local combatantSet = {}
            for _, c in ipairs(combatants) do
                local u = safeStr(c)
                if u ~= "" then combatantSet[u] = true end
            end

            targetParty = {}
            -- PASS #38: only fold a real player-controlled character into THIS caster's own
            -- reachability/mobility-selection pool (Step 1 below, and the "close distance on
            -- nearest reachable player" fallback) if they're actually a combatant in its own
            -- fight — or a targetable Invoke Duplicity duplicate. Without this, this
            -- function's own scoring pass (built from the always-on PlayerContext/
            -- AnalyzePlayerParty() snapshot, independent of Skynet_AITurn's separate
            -- aliveTargets/downedTargets filtering) could still recommend closing distance on
            -- a party that hasn't engaged this caster at all — the actual reported bug (see
            -- Maintenance history pass #38): an enemy already fighting non-player NPCs
            -- started shadowing a still-sneaking, not-yet-in-combat party because THIS pass —
            -- not the later PickBestTarget/Skynet_FindNearestPlayer stage — is what decided a
            -- move toward them was worth making in the first place.
            for uuid, snap in pairs(playerParty) do
                if Skynet_IsEligibleCombatant(safeStr(uuid), combatantSet) then
                    targetParty[uuid] = snap
                end
            end
            for _, c in ipairs(combatants) do
                local huuid = safeStr(c)
                if huuid ~= "" and huuid ~= enemyId and not IsPlayerCharacterSafe(huuid) and not targetParty[huuid] then
                    local eOk, isEnemyOfThis = pcall(function() return Osi.IsEnemy(huuid, enemyId) end)
                    if eOk and isEnemyOfThis == 1 then
                        local deadOk, isDead = pcall(function() return Osi.IsDead(huuid) end)
                        if not deadOk or isDead ~= 1 then
                            local snapOk, snap = pcall(GetCharacterSnapshot, huuid)
                            if snapOk and snap then
                                targetParty[huuid] = snap
                            end
                        end
                    end
                end
            end
            LOSCache[hostileCacheKey] = targetParty
        end
        playerParty = targetParty
    end

    -- Use cached threats/battlefield (avoid re-analyzing per spell)
    local threats, battlefield, obstacles
    if CachedThreats then
        threats = CachedThreats
    else
        local threatsOk
        threatsOk, threats = pcall(AnalyzePlayerThreats, playerParty)
        threats = threatsOk and threats or {hasConcentration=false, isStealthHeavy=false, highGround=false, recentControl=0, dangerousPassives={}}
        CachedThreats = threats
    end

    if CachedBattlefield then
        battlefield = CachedBattlefield
    else
        local battlefieldOk
        battlefieldOk, battlefield = pcall(GetBattlefieldContext)
        battlefield = battlefieldOk and battlefield or {averagePlayerHeight=0, clusteredEnemies=false}
        CachedBattlefield = battlefield
    end

    local obstaclesOk, obResult = pcall(FindObstaclesInCombat)
    obstacles = obstaclesOk and obResult or {globes={}, walls={}, doors={}}

    local capsOk, enemyCaps = pcall(GetEnemyCapabilities, enemyId)
    enemyCaps = capsOk and enemyCaps or {strength=10, canJump=false, canFly=false, movement=6}

    -- ==================== STEP 1: ENVIRONMENT ANALYSIS FIRST ====================
    -- Check which players are actually reachable (LOS + distance) before choosing any spell
    local reachablePlayers = {}
    local unreachablePlayers = {}
    local nearestReachableDist = 999
    local nearestReachablePlayer = nil

    for uuid, player in pairs(playerParty or {}) do
        if player and (player.uuid or uuid) and IsValidTarget(enemyId, player.uuid or uuid) then
            local playerUuid = player.uuid or uuid
            local dist = GetDistanceBetween(enemyId, playerUuid)
            local los = CheckLineOfSight(enemyId, playerUuid)
            if los and dist < 30 then -- within reasonable range and visible
                reachablePlayers[#reachablePlayers + 1] = player
                if dist < nearestReachableDist then
                    nearestReachableDist = dist
                    nearestReachablePlayer = player
                end
            else
                unreachablePlayers[#unreachablePlayers + 1] = player
                log("  ENV: " .. tostring(player.name or playerUuid) .. " unreachable (dist=" .. string.format("%.1f", dist) .. ", LOS=" .. tostring(los) .. ")")
            end
        end
    end

    log("  ENV: " .. #reachablePlayers .. " reachable, " .. #unreachablePlayers .. " unreachable players")
    if nearestReachablePlayer then
        log("  ENV: Nearest reachable: " .. tostring(nearestReachablePlayer.name or nearestReachablePlayer.uuid) .. " at " .. string.format("%.1f", nearestReachableDist) .. "m")
    end

    -- ==================== STEP 2: SEPARATE SPELLS BY REACHABILITY ====================
    local reachableView = {}      -- spells that can reach at least one player
    local mobilitySpells = {}     -- jump/leap/fly/teleport (for closing distance)
    local otherSpells = {}        -- everything else

    for _, spell in ipairs(available) do
      if Skynet_HasUsedLimitedSpell(enemyId, spell) then
        goto skynetSkipLimitedSpell
      end
      -- PASS #59: Dip is never a scoring candidate (every candidate gets aimed at a creature).
      if Skynet_IsDipSpell and Skynet_IsDipSpell(spell) then
        goto skynetSkipLimitedSpell
      end
      -- PASS #62: Help / Distract / Throw are never attack choices.
      if Skynet_IsAidAction and Skynet_IsAidAction(spell) then
        goto skynetSkipLimitedSpell
      end
      -- PASS #56: never a scoring candidate unless its situational rule is met (see Skynet_ExtraordinaryAllowed).
      if Skynet_ExtraordinaryAllowed and not Skynet_ExtraordinaryAllowed(enemyId, spell) then
        goto skynetSkipLimitedSpell
      end
      -- Wildshape/Polymorph form spells (when blocked / already transformed / already used this
      -- fight) and Dismiss spells must not even be candidates: when every spell scored 0.0 the
      -- first one in the list won the tie (seen live: "WSO_Shout_WildShape_Hyena (score 0.0)").
      if Skynet_WildshapeBlocked(enemyId, ClassifySpell(spell), spell) then
        goto skynetSkipLimitedSpell
      end
      -- PASS #25: skip a spell Skynet_SelfPrepare already cast THIS turn (as a self-buff),
      -- even if it has no real Cooldown restriction and so was never picked up by the
      -- limited-use tracking check just above. Reported bug: Minthara (a Full-Illithid
      -- character) auto-casting Mind Sanctuary twice at the start of her turn, using up all
      -- her resources — Mind Sanctuary is a real, "at-will, no cooldown" Illithid power per
      -- bg3.wiki, and its BG3 stat data (VerbalIntent "Buff", SpellType "zone") classifies it
      -- as exactly the kind of caster-centered selfbuff Skynet_SelfPrepare's Priority-1 loop
      -- looks for. `bestSpell` (see Skynet_AITurn) is computed once, BEFORE Self-Prepare runs,
      -- so nothing previously stopped that same spell from being picked again as the turn's
      -- main "attack." Marked via `LOSCache["__castThisTurn__"..spell]` in Skynet_SelfPrepare
      -- (piggybacking on the existing per-turn cache table with a prefixed key, same technique
      -- as pass #24, rather than a new top-level local — the file is already at/near Lua's 200
      -- top-level-local ceiling). See Maintenance history pass #25.
      if LOSCache["__castThisTurn__" .. spell] then
        goto skynetSkipLimitedSpell
      end
      do
        local props = GetSpellProperties(spell, enemyId)
        local cat = ClassifySpell(spell)
        local sLower = string.lower(spell or "")
        local isHatchEggsSpell = sLower:find("hatchegg") or (sLower:find("spiderqueen") and sLower:find("hatch"))

        if cat.mobility > 0 then
            mobilitySpells[#mobilitySpells + 1] = spell
        elseif Skynet_NeedsSpecialCreatureType(spell)
               and not (Skynet_HasQualifyingCreatureTypeTarget(reachablePlayers) or Skynet_HasQualifyingCreatureTypeTarget(unreachablePlayers)) then
            -- Dispel Evil and Good / Protection from Evil and Good / Turn Undead / Destroy
            -- Undead only do anything against a celestial/elemental/fey/fiend/undead creature.
            -- Nothing previously checked whether one was actually present before letting these
            -- into the candidate pool, so a hostile caster with one of these in its kit could
            -- "use" it every time it happened to score highest among reachable options, even
            -- with zero qualifying creatures anywhere on the battlefield — reported as a
            -- priest casting "Dispel" with no undead around. When no qualifying creature is
            -- present at all, drop it straight into otherSpells (like HatchEggs above) without
            -- even running the normal reachability check below — it could never do anything
            -- regardless of range. When a qualifying creature IS present, this branch is
            -- skipped and the spell falls through to the normal reachability check below,
            -- same as any other targeted spell.
            otherSpells[#otherSpells + 1] = spell
        elseif isHatchEggsSpell then
            -- HatchEggs only ever legitimately targets egg clusters, never players — but
            -- IsTargetReachable below just checks raw range/LOS against a player uuid, with
            -- no concept of "is this player even a valid target type for this spell." That
            -- let HatchEggs get misclassified as "reachable" (since a player standing within
            -- its 9m range trivially passes a range/LOS check) and then out-score real attack
            -- spells in ScoreSpellForEnemy, even with zero egg clusters anywhere nearby — she'd
            -- "choose" HatchEggs, fail to find a cluster at cast time, and only then fall back
            -- to actually attacking (see Skynet_ExecuteDirect's HatchEggs special case below).
            -- That whole detour is wasted evaluation (and looked to the player like turning
            -- toward nothing) whenever no cluster actually exists. Gate it here instead: only
            -- let it into the real candidate pool when a cluster genuinely exists to hatch.
            if #FindEggClustersNear(enemyId, 50.0) > 0 then
                reachableView[#reachableView + 1] = spell
            else
                otherSpells[#otherSpells + 1] = spell
            end
        elseif props and props.isConcentration and Skynet_IsAlreadyConcentrating(enemyId) then
            -- PASS #35: casting a second concentration spell breaks the enemy's own
            -- first one (Fog Cloud, then Silence, same turn — reported live). The
            -- pre-existing check for this in ScoreSpellForEnemy was scoring-only (a -50
            -- penalty), which an enemy whose kit leans heavily on control/concentration
            -- spells could still out-score everything else with. Gate it here instead,
            -- same technique as HatchEggs/creature-type gating above: a concentration
            -- spell only enters the real candidate pool when the enemy ISN'T already
            -- concentrating on something; otherwise it's demoted to otherSpells —
            -- last-resort only, if truly nothing else is usable this turn (Priority 3's
            -- "desperate" pass below still considers it, so this never leaves an enemy
            -- doing literally nothing when it's the only option). See Maintenance
            -- history pass #35.
            otherSpells[#otherSpells + 1] = spell
        elseif props and props.isConcentration and SkynetGates
               and SkynetGates.allAffected(enemyId, spell, reachablePlayers) then
            -- Every reachable target already has this concentration spell's effect (or has it queued this
            -- turn): casting it again would only break it. Same last-resort demotion as above.
            otherSpells[#otherSpells + 1] = spell
        elseif props then
            -- Check if this spell can reach any player
            local canReach = false
            for _, player in ipairs(reachablePlayers) do
                local reachable, reason = IsTargetReachable(enemyId, player.uuid, spell)
                if reachable then
                    canReach = true
                    break
                end
            end
            if canReach then
                reachableView[#reachableView + 1] = spell
            else
                otherSpells[#otherSpells + 1] = spell
            end
        else
            otherSpells[#otherSpells + 1] = spell
        end
      end
      ::skynetSkipLimitedSpell::
    end

    log("  SPELLS: " .. #reachableView .. " reachable, " .. #mobilitySpells .. " mobility, " .. #otherSpells .. " other")

    -- ==================== STEP 3: CHOOSE BEST ACTION ====================

    -- Priority 1: If we have spells that can reach players, score and pick the best
    if #reachableView > 0 then
        local best = nil
        local bestScore = -999

        for _, spell in ipairs(reachableView) do
            local scOk, sc = pcall(ScoreSpellForEnemy, spell, enemySnap or {}, playerParty, battlefield, threats, obstacles, enemyCaps)
            if scOk and sc > bestScore then
                bestScore = sc
                best = spell
            elseif scOk and sc == bestScore and best ~= nil
                and BASIC_WEAPON_ATTACK_SPELLS[string.lower(tostring(spell))]
                and not BASIC_WEAPON_ATTACK_SPELLS[string.lower(tostring(best))] then
                best = spell -- tie: a basic attack beats an arbitrary first-in-list spell
            end
        end

        if best then
            local props = GetSpellProperties(best)
            local rangeInfo = props and string.format("range=%.0fm, type=%s", props.rangeMeters, props.spellType) or "no_data"
            local recMsg = string.format("Skynet recommends for %s: %s (score %.1f) - Context: concentration=%s, stealth=%s, height=%s, obstacles=%d, %s",
                (enemySnap and enemySnap.name) or "enemy", best, bestScore,
                tostring(threats.hasConcentration), tostring(threats.isStealthHeavy), tostring(threats.highGround),
                #obstacles.globes + #obstacles.walls, rangeInfo)
            Ext.Utils.Print(LOG_PREFIX .. recMsg)
            log(recMsg)

            -- Log reachability for each player
            for uuid, player in pairs(playerParty or {}) do
                if player and (player.uuid or uuid) then
                    local playerUuid = player.uuid or uuid
                    local reachable, reason = IsTargetReachable(enemySnap.uuid, playerUuid, best)
                    local dist = GetDistanceBetween(enemySnap.uuid, playerUuid)
                    local los = CheckLineOfSight(enemySnap.uuid, playerUuid)
                    log(string.format("  vs %s: reachable=%s (%s), dist=%.1f, LOS=%s",
                        tostring(player.name or playerUuid), tostring(reachable), tostring(reason), dist, tostring(los)))
                end
            end

            if t0 then
                local t1 = Ext.Utils.MonotonicTime()
                log("  PERF: ChooseBestAction took " .. tostring(t1 - t0) .. "ms for " .. (enemySnap.name or "unknown") .. " (reachable)")
            end
            return best
        end
    end

    -- Priority 2: No spells can reach players — use mobility to close distance
    if #mobilitySpells > 0 then
        -- Find the mobility spell that gets us closest to the nearest reachable player
        local bestMobility = nil
        local bestMobilityScore = -999

        for _, spell in ipairs(mobilitySpells) do
            local props = GetSpellProperties(spell)
            local score = 0

            local s = string.lower(spell)
            if s:find("enhance") or s:find("leap") or s:find("jump") then
                score = score + 20
            elseif s:find("ethereal") or s:find("misty") or s:find("teleport") then
                score = score + 18  -- teleports are best (reach far, no OA risk)
            elseif s:find("fly") or s:find("dimension") or s:find("thunderstep") or s:find("far step") then
                score = score + 12
            elseif s:find("dash") or s:find("disengage") then
                score = score + 5
            else
                score = score + 3
            end

            local hazardOk, onHazard = pcall(HasDangerousSurfacesBetween, enemyId, nil)
            if hazardOk and onHazard then
                score = score + 10
            end

            if #obstacles.walls > 0 or #obstacles.doors > 0 then
                score = score + 8
            end

            if nearestReachableDist > 9 then
                score = score + 10
            elseif nearestReachableDist > 6 then
                score = score + 5
            end

            if enemyCaps.strength > 15 and (s:find("leap") or s:find("jump")) then
                score = score + 5
            end

            if score > bestMobilityScore then
                bestMobilityScore = score
                bestMobility = spell
            end
        end

        if bestMobility then
            local targetName = nearestReachablePlayer and (nearestReachablePlayer.name or nearestReachablePlayer.uuid) or "nearest enemy"
            local recMsg = string.format("Skynet MOBILITY for %s: %s (score %.1f) - Closing distance to %s (%.1fm)",
                (enemySnap and enemySnap.name) or "enemy", bestMobility, bestMobilityScore,
                targetName, nearestReachableDist)
            Ext.Utils.Print(LOG_PREFIX .. recMsg)
            log(recMsg)
            if t0 then
                local t1 = Ext.Utils.MonotonicTime()
                log("  PERF: ChooseBestAction took " .. tostring(t1 - t0) .. "ms for " .. (enemySnap.name or "unknown") .. " (mobility)")
            end
            return bestMobility
        end
    end

    -- Priority 3: No reachable targets AND no mobility — try any spell (desperate)
    if #reachableView == 0 and #mobilitySpells == 0 then
        log("  DESPERATE: No reachable targets, no mobility. Trying any spell.")
        local best = nil
        local bestScore = -999
        for _, spell in ipairs(available) do
            local scOk, sc = false, nil
            if not Skynet_WildshapeBlocked(enemyId, ClassifySpell(spell), spell) then
                scOk, sc = pcall(ScoreSpellForEnemy, spell, enemySnap or {}, playerParty, battlefield, threats, obstacles, enemyCaps)
            end
            if scOk and sc > bestScore then
                bestScore = sc
                best = spell
            elseif scOk and sc == bestScore and best ~= nil
                and BASIC_WEAPON_ATTACK_SPELLS[string.lower(tostring(spell))]
                and not BASIC_WEAPON_ATTACK_SPELLS[string.lower(tostring(best))] then
                best = spell -- tie: a basic attack beats an arbitrary first-in-list spell
            end
        end
        if best then
            log("  DESPERATE choice: " .. best .. " (score " .. tostring(bestScore) .. ")")
            if t0 then
                local t1 = Ext.Utils.MonotonicTime()
                log("  PERF: ChooseBestAction took " .. tostring(t1 - t0) .. "ms for " .. (enemySnap.name or "unknown") .. " (desperate)")
            end
            return best
        end
    end

    if t0 then
        local t1 = Ext.Utils.MonotonicTime()
        log("  PERF: ChooseBestAction took " .. tostring(t1 - t0) .. "ms for " .. (enemySnap.name or "unknown"))
    end
    return nil
end

-- ==================== ACTION EXECUTION ENGINE ====================
-- Replaces the archetype-recommendation system with direct spell execution.
-- On TurnStarted: suppress base AI, score all spells, pick best, execute.
-- Pulse tick: movement, repositioning, environmental checks.

local skynetPulseTimer = nil
local skynetExecutorInitialized = false

local function Skynet_ExecuteUseSpell(caster, spellId, target)
  if not caster or caster == "" or not spellId or spellId == "" then return false, "invalid_args" end
  if target and target ~= "" then
    return Skynet_UseSpellOnTarget(caster, target, spellId)
  end
  -- PASS #59: Dip needs a surface/object target; without one it is never cast.
  if Skynet_IsDipSpell and Skynet_IsDipSpell(spellId) then
    log("  DIP BLOCKED: " .. tostring(caster):sub(1,30) .. " — Dip needs a surface or burning object to dip into")
    return false, "dip_needs_surface"
  end
  -- PASS #56: last line of defence for Heroic Action Surge / Hyper Focus / Dig Deeper (all self-cast shouts).
  if Skynet_ExtraordinaryAllowed then
    local allowed, why = Skynet_ExtraordinaryAllowed(caster, spellId)
    if not allowed then
      log("  EXTRAORDINARY GATE BLOCKED: " .. tostring(spellId) .. " for " .. tostring(caster):sub(1,30) .. " — " .. tostring(why))
      return false, "situation_gate"
    end
  end
  -- Self-cast / no target
  local ok, err = pcall(function()
    Osi.UseSpell(caster, spellId, caster)
  end)
  if ok then
    if SkynetGates then SkynetGates.noteQueued(caster, nil, spellId) end
    if Skynet_TurnQueued then Skynet_TurnQueued[resolveUuid(caster)] = true end   -- PASS #60
    -- PASS #64: a Dash Skynet queued adds one more "speed" of movement to this turn's ledger.
    if SkynetMove and string.lower(tostring(spellId)):find("dash", 1, true) then SkynetMove.noteDash(caster) end
    if Skynet_XbowNoteCast then Skynet_XbowNoteCast(caster, spellId) end   -- PASS #65 (Load Bolt)
    return true, "ok_self"
  end
  return false, tostring(err)
end

local function Skynet_UseSpellOnTarget(caster, target, spellId)
  if not caster or caster == "" or not target or target == "" or not spellId or spellId == "" then
    return false, "invalid_args"
  end
  -- PASS #55: final chokepoint. Every cast below is FORCED (NRD_RequestUseSpellsOnTarget /
  -- RequestUseSpellsOnTarget / UseSpell) — the engine does not re-check whether the caster
  -- can actually perceive the target, so unlike vanilla AI, a scripted cast will happily fire
  -- at a hidden or invisible character standing in plain view. Every target-selection path
  -- upstream is supposed to have filtered hidden targets already; this is the last line of
  -- defence so no current or future path can ever land a hostile cast on an undetected
  -- target. Only blocks hostile casts (caster and target are enemies) — self-casts and
  -- heals/buffs on allies are untouched.
  if resolveUuid(target) ~= resolveUuid(caster) then
    local enOk, isEnemyRel = pcall(function() return Osi.IsEnemy(caster, target) end)
    if enOk and (isEnemyRel == 1 or isEnemyRel == true) and Skynet_IsTargetUndetected(target) then
      log("  HIDDEN TARGET BLOCKED: refusing " .. tostring(spellId) .. " from " .. tostring(caster):sub(1,30) ..
          " on undetected " .. tostring(target):sub(1,30))
      return false, "target_undetected"
    end
    -- PASS #62: Help is for allies; never cast it on someone the caster is fighting.
    if enOk and (isEnemyRel == 1 or isEnemyRel == true) and Skynet_IsHelpSpell and Skynet_IsHelpSpell(spellId) then
      log("  HELP BLOCKED: " .. tostring(caster):sub(1,30) .. " — Help is never cast on an enemy (" .. tostring(target):sub(1,30) .. ")")
      return false, "help_on_enemy"
    end
  end
  -- PASS #59: Dip only on a surface/object, never a creature, and once per fight per caster.
  local isDip = Skynet_IsDipSpell and Skynet_IsDipSpell(spellId)
  if isDip then
    if Skynet_IsCharacterTarget(target) then
      log("  DIP BLOCKED: " .. tostring(caster):sub(1,30) .. " tried to Dip on a creature (" .. tostring(target):sub(1,30) .. ")")
      return false, "dip_on_creature"
    end
    if Skynet_DipUsedInCombat[resolveUuid(caster)] == tostring(CurrentCombatId or "") then
      log("  DIP BLOCKED: " .. tostring(caster):sub(1,30) .. " already dipped its weapon this fight")
      return false, "dip_already_used"
    end
    Skynet_DipUsedInCombat[resolveUuid(caster)] = tostring(CurrentCombatId or "")
  end
  -- PASS #56: same situational gate as Skynet_ExecuteUseSpell (a self-targeted call can land here too).
  if Skynet_ExtraordinaryAllowed then
    local allowed, why = Skynet_ExtraordinaryAllowed(caster, spellId)
    if not allowed then
      log("  EXTRAORDINARY GATE BLOCKED: " .. tostring(spellId) .. " for " .. tostring(caster):sub(1,30) .. " — " .. tostring(why))
      return false, "situation_gate"
    end
  end
  -- PASS #65: an unloaded crossbow shot (apcs_RestSystem) needs a Bonus Action as well.
  if Skynet_XbowCanAfford then
    local affordable, why = Skynet_XbowCanAfford(caster, spellId)
    if not affordable then
      log("  CROSSBOW BLOCKED: " .. tostring(spellId) .. " for " .. tostring(caster):sub(1,30) .. " — " .. tostring(why))
      return false, "crossbow_needs_bonus"
    end
  end
  -- Try NRD_RequestUseSpellsOnTarget first (most reliable, works with action points)
  local ok, err = pcall(function()
    Osi.NRD_RequestUseSpellsOnTarget(caster, target, spellId)
  end)
  if ok then
    Skynet_MarkLimitedSpellUsed(caster, spellId)
    if SkynetGates then SkynetGates.noteQueued(caster, target, spellId) end
    if Skynet_TurnQueued then Skynet_TurnQueued[resolveUuid(caster)] = true end   -- PASS #60
    if Skynet_XbowNoteCast then Skynet_XbowNoteCast(caster, spellId) end            -- PASS #65
    return true, "ok_nrd"
  end
  -- Fallback to RequestUseSpellsOnTarget
  local ok2, err2 = pcall(function()
    Osi.RequestUseSpellsOnTarget(caster, target, spellId)
  end)
  if ok2 then
    Skynet_MarkLimitedSpellUsed(caster, spellId)
    if SkynetGates then SkynetGates.noteQueued(caster, target, spellId) end
    if Skynet_TurnQueued then Skynet_TurnQueued[resolveUuid(caster)] = true end   -- PASS #60
    if Skynet_XbowNoteCast then Skynet_XbowNoteCast(caster, spellId) end            -- PASS #65
    return true, "ok_request"
  end
  -- Last resort: Osi.UseSpell
  local ok3, err3 = pcall(function()
    Osi.UseSpell(caster, spellId, target)
  end)
  if ok3 then
    Skynet_MarkLimitedSpellUsed(caster, spellId)
    if SkynetGates then SkynetGates.noteQueued(caster, target, spellId) end
    if Skynet_TurnQueued then Skynet_TurnQueued[resolveUuid(caster)] = true end   -- PASS #60
    if Skynet_XbowNoteCast then Skynet_XbowNoteCast(caster, spellId) end            -- PASS #65
    return true, "ok_use"
  end
  return false, tostring(err3 or err2 or err)
end

local function Skynet_ExecuteActionOnPosition(caster, spellId, x, y, z)
  if SkynetMove and caster and caster ~= "" then pcall(SkynetMove.allowJump, caster) end   -- PASS #64
  if Skynet_XbowCanAfford and caster and caster ~= "" then   -- PASS #65: unloaded crossbow shot needs a Bonus Action
    local affordable, why = Skynet_XbowCanAfford(caster, spellId)
    if not affordable then
      log("  CROSSBOW BLOCKED: " .. tostring(spellId) .. " for " .. tostring(caster):sub(1,30) .. " — " .. tostring(why))
      return false, "crossbow_needs_bonus"
    end
  end
  if not caster or caster == "" or not spellId or spellId == "" then return false, "invalid_args" end
  local resolved = resolveUuid(caster)
  if resolved == "" then return false, "invalid_caster" end

  -- Get spell properties for position targeting
  local props = GetSpellProperties(spellId)
  local isPositionSpell = props and (props.canTargetTerrain or props.spellType == "zone" or
    string.lower(spellId):find("jump") or string.lower(spellId):find("leap") or
    string.lower(spellId):find("teleport") or string.lower(spellId):find("fly") or
    string.lower(spellId):find("misty") or string.lower(spellId):find("dimension"))

  -- Mobility/teleport spells relocate the caster to a specific location. Self-casting one
  -- as a "fallback" is a no-op — you can't productively teleport to where you already are —
  -- so these must never fall back to a self-cast; a failed position cast should just fail.
  local slMob = string.lower(spellId or "")
  local isMobilitySpell = slMob:find("jump") or slMob:find("leap") or slMob:find("teleport") or
    slMob:find("misty") or slMob:find("dimension") or slMob:find("ethereal") or
    slMob:find("blink") or slMob:find("shadow") or slMob:find("astral") or
    slMob:find("warp") or slMob:find("hellcrawl") or slMob:find("dark currents") or
    slMob:find("benign transposition") or slMob:find("fleeting dream") or
    slMob:find("shifting winds") or slMob:find("supernatural attraction") or
    slMob:find("wild magic") or slMob:find("mobile flourish") or
    slMob:find("thunderstep") or slMob:find("far step") or slMob:find("fly")

  -- For position-target spells (jump, fly, teleport, misty step), use ground targeting
  if isPositionSpell then
    -- Find valid ground position near target
    local groundX, groundY, groundZ = x, y, z
    local gOk = pcall(function()
      groundX, groundY, groundZ = Osi.FindValidPosition(x, y, z, 3.0, resolved, 1)
    end)
    if gOk and groundX then
      x, y, z = groundX, groundY, groundZ
    end

    -- Check if position is reachable (not too far for jump/leap)
    local cx, cy, cz
    local posOk = pcall(function() cx, cy, cz = Osi.GetPosition(resolved) end)
    if posOk and cx then
      local dist = math.sqrt((x-cx)^2 + (y-cy)^2 + (z-cz)^2)
      local spellLower = string.lower(spellId)

      -- Jump/Leap range limits
      if spellLower:find("jump") or spellLower:find("leap") then
        local maxJump = 9  -- default jump range
        local stats = safeCall(Ext.Stats.Get, spellId)
        if stats and stats.Range then
          local rangeNum = tonumber(tostring(stats.Range):match("(%d+)")) or 9
          maxJump = rangeNum
        end
        if dist > maxJump then
          log("  JUMP TOO FAR: " .. string.format("%.1f", dist) .. "m > " .. maxJump .. "m max")
          return false, "jump_out_of_range"
        end
      end
    end

    -- Try the real Osiris ground-targeting call first. NOTE: "NRD_RequestUseSpellsOnPosition"
    -- is not a real Osiris/SE function (confirmed nil at runtime — see game log) and was
    -- silently failing on every single position-targeted cast in the mod. The documented,
    -- working call for this is UseSpellAtPosition(caster, spellId, x, y, z, [withoutMove]).
    local ok, err = pcall(function()
      Osi.UseSpellAtPosition(resolved, spellId, x, y, z)
    end)
    if ok then
      log("  CAST POSITION: " .. spellId .. " at (" .. string.format("%.1f", x) .. "," .. string.format("%.1f", y) .. "," .. string.format("%.1f", z) .. ")")
      if Skynet_TurnQueued then Skynet_TurnQueued[resolved] = true end   -- PASS #60: a queued position cast
      if Skynet_XbowNoteCast then Skynet_XbowNoteCast(caster, spellId) end   -- PASS #65
      return true, "ok_use_spell_at_position"
    end

    if isMobilitySpell then
      -- Never self-cast a teleport/mobility spell as a "fallback" — it leaves the caster
      -- exactly where it started while still looking like a successful cast. Report failure
      -- so the caller (e.g. the movement-evaluation loop) knows to try something else.
      log("  CAST FAILED (mobility, no self-cast fallback): " .. spellId .. " | UseSpellAtPosition:" .. tostring(err))
      return false, tostring(err)
    end

    -- Fallback: try UseSpell with ground targeting (only for non-mobility position spells,
    -- e.g. ground-targeted AoE, where self-targeting is at least a sane substitute)
    local ok2, err2 = pcall(function()
      Osi.UseSpell(resolved, spellId, resolved)
    end)
    if ok2 then
      log("  CAST FALLBACK: " .. spellId .. " (self-target fallback)")
      if Skynet_TurnQueued then Skynet_TurnQueued[resolved] = true end   -- PASS #60
      if Skynet_XbowNoteCast then Skynet_XbowNoteCast(caster, spellId) end   -- PASS #65
      return true, "ok_use_spell_fallback"
    end

    log("  CAST FAILED: " .. spellId .. " | UseSpellAtPosition:" .. tostring(err) .. " | Use:" .. tostring(err2))
    return false, tostring(err)
  end

  -- For character-target spells, use standard targeting
  local ok, err = pcall(function()
    Osi.UseSpellAtPosition(resolved, spellId, x, y, z)
  end)
  if ok then
    if Skynet_TurnQueued then Skynet_TurnQueued[resolved] = true end   -- PASS #60
    if Skynet_XbowNoteCast then Skynet_XbowNoteCast(caster, spellId) end   -- PASS #65
    return true, "ok_use_spell_at_position"
  end
  return false, tostring(err)
end

-- ==================== PASS #64: WALKS STAY ON A REAL ROUTE, WITHIN MOVEMENT, AND WARPS ARE UNDONE ====================
-- Reported live (mind flayer appearing in front of Astarion on a ledge; a wolf appearing in front of Shadowheart
-- after Dash). The log showed it under Skynet's control: "MOVE: Run to (192.6,8.9,290.4)", then the position watch
-- caught the mind flayer going 6.7 m across and 5.2 m up in a quarter of a second, landing on exactly that x/z.
-- Skynet moves characters with the story call Osi.CharacterMoveToPosition. Per Larian's own documentation of that
-- call: in combat the character moves "ignoring remaining AP" (no movement points are spent or checked), and "if
-- the path to the destination is blocked somewhere, the character will immediately teleport there". Skynet ordered
-- walks to raw points (20 m orders for a creature with 7 m of movement), so any walk the game could not finish on
-- foot ended as a teleport next to the target. Now:
--   * the walk is planned on the game's own route (path nodes), without ladders, and only as far along that route
--     as the character's movement for this turn allows (its real Movement resource, plus one more for each Dash
--     Skynet cast, minus what Skynet already walked it this turn); the order goes to a point ON that route;
--   * while a Skynet walk is in flight the character is watched; if it is warped onto its walk destination (moves
--     faster than anything on foot), the walk is cancelled, the character is put back where it was, and Skynet
--     orders no more walking for it this turn;
--   * a walk still unfinished when the turn ends is stopped instead of carrying on (or being completed by a warp)
--     during someone else's turn.
-- Everything lives in this one global table: the main chunk is at Lua's limit of 200 local variables.
SkynetMove = {
  SAMPLE_MS = 250,
  WARP_STEP_M = 4.0,       -- moved further than this between two samples ...
  WARP_SPEED = 14.0,       -- ... at more than this many m/s: nothing walks, runs or sprints that fast
  WARP_RISE_M = 2.0,       -- rose more than this between two samples ...
  WARP_RISE_SPEED = 8.0,   -- ... at more than this many m/s
  DEST_MATCH_M = 2.5,      -- "landed on its walk destination" = within this (flat distance) of an ordered point
  ALLOW_MS = 5000,         -- after the character casts a jump/fly/teleport-type spell: no undo for this long
  AFTER_TURN_MS = 2000,    -- keep watching this long after the turn ended
  MAX_WATCH_MS = 90000,
  MIN_MOVE_M = 1.0,
  DEFAULT_MOVEMENT = 9,
  ledger = {},             -- resolved uuid -> this turn's movement ledger
  watch = {},              -- resolved uuid -> watch record while a Skynet walk may be in flight
}

function SkynetMove.now()
  return Ext.Utils.MonotonicTime and Ext.Utils.MonotonicTime() or 0
end

function SkynetMove.pos(uuid)
  local ok, x, y, z = pcall(function() return Osi.GetPosition(uuid) end)
  if ok and type(x) == "number" and type(z) == "number" then return { x, y or 0, z } end
  return nil
end

function SkynetMove.flat(a, b)
  return math.sqrt((a[1] - b[1]) ^ 2 + (a[3] - b[3]) ^ 2)
end

function SkynetMove.dist3(a, b)
  return math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2)
end

-- The character's real Movement resource: amount left, maximum. nil when it cannot be read.
function SkynetMove.movement(uuid)
  local amount, maxAmount = nil, nil
  pcall(function()
    local entity = Ext.Entity.Get(uuid)
    for resourceGuid, entries in pairs(entity.ActionResources.Resources) do
      local def = Ext.StaticData.Get(resourceGuid, "ActionResource")
      if def and def.Name == "Movement" then
        amount, maxAmount = 0, 0
        for _, entry in ipairs(entries or {}) do
          amount = amount + (entry.Amount or 0)
          maxAmount = maxAmount + (entry.MaxAmount or 0)
        end
      end
    end
  end)
  return amount, maxAmount
end

-- Called at the top of Skynet_AITurn: a fresh ledger for this turn.
function SkynetMove.beginTurn(uuid)
  local key = resolveUuid(uuid)
  -- The per-turn maximum, not the amount left: this runs as the turn starts, when the amount may still be what the
  -- previous turn left over (and story walks never spend it anyway).
  local amount, maxAmount = SkynetMove.movement(key)
  local base = (maxAmount and maxAmount > 0) and maxAmount or ((amount and amount > 0) and amount or SkynetMove.DEFAULT_MOVEMENT)
  SkynetMove.ledger[key] = {
    base = base,    -- movement for this turn
    speed = base,   -- what one Dash adds
    bonus = 0, spent = 0, pending = 0, at = nil, blocked = false,
  }
  SkynetMove.watch[key] = nil
  return SkynetMove.ledger[key]
end

function SkynetMove.ledgerFor(uuid)
  local key = resolveUuid(uuid)
  return SkynetMove.ledger[key] or SkynetMove.beginTurn(key)
end

-- Skynet queued a Dash for this character: one more "speed" of movement this turn.
function SkynetMove.noteDash(uuid)
  local L = SkynetMove.ledgerFor(uuid)
  L.bonus = L.bonus + L.speed
end

-- The game's own route from the character to (tx, ty, tz): a list of {x, y, z} points starting at the character,
-- an empty list when a route exists but its points cannot be read, nil when there is no route. No ladders: a
-- story move cannot climb one, it would be "blocked" and teleport.
function SkynetMove.route(uuid, tx, ty, tz)
  local found, nodes = false, {}
  local ok = pcall(function()
    local path = Ext.Level.BeginPathfindingImmediate(Ext.Entity.Get(uuid), { tx, ty, tz })
    if not path then return end
    found = Ext.Level.FindPath(path) and true or false
    if found then
      pcall(function()
        local list = path.Nodes
        for i = 1, #list do
          local p = list[i].Position
          if p and type(p[1]) == "number" then nodes[#nodes + 1] = { p[1], p[2], p[3] } end
        end
      end)
    end
    pcall(function() Ext.Level.ReleasePath(path) end)
  end)
  if not ok or not found then return nil end
  local me = SkynetMove.pos(uuid)
  if me and #nodes >= 2 and SkynetMove.flat(nodes[#nodes], me) < SkynetMove.flat(nodes[1], me) then
    local rev = {}
    for i = #nodes, 1, -1 do rev[#rev + 1] = nodes[i] end
    nodes = rev
  end
  return nodes
end

function SkynetMove.routeLength(nodes)
  local total = 0
  for i = 2, #nodes do total = total + SkynetMove.dist3(nodes[i - 1], nodes[i]) end
  return total
end

-- The point `dist` metres along the route.
function SkynetMove.pointAlong(nodes, dist)
  local walked = 0
  for i = 2, #nodes do
    local seg = SkynetMove.dist3(nodes[i - 1], nodes[i])
    if walked + seg >= dist and seg > 0 then
      local f = (dist - walked) / seg
      local a, b = nodes[i - 1], nodes[i]
      return { a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f }
    end
    walked = walked + seg
  end
  return nodes[#nodes]
end

-- Plan a walk toward (tx, ty, tz). Returns nil when the game has no route there; { skip = reason } when no walk
-- should be ordered; otherwise { x, y, z, len, total, avail, clamped }: the point to order the move to (on the
-- route), how far that is on foot, the whole route's length and the movement that was left.
function SkynetMove.plan(uuid, tx, ty, tz)
  local key = resolveUuid(uuid)
  local L = SkynetMove.ledgerFor(key)
  if L.blocked then return { skip = "a walk was already blocked and undone this turn — no more walking this turn" } end
  local me = SkynetMove.pos(key)
  if not me then return { skip = "its position cannot be read" } end
  -- Skynet plans a whole turn in one go, so several walks can be ordered from the same spot; they are then walked one
  -- after another along (nearly) the same route, which is why the longest one is what counts ("pending"). Once the
  -- character has actually moved away from that spot, those orders count as walked.
  if L.at and SkynetMove.flat(me, L.at) > 1.0 then
    L.spent = L.spent + L.pending
    L.pending = 0
  end
  local avail = L.base + L.bonus - L.spent
  if avail < SkynetMove.MIN_MOVE_M then
    return { skip = string.format("no movement left this turn (%.1fm to start with, +%.1fm from Dash, %.1fm walked)", L.base, L.bonus, L.spent) }
  end
  local nodes = SkynetMove.route(key, tx, ty, tz)
  if not nodes then return nil end

  local dest, len, total, clamped = nil, 0, 0, false
  if #nodes < 2 then
    -- A route exists but its points cannot be read: only a straight, level walk can be trusted.
    if math.abs(ty - me[2]) > 1.5 then
      return { skip = "the route's points cannot be read and the destination is on another level" }
    end
    total = SkynetMove.dist3(me, { tx, ty, tz })
    len = math.min(total, avail)
    clamped = len < total
    local f = total > 0 and (len / total) or 0
    dest = { me[1] + (tx - me[1]) * f, me[2] + (ty - me[2]) * f, me[3] + (tz - me[3]) * f }
  else
    total = SkynetMove.routeLength(nodes)
    if total <= avail then
      dest, len = nodes[#nodes], total
    else
      -- Stop where the movement runs out, and make sure the game really has a walk of that length to that point.
      clamped = true
      local want = avail
      for _ = 1, 3 do
        local p = SkynetMove.pointAlong(nodes, want)
        local okV, vx, vy, vz = pcall(function() return Osi.FindValidPosition(p[1], p[2], p[3], 1.0, key, 1) end)
        if okV and vx then p = { vx, vy, vz } end
        local check = SkynetMove.route(key, p[1], p[2], p[3])
        if check and #check >= 2 then
          local checkLen = SkynetMove.routeLength(check)
          if checkLen <= avail + 0.75 then
            dest, len = check[#check], checkLen
            break
          end
        end
        want = want * 0.75
      end
      if not dest then
        return { skip = string.format("no point on the %.1fm route is within the %.1fm of movement left", total, avail) }
      end
    end
  end
  if len < SkynetMove.MIN_MOVE_M then return { skip = "already as close as its movement allows" } end
  return { x = dest[1], y = dest[2], z = dest[3], len = len, total = total, avail = avail, clamped = clamped }
end

-- A walk was ordered: book it and watch the character until the walk is over.
function SkynetMove.ordered(uuid, plan)
  local key = resolveUuid(uuid)
  local L = SkynetMove.ledgerFor(key)
  local me = SkynetMove.pos(key)
  L.at = me or L.at
  if plan.len > L.pending then L.pending = plan.len end
  local w = SkynetMove.watch[key]
  local t = SkynetMove.now()
  if not w then
    w = { id = uuid, key = key, dests = {}, last = me, lastAt = t, startedAt = t, allowUntil = 0 }
    SkynetMove.watch[key] = w
    if me then Ext.Timer.WaitFor(SkynetMove.SAMPLE_MS, function() SkynetMove.sample(w) end) end
  end
  w.dests[#w.dests + 1] = { plan.x, plan.y, plan.z }
end

-- The character cast something that legitimately moves it fast (jump, fly, teleport...): no undo for a moment.
function SkynetMove.noteCast(caster, spell)
  local w = SkynetMove.watch[resolveUuid(caster)]
  if not w then return end
  local s = string.lower(tostring(spell or ""))
  if s:find("dash", 1, true) then return end
  if s:find("jump", 1, true) or s:find("leap", 1, true) or s:find("fly", 1, true) or s:find("flight", 1, true)
     or s:find("teleport", 1, true) or s:find("misty", 1, true) or s:find("dimension", 1, true)
     or s:find("blink", 1, true) or s:find("step", 1, true) or s:find("charge", 1, true)
     or s:find("rush", 1, true) or s:find("pounce", 1, true) then
    w.allowUntil = SkynetMove.now() + SkynetMove.ALLOW_MS
  end
end

-- Skynet itself cast a jump/fly/teleport-type spell at a position this turn: its landing spot can be right where a
-- walk was also ordered, so nothing is undone for this character for the rest of the turn.
function SkynetMove.allowJump(caster)
  SkynetMove.ledgerFor(caster).noUndo = true
end

function SkynetMove.nearDest(w, p)
  for _, d in ipairs(w.dests) do
    if SkynetMove.flat(d, p) <= SkynetMove.DEST_MATCH_M then return true end
  end
  return false
end

function SkynetMove.purge(uuid)
  local ok = pcall(function() Osi.PurgeOsirisQueue(uuid, 1) end)
  if not ok then ok = pcall(function() Osi.PurgeOsirisQueue(uuid) end) end
  return ok
end

function SkynetMove.teleport(uuid, x, y, z)
  local tries = {
    function() Osi.TeleportToPosition(uuid, x, y, z, "", 0, 0, 0, 0, 1) end,
    function() Osi.TeleportToPosition(uuid, x, y, z, "", 0, 0, 0, 0) end,
    function() Osi.TeleportToPosition(uuid, x, y, z, "", 0, 0, 0) end,
    function() Osi.TeleportToPosition(uuid, x, y, z, "", 0) end,
    function() Osi.TeleportToPosition(uuid, x, y, z, "") end,
  }
  for i, try in ipairs(tries) do
    if pcall(try) then return true, i end
  end
  return false
end

-- The character was warped onto its walk destination: cancel what is queued, put it back, no more walks this turn.
function SkynetMove.undo(w, p, step, rise, dt)
  SkynetMove.watch[w.key] = nil
  SkynetMove.ledgerFor(w.key).blocked = true
  local back = w.last
  log(string.format("  TELEPORT UNDONE: %s was warped %.1fm across and %+.1fm up in %d ms onto its walk destination (the game does this when a story walk gets blocked) — cancelling its queued actions and putting it back at (%.1f, %.1f, %.1f)",
    tostring(w.key):sub(1, 40), step, rise, dt, back[1], back[2], back[3]))
  local purged = SkynetMove.purge(w.id)
  local okT, variant = SkynetMove.teleport(w.id, back[1], back[2], back[3])
  if not okT then
    log("  TELEPORT UNDONE: could not put it back — no TeleportToPosition call was accepted (queue cancelled: " .. tostring(purged) .. ")")
    return
  end
  Ext.Timer.WaitFor(500, function()
    local now = SkynetMove.pos(w.id)
    if now and SkynetMove.flat(now, back) <= 2.0 and math.abs(now[2] - back[2]) <= 2.0 then
      log("  TELEPORT UNDONE: confirmed — " .. tostring(w.key):sub(1, 40) .. " is back where it was (call variant " .. tostring(variant) .. ")")
    else
      log("  TELEPORT UNDONE: NOT confirmed — " .. tostring(w.key):sub(1, 40) .. " is at " ..
          (now and string.format("(%.1f, %.1f, %.1f)", now[1], now[2], now[3]) or "(unreadable)") .. " (call variant " .. tostring(variant) .. ")")
    end
  end)
end

function SkynetMove.sample(w)
  if SkynetMove.watch[w.key] ~= w then return end
  local t = SkynetMove.now()
  if (w.endsAt and t >= w.endsAt) or (t - w.startedAt) > SkynetMove.MAX_WATCH_MS then
    SkynetMove.watch[w.key] = nil
    return
  end
  local p = SkynetMove.pos(w.id)
  if p and w.last then
    local dt = math.max(1, t - w.lastAt)
    local step = SkynetMove.flat(w.last, p)
    local rise = p[2] - w.last[2]
    local secs = dt / 1000
    local warped = (step > SkynetMove.WARP_STEP_M and (step / secs) > SkynetMove.WARP_SPEED)
                or (rise > SkynetMove.WARP_RISE_M and (rise / secs) > SkynetMove.WARP_RISE_SPEED)
    if warped and t >= w.allowUntil and not SkynetMove.ledgerFor(w.key).noUndo and SkynetMove.nearDest(w, p) then
      SkynetMove.undo(w, p, step, rise, dt)
      return
    end
  end
  if p then w.last, w.lastAt = p, t end
  Ext.Timer.WaitFor(SkynetMove.SAMPLE_MS, function() SkynetMove.sample(w) end)
end

-- TurnEnded feed. A walk that is not finished is stopped where the character stands: left alone it would carry on
-- during someone else's turn, or be completed by a warp.
function SkynetMove.turnEnded(character)
  local key = resolveUuid(character)
  local w = SkynetMove.watch[key]
  if not w then return end
  w.endsAt = SkynetMove.now() + SkynetMove.AFTER_TURN_MS
  local p = SkynetMove.pos(w.id)
  local final = w.dests[#w.dests]
  if p and final and SkynetMove.flat(p, final) > SkynetMove.DEST_MATCH_M then
    log(string.format("  WALK STOPPED: %s's turn ended %.1fm short of its walk destination — the walk is cancelled, not finished out of turn",
      tostring(key):sub(1, 40), SkynetMove.flat(p, final)))
    SkynetMove.purge(w.id)
  end
end

local function Skynet_MoveToPosition(caster, x, y, z)
  if not caster or caster == "" then return end
  local resolved = resolveUuid(caster)
  if resolved == "" then return end

  -- Get current position for distance calculation
  local cx, cy, cz
  local posOk = pcall(function() cx, cy, cz = Osi.GetPosition(resolved) end)
  if not posOk or not cx then return end

  -- Calculate distance to target
  local dx, dy, dz = x - cx, y - cy, z - cz
  local distance = math.sqrt(dx*dx + dy*dy + dz*dz)

  -- Skip if already very close (within 1.5m)
  if distance < 1.5 then
    log("  SKIP MOVE: already at target (" .. string.format("%.1f", distance) .. "m)")
    return
  end

  -- PASS #30: PositionCache/DistanceCache are only cleared once, at the very start of
  -- Skynet_AITurn — but a caster can move (this free walk, a Dash, a teleport) several
  -- times within that SAME turn, via this same function, as Phase 1 re-evaluates. Every
  -- later re-evaluation this turn (the "did the free walk already get me in range?" check,
  -- the post-mobility "ALREADY IN ATTACK RANGE" check, PHASE 1.5/2) calls GetDistanceBetween
  -- / GetPosition for this caster, both of which serve straight from cache once populated —
  -- so once this caster's pre-move position got cached earlier in the turn (typically by
  -- the very first ChooseBestAction call), it stayed frozen there for the rest of the turn
  -- no matter how many real moves actually happened. Reported live as an enemy repeatedly
  -- re-selecting/re-casting Dash: its own distance-to-target never appeared to change
  -- across 3-4 re-evaluations in the same turn even though MOVE/WALK log lines in between
  -- showed it actually moving. We're about to actually attempt moving this caster below, so
  -- invalidate its stale cache entries now rather than waiting for the next turn's reset.
  -- Only this caster's entries need clearing (its target's position hasn't changed).
  PositionCache[resolved] = nil
  for key in pairs(DistanceCache) do
    if key:find(resolved, 1, true) then
      DistanceCache[key] = nil
    end
  end

  -- Calculate movement speed based on distance
  local moveSpeed = "Run"
  if distance > 10 then
    moveSpeed = "Sprint"
  elseif distance > 6 then
    moveSpeed = "Run"
  elseif distance > 3 then
    moveSpeed = "Walk"
  else
    moveSpeed = "Stroll"
  end

  -- Find valid position near target using interpolation
  local targetX, targetY, targetZ = x, y, z
  local validRadius = 3.0
  local vx, vy, vz
  local vOk = pcall(function()
    vx, vy, vz = Osi.FindValidPosition(x, y, z, validRadius, resolved, 1)
  end)
  if vOk and vx then
    targetX, targetY, targetZ = vx, vy, vz
  else
    -- Try smaller radius
    vOk = pcall(function()
      vx, vy, vz = Osi.FindValidPosition(x, y, z, 1.5, resolved, 1)
    end)
    if vOk and vx then
      targetX, targetY, targetZ = vx, vy, vz
    else
      -- Interpolate between current and target position
      local frac = 0.7  -- try 70% of the way
      for attempt = 1, 5 do
        local ix = cx + dx * frac
        local iy = cy + dy * frac
        local iz = cz + dz * frac
        vOk = pcall(function()
          vx, vy, vz = Osi.FindValidPosition(ix, iy, iz, 2.0, resolved, 1)
        end)
        if vOk and vx then
          targetX, targetY, targetZ = vx, vy, vz
          log("  INTERPOLATE: found valid position at " .. string.format("%.1f", frac*100) .. "% of path")
          break
        end
        frac = frac - 0.1  -- try closer positions
      end
    end
  end

  -- PASS #64: the walk is planned on the game's own route and within this turn's movement (see SkynetMove above).
  -- The old code only asked "does a path exist?" and then ordered a move to the raw point: an Osiris move ignores
  -- movement points and TELEPORTS the character when the walk is blocked or the point is not really reachable.
  local plan = SkynetMove.plan(resolved, targetX, targetY, targetZ)
  if not plan then
    -- PASS #34: "no path" is usually the valid-position search landing on a hazard surface; retry once with a
    -- much wider search before giving up. Never a teleport.
    log("  NO PATH: retrying with wider valid-position search for " .. resolved:sub(1,20))
    local wideOk, wx, wy, wz = pcall(function()
      return Osi.FindValidPosition(x, y, z, 6.0, resolved, 1)
    end)
    if wideOk and wx then plan = SkynetMove.plan(resolved, wx, wy, wz) end
    if plan and not plan.skip then
      log("  WIDE RETRY: found path via 6.0m valid-position search")
    elseif not plan then
      log("  MOVE FAILED: no path found even on wider retry — staying put")
      return false
    end
  end
  if plan.skip then
    log("  MOVE SKIPPED: " .. tostring(plan.skip))
    return false
  end
  targetX, targetY, targetZ = plan.x, plan.y, plan.z
  if plan.len > 10 then moveSpeed = "Sprint" elseif plan.len > 6 then moveSpeed = "Run" elseif plan.len > 3 then moveSpeed = "Walk" else moveSpeed = "Stroll" end

  -- Execute movement
  local ok2, err2 = pcall(function()
    Osi.CharacterMoveToPosition(resolved, targetX, targetY, targetZ, moveSpeed, "SkynetMove", 0)
  end)
  if ok2 then
    if Skynet_TurnQueued then Skynet_TurnQueued[resolved] = true end   -- PASS #60: a queued move counts as queued work
    SkynetMove.ordered(resolved, plan)
    log("  MOVE: " .. moveSpeed .. " to (" .. string.format("%.1f", targetX) .. "," .. string.format("%.1f", targetY) .. "," .. string.format("%.1f", targetZ) .. ") dist=" .. string.format("%.1f", distance) .. "m" ..
        string.format(" — walking %.1fm of a %.1fm route (%.1fm of movement left before this)%s", plan.len, plan.total, plan.avail, plan.clamped and ", stopping where the movement runs out" or ""))
    return true
  end
  -- PASS #64: no more fallbacks (Proc_ProcObjectMove / dash + move): each was another unchecked story move.
  log("  MOVE FAILED: " .. tostring(err2) .. " — staying put")
  return false
end

local function Skynet_FindNearestPlayer(enemyId, players)
  local nearestDist = 999
  local nearestTarget = nil
  for _, p in ipairs(players or {}) do
    local pid = tostring(p)
    if IsValidTarget(enemyId, pid) then
      local dist = GetDistanceBetween(enemyId, pid)
      if dist < nearestDist then
        nearestDist = dist
        nearestTarget = pid
      end
    end
  end
  return nearestTarget, nearestDist
end

-- Hazard-aware movement: scans for fire/acid/poison/etc surfaces
-- and finds a safe position to move to.
local HAZARD_TYPES = {
  Fire = true, Acid = true, Poison = true,
  Electrified = true, Hellfire = true, Web = true, Oil = true,
  Blood = true, Ice = true,
}

local function Skynet_GetHazardsAt(x, y, z, radius)
  local hazards = {}
  local r = radius or 2.0
  local ok, result = pcall(function()
    return Osi.GetSurfacesInArea(x, y, z, r)
  end)
  if ok and result then
    for _, s in ipairs(result) do
      if HAZARD_TYPES[s.Type] then table.insert(hazards, s) end
    end
  end
  return hazards
end

-- Direct check: query surface type at an exact position (works when GetSurfacesInArea fails)
local function Skynet_IsSurfaceDangerousAt(x, y, z)
  local ok, surfaceType = pcall(function()
    return Osi.GetSurfaceChargeAtPosition(x, y, z)
  end)
  if ok and surfaceType and HAZARD_TYPES[surfaceType] then
    return true
  end
  -- Also try GetSurfaceAtPosition
  local ok2, surface2 = pcall(function()
    return Osi.GetSurfaceAtPosition(x, y, z)
  end)
  if ok2 and surface2 and HAZARD_TYPES[surface2] then
    return true
  end
  return false
end

local function Skynet_IsPositionSafe(x, y, z)
  if #Skynet_GetHazardsAt(x, y, z) > 0 then return false end
  -- Fallback: direct surface query (catches when GetSurfacesInArea fails)
  if Skynet_IsSurfaceDangerousAt(x, y, z) then return false end
  return true
end

local function Skynet_FindSafePositionNear(targetX, targetY, targetZ, searchRadius)
  if Skynet_IsPositionSafe(targetX, targetY, targetZ) then
    return targetX, targetY, targetZ
  end
  -- Expanding ring search around target
  for r = 1, math.floor(searchRadius or 6) do
    for angle = 0, 315, 45 do
      local rad = math.rad(angle)
      local px = targetX + math.cos(rad) * r
      local pz = targetZ + math.sin(rad) * r
      if Skynet_IsPositionSafe(px, targetY, pz) then
        return px, targetY, pz
      end
    end
  end
  return nil -- no safe position found
end

local function Skynet_PathHasHazards(startX, startY, startZ, endX, endY, endZ)
  local dx, dy, dz = endX - startX, endY - startY, endZ - startZ
  local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
  if dist < 0.5 then return false end
  -- Sample every 1m for tight hazard detection
  local steps = math.max(4, math.floor(dist / 1.0))
  for i = 1, steps do
    local t = i / (steps + 1)
    local sx, sy, sz = startX + dx * t, startY + dy * t, startZ + dz * t
    if #Skynet_GetHazardsAt(sx, sy, sz) > 0 then return true end
    if Skynet_IsSurfaceDangerousAt(sx, sy, sz) then return true end
  end
  return false
end

-- Find a disabling spell dynamically by checking spell effects and name patterns
-- Works with ANY spell mod — no hardcoded spell names needed
local DISABLE_STATUSES = {
  STUNNED = true, PARALYZED = true, FRIGHTENED = true, BLINDED = true,
  SLEEPING = true, UNCONSCIOUS = true, CHARMED = true, TAUNTED = true,
  PRONE = true, RESTRAINED = true, PETRIFIED = true,
}
local DISABLE_NAME_PATTERNS = {
  "hold", "command", "fear", "sleep", "blind", "web", "stun",
  "paralyz", "frighten", "hypnotic", "tasha", "hideous_laughter",
  "banish", "slow", "confus", "charm", "dominate", "taunt", "daze",
  "sleet_storm", "grease", "entangle", "snare", "root", "bind",
}
local PUSH_NAME_PATTERNS = {
  "push", "shove", "throw", "telekinesis", "repelling", "gust",
  "thunderwave", "wind", "blast", "slam", "charge", "knockback",
}
local function FindDisablingSpell(enemyId)
  local spells = GetEnemyAvailableSpells(enemyId) or {}
  -- Priority 1: Check spell effects (ApplyStatuses) for disable conditions
  for _, spell in ipairs(spells) do
    local stats = safeCall(Ext.Stats.Get, spell)
    if stats then
      -- Check ApplyStatuses for disable conditions
      local statuses = stats.ApplyStatuses
      if statuses then
        for _, statusEntry in pairs(statuses) do
          local statusName = tostring(statusEntry.Status or ""):upper()
          if DISABLE_STATUSES[statusName] then
            return spell
          end
        end
      end
      -- Check Boosts for status application
      local boosts = stats.Boosts
      if boosts then
        for _, boost in pairs(boosts) do
          local bStr = tostring(boost)
          for status, _ in pairs(DISABLE_STATUSES) do
            if bStr:find(status) then
              return spell
            end
          end
        end
      end
    end
  end
  -- Priority 2: Check name patterns (catches modded spells with custom names)
  for _, spell in ipairs(spells) do
    local s = string.lower(spell or "")
    for _, pattern in ipairs(DISABLE_NAME_PATTERNS) do
      if s:find(pattern) then
        return spell
      end
    end
  end
  return nil
end

-- Find a push/shove spell dynamically
local function FindPushSpell(enemyId)
  local spells = GetEnemyAvailableSpells(enemyId) or {}
  for _, spell in ipairs(spells) do
    local s = string.lower(spell or "")
    for _, pattern in ipairs(PUSH_NAME_PATTERNS) do
      if s:find(pattern) then
        return spell
      end
    end
  end
  return nil
end

-- Check if a character has a melee attack available
local function HasMeleeAttack(enemyId)
  local spells = GetEnemyAvailableSpells(enemyId) or {}
  for _, spell in ipairs(spells) do
    local s = string.lower(spell or "")
    if s:find("melee") or s:find("unarmed") or s:find("slash") or
       s:find("cleave") or s:find("thrust") or s:find("strike") then
      local props = GetSpellProperties(spell)
      if props and props.isMelee then
        return spell
      end
    end
  end
  return nil
end

local function Skynet_MoveToward(enemyId, targetId, desiredDist, players)
  if not enemyId or enemyId == "" or not targetId or targetId == "" then return false end
  -- Use position cache
  local function cachedGetPosition(uuid)
    if PositionCache[uuid] then
      local c = PositionCache[uuid]
      return c.x, c.y, c.z
    end
    local ok, x, y, z = pcall(function() return Osi.GetPosition(uuid) end)
    if ok and type(x) == "number" then
      PositionCache[uuid] = {x = x, y = y or 0, z = z or 0}
      return x, y or 0, z or 0
    end
    return nil
  end

  -- If currently standing on a hazard, prioritize fleeing to a safe position first
  local ex0, ey0, ez0 = cachedGetPosition(enemyId)
  if ex0 and not Skynet_IsPositionSafe(ex0, ey0, ez0) then
    log("  HAZARD FLEE: standing on hazard surface — evaluating escape options")

    -- Check for nearby enemies that could opportunity attack
    local adjacentThreats = GetAdjacentThreats(enemyId, players)
    local hasDisengage = false
    local disengageSpell = nil
    local enemySpells = GetEnemyAvailableSpells(enemyId) or {}
    for _, sp in ipairs(enemySpells) do
      local sl = string.lower(sp or "")
      if sl:find("disengage") or sl:find("tumble") then
        hasDisengage = true
        disengageSpell = sp
        break
      end
    end

    if #adjacentThreats == 0 then
      -- No threats — flee freely
      log("  HAZARD FLEE: no adjacent threats — fleeing to safe position")
      local safeX, safeY, safeZ = Skynet_FindSafePositionNear(ex0, ey0, ez0, 8.0)
      if safeX then
        Skynet_MoveToPosition(enemyId, safeX, safeY, safeZ)
        return true
      end
    elseif hasDisengage then
      -- Has threats but also has Disengage — use it then flee
      log("  HAZARD FLEE: adjacent threats but has " .. disengageSpell .. " — using it first")
      Skynet_ExecuteUseSpell(enemyId, disengageSpell, nil)
      local safeX, safeY, safeZ = Skynet_FindSafePositionNear(ex0, ey0, ez0, 8.0)
      if safeX then
        Skynet_MoveToPosition(enemyId, safeX, safeY, safeZ)
        return true
      end
    else
      -- Has threats and no Disengage — weigh hazard damage vs opportunity attack using AC/attack role
      local hazardDps = 2  -- rough estimate: fire does ~2 damage per turn
      -- Get enemy AC
      local enemyAC = 10
      local eOk, eEntity = pcall(function() return Ext.Entity.Get(resolveUuid(enemyId)) end)
      if eOk and eEntity and eEntity.Stats then
        local acOk, acVal = pcall(function() return eEntity.Stats.ArmorClass end)
        if acOk and acVal then enemyAC = acVal end
      end
      local totalThreat = 0
      local worstHitChance = 0
      for _, threat in ipairs(adjacentThreats) do
        local hitChance = GetOpportunityAttackThreat(enemyId, threat.id)
        totalThreat = totalThreat + hitChance
        if hitChance > worstHitChance then worstHitChance = hitChance end
      end
      -- Estimate opportunity attack damage: base 8 * average hit chance
      local avgHitChance = #adjacentThreats > 0 and (totalThreat / #adjacentThreats) or 0.5
      local oppAttackDmg = 8 * avgHitChance
      local stayCost = hazardDps
      local fleeCost = oppAttackDmg

      log("  HAZARD FLEE: AC check — enemy AC=" .. tostring(enemyAC) .. ", avg hit chance=" .. string.format("%.0f", avgHitChance * 100) .. "%, opp attack dmg=" .. string.format("%.1f", fleeCost))

      if stayCost < fleeCost then
        log("  HAZARD FLEE: staying in hazard (hazard=" .. stayCost .. " < expected opp attack=" .. string.format("%.1f", fleeCost) .. ")")
        return false  -- stay and take hazard damage, avoid opportunity attack
      else
        log("  HAZARD FLEE: fleeing despite opportunity attack (hazard=" .. stayCost .. " >= expected opp attack=" .. string.format("%.1f", fleeCost) .. ")")
        local safeX, safeY, safeZ = Skynet_FindSafePositionNear(ex0, ey0, ez0, 8.0)
        if safeX then
          Skynet_MoveToPosition(enemyId, safeX, safeY, safeZ)
          return true
        end
      end
    end
    log("  HAZARD FLEE: no safe escape found")
  end
  local ex, ey, ez = cachedGetPosition(enemyId)
  local px, py, pz = cachedGetPosition(targetId)
  if not (ex and px) then return false end

  -- Calculate destination: position at desiredDist from target
  local dx, dz = px - ex, pz - ez
  local dist = math.sqrt(dx*dx + dz*dz)
  if dist <= desiredDist then return true end
  local ratio = (dist - desiredDist) / dist
  local mx, mz = ex + dx * ratio, ez + dz * ratio

  -- Opportunity attack check: if moving would leave adjacent threats, consider staying
  if players and #players > 0 then
    local adjacentThreats = GetAdjacentThreats(enemyId, players)
    if #adjacentThreats > 0 then
      local totalThreat = 0
      for _, threat in ipairs(adjacentThreats) do
        totalThreat = totalThreat + GetOpportunityAttackThreat(enemyId, threat.id)
      end
      -- Check if this is a ranged character by examining their spells
      local isRangedChar = false
      local enemySpells = GetEnemyAvailableSpells(enemyId) or {}
      for _, sp in ipairs(enemySpells) do
        local spProps = GetSpellProperties(sp, enemyId)
        if spProps and spProps.isRanged and not spProps.isMelee then
          isRangedChar = true
          break
        end
      end
      -- A pure weapon-attacker (bandit archer, etc.) often has no real spellbook entries at
      -- all, so the scan above finds nothing either way — fall back to the actual equipped
      -- weapon (see Maintenance history pass #20).
      if not isRangedChar then
        local weaponInfo = Skynet_GetCasterWeaponRangeInfo(enemyId)
        if weaponInfo and weaponInfo.isRanged then isRangedChar = true end
      end
      -- Melee: if opportunity attack risk is high and target is far, don't move toward target
      if totalThreat > 0.5 and dist > 6 and not isRangedChar then
        log("  MOVE BLOCKED: high opportunity attack risk (threat=" .. string.format("%.2f", totalThreat) .. ") — staying put")
        return false
      end
      -- Ranged: if adjacent to threats, try to disable then create distance
      if isRangedChar and totalThreat > 0.3 then
        log("  RANGED FLEE: adjacent threats (threat=" .. string.format("%.2f", totalThreat) .. ") — disabling then fleeing")
        -- Move away from the most dangerous adjacent threat
        local worstThreat = nil
        local worstLevel = 0
        for _, threat in ipairs(adjacentThreats) do
          local tLevel = GetOpportunityAttackThreat(enemyId, threat.id)
          if tLevel > worstLevel then
            worstLevel = tLevel
            worstThreat = threat.id
          end
        end
        if worstThreat then
          -- SMART ESCAPE: try to disable the threat first to avoid opportunity attack
          local disableSpell = FindDisablingSpell(enemyId)
          if disableSpell then
            log("  SMART ESCAPE: casting " .. disableSpell .. " on threat " .. worstThreat:sub(1,20))
            Skynet_UseSpellOnTarget(enemyId, worstThreat, disableSpell)
          else
            -- No disable spell — try push spell to create distance
            local pushSpell = FindPushSpell(enemyId)
            if pushSpell then
              log("  SMART ESCAPE: pushing threat with " .. pushSpell)
              Skynet_UseSpellOnTarget(enemyId, worstThreat, pushSpell)
            else
              -- No disable or push — check if melee fallback is viable
              local meleeSpell = HasMeleeAttack(enemyId)
              if meleeSpell then
                local targetHp = 1.0
                local hpOk, hp = pcall(function() return Osi.GetHitpointsPercentage(worstThreat) / 100 end)  -- PASS #56: 0-100 -> fraction
                if hpOk and type(hp) == "number" then targetHp = hp end
                if targetHp < 0.5 then
                  log("  MELEE FALLBACK: " .. meleeSpell .. " on low-HP threat " .. worstThreat:sub(1,20))
                  Skynet_UseSpellOnTarget(enemyId, worstThreat, meleeSpell)
                  return true
                end
              end
            end
          end
          -- Now flee
          local tOk, tx, ty, tz = pcall(function() return Osi.GetPosition(worstThreat) end)
          if tOk and tx then
            local fleeX = ex + (ex - tx)
            local fleeZ = ez + (ez - tz)
            local fleeLen = math.sqrt((ex-tx)*(ex-tx) + (ez-tz)*(ez-tz))
            if fleeLen > 0.5 then
              fleeX = ex + (ex - tx) / fleeLen * 6
              fleeZ = ez + (ez - tz) / fleeLen * 6
            end
            Skynet_MoveToPosition(enemyId, fleeX, ey, fleeZ)
            return true
          end
        end
      end
    end
  end

  -- Hazard avoidance: check if destination or path is safe
  local destSafe = Skynet_IsPositionSafe(mx, ey, mz)
  local pathSafe = not Skynet_PathHasHazards(ex, ey, ez, mx, ey, mz)

  if destSafe and pathSafe then
    -- PASS #64: no route / no movement left is "could not move" (the caller then releases the turn to the base AI).
    return Skynet_MoveToPosition(enemyId, mx, ey, mz) ~= false
  end

  -- Find a safe alternative destination
  local sx, sy, sz = Skynet_FindSafePositionNear(mx, ey, mz)
  if sx then
    -- Check if path to safe alternative is clear
    if not Skynet_PathHasHazards(ex, ey, ez, sx, sy, sz) then
      Skynet_MoveToPosition(enemyId, sx, sy, sz)
      return true
    end
    -- Path to alternative also has hazards — move partway toward it
    local dx2, dz2 = sx - ex, sz - ez
    local d2 = math.sqrt(dx2*dx2 + dz2*dz2)
    if d2 > 0.5 then
      local r2 = math.min(1, 3.0 / d2) -- move 3m toward safe point
      Skynet_MoveToPosition(enemyId, ex + dx2 * r2, ey, ez + dz2 * r2)
      return true
    end
  end

  -- Fallback: move toward target but stop short of hazards (get as close as possible)
  local safeRatio = 0
  for i = 1, 20 do
    local t = i * 0.05
    local cx, cz = ex + dx * t, ez + dz * t
    if Skynet_IsPositionSafe(cx, ey, cz) then
      safeRatio = t
    else
      break
    end
  end
  if safeRatio > 0 then
    log("  HAZARD AVOIDANCE: moving as close as possible (" .. math.floor(safeRatio * dist) .. "m of " .. math.floor(dist) .. "m)")
    Skynet_MoveToPosition(enemyId, ex + dx * safeRatio, ey, ez + dz * safeRatio)
    return true
  end

  log("  HAZARD AVOIDANCE: completely blocked, enemy is stuck in hazards")
  return false
end

-- ==================== PHASE 0: SELF-PREPARE HELPERS ====================

local function IsMeleeAttacker(enemyId)
  local spells = GetEnemyAvailableSpells(enemyId) or {}
  for _, spell in ipairs(spells) do
    local props = GetSpellProperties(spell)
    if props and props.isMelee then return true end
  end
  return false
end

local function HasActiveBuff(enemyId, spellName)
  local props = GetSpellProperties(spellName)
  if props and props.applyStatuses then
    for _, status in ipairs(props.applyStatuses) do
      local hasStatus = false
      local ok, val = pcall(function() return Osi.HasStatus(enemyId, status) end)
      if ok and val == 1 then hasStatus = true end
      if hasStatus then return true end
    end
  end
  -- props.applyStatuses is never filled in anywhere, so the loop above could not see any buff; ask
  -- SkynetGates which statuses this spell applies and treat it as active if the enemy already has one.
  if SkynetGates then
    for _, status in ipairs(SkynetGates.statusesFor(spellName)) do
      local gOk, gVal = pcall(function() return Osi.HasStatus(enemyId, status) end)
      if gOk and gVal == 1 then return true end
    end
  end
  -- Also check for Shillelagh condition directly (10-turn duration)
  local sOk, sVal = pcall(function() return Osi.HasStatus(enemyId, "Shillelagh") end)
  if sOk and (sVal == 1 or sVal == true) then return true end
  return false
end

local function FindWeaponCoating(enemyId)
  local coatingTags = {"OBJ_Coating_", "OBJ_Oil_"}
  for _, tag in ipairs(coatingTags) do
    local item = nil
    local ok, val = pcall(function() return Osi.GetItemByTagInInventory(tag, enemyId) end)
    if ok and val then item = val end
    if item then return item end
  end
  return nil
end

local function FindStatPotion(enemyId)
  local potionTags = {"OBJ_Potion_Strength", "OBJ_Potion_Dexterity", "OBJ_Potion_Constitution", "OBJ_Elixir_"}
  for _, tag in ipairs(potionTags) do
    local item = nil
    local ok, val = pcall(function() return Osi.GetItemByTagInInventory(tag, enemyId) end)
    if ok and val then item = val end
    if item then return item end
  end
  return nil
end

local function FindHealingPotion(enemyId)
  -- PASS #37: the three higher tiers below were previously "OBJ_Potion_HealingGreater" /
  -- "HealingSuperior" / "HealingSupreme" (no underscore before the tier word) — checked
  -- directly against bg3.wiki's own "Stats ID" field for each item, the REAL stats IDs all
  -- have an underscore there (OBJ_Potion_Healing_Greater, etc.), so those three tags never
  -- actually matched anything in a live inventory. Only the base "OBJ_Potion_Healing" tier
  -- was ever findable — meaning any enemy carrying a Greater/Superior/Supreme healing
  -- potion (far more common than the base tier from roughly Act 1's second half onward)
  -- was invisible to this function the whole time. This alone likely explains a good part
  -- of "Skynet never seems to use potions." See Maintenance history pass #37.
  local healTags = {"OBJ_Potion_Healing", "OBJ_Potion_Healing_Greater", "OBJ_Potion_Healing_Superior", "OBJ_Potion_Healing_Supreme"}
  for _, tag in ipairs(healTags) do
    local item = nil
    local ok, val = pcall(function() return Osi.GetItemByTagInInventory(tag, enemyId) end)
    if ok and val then item = val end
    if item then return item end
  end
  return nil
end

-- Skynet_GetItemUseCost
-- ===========================
-- Returns "action", "bonusaction", or "unknown" for the real action-economy cost of
-- using itemId, read directly from its own stat data (Ext.Stats.Get(...).UseCosts) via
-- the item's stat name (Osi.GetStatString) — the same UseCosts field GetSpellProperties
-- already reads for spells (props.useCosts), just applied to an item instead. In vanilla
-- BG3 every potion checked for this pass (Healing, Antidote, Elixir of Health, Potion of
-- Vitality, Basilisk Oil, Remedial Potion) costs a Bonus Action — but the user specifically
-- flagged that a balance/overhaul mod could change that to a full Action, and asked for it
-- to be detected rather than assumed, since drinking a potion on the real Action while
-- still standing in melee range is a genuine tactical mistake (no action left to attack
-- with, and nothing done to avoid being hit back). See Skynet_SelfPrepare's healing-potion
-- branch for where this is used. See Maintenance history pass #37.
function Skynet_GetItemUseCost(itemId)
    if not itemId or itemId == "" then return "unknown" end
    local nameOk, statName = pcall(function() return Osi.GetStatString(itemId) end)
    if not nameOk or not statName or statName == "" then return "unknown" end
    local statsOk, stats = pcall(function() return Ext.Stats.Get(statName) end)
    if not statsOk or not stats then return "unknown" end
    local uc = string.lower(tostring(stats.UseCosts or ""))
    if uc == "" then return "unknown" end
    -- Check the more specific "bonusactionpoint" first — "actionpoint" is itself a
    -- substring of "bonusactionpoint", so checking it first would misclassify every
    -- bonus-action item as a full-action one.
    if uc:find("bonusactionpoint") then return "bonusaction" end
    if uc:find("actionpoint") then return "action" end
    return "unknown"
end

-- Skynet_FindConditionCurePotion
-- ===========================
-- Returns itemId, conditionName if the caster is currently suffering a curable condition
-- AND has a matching cure item in inventory — nil, nil otherwise. Real BG3 Stats IDs below
-- were all confirmed directly against bg3.wiki's "Stats ID" field for each item (not
-- guessed from a naming convention — Basilisk Oil and Remedial Potion in particular use
-- entirely different prefixes, "OBJ_Oil_Of_..." and "ALCH_Solution_...", than the
-- "OBJ_Potion_..." pattern the rest of this file's item tags follow). Paralyzed is
-- deliberately NOT checked here: a genuinely Paralyzed character is already fully handed
-- to base-game AI before Skynet_AITurn (and therefore Skynet_SelfPrepare) ever runs for
-- them at all (see ShouldBaseGameControl/BASE_GAME_STATUSES), so a cure-Paralyzed check
-- here would be dead code. See Maintenance history pass #37.
function Skynet_FindConditionCurePotion(enemyId)
    if not enemyId or enemyId == "" then return nil, nil end

    local function firstAvailable(tags)
        for _, tag in ipairs(tags) do
            local ok, item = pcall(function() return Osi.GetItemByTagInInventory(tag, enemyId) end)
            if ok and item then return item end
        end
        return nil
    end

    -- Poisoned — the user's own example ("if they are poisoned, they use antidotes if
    -- they have an antidote"). Checked via the SG_Poisoned status group (confirmed real —
    -- AdditionalSpellInteractions' own StatusGroups table lists it) so this also catches
    -- poison from any source, not just one specific status name.
    local poisonOk, isPoisoned = pcall(function() return Osi.HasActiveStatusWithGroup(enemyId, "SG_Poisoned") end)
    if poisonOk and isPoisoned == 1 then
        local item = firstAvailable({"OBJ_Antitoxin", "OBJ_Potion_Of_Vitality", "OBJ_Potion_Elixir_Of_Health", "ALCH_Solution_Potion_Remedy"})
        if item then return item, "Poisoned" end
    end

    -- Petrified — Basilisk Oil is the dedicated cure; Elixir of Health also reverses it
    -- per bg3.wiki (a documented divergence from its own tooltip, which claims Paralyzed).
    local petrifiedOk, isPetrified = pcall(function() return Osi.HasStatus(enemyId, "PETRIFIED") end)
    if petrifiedOk and isPetrified == 1 then
        local item = firstAvailable({"OBJ_Oil_Of_The_Basilisk", "OBJ_Potion_Elixir_Of_Health"})
        if item then return item, "Petrified" end
    end

    -- Blinded — Elixir of Health and Remedial Potion both cure it.
    local blindOk, isBlind = pcall(function() return Osi.HasActiveStatusWithGroup(enemyId, "SG_Blinded") end)
    if blindOk and isBlind == 1 then
        local item = firstAvailable({"OBJ_Potion_Elixir_Of_Health", "ALCH_Solution_Potion_Remedy"})
        if item then return item, "Blinded" end
    end

    return nil, nil
end

-- ==================== PASS #56: EXTRAORDINARY ACTIONS ONLY WHEN THE SITUATION CALLS FOR THEM ====================
-- apcs_RestSystem grants Heroic Action Surge, Hyper Focus and Dig Deeper to every humanoid NPC. Each comes with a
-- heavy after-effect (HeroicActionSurgeDelay / HyperFocusDelay / DigDeeperDelay), but Skynet treated the first two
-- as ordinary self-buffs and cast them on turn 1-2 of every fight. Per the user's rules:
--   * Dig Deeper    — the Second Wind situation (HP below Skynet_SecondWindHpPct), but ONLY when Second Wind is not
--                     available: not in the kit, or already spent this rest. Tracked once per LONG rest (see
--                     Skynet_GetSpellLimitBucket), as the user describes it.
--   * Hyper Focus   — HP below 80% AND this character's attacks this fight have mostly missed or done little
--                     damage (Skynet_OffenseRecord, fed by the UsingSpellOnTarget/AttackedBy listeners).
--   * Heroic Action Surge — the caster's side is losing the HP race: at least half of the opponents it is
--                     fighting are at least Skynet_SurgeHpMarginPct points healthier than the caster side's
--                     average. Works the same for enemies vs the party and for NPCs vs other NPCs (sides come
--                     from Osi.IsEnemy/IsAlly relative to the caster, not from "player or not").
-- Everything is a bare global (no top-level local slot; the chunk is at Lua's 200-local ceiling).
Skynet_SecondWindHpPct = 50     -- same threshold Skynet_SelfPrepare's Priority 4 heals at
Skynet_HyperFocusHpPct = 80
Skynet_SurgeHpMarginPct = 20
Skynet_OffenseMinAttempts = 3
Skynet_OffenseRecord = Skynet_OffenseRecord or {}

-- Osi.GetHitpointsPercentage is documented on a 0-100 scale (official Osiris docs example: "_Percentage < 70.0").
-- Returns 0-100, or nil if unknown.
function Skynet_HpPct(uuid)
  if not uuid or uuid == "" then return nil end
  local ok, v = pcall(function() return Osi.GetHitpointsPercentage(uuid) end)
  if ok and type(v) == "number" then return v end
  local eOk, hp, maxHp = pcall(function()
    local e = Ext.Entity.Get(uuid)
    return e.Health.Hp, e.Health.MaxHp
  end)
  if eOk and type(hp) == "number" and type(maxHp) == "number" and maxHp > 0 then return hp * 100 / maxHp end
  return nil
end

-- Second Wind counts as available when the kit has it and Skynet has not recorded it as spent this rest.
function Skynet_SecondWindAvailable(enemyId)
  for _, spell in ipairs(GetEnemyAvailableSpells(enemyId) or {}) do
    if string.lower(spell or ""):find("secondwind", 1, true) and not Skynet_HasUsedLimitedSpell(enemyId, spell) then
      return true
    end
  end
  return false
end

-- Splits the caster's combat into its own side and its opponents, relative to the caster itself.
function Skynet_CombatSides(enemyId)
  local own, opp = { enemyId }, {}
  local me = resolveUuid(enemyId)
  for _, c in ipairs(Skynet_GetKnownCombatants(enemyId) or {}) do
    local cid = tostring(c)
    if resolveUuid(cid) ~= me and not IsInvokeDuplicityDuplicate(cid) then
      local deadOk, dead = pcall(function() return Osi.IsDead(cid) end)
      if not (deadOk and dead == 1) then
        local eOk, isEnemy = pcall(function() return Osi.IsEnemy(enemyId, cid) end)
        local aOk, isAlly = pcall(function() return Osi.IsAlly(enemyId, cid) end)
        if eOk and isEnemy == 1 then
          opp[#opp + 1] = cid
        elseif aOk and isAlly == 1 then
          own[#own + 1] = cid
        end
      end
    end
  end
  return own, opp
end

-- Heroic Action Surge rule. Returns allowed, explanation.
function Skynet_IsOutmatchedOnHp(enemyId)
  local own, opp = Skynet_CombatSides(enemyId)
  if #opp == 0 then return false, "no opponents" end
  local sum, n = 0, 0
  for _, c in ipairs(own) do
    local p = Skynet_HpPct(c)
    if p then sum = sum + p; n = n + 1 end
  end
  if n == 0 then return false, "own HP unknown" end
  local ownAvg = sum / n
  local higher, known = 0, 0
  for _, c in ipairs(opp) do
    local p = Skynet_HpPct(c)
    if p then
      known = known + 1
      if p >= ownAvg + Skynet_SurgeHpMarginPct then higher = higher + 1 end
    end
  end
  local why = string.format("own side avg %.0f%% (%d), %d of %d opponents at %.0f%%+", ownAvg, n, higher, #opp,
    ownAvg + Skynet_SurgeHpMarginPct)
  return known > 0 and higher * 2 >= #opp, why
end

-- Hyper Focus rule part 2: has this character's offence been failing this fight?
function Skynet_IsOffenseFailing(enemyId)
  local rec = Skynet_OffenseRecord[resolveUuid(enemyId)]
  if not rec or rec.combat ~= tostring(CurrentCombatId or "") then return false, "no attacks recorded this fight" end
  local attempts = math.max(rec.nAttempts or 0, rec.nHits or 0)  -- hits from turns Skynet didn't plan still count
  if attempts < Skynet_OffenseMinAttempts then
    return false, string.format("only %d attack(s) so far", attempts)
  end
  local hitRate = (rec.nHits or 0) / attempts
  local avgDmg = (rec.damage or 0) / attempts
  -- "Not doing much damage": under 10% of the average opponent's max HP per attack.
  local _, opp = Skynet_CombatSides(enemyId)
  local maxSum, maxN = 0, 0
  for _, c in ipairs(opp) do
    local ok, mx = pcall(function() return Ext.Entity.Get(c).Health.MaxHp end)
    if ok and type(mx) == "number" and mx > 0 then maxSum = maxSum + mx; maxN = maxN + 1 end
  end
  local lowDamage = maxN > 0 and avgDmg < 0.10 * (maxSum / maxN)
  local why = string.format("%d/%d hit, %.1f dmg per attack", rec.nHits or 0, attempts, avgDmg)
  return hitRate < 0.5 or lowDamage, why
end

-- ==================== PASS #57: RAGE ====================
-- Reported: a raging enemy cast Rage again at the start of every turn, and cast End Rage at party members.
--   * Rage was re-cast because "is the buff already on?" only knew the names RAGE / RAGE_TOTEM_BEAR etc. guessed
--     from the spell ID, not RAGE_2 / RAGE_FRENZY_2 / RAGE_TOTEM_*_2 (level 9+), Giant's Rage, or modded rages —
--     and with True Rage Unlimited the rage never times out, so every re-cast was pure waste. Now: any status in
--     the SG_Rage group (the group every rage status belongs to, bg3.wiki) means "already raging".
--   * End Rage (Shout_EndRage, bonus action) matched the "rage" self-buff name pattern, and PickBestTarget sent it
--     at a party member. bg3.wiki notes it lacks a Self() restriction, so it can even strip a raging target's
--     rage. Rage has real downsides (no spellcasting, no concentration — bg3.wiki Rage condition), but Skynet has
--     no rule yet for when dropping it is worth a bonus action, so Skynet never uses End Rage.
Skynet_RageGroupCache = Skynet_RageGroupCache or {}

function Skynet_IsRageStatusId(statusId)
  if not statusId or statusId == "" then return false end
  local cached = Skynet_RageGroupCache[statusId]
  if cached ~= nil then return cached end
  local gOk, inGroup = pcall(function() return Osi.IsStatusFromGroup(statusId, "SG_Rage") end)
  local result = gOk and (inGroup == 1 or inGroup == true) or false
  Skynet_RageGroupCache[statusId] = result
  return result
end

function Skynet_IsRaging(uuid)
  if not uuid or uuid == "" then return false end
  for _, name in ipairs({ "RAGE", "RAGE_2" }) do
    local ok, v = pcall(function() return Osi.HasStatus(uuid, name) end)
    if ok and (v == 1 or v == true) then return true end
  end
  local okL, list = pcall(function()
    local e = Ext.Entity.Get(uuid)
    return e and e.StatusContainer and e.StatusContainer.Statuses
  end)
  if okL and list then
    for _, sid in pairs(list) do
      if Skynet_IsRageStatusId(tostring(sid)) then return true end
    end
  end
  return false
end

function Skynet_IsEndRageSpell(spellId)
  local s = string.lower(tostring(spellId or ""))
  return s:find("endrage", 1, true) ~= nil or s:find("end_rage", 1, true) ~= nil
end

-- A spell that STARTS a rage: Shout_Rage and its variants (Frenzy, Totem, Wild Magic, Giant...), recognised by
-- name or by costing the Rage resource. End Rage is excluded.
Skynet_RageStartCache = Skynet_RageStartCache or {}
function Skynet_IsRageStartSpell(spellId)
  local id = tostring(spellId or "")
  if id == "" or Skynet_IsEndRageSpell(id) then return false end
  local cached = Skynet_RageStartCache[id]
  if cached ~= nil then return cached end
  local s = string.lower(id)
  local result = s:find("^shout_rage") ~= nil or s:find("ragemagerage", 1, true) ~= nil
  if not result and s:find("rage", 1, true) then
    local ok, uc = pcall(function() return Ext.Stats.Get(id).UseCosts end)
    result = ok and type(uc) == "string" and string.lower(uc):find("rage:", 1, true) ~= nil or false
  end
  Skynet_RageStartCache[id] = result
  return result
end

-- A spell whose TargetConditions only allow the caster ("Self()", "Self() and not Dead()"...). PickBestTarget
-- used to hand these a party member as the target.
Skynet_SelfOnlyCache = Skynet_SelfOnlyCache or {}
function Skynet_IsSelfOnlySpell(spellId)
  local id = tostring(spellId or "")
  if id == "" then return false end
  local cached = Skynet_SelfOnlyCache[id]
  if cached ~= nil then return cached end
  local ok, tc = pcall(function() return Ext.Stats.Get(id).TargetConditions end)
  local result = false
  if ok and type(tc) == "string" then
    local t = string.lower(tc):gsub("%s+", "")
    result = t:find("^self%(%)") ~= nil and not t:find("or", 1, true)
  end
  Skynet_SelfOnlyCache[id] = result
  return result
end

-- ==================== PASS #59: DIP ====================
-- Reported: Minthara, with only an Invoke Duplicity duplicate in view, spent every action casting Dip (Target_Dip)
-- "at" the duplicate. Dip coats your weapon from a surface or burning object and does nothing to a creature. It got
-- there through the attack FALLBACKS (Phase 2 "brute force" and Skynet_ExecuteDirect's "can anything reach?" scans),
-- which took the first spell in the list that could "reach" a target, attack or not — and Dip looked reachable from
-- 13 m because its range isn't a normal attack range. Rules now: Dip is never aimed at a character, never a scoring
-- candidate or fallback attack, and at most once per fight per caster even on a valid (non-character) target, since a
-- dipped weapon stays coated for most of a fight.
function Skynet_IsDipSpell(spellId)
  local s = string.lower(tostring(spellId or ""))
  return s == "target_dip" or s:find("^target_dip_") ~= nil or s:find("_dip$") ~= nil or s:find("_dip_", 1, true) ~= nil
end

function Skynet_IsCharacterTarget(target)
  local ok, v = pcall(function() return Osi.IsCharacter(target) end)
  if ok and v ~= nil then return v == 1 or v == true end
  local eOk, isChar = pcall(function() return Ext.Entity.Get(target).ServerCharacter ~= nil end)
  return eOk and isChar == true
end

-- May this spell be used by the attack fallbacks (which aim it at a hostile character)? Basic weapon attacks: yes.
-- Dip, and anything whose own data says it is utility / buff / healing / movement / summoning: no.
Skynet_NonAttackIntents = { utility = true, buff = true, healing = true, movement = true, summon = true }
function Skynet_IsAttackFallbackCandidate(spellId)
  local s = string.lower(tostring(spellId or ""))
  if Skynet_IsDipSpell(spellId) then return false end
  if BASIC_WEAPON_ATTACK_SPELLS[s] then return true end
  local ok, props = pcall(GetSpellProperties, spellId)
  if ok and props and Skynet_NonAttackIntents[string.lower(props.verbalIntent or "")] then return false end
  return true
end

Skynet_DipUsedInCombat = Skynet_DipUsedInCombat or {}

-- ==================== PASS #60: NO ATTACK -> THE BASE GAME AI TAKES OVER ====================
-- When Skynet's own choice gives it no real attack that reaches anyone, it no longer grabs "any spell that reaches"
-- (or casts a mobility spell "at" someone). It marks the turn and hands it to the base game AI: immediately if Skynet
-- hasn't queued anything yet this turn, otherwise once what it already queued has finished (SkynetFC hand-back), so
-- the base AI is never handed a half-resolved turn.
Skynet_NoAttackHandOff = Skynet_NoAttackHandOff or {}   -- enemy -> reason, this turn
Skynet_TurnQueued = Skynet_TurnQueued or {}             -- enemy -> true once Skynet queued a cast or a move this turn
function Skynet_MarkNoAttack(enemyId, reason)
  local key = resolveUuid(enemyId)
  if not Skynet_NoAttackHandOff[key] then
    Skynet_NoAttackHandOff[key] = reason or "no attack"
    log("  NO ATTACK: " .. tostring(reason) .. " — handing the turn to the base game AI")
  end
end

-- Single rule for all of these. Any other spell is always allowed.
function Skynet_ExtraordinaryAllowed(enemyId, spellId)
  local s = string.lower(tostring(spellId or ""))
  if Skynet_IsEndRageSpell(spellId) then
    return false, "Skynet never ends a rage (no rule yet for when it is worth a bonus action)"
  end
  if s:find("rage", 1, true) and Skynet_IsRageStartSpell(spellId) and Skynet_IsRaging(enemyId) then
    return false, "already raging"
  end
  if s:find("heroicactionsurge", 1, true) then
    return Skynet_IsOutmatchedOnHp(enemyId)
  elseif s:find("hyperfocus", 1, true) then
    local hp = Skynet_HpPct(enemyId)
    if not hp or hp >= Skynet_HyperFocusHpPct then
      return false, string.format("HP %s%% (needs < %d%%)", hp and string.format("%.0f", hp) or "?", Skynet_HyperFocusHpPct)
    end
    local failing, why = Skynet_IsOffenseFailing(enemyId)
    return failing, string.format("HP %.0f%%, %s", hp, why)
  elseif s:find("digdeeper", 1, true) then
    local hp = Skynet_HpPct(enemyId)
    if not hp or hp >= Skynet_SecondWindHpPct then
      return false, string.format("HP %s%% (needs < %d%%)", hp and string.format("%.0f", hp) or "?", Skynet_SecondWindHpPct)
    end
    if Skynet_SecondWindAvailable(enemyId) then
      return false, "Second Wind still available — use that first"
    end
    return true, string.format("HP %.0f%%, Second Wind spent or not in kit", hp)
  end
  return true, nil
end

local function FindHealSpell(enemyId)
  local spells = GetEnemyAvailableSpells(enemyId) or {}
  -- PASS #36: "secondwind" added so Second Wind (Shout_SecondWind) is picked up by this
  -- self-heal path, HP-gated at <50% by the caller (Skynet_SelfPrepare's Priority 4)
  -- the same as any other self-heal — see the matching note where it was excluded from
  -- the earlier, ungated self-buff loop. See Maintenance history pass #36.
  -- PASS #56: spells already spent this rest are skipped here (previously the first match was
  -- returned even when used, so the caller fell through to potions and a spent Second Wind
  -- could never hand over to Dig Deeper), and Dig Deeper is only offered as a last resort,
  -- under Skynet_ExtraordinaryAllowed's rule (Second Wind gone). Normal heals come first.
  local digDeeper = nil
  for _, spell in ipairs(spells) do
    local s = string.lower(spell or "")
    if not Skynet_HasUsedLimitedSpell(enemyId, spell) then
      if s:find("digdeeper") then
        digDeeper = digDeeper or spell
      elseif s:find("heal") or s:find("cure") or s:find("restoration") or s:find("lay_on_hands") or s:find("secondwind") then
        return spell
      end
    end
  end
  if digDeeper then
    local allowed, why = Skynet_ExtraordinaryAllowed(enemyId, digDeeper)
    if allowed then return digDeeper end
    log("  EXTRAORDINARY GATE: holding " .. digDeeper .. " — " .. tostring(why))
  end
  return nil
end

local function UseItemOnSelf(enemyId, itemId)
  local ok = pcall(function() Osi.Use(enemyId, itemId, 1) end)
  return ok
end

-- ==================== ENEMY DOWNED SYSTEM: ALLY HEALING AI ====================

local function FindAllyHealSpells(caster)
  local spells = GetEnemyAvailableSpells(caster) or {}
  local healSpells = {}
  for _, spell in ipairs(spells) do
    local s = string.lower(spell or "")
    if s:find("heal") or s:find("cure") or s:find("restoration")
       or s:find("lay_on_hands") then
      healSpells[#healSpells + 1] = spell
    end
  end
  return healSpells
end

local function CanHealTarget(caster, spell, target)
  local props = GetSpellProperties(spell)
  if not props then return false end
  local dist = GetDistanceBetween(caster, target)
  if dist > props.rangeMeters then return false end
  if not props.ignoresVisionBlock then
    local los = CheckLineOfSight(caster, target)
    if not los then return false end
  end
  return true
end

local function ScoreAllyHeal(caster, target, spell)
  local score = 0
  local props = GetSpellProperties(spell)
  if not props then return 0 end

  local cat = ClassifySpell(spell)
  score = score + (cat.selfbuff or 0) * 2

  local dist = GetDistanceBetween(caster, target)
  if dist < 6 then
    score = score + 10
  elseif dist < 12 then
    score = score + 5
  else
    score = score - 5
  end

  local downedAllies = GetDownedAllies(caster)
  if #downedAllies >= 3 then
    score = score + 15
  elseif #downedAllies >= 2 then
    score = score + 10
  elseif #downedAllies >= 1 then
    score = score + 5
  end

  if CombatHistory["heal_" .. target] and CombatHistory["heal_" .. target] > 0 then
    score = score - 10
  end

  return score
end

-- Instant death check: if downed enemy takes damage exceeding currentHP + maxHP
local PendingDownedHPBefore = {}

-- uuid -> true while Skynet's own downed-recovery logic is applying DEATHDOOR itself,
-- so the compatibility interceptor (which strips DEATHDOOR from enemies applied by other
-- mods, e.g. Rogue Test's Combat Mastery) doesn't strip the one Skynet just granted.
local Skynet_ExpectedDeathDoor = {}

-- Shared damage-type -> Osi.Die() death-type mapping, used by both the "overkill while
-- already downed" instant-death check and the "Death's Door, downed a second time" check.
-- Osi.Die takes its death type as a NUMBER (Ext.Enums.StatsDeathType); passing the name ("DoT", "Incinerate"...)
-- makes the call fail, and every Osi.Die below is inside a pcall, so the kill silently never happened. The names are
-- kept for the logs and turned into numbers here. Global (not a top-level local): this file is at the local limit.
Skynet_DeathTypeIds = { None = 0, Acid = 1, Chasm = 2, DoT = 3, Electrocution = 4, Explode = 5, Falling = 6, Incinerate = 7,
    KnockedDown = 8, Lifetime = 9, Necrotic = 10, Physical = 11, Psychic = 12, Radiant = 13, CinematicDeath = 14, Cold = 15,
    Disintegrate = 16 }
Skynet_NullGuid = "00000000-0000-0000-0000-000000000000"
function Skynet_DeathTypeId(name) return Skynet_DeathTypeIds[name] or 3 end

local function Skynet_DeathTypeForDamage(damageType)
    local deathType = "DoT"
    local dt = string.lower(damageType or "")
    if dt:find("fire") then deathType = "Incinerate"
    elseif dt:find("cold") then deathType = "Cold"
    elseif dt:find("acid") or dt:find("poison") then deathType = "Acid"
    elseif dt:find("lightning") or dt:find("electric") then deathType = "Electrocution"
    elseif dt:find("necro") then deathType = "Necrotic"
    elseif dt:find("radiant") then deathType = "Radiant"
    elseif dt:find("psychic") then deathType = "Psychic"
    end
    return deathType
end

-- Characters that should be controlled by base game AI (incapacitated, frightened, etc.)
local BaseGameControlled = {}
local BASE_GAME_STATUSES = {} -- built once from INCAPACITATING_STATUSES + FRIGHTENED_STATUSES + MOVEMENT_RESTRICTING_STATUSES
do
    for k, _ in pairs(INCAPACITATING_STATUSES) do BASE_GAME_STATUSES[k] = "incapacitated" end
    for k, _ in pairs(FRIGHTENED_STATUSES) do BASE_GAME_STATUSES[k] = "frightened" end
    for k, _ in pairs(MOVEMENT_RESTRICTING_STATUSES) do BASE_GAME_STATUSES[k] = "movement_restricted" end
end

-- Spider Queen egg cluster tracking — if any are alive, don't control the queen

-- NOTE: this file's top-level local-variable count is already at Lua's 200-local ceiling
-- (the whole file compiles as one flat top-level chunk, so every top-level `local` — this one
-- included — permanently occupies one of only 200 slots for the rest of the file). The
-- BASE_GAME_STATUSES-classifying logic below is therefore inlined here AND duplicated as a
-- nested local inside Skynet_RegisterAllOsirisListeners (for its StatusApplied/StatusRemoved
-- listeners) rather than factored into one shared top-level helper, which would have added
-- another permanent slot. Keep both copies in sync if this logic changes. See Maintenance
-- history pass #23.
local function ShouldBaseGameControl(uuid)
    if BaseGameControlled[uuid] ~= nil then return true end
    local ok, entity = pcall(function() return Ext.Entity.Get(uuid) end)
    if ok and entity and entity.ServerCharacter and entity.ServerCharacter.StatusManager and entity.ServerCharacter.StatusManager.Statuses then
        for _, status in pairs(entity.ServerCharacter.StatusManager.Statuses) do
            local st = tostring(status.StatusId)
            local reason = BASE_GAME_STATUSES[st]
            if not reason then
                -- Real BG3/Osiris status ID is "PARALYZED" (see the spelling note on
                -- INCAPACITATING_STATUSES above) — this group fallback additionally catches
                -- any OTHER paralysis-family status (Hold Person, Hold Monster, modded
                -- sources, etc.) that isn't individually hardcoded above.
                local gOk, isParalyzeGroup = pcall(function() return Osi.IsStatusFromGroup(st, "SG_Paralyzed") end)
                if gOk and isParalyzeGroup == 1 then reason = "incapacitated" end
            end
            if not reason then
                -- PASS #39: general "SG_Incapacitated" group fallback, the same real BG3
                -- status group SG_Paralyzed above is itself a member of — catches ANY
                -- incapacitating status (present or future, vanilla or modded) that isn't
                -- individually hardcoded in INCAPACITATING_STATUSES, the same way the
                -- SG_Paralyzed check already generalizes paralysis specifically. Root cause
                -- of a reported bug: the DSleep mod's own pre-sleep statuses (DWE_SLEEP,
                -- DWE_SLEEP_SLEEPY, DWE_SLEEP_SLEEPY_ACTIVE — applied the instant Sleep is
                -- cast, before the mod's own end-of-turn Constitution save decides whether
                -- the target actually falls into real, vanilla "SLEEP") all declare
                -- "SG_Incapacitated" in their own StatusGroups (confirmed by reading the
                -- mod's stat file directly) but were never individually hardcoded above —
                -- real "SLEEP"/"SLEEPING" already were, but not this mod's own three
                -- precursor statuses. That gap meant a character freshly put under DWE_SLEEP
                -- still had ITS OWN NEXT TurnStarted handled by Skynet instead of being
                -- deferred to base-game AI like every other incapacitating status is —
                -- exactly the kind of turn Skynet was never meant to touch. See Maintenance
                -- history pass #39.
                local iOk, isIncapGroup = pcall(function() return Osi.IsStatusFromGroup(st, "SG_Incapacitated") end)
                if iOk and isIncapGroup == 1 then reason = "incapacitated" end
            end
            if reason then
                BaseGameControlled[uuid] = reason
                return true
            end
        end
    end
    return false
end

local function Skynet_SelfPrepare(enemyId, players)
  if not enemyId or enemyId == "" then return false end

  -- Priority 0.5: Condition-cure potions (Poisoned/Petrified/Blinded)
  -- PASS #37: new. The user asked specifically for "if they are poisoned, they use
  -- antidotes if they have an antidote" — checked here, first, before any self-buff or
  -- healing, since an active debilitating condition is usually more urgent than a stat
  -- buff and independent of HP. See Skynet_FindConditionCurePotion above for exactly
  -- which real items cure which condition (each individually confirmed against
  -- bg3.wiki's own Stats ID field, not guessed). All condition-cure items checked here
  -- are confirmed Bonus Action in vanilla BG3, so no retreat-first logic is needed for
  -- this branch the way there is for the healing-potion branch below — but the real
  -- cost is still read via Skynet_GetItemUseCost rather than assumed, in case a mod
  -- changes it. See Maintenance history pass #37.
  do
    local cureItem, cureCondition = Skynet_FindConditionCurePotion(enemyId)
    if cureItem then
      log("  SELF-PREPARE: using condition-cure item for " .. tostring(cureCondition))
      UseItemOnSelf(enemyId, cureItem)
      local cureCost = Skynet_GetItemUseCost(cureItem)
      return true, (cureCost == "action") and "action" or "bonus"
    end
  end

  -- Priority 0.75: apcs_RestSystem rope tie-up (small AND medium/large candidates — pass #52
  -- extends this beyond small-tier for the first time, see below)
  -- PASS #43-#45: the user's own mod (apcs_RestSystem), layered on top of Gray's Bondage's
  -- original rope concept, gives small/sneaky creatures (goblins, kobolds, imps, gnomes,
  -- Rogues, this mod's own bandit ambushers — see Skynet_IsSmallRopeTieUpCandidate) a real,
  -- action-costing spell to tie up a party member: "if a small creature has the rope, they
  -- do attempt to tie up a party member... tried a reasonable amount of times... not every
  -- single time... but a good amount, because it is a good strategy." Checked here, right
  -- after condition-cure and before self-buff spells, as a proactive tactical setup move.
  -- Placed inside Skynet_SelfPrepare (rather than onTurnStarted, where this lived in pass
  -- #43/#44) specifically so the real Action this spell costs (UseCosts "ActionPoint:1" —
  -- corrected in pass #45 after the user clarified the free Target_apcs_Bandit_Rope_TieUp
  -- is Shared/BanditBehavior.lua's own exclusive bandit-ambusher spell, NOT this one) gets
  -- told to this turn's real resource ledger via `deductAction`, the same established
  -- pattern pass #37/#42 use for every other branch here — so Phase 2's `canAct()` check
  -- correctly skips a now-impossible follow-up attack instead of trying it anyway. The 40%
  -- per-turn roll (not a permanent cache) matches the user's "reasonable amount... not
  -- every single time" framing. See Skynet_IsSmallRopeTieUpCandidate/Skynet_TryApcsRopeTieUp
  -- and Maintenance history pass #43/#44/#45.
  --
  -- PASS #52: extended to medium/large-tier casters too (previously this whole priority was
  -- gated to small-tier only via Skynet_IsSmallRopeTieUpCandidate, so a medium/large enemy
  -- never attempted a direct tie-up at all). Now reads the real tier straight from
  -- apcs_RestSystem's own classifier (the same call Skynet_TryApcsRopeTieUp itself makes) so
  -- both tiers share one gate, and passes `preferGrappleSetup=true` into
  -- Skynet_TryApcsRopeTieUp unconditionally for small-tier (grappling first is a strict
  -- upgrade for them — see that function's own big comment) and only when the new risk-aware
  -- Skynet_ShouldGrappleBeforeTieUp helper says so for medium/large (per the user's explicit
  -- choice: grapple-first only when it's actually worth the extra turn — caster already hurt,
  -- or the likely target is a known hard hitter). Gating directly on `Mods.apcs_RestSystem`
  -- rather than reusing Skynet_IsSmallRopeTieUpCandidate's own non-apcs_RestSystem fallback,
  -- since Skynet_TryApcsRopeTieUp bails out immediately without that mod anyway regardless of
  -- tier classification — that fallback was already unreachable dead weight for this call
  -- site specifically. See Maintenance history pass #52.
  if (not IsActualAlly(enemyId)) and Mods and Mods.apcs_RestSystem then
    local tierOk75, tier75 = pcall(function()
      if Mods.apcs_RestSystem.APCSRopeTieUp and Mods.apcs_RestSystem.APCSRopeTieUp.GetTieUpDCTier then
        return Mods.apcs_RestSystem.APCSRopeTieUp.GetTieUpDCTier(enemyId)
      end
      return nil
    end)
    if tierOk75 and (tier75 == "small" or tier75 == "medium_large") and math.random(100) <= 40 then
      local preferGrappleSetup75 = (tier75 == "small") or Skynet_ShouldGrappleBeforeTieUp(enemyId)
      local tiedUp, tieUpCost = Skynet_TryApcsRopeTieUp(enemyId, nil, nil, nil, preferGrappleSetup75)
      if tiedUp then
        return true, tieUpCost
      end
    end
  end

  local spells = GetEnemyAvailableSpells(enemyId) or {}

  -- Priority 1: Self-buff spells
  for _, spell in ipairs(spells) do
    local cat = ClassifySpell(spell)
    -- Once-per-combat/rest resources (Action Surge, a boss's signature shout, etc.) don't
    -- reliably show as an "active buff" the way a normal duration-based buff status would —
    -- their effect is a one-time resource grant, not a lasting status HasActiveBuff can see.
    -- Without this check, that meant they looked perpetually "not yet cast" and got re-picked
    -- here every single turn, handing out a free extra action/resource forever instead of the
    -- once-per-window the real spell data (Cooldown) says it should be. See the LIMITED-USE
    -- SPELL TRACKING block near getEntityUuid for how usage is tracked and reset.
    -- Wildshape/Polymorph forms are self-buffs too, so this phase cast them first thing every turn
    -- (the console showed "SELF-PREPARE: casting buff Shout_WildShape_..."). Skip them unless the MCM
    -- option EnemyAllowWildshape is on; a long fight crashed right after one of these casts.
    -- PASS #56: Heroic Action Surge / Hyper Focus / Dig Deeper only when Skynet_ExtraordinaryAllowed says the
    -- situation calls for them (they were being cast here on turn 1-2 of every fight).
    local extraOk, extraWhy = true, nil
    if cat and cat.selfbuff > 0 and cat.mobility == 0 and not Skynet_HasUsedLimitedSpell(enemyId, spell) then
      extraOk, extraWhy = Skynet_ExtraordinaryAllowed(enemyId, spell)
      if not extraOk then
        log("  EXTRAORDINARY GATE: holding " .. spell .. " — " .. tostring(extraWhy))
      elseif extraWhy then
        log("  EXTRAORDINARY GATE: " .. spell .. " allowed — " .. tostring(extraWhy))
      end
    end
    if cat and cat.selfbuff > 0 and cat.mobility == 0 and not Skynet_HasUsedLimitedSpell(enemyId, spell)
       and extraOk
       and not Skynet_WildshapeBlocked(enemyId, cat, spell)
       and not (SkynetGates and SkynetGates.skipBuff(enemyId, spell)) then
      if not HasActiveBuff(enemyId, spell) then
        local s = string.lower(spell or "")
        -- Exclude heals, utility, non-buff spells, and free reactive abilities
        -- PASS #36: "secondwind" added here (Shout_SecondWind, per bg3.wiki's own UID for
        -- the ability) — reported live as enemies burning Second Wind as their very first
        -- action on turn 1, at full HP, for no reason. It wasn't excluded from this generic
        -- self-buff loop because it doesn't contain "heal"/"cure"/"restoration" the way the
        -- other exclusions here assume every self-heal does, and it also wasn't caught by
        -- FindHealSpell's matching below for the same reason — it fell into a gap between
        -- the two, landing in this ungated Priority 1 branch with zero HP awareness at all.
        -- Now routed instead through Priority 4 below (HP < 50%), matching the user's own
        -- description of when it's actually worth using. See Maintenance history pass #36.
        if not s:find("heal") and not s:find("cure") and not s:find("restoration") and
           not s:find("secondwind") and not s:find("digdeeper") and
           not s:find("help") and not s:find("throw") and not s:find("push") and
           not s:find("shove") and not s:find("disengage") and not s:find("dip") and
           not s:find("jump") and not s:find("leap") and not s:find("fly") and
           not s:find("teleport") and not s:find("misty") and not s:find("ethereal") and
           not s:find("dimension door") and not s:find("thunderstep") and not s:find("far step") and
           not s:find("readyattack") and not s:find("overwatch") and not s:find("opportunity") and
           not s:find("counter") and not s:find("riposte") and not s:find("reaction") then
          log("  SELF-PREPARE: casting buff " .. spell)
          local castOk = Skynet_ExecuteUseSpell(enemyId, spell, nil)
          if castOk then
            Skynet_MarkLimitedSpellUsed(enemyId, spell)
            if Skynet_IsWildshapeFormSpell(spell) then
              Skynet_WildshapeCastCombat[enemyId] = tostring(CurrentCombatId or "")
            end
            -- PASS #25: also remember (per-turn only, via LOSCache — see the matching note
            -- in ChooseBestAction's classification loop) that this exact spell was just cast
            -- here, so the turn's already-computed `bestSpell` doesn't get executed a second
            -- time on this same spell in Phase 1/2 for a no-cooldown ability (e.g. Mind
            -- Sanctuary as a Full-Illithid) that Skynet_HasUsedLimitedSpell has no way to know
            -- about at all.
            LOSCache["__castThisTurn__" .. spell] = true
          end
          -- PASS #42: this branch previously always returned bare `true` — `prepareCost`
          -- (the caller's second return value) came back nil, so this self-buff cast was
          -- never told to the turn's resource ledger at all, regardless of whether the real
          -- spell actually costs an Action or Bonus Action. Fixed by resolving the spell's
          -- own real UseCosts stat here (the same field GetSpellProperties already reads,
          -- parsed the same way Skynet_GetItemUseCost — pass #37 — already parses it for
          -- items) and reporting it back, so Phase 2's existing "if not canAct() then ..."
          -- check can correctly see a self-buff that spent a real action. A spell whose cost
          -- can't be identified (e.g. a genuinely free/reaction-type buff) still returns nil
          -- here, unchanged from before. See Maintenance history pass #42.
          local selfBuffCost = nil
          local sbPropsOk, sbProps = pcall(GetSpellProperties, spell, enemyId)
          if sbPropsOk and sbProps and sbProps.useCosts and sbProps.useCosts ~= "" then
            local sbUc = string.lower(sbProps.useCosts)
            if sbUc:find("bonusactionpoint") then
              selfBuffCost = "bonus"
            elseif sbUc:find("actionpoint") then
              selfBuffCost = "action"
            end
          end
          return true, selfBuffCost
        end
      end
    end
  end

  -- Priority 1.5: equip gear looted off a tied-up target (PASS #49)
  -- The user's own apcs_RestSystem strip mechanic (Shared/TieUpStripSystem.lua) transfers a
  -- tied-up character's unequipped gear directly into whoever attacked them. Per the user's
  -- explicit request this session: "on the next turn, if the enemy is a reasonable enough
  -- distance away that they can spare an action to equip, or they maybe have two action
  -- points, they should consider equipping the item they took... the item is now equipped
  -- by the enemy and the enemy can now use it against the party." Checked here, before
  -- weapon coating (coating should see whatever weapon just got equipped, not the old one),
  -- gated on whether an item is actually queued for this enemy (see the "Unequipped" Osiris
  -- listener registered in Skynet_RegisterAllOsirisListeners, pass #49) and on the
  -- distance/resource condition above. See Skynet_TryEquipLootedGear and Maintenance
  -- history pass #49.
  --
  -- PASS #50: Skynet_TryEquipLootedGear now returns a THIRD value — the cost of an Action
  -- Surge/Heroic Action Surge cast it may have used internally to free up the action this
  -- equip needed (see Skynet_TryGrantExtraAction). Both costs get threaded back to the caller
  -- (Skynet_AITurn, via Skynet_SelfPrepare's own third return value) so a resource genuinely
  -- spent on the surge isn't silently dropped from this turn's ledger.
  if Skynet_PendingLootedGear[enemyId] and #Skynet_PendingLootedGear[enemyId] > 0 then
    local equipped, equipCost, surgeCost = Skynet_TryEquipLootedGear(enemyId, players)
    if equipped then
      return true, equipCost, surgeCost
    end
  end

  -- Priority 2: Weapon coating
  if IsMeleeAttacker(enemyId) then
    local coating = FindWeaponCoating(enemyId)
    if coating then
      log("  SELF-PREPARE: applying weapon coating")
      UseItemOnSelf(enemyId, coating)
      return true
    end
  end

  -- Priority 3: Stat potions
  local potion = FindStatPotion(enemyId)
  if potion then
    log("  SELF-PREPARE: using stat potion")
    UseItemOnSelf(enemyId, potion)
    return true
  end

  -- Priority 4: Healing (when HP < 50%)
  -- PASS #56 BUGFIX: Osi.GetHitpointsPercentage returns 0-100 (official Osiris docs), but this compared it to
  -- 0.5 as if it were a 0-1 fraction — so this branch (Second Wind, heal spells, healing potions) only ever fired
  -- below half a percent of HP, i.e. practically never. Normalised to a fraction here.
  local hp = 1.0
  local hpVal = Skynet_HpPct(enemyId)
  if type(hpVal) == "number" then hp = hpVal / 100 end

  if hp < (Skynet_SecondWindHpPct / 100) then
    local healSpell = FindHealSpell(enemyId)
    -- PASS #36: gate through the existing limited-use tracker (same one Action Surge/
    -- Second Wind-style once-per-rest resources already use elsewhere in this file — see
    -- the LIMITED-USE SPELL TRACKING block). Harmless no-op for a normal, repeatable heal
    -- spell (real Cooldown="Default" -> Skynet_HasUsedLimitedSpell always returns false for
    -- those), but necessary now that FindHealSpell also matches Second Wind
    -- (Shout_SecondWind, a real once-per-short-rest resource): without this, an enemy
    -- dropping below 50% HP more than once in the same fight (before an actual short rest)
    -- would keep trying to recast Second Wind every time, the same "forced Osi.UseSpell
    -- doesn't reliably respect the engine's own cooldown state" risk passes #11/#12 already
    -- had to fix for other limited resources. See Maintenance history pass #36.
    if healSpell and not HasActiveBuff(enemyId, healSpell) and not Skynet_HasUsedLimitedSpell(enemyId, healSpell) then
      log("  SELF-PREPARE: healing with " .. healSpell .. " (HP=" .. math.floor(hp * 100) .. "%)")
      local healCastOk = Skynet_ExecuteUseSpell(enemyId, healSpell, nil)
      if healCastOk then
        Skynet_MarkLimitedSpellUsed(enemyId, healSpell)
      end
      -- PASS #50: resolve the real cost the same way Priority 1's self-buff branch already
      -- does (GetSpellProperties().useCosts), rather than returning bare `true` with no cost —
      -- this branch already handles a real once-per-short-rest resource (Shout_DigDeeper,
      -- BonusActionPoint:1, and Shout_SecondWind) that previously went untold to this turn's
      -- resource ledger, the exact gap pass #37's comment above (deductAction) already flagged
      -- as pre-existing and unaddressed for this specific branch.
      local healCost = nil
      local hcPropsOk, hcProps = pcall(GetSpellProperties, healSpell, enemyId)
      if hcPropsOk and hcProps and hcProps.useCosts and hcProps.useCosts ~= "" then
        local hcUc = string.lower(hcProps.useCosts)
        if hcUc:find("bonusactionpoint") then
          healCost = "bonus"
        elseif hcUc:find("actionpoint") then
          healCost = "action"
        end
      end
      return true, healCost
    end
    local healPotion = FindHealingPotion(enemyId)
    if healPotion then
      -- PASS #37: drinking a potion is a Bonus Action in vanilla BG3 (confirmed against
      -- bg3.wiki for every healing tier), so normally there's nothing to protect against
      -- here — the enemy can still move and attack the same turn regardless. But the user
      -- specifically flagged that a balance/overhaul mod could change potions to cost the
      -- real Action instead, and asked for that to be detected rather than assumed: if it
      -- does, drinking while standing adjacent to a threat wastes the entire turn AND
      -- leaves the enemy sitting in melee range having done nothing to defend itself —
      -- strictly worse than either attacking or repositioning. So when the real cost isn't
      -- confirmed to be a bonus action (covers both a genuine Action cost and the
      -- "unknown" case, erring toward caution), retreat to a safe position FIRST if
      -- there's an adjacent threat, using the same GetAdjacentThreats/FindLOSsafePosition
      -- primitives Skynet_PostAttackEscape already uses for the equivalent
      -- after-attack case. If no safe position can be found, drinks anyway rather than
      -- doing nothing — healing while still at risk beats not healing at all. See
      -- Maintenance history pass #37.
      local potionCost = Skynet_GetItemUseCost(healPotion)
      if potionCost ~= "bonusaction" and players and #players > 0 then
        local adjacentOk, adjacentThreats = pcall(GetAdjacentThreats, enemyId, players)
        if adjacentOk and adjacentThreats and #adjacentThreats > 0 then
          local safeOk, sx, sy, sz = pcall(FindLOSsafePosition, enemyId, players, 6.0)
          if safeOk and sx then
            log("  SELF-PREPARE: retreating before drinking healing potion (cost=" .. tostring(potionCost) .. ", adjacent threat)")
            Skynet_MoveToPosition(enemyId, sx, sy, sz)
          end
        end
      end
      log("  SELF-PREPARE: using healing potion (HP=" .. math.floor(hp * 100) .. "%)")
      UseItemOnSelf(enemyId, healPotion)
      return true, (potionCost == "action") and "action" or "bonus"
    end
  end

  return false
end

local function Skynet_MobilityPattern(spell)
  local s = string.lower(spell or "")
  return (s:find("dash") or s:find("sprint") or s:find("teleport") or
          s:find("fly") or s:find("misty") or s:find("shift") or s:find("haste") or
          s:find("jump") or s:find("leap") or s:find("ethereal") or s:find("dimension") or
          s:find("thunderstep") or s:find("far step") or s:find("blink") or
          s:find("shadow") or s:find("burrow") or s:find("displace") or
          s:find("warp") or s:find("hellcrawl") or s:find("astral") or
          s:find("dark currents") or s:find("benign transposition") or
          s:find("fleeting dream") or s:find("shifting winds") or
          s:find("supernatural attraction") or s:find("wild magic") or
          s:find("mobile flourish")) and
          not s:find("warding")
end

local function Skynet_NeedsPositionTarget(spell)
  local s = string.lower(spell or "")
  return s:find("jump") or s:find("leap") or s:find("teleport") or
         s:find("misty") or s:find("dimension") or s:find("ethereal") or
         s:find("blink") or s:find("shadow") or s:find("astral") or
         s:find("warp") or s:find("hellcrawl") or s:find("dark currents") or
         s:find("benign transposition") or s:find("fleeting dream") or
         s:find("shifting winds") or s:find("supernatural attraction") or
         s:find("wild magic") or s:find("mobile flourish") or
         s:find("thunderstep") or s:find("far step") or
         -- "fly"/"flight" spells relocate the caster the same way jump/leap/teleport do (and
         -- Skynet_ExecuteActionOnPosition's own isPositionSpell/isMobilitySpell checks already
         -- treat them identically) — omitting it here sent Fly spells down the entity-target
         -- execution path instead, where a nil target self-casts them as a no-op. See
         -- Maintenance history pass #19.
         s:find("fly") or s:find("flight")
end

local function Skynet_SuppressBaseAI(enemyId)
  if not enemyId or enemyId == "" then return end
  -- Remember the enemy's own archetype BEFORE it is blanked below, so Skynet_ReleaseBaseAI can give it back.
  if SkynetGates then SkynetGates.saveArchetype(enemyId) end
  -- Apply a pause component to prevent base game AI from acting
  pcall(function()
    Osi.ApplyStatus(enemyId, "PAUSED", -1, 0)
  end)
  -- Remove any conflicting archetype passives that would trigger AI decisions
  pcall(function()
    -- A blank archetype is something the base game never has on a character, so the engine's AI never ran with
    -- one; a valid do-nothing archetype is used instead.
    Osi.RequestSetBaseArchetype(enemyId, SkynetGates and SkynetGates.suppressArchetype(true) or "base")
  end)
end

local function Skynet_ReleaseBaseAI(enemyId)
  if not enemyId or enemyId == "" then return end
  pcall(function()
    Osi.RemoveStatus(enemyId, "PAUSED")
  end)
  -- Handing the turn to the base game AI: give it a valid archetype to work with. Skynet used to leave it
  -- blank for good, which left the base AI with nothing to plan with for the rest of the turn.
  if SkynetGates then
    local name, source, okR, why = SkynetGates.restoreArchetype(enemyId, true)
    log("  ARCHETYPE: gave " .. tostring(enemyId):sub(1,40) .. " '" .. tostring(name) .. "' — " .. tostring(why) ..
        " (own archetype from: " .. tostring(source) .. ")" .. (okR and "" or " — RequestSetBaseArchetype failed"))
  end
end

local actedThisTurn = {}

local function Skynet_ExecuteDirect(enemyId, players, summonPairs)
  local bestSpell = Skynet.ChooseBestAction(enemyId)
  -- PASS #60: no usable action from Skynet's own choice -> the base game AI takes over (no "any spell that reaches" scan).
  if not bestSpell then
    Skynet_MarkNoAttack(enemyId, "Skynet found no action to use")
    return false
  end

  -- Special handling for HatchEggs: target ALL egg clusters, not just one
  local sl = string.lower(bestSpell or "")
  if sl:find("hatchegg") or (sl:find("spiderqueen") and sl:find("hatch")) then
    local clusters = FindEggClustersNear(enemyId, 50.0)
    if #clusters > 0 then
      log("  HATCH EGGS: found " .. #clusters .. " clusters, casting on each")
      local castCount = 0
      for _, cluster in ipairs(clusters) do
        local ok, reason = Skynet_UseSpellOnTarget(enemyId, cluster.uuid, bestSpell)
        if ok then
          log("  HATCH EGGS: cast on " .. cluster.uuid:sub(1,30) .. " (" .. string.format("%.1f", cluster.dist) .. "m)")
          castCount = castCount + 1
        else
          log("  HATCH EGGS: failed on " .. cluster.uuid:sub(1,30) .. ": " .. tostring(reason))
        end
      end
      if castCount > 0 then
        log("  HATCH EGGS: hatched " .. castCount .. " clusters — switching to attack")
        return true
      end
    end
    -- No clusters found or all failed — no other planned action (PASS #60: hand-off below)
    log("  HATCH EGGS: no clusters found")
    bestSpell = nil  -- Clear so we pick an attack spell below
  end

  -- PASS #60: these used to be fallbacks — if Skynet's own choice was nothing, or a mobility spell because no attack
  -- reached, they scanned the spell list for the FIRST spell that could "reach" any target (that is how Dip got aimed
  -- at a duplicate in pass #59) or cast the mobility spell "at" a target. Per the user: if Skynet has no real way to
  -- attack, it must not grab whatever reaches — it hands the turn to the base game AI instead.
  if not bestSpell then
    Skynet_MarkNoAttack(enemyId, "Spider Queen found no egg cluster and has no attack")
    return false
  end
  if Skynet_MobilityPattern(bestSpell) or Skynet_NeedsPositionTarget(bestSpell) then
    Skynet_MarkNoAttack(enemyId, "no attack reaches any target (Skynet's best option was only " .. bestSpell .. ")")
    return false
  end
  local bestTarget = PickBestTarget(enemyId, bestSpell, players, summonPairs)
  if bestTarget then
    log("  EXECUTING: " .. bestSpell .. " -> " .. bestTarget:sub(1,40))
    local ok, reason = Skynet_UseSpellOnTarget(enemyId, bestTarget, bestSpell)
    if not ok then log("  CAST FAILED: " .. tostring(reason)) end
    return true
  end
  log("  NO TARGET for " .. bestSpell .. " — checking for self-buff")
  -- Only self-cast if the spell is a buff (healing, shield, etc.)
  local cat = ClassifySpell(bestSpell)
  local sl = string.lower(bestSpell or "")
  local isExcluded = sl:find("help") or sl:find("ethereal") or sl:find("teleport") or
                     sl:find("misty") or sl:find("dimension door") or sl:find("thunderstep") or
                     sl:find("far step") or sl:find("readyattack") or sl:find("overwatch") or
                     sl:find("opportunity") or sl:find("counter") or sl:find("riposte") or
                     sl:find("reaction")
  if cat and cat.selfbuff > 0 and not isExcluded then
    log("  SELF-BUFF: " .. bestSpell)
    Skynet_ExecuteUseSpell(enemyId, bestSpell, nil)
    return true
  end
  -- Not a buff — never self-attack; hand the turn to the base game AI (PASS #60)
  Skynet_MarkNoAttack(enemyId, "no valid target for " .. bestSpell)
  return false
end

local function Skynet_MoveTowardPosition(enemyId, targetId, moveDist)
  if not enemyId or enemyId == "" or not targetId or targetId == "" then return false end
  local xOk, ex, ey, ez = pcall(function() return Osi.GetPosition(enemyId) end)
  local pOk, px, py, pz = pcall(function() return Osi.GetPosition(targetId) end)
  if not (xOk and pOk and ex and px) then return false end
  local dx, dz = px - ex, pz - ez
  local dist = math.sqrt(dx*dx + dz*dz)
  if dist < 0.5 then return false end
  local ratio = moveDist / dist
  if ratio > 1 then ratio = 1 end
  Skynet_MoveToPosition(enemyId, ex + dx * ratio, ey, ez + dz * ratio)
  return true
end

-- Reposition with free movement (no action cost) to unlock better spells
local function Skynet_RepositionForBetterSpell(enemyId, players)
  local available = GetEnemyAvailableSpells(enemyId) or {}
  if #available == 0 then return false end

  -- Opportunity-attack awareness (pass #14): this whole function is a pure convenience
  -- move — walking a few meters to unlock a marginally better spell — unlike Phase 1's
  -- movement (which already checks this, see canMoveSafely above) this repositioning was
  -- never gated on adjacent threats at all, so an enemy could walk out of a party member's
  -- reach for a small spell-choice upgrade and eat a completely unnecessary free hit for
  -- it. Since the benefit here is minor and optional, skip repositioning entirely rather
  -- than trying to weigh cost/benefit — it's essentially never worth an opportunity attack.
  if players and #players > 0 then
    local adjacentThreats = GetAdjacentThreats(enemyId, players)
    if #adjacentThreats > 0 then
      local totalThreat = 0
      for _, threat in ipairs(adjacentThreats) do
        totalThreat = totalThreat + GetOpportunityAttackThreat(enemyId, threat.id)
      end
      if totalThreat > 0.3 then
        log("  REPOSITION BLOCKED: opportunity attack risk (threat=" .. string.format("%.2f", totalThreat) .. ") — staying put")
        return false
      end
    end
  end

  local nearestTarget, nearestDist = Skynet_FindNearestPlayer(enemyId, players)
  if not nearestTarget then return false end

  -- Check if any non-mobility spells could become reachable after ~4m of movement
  -- PASS #53: this loop computed `hDist` directly off the raw `players` list and moved
  -- toward whichever one happened to be barely out of range, with NO IsValidTarget/
  -- Skynet_IsTargetUndetected check at all — unlike every other target-resolution path in
  -- this file (Skynet_FindNearestPlayer two lines up, PickBestTarget, IsTargetReachable), so
  -- a hidden/sneaking/invisible party member who merely happened to be geometrically
  -- closest-to-in-range could get this enemy repositioned to step toward their exact real
  -- position — a genuine, confirmed gap (not just a detection-accuracy question) behind
  -- the user's repeated "Skynet still moves enemies toward hidden characters" reports. See
  -- Maintenance history pass #53.
  for _, spell in ipairs(available) do
    local props = GetSpellProperties(spell)
    if props and props.rangeMeters and props.rangeMeters > 3 and not props.isMelee then
      for _, p in ipairs(players) do
        local pid = tostring(p)
        if IsValidTarget(enemyId, pid) then
          local hDist = GetHorizontalDistance(enemyId, pid)
          if hDist > props.rangeMeters and hDist <= props.rangeMeters + 4 then
            -- Move 3.5m toward the nearest player (free movement, no action cost)
            log(string.format("  REPOSITION: %s barely out of range (%.1fm vs %.1fm range) — stepping closer", spell, hDist, props.rangeMeters))
            return Skynet_MoveTowardPosition(enemyId, pid, hDist - props.rangeMeters + 1.5)
          end
        end
      end
    end
  end

  -- Also check if moving slightly toward nearest player would improve melee access
  local curBest = Skynet.ChooseBestAction(enemyId)
  if curBest then
    local props = GetSpellProperties(curBest)
    if props and props.isMelee and nearestDist > 3 and nearestDist < 8 then
      log(string.format("  REPOSITION: stepping closer for melee (%.1fm away)", nearestDist))
      return Skynet_MoveTowardPosition(enemyId, nearestTarget, nearestDist - 2.5)
    end
  end

  return false
end

-- Find a position out of line of sight of all players
-- Scans directions around the enemy, picks first position where no player has LOS
local function FindLOSsafePosition(enemyId, players, moveDist)
  -- Use position cache for enemy position
  local ex, ey, ez
  if PositionCache[enemyId] then
    local c = PositionCache[enemyId]
    ex, ey, ez = c.x, c.y, c.z
  else
    local eOk, x, y, z = pcall(function() return Osi.GetPosition(enemyId) end)
    if eOk and type(x) == "number" then
      ex, ey, ez = x, y or 0, z or 0
      PositionCache[enemyId] = {x = ex, y = ey, z = ez}
    else
      return nil
    end
  end
  if not ex then return nil end

  local testDist = moveDist or 4.0

  -- Find direction away from nearest player
  local awayX, awayZ = 0, 0
  local nearDist = 999
  for _, p in ipairs(players or {}) do
    local pid = tostring(p)
    local px, py, pz
    if PositionCache[pid] then
      local c = PositionCache[pid]
      px, py, pz = c.x, c.y, c.z
    else
      local pOk, x, y, z = pcall(function() return Osi.GetPosition(pid) end)
      if pOk and type(x) == "number" then
        px, py, pz = x, y or 0, z or 0
        PositionCache[pid] = {x = px, y = py, z = pz}
      end
    end
    if px then
      local dx, dz = px - ex, pz - ez
      local d = math.sqrt(dx*dx + dz*dz)
      if d < nearDist then
        nearDist = d
        awayX = ex - px
        awayZ = ez - pz
      end
    end
  end

  local awayLen = math.sqrt(awayX*awayX + awayZ*awayZ)
  if awayLen < 0.1 then return nil end
  awayX, awayZ = awayX / awayLen, awayZ / awayLen

  -- Predefined 8 directions: forward (away), back, left, right, and diagonals
  local dirs = {
    {awayX, awayZ},                                       -- away from player
    {-awayX, -awayZ},                                     -- toward player (last resort)
    {-awayZ, awayX},                                      -- perpendicular left
    {awayZ, -awayX},                                      -- perpendicular right
    {(awayX - awayZ) * 0.707, (awayZ + awayX) * 0.707},  -- diagonal
    {(awayX + awayZ) * 0.707, (awayZ - awayX) * 0.707},  -- diagonal
    {-awayZ * 0.707, awayX * 0.707},                      -- diagonal
    {awayZ * 0.707, -awayX * 0.707},                      -- diagonal
  }

  for _, dir in ipairs(dirs) do
    local tx = ex + dir[1] * testDist
    local tz = ez + dir[2] * testDist

    if Skynet_IsPositionSafe(tx, ey, tz) then
      local visible = false
      for _, p in ipairs(players) do
        local pid = tostring(p)
        if IsValidTarget(enemyId, pid) then
          local px, py, pz
          if PositionCache[pid] then
            local c = PositionCache[pid]
            px, py, pz = c.x, c.y, c.z
          else
            local pOk, x, y, z = pcall(function() return Osi.GetPosition(pid) end)
            if pOk and type(x) == "number" then
              px, py, pz = x, y or 0, z or 0
              PositionCache[pid] = {x = px, y = py, z = pz}
            end
          end
          if px then
            local dx, dz = px - tx, pz - tz
            local dist = math.sqrt(dx*dx + dz*dz)
            if dist < 12 then
              visible = true
              break
            end
          end
        end
      end
      if not visible then
        return tx, ey, tz
      end
    end
  end

  return nil
end

-- Post-attack escape: only move out of LOS if no adjacent threats
-- `remainingAction`/`remainingBonusAction` (pass #42): the caller's OWN turn-resource ledger
-- (Skynet_AITurn's locals of the same name), passed in by value so this function's own
-- disable/push/melee-fallback casts can be gated by what's actually left, and the real cost
-- of whichever one it ends up casting can be reported back via this function's return value
-- for the caller to deduct. See Maintenance history pass #42 for the bug this closes: these
-- casts previously had no resource check at all, firing unconditionally regardless of
-- remaining action/bonus action, and nothing ever told the turn's ledger they'd spent
-- anything — a real gap, confirmed via direct code reading after a user-forwarded, technically
-- precise bug report (Nexus comment, see pass #42).
local function Skynet_PostAttackEscape(enemyId, players, remainingAction, remainingBonusAction)
  local spentCost = nil

  -- Resolve a spell's real action-economy cost type ("action"/"bonus"/nil-for-unknown-or-free)
  -- from its own UseCosts stat, the same field GetSpellProperties already reads and
  -- Skynet_GetItemUseCost (pass #37) already parses this exact same way for items — nothing
  -- in this file previously did this for a spell being cast from OUTSIDE the main attack
  -- phase's hardcoded "action"/"bonus" bookkeeping. Nested here (not top-level) since the file
  -- sits at the 200 top-level-local ceiling — see File layout note.
  local function resolveSpellCostType(spellId)
    local propsOk, props = pcall(GetSpellProperties, spellId, enemyId)
    if not propsOk or not props or not props.useCosts or props.useCosts == "" then return nil end
    local uc = string.lower(props.useCosts)
    if uc:find("bonusactionpoint") then return "bonus" end
    if uc:find("actionpoint") then return "action" end
    return nil
  end

  -- An unknown/free cost is deliberately NOT blocked — consistent with this file's existing
  -- "if unsure, don't block" posture elsewhere (e.g. Skynet_GetItemUseCost's own "unknown"
  -- fallback). Only a cost this function can actually identify as action/bonus is gated.
  local function canAffordCost(costType)
    if costType == "action" then return (remainingAction or 1) > 0 end
    if costType == "bonus" then return (remainingBonusAction or 1) > 0 end
    return true
  end

  -- Use position cache for enemy position
  local ex, ey, ez
  if PositionCache[enemyId] then
    local c = PositionCache[enemyId]
    ex, ey, ez = c.x, c.y, c.z
  else
    local eOk, x, y, z = pcall(function() return Osi.GetPosition(enemyId) end)
    if eOk and type(x) == "number" then
      ex, ey, ez = x, y or 0, z or 0
      PositionCache[enemyId] = {x = ex, y = ey, z = ez}
    else
      return
    end
  end
  if not ex then return end

  -- Check if this is a ranged character
  local isRangedChar = false
  local enemySpells = GetEnemyAvailableSpells(enemyId) or {}
  for _, sp in ipairs(enemySpells) do
    local spProps = GetSpellProperties(sp, enemyId)
    if spProps and spProps.isRanged and not spProps.isMelee then
      isRangedChar = true
      break
    end
  end
  -- Pure weapon-attackers with no real spellbook fall back to their actual equipped weapon.
  if not isRangedChar then
    local weaponInfo = Skynet_GetCasterWeaponRangeInfo(enemyId)
    if weaponInfo and weaponInfo.isRanged then isRangedChar = true end
  end

  local visible = false
  for _, p in ipairs(players) do
    local pid = tostring(p)
    local px, py, pz
    if PositionCache[pid] then
      local c = PositionCache[pid]
      px, py, pz = c.x, c.y, c.z
    else
      local pOk, x, y, z = pcall(function() return Osi.GetPosition(pid) end)
      if pOk and type(x) == "number" then
        px, py, pz = x, y or 0, z or 0
        PositionCache[pid] = {x = px, y = py, z = pz}
      end
    end
    if px then
      local dx, dz = px - ex, pz - ez
      local dist = math.sqrt(dx*dx + dz*dz)
      if dist < 15 then visible = true; break end
    end
  end

  if not visible then return end

  -- Check for adjacent threats — don't escape if someone is in melee range
  local adjacentThreats = GetAdjacentThreats(enemyId, players)
  if #adjacentThreats > 0 and not isRangedChar then
    -- Check if any adjacent threat is low HP (finish them off instead of running)
    for _, threat in ipairs(adjacentThreats) do
      local hpOk, hp = pcall(function() return Osi.GetHitpointsPercentage(threat.id) / 100 end)  -- PASS #56: 0-100 -> fraction
      if hpOk and type(hp) == "number" and hp < 0.3 then
        log("  POST-ATTACK: staying — adjacent target low HP (" .. string.format("%.0f", hp * 100) .. "%)")
        return
      end
    end

    -- Check if staying near ranged characters is advantageous
    local stayBonus = 0
    for _, threat in ipairs(adjacentThreats) do
      if IsNearbyRangedDisadvantage(enemyId, threat.id) then
        stayBonus = stayBonus + 8
      end
    end

    -- Calculate total opportunity attack risk of escaping
    local totalThreat = 0
    for _, threat in ipairs(adjacentThreats) do
      totalThreat = totalThreat + GetOpportunityAttackThreat(enemyId, threat.id)
    end

    -- If staying near ranged characters or opportunity attack risk is high, don't escape
    if stayBonus > 5 or totalThreat > 0.6 then
      log("  POST-ATTACK: staying — adjacent threats (risk=" .. string.format("%.2f", totalThreat) .. ", ranged_bonus=" .. stayBonus .. ")")
      return
    end
  end

  -- Ranged characters always try to create distance after attacking
  if isRangedChar then
    -- Check for adjacent threats — try to disable them first
    local adjThreats = GetAdjacentThreats(enemyId, players)
    if #adjThreats > 0 then
      local worstT = adjThreats[1].id
      local handled = false

      local disableSpell = FindDisablingSpell(enemyId)
      if disableSpell then
        local costType = resolveSpellCostType(disableSpell)
        if canAffordCost(costType) then
          log("  POST-ATTACK SMART ESCAPE: casting " .. disableSpell .. " on " .. worstT:sub(1,20))
          Skynet_UseSpellOnTarget(enemyId, worstT, disableSpell)
          spentCost = costType
          handled = true
        else
          log("  POST-ATTACK SMART ESCAPE: skipped " .. disableSpell .. " — no " .. tostring(costType) .. " remaining")
        end
      end

      if not handled then
        local pushSpell = FindPushSpell(enemyId)
        if pushSpell then
          local costType = resolveSpellCostType(pushSpell)
          if canAffordCost(costType) then
            log("  POST-ATTACK PUSH: " .. pushSpell .. " on " .. worstT:sub(1,20))
            Skynet_UseSpellOnTarget(enemyId, worstT, pushSpell)
            spentCost = costType
            handled = true
          else
            log("  POST-ATTACK PUSH: skipped " .. pushSpell .. " — no " .. tostring(costType) .. " remaining")
          end
        end
      end

      if not handled then
        local meleeSpell = HasMeleeAttack(enemyId)
        if meleeSpell then
          local bestMeleeTarget = nil
          local bestMeleeScore = -999
          for _, threat in ipairs(adjThreats) do
            local score = 0
            local hpOk, hp = pcall(function() return Osi.GetHitpointsPercentage(threat.id) / 100 end)  -- PASS #56: 0-100 -> fraction
            if hpOk and type(hp) == "number" and hp < 0.4 then
              score = score + 30
            end
            local proneOk, isProne = pcall(function() return Osi.HasStatus(threat.id, "PRONE") end)
            if proneOk and isProne == 1 then score = score + 20 end
            local stunOk, isStun = pcall(function() return Osi.HasStatus(threat.id, "STUNNED") end)
            if stunOk and isStun == 1 then score = score + 25 end
            if score > bestMeleeScore then
              bestMeleeScore = score
              bestMeleeTarget = threat.id
            end
          end
          if bestMeleeTarget and bestMeleeScore > 10 then
            local costType = resolveSpellCostType(meleeSpell)
            if canAffordCost(costType) then
              log("  MELEE FALLBACK: " .. meleeSpell .. " on " .. bestMeleeTarget:sub(1,20) .. " (score=" .. bestMeleeScore .. ")")
              Skynet_UseSpellOnTarget(enemyId, bestMeleeTarget, meleeSpell)
              return costType
            else
              log("  MELEE FALLBACK: skipped " .. meleeSpell .. " — no " .. tostring(costType) .. " remaining")
            end
          end
        end
      end
    end
    -- Flee from nearest player
    local nearestTarget, nearestDist = Skynet_FindNearestPlayer(enemyId, players)
    if nearestTarget then
      local tOk, tx, ty, tz = pcall(function() return Osi.GetPosition(nearestTarget) end)
      if tOk and tx then
        local fleeX = ex + (ex - tx)
        local fleeZ = ez + (ez - tz)
        local fleeLen = math.sqrt((ex-tx)*(ex-tx) + (ez-tz)*(ez-tz))
        if fleeLen > 0.5 then
          fleeX = ex + (ex - tx) / fleeLen * 8
          fleeZ = ez + (ez - tz) / fleeLen * 8
        end
        Skynet_MoveToPosition(enemyId, fleeX, ey, fleeZ)
        log("  POST-ATTACK RANGED: created distance from target")
        return spentCost
      end
    end
  end

  -- Safe to escape
  local safeX, safeY, safeZ = FindLOSsafePosition(enemyId, players, 4.0)
  if safeX then
    local eOk, ex, ey, ez = pcall(function() return Osi.GetPosition(enemyId) end)
    if eOk and ex and not Skynet_PathHasHazards(ex, ey, ez, safeX, safeY, safeZ) then
      Skynet_MoveToPosition(enemyId, safeX, safeY, safeZ)
      log("  POST-ATTACK ESCAPE: moved out of LOS")
    end
  end
  return spentCost
end

-- Get creature's movement distance per turn (reads Movement action resource)
local function GetCreatureMovementSpeed(uuid)
  local ok, entity = pcall(function() return Ext.Entity.Get(uuid) end)
  if ok and entity then
    -- Method 1: Check ActionResources directly
    if entity.ActionResources and entity.ActionResources.Resources then
      for resourceGuid, resourceData in pairs(entity.ActionResources.Resources) do
        if resourceData and resourceData[1] and resourceData[1].MaxAmount then
          -- Movement resource is typically the one with MaxAmount in range 3-30
          local maxAmt = resourceData[1].MaxAmount
          if maxAmt >= 3 and maxAmt <= 30 then
            return maxAmt
          end
        end
      end
    end
    -- Method 2: Check template boosts for ActionResource(Movement,...)
    local tplId = entity.GameObjectVisual and entity.GameObjectVisual.RootTemplateId
    if tplId then
      local ok2, tpl = pcall(function() return Ext.Template.GetTemplate(tplId) end)
      if ok2 and tpl and tpl.Boosts then
        local baseMovement = 9
        for boost in string.gmatch(tpl.Boosts, "[^;]+") do
          local delta = boost:match("ActionResource%(Movement,%s*(-?%d+)")
          if delta then
            baseMovement = baseMovement + tonumber(delta)
          end
        end
        return baseMovement
      end
    end
  end
  return 9  -- default BG3 movement distance
end

-- Read a character's REAL current action-resource amounts directly from the engine
-- (Ext.Entity.Get(uuid).ActionResources.Resources, keyed by a resource GUID resolved via
-- Ext.StaticData.Get(guid, "ActionResource").Name), rather than assuming a fixed "1 action +
-- 1 bonus action" every turn. This is what lets a mid-turn buff that grants an extra attack
-- (e.g. the Spider Queen's Enrage shout, which per the BG3 wiki grants +1 attack) actually
-- be detected and used instead of being silently capped by a hardcoded assumption.
-- Returns actionPoints, bonusActionPoints — either can be nil if the lookup fails, in which
-- case callers should fall back to their own default/tracked value rather than treating nil
-- as zero.
local function Skynet_GetRealActionPoints(uuid)
    local ok, entity = pcall(function() return Ext.Entity.Get(uuid) end)
    if not ok or not entity or not entity.ActionResources or not entity.ActionResources.Resources then
        return nil, nil
    end
    local actionPoints, bonusActionPoints = nil, nil
    for resourceGuid, entries in pairs(entity.ActionResources.Resources) do
        local nameOk, resDef = pcall(function() return Ext.StaticData.Get(resourceGuid, "ActionResource") end)
        local resName = nameOk and resDef and resDef.Name
        if resName == "ActionPoint" or resName == "BonusActionPoint" then
            local total = 0
            for _, entry in ipairs(entries or {}) do
                total = total + (entry.Amount or 0)
            end
            if resName == "ActionPoint" then
                actionPoints = total
            else
                bonusActionPoints = total
            end
        end
    end
    return actionPoints, bonusActionPoints
end

-- ==================== FULL CONTROL: SKYNET ENDS ITS OWN TURN ====================
-- Skynet_AITurn plans a whole turn in one go (~200 ms) and queues every action with the engine; the engine
-- then plays them out one after another over many seconds. The old onTurnStarted gave control back to the
-- base game AI the moment planning finished, so the base AI (whose archetype Skynet had blanked) was left
-- to work out what to do with whatever the turn had left, e.g. unspent bonus actions, while Skynet's
-- queued actions were still resolving. A crash in exactly that spot was seen again and again.
--
-- Now, when Skynet_AITurn runs to its normal end (a deliberate hand-off — no visible targets, no spell
-- selected, hidden target, stuck, incapacitated... — returns early and never reaches that point), control
-- stays with Skynet: this watch waits until the queued actions have all resolved and then ends the turn.
--   * drained : the engine's real action points are down to what Skynet's own ledger says is left
--   * quiet   : no cast in flight (UsingSpell without its CastSpell yet) and none resolved for a moment,
--               and the character is not moving (a retreat after an attack is still part of the turn)
--   * fallbacks: nothing at all happened for IDLE_MS, or MAX_MS passed in total.
-- Everything lives in this one table: the main chunk is at Lua's limit of 200 local variables.
local SkynetFC = {
  POLL_MS = 500,
  SETTLE_MS = 1500,
  IDLE_MS = 20000,
  MAX_MS = 90000,
  GRACE_MS = 12000,  -- after the hand-back: how long the base AI gets to finish the turn before Skynet ends it
  KEEP_SETTLE_MS = 2500,      -- PASS #62: leftovers kept by Skynet: quiet this long after its last cast -> end the turn
  KEEP_FIRST_CAST_MS = 6000,  -- PASS #62: ...but give a queued first cast this long to start before calling it quiet
  completed = {},  -- enemyId -> true once Skynet_AITurn ran to its normal end this turn
  ledger = {},     -- enemyId -> { spentAction, spentBonus, action, bonus } as Skynet's ledger ended
  watch = {},      -- enemyId -> watch record while Skynet waits for its queued actions
}

function SkynetFC.nowMs()
  return Ext.Utils.MonotonicTime and Ext.Utils.MonotonicTime() or 0
end

function SkynetFC.endTurnNow(enemyId, why)
  SkynetFC.watch[enemyId] = nil
  -- Only end a turn that is still this character's: if the engine already moved on, "ending its turn"
  -- would be wrong.
  local okC, combat = pcall(function() return Osi.CombatGetGuidFor(enemyId) end)
  if okC and combat and combat ~= "" then
    local okA, active = pcall(function() return Osi.CombatGetActiveEntity(combat) end)
    if okA and active and active ~= "" and resolveUuid(active) ~= resolveUuid(enemyId) then
      log("  END TURN skipped for " .. tostring(enemyId):sub(1,40) .. " (" .. why .. "): the turn already passed to " .. tostring(active):sub(1,30))
      Skynet_ReleaseBaseAI(enemyId)
      return
    end
  end
  Skynet_ReleaseBaseAI(enemyId)
  local ok, err = pcall(function() Osi.EndTurn(enemyId) end)
  log("  END TURN: Skynet ended the turn for " .. tostring(enemyId):sub(1,40) .. " (" .. why .. ")" ..
      (ok and "" or (" — EndTurn failed: " .. tostring(err))))
end

-- Skynet has done what it planned: give the enemy its archetype back and let the base game AI use whatever the
-- turn has left (with Skynet having spent most of it, there is little left to plan, which is what keeps the
-- base AI from hanging on a big spell list). The watch keeps running as a safety net: if the base AI has not
-- ended the turn GRACE_MS later, Skynet ends it.
function SkynetFC.handBack(enemyId, w, why)
  if w.handedBack then return end
  w.handedBack = SkynetFC.nowMs()
  log("  HAND BACK: " .. tostring(enemyId):sub(1,40) .. " (" .. why .. ") — the base game AI may finish the turn; Skynet ends it itself if it is not over in " ..
      math.floor(SkynetFC.GRACE_MS / 1000) .. " s")
  Skynet_ReleaseBaseAI(enemyId)
  -- PASS #61: movement diagnostics (only does anything when enabled in MCM)
  if SkynetMoveDiag and SkynetMoveDiag.onHandOff then
    pcall(SkynetMoveDiag.onHandOff, enemyId, "rest of the turn after Skynet's actions (" .. tostring(why) .. ")")
  end
end

function SkynetFC.watchTurn(enemyId, w)
  if SkynetFC.watch[enemyId] ~= w then return end   -- superseded, or the turn already ended
  local t = SkynetFC.nowMs()

  if w.handedBack then
    if t - w.handedBack >= SkynetFC.GRACE_MS then
      SkynetFC.endTurnNow(enemyId, "the base game AI had not finished the turn " .. math.floor(SkynetFC.GRACE_MS / 1000) .. " s after the hand-back")
      return
    end
    Ext.Timer.WaitFor(SkynetFC.POLL_MS, function() SkynetFC.watchTurn(enemyId, w) end)
    return
  end

  -- Movement counts as activity: a retreat queued after the last attack is part of the turn.
  local okP, x, _, z = pcall(function() return Osi.GetPosition(enemyId) end)
  if okP and x ~= nil and z ~= nil then
    if w.px ~= nil and (math.abs(x - w.px) + math.abs(z - w.pz)) > 0.25 then
      w.lastActivity = t
      w.lastResolved = t
    end
    w.px, w.pz = x, z
  end

  -- PASS #62: leftovers kept by Skynet. Don't wait for the engine's action points to read "drained" (that reading
  -- can stay flat all turn) — once Skynet's own casts have started and gone quiet, end the turn before the base
  -- game AI starts on the leftovers.
  if w.keep then
    local firstCastDue = w.sawCast or not w.queuedSomething or (t - w.startedAt) >= SkynetFC.KEEP_FIRST_CAST_MS
    if firstCastDue and w.nInflight == 0 and (t - w.lastResolved) >= SkynetFC.KEEP_SETTLE_MS then
      SkynetFC.endTurnNow(enemyId, "Skynet's actions are done; the leftovers stay with Skynet")
      return
    elseif t - w.lastActivity >= SkynetFC.IDLE_MS or t - w.startedAt >= SkynetFC.MAX_MS then
      SkynetFC.endTurnNow(enemyId, "no activity; the leftovers stay with Skynet")
      return
    end
    Ext.Timer.WaitFor(SkynetFC.POLL_MS, function() SkynetFC.watchTurn(enemyId, w) end)
    return
  end

  local ledger = SkynetFC.ledger[enemyId] or {}
  local realA, realB = Skynet_GetRealActionPoints(enemyId)
  local readable = realA ~= nil and realB ~= nil
  local drained = true
  if readable then
    if (ledger.spentAction or 0) > 0 and realA > (ledger.action or 0) then drained = false end
    if (ledger.spentBonus or 0) > 0 and realB > (ledger.bonus or 0) then drained = false end
  end
  local settle = readable and SkynetFC.SETTLE_MS or (SkynetFC.SETTLE_MS * 3)
  local quiet = w.nInflight == 0 and (t - w.lastResolved) >= settle

  if drained and quiet then
    SkynetFC.handBack(enemyId, w, "queued actions resolved")
  elseif t - w.lastActivity >= SkynetFC.IDLE_MS then
    SkynetFC.handBack(enemyId, w, string.format("no activity for %d s; engine has %s/%s action/bonus left, ledger %s/%s, %d cast(s) still in flight",
      math.floor(SkynetFC.IDLE_MS / 1000), tostring(realA), tostring(realB), tostring(ledger.action), tostring(ledger.bonus), w.nInflight))
  elseif t - w.startedAt >= SkynetFC.MAX_MS then
    SkynetFC.handBack(enemyId, w, "gave up waiting after " .. math.floor(SkynetFC.MAX_MS / 1000) .. " s")
  end
  Ext.Timer.WaitFor(SkynetFC.POLL_MS, function() SkynetFC.watchTurn(enemyId, w) end)
end

-- Called right after Skynet_AITurn ran to its normal end. Keeps Skynet in control and ends the turn
-- itself once the queued actions are done (within a couple of seconds if nothing was queued at all).
function SkynetFC.finishWhenDone(enemyId)
  local t = SkynetFC.nowMs()
  local w = { startedAt = t, lastActivity = t, lastResolved = t, inflight = {}, nInflight = 0 }
  -- PASS #62: the base game AI misused this enemy's leftovers before -> Skynet keeps them and ends the turn itself
  -- (not when Skynet had no attack at all this turn: pass #60 still hands that turn to the base game AI).
  local key = resolveUuid(enemyId)
  local keepWhy = Skynet_KeepsLeftovers and Skynet_KeepsLeftovers(enemyId)
  if keepWhy and not (Skynet_NoAttackHandOff and Skynet_NoAttackHandOff[key]) then
    w.keep = keepWhy
    w.queuedSomething = Skynet_TurnQueued and Skynet_TurnQueued[key] and true or false
  end
  SkynetFC.watch[enemyId] = w
  if w.keep then
    log("  FULL CONTROL: Skynet keeps control of " .. tostring(enemyId):sub(1,40) .. " until its queued actions finish, then ends the turn itself — leftovers are NOT handed to the base game AI (it " .. tostring(w.keep) .. ")")
  else
  log("  FULL CONTROL: Skynet keeps control of " .. tostring(enemyId):sub(1,40) .. " until its queued actions finish, then hands the turn back to the base game AI with the enemy's own archetype")
  end
  Ext.Timer.WaitFor(SkynetFC.POLL_MS, function() SkynetFC.watchTurn(enemyId, w) end)
end

-- Event feed for the watch (registered next to the other listeners). A cast starts with UsingSpell and
-- resolves with CastSpell, matched by story action id.
function SkynetFC.castStarted(caster, storyActionId)
  local w = SkynetFC.watch[resolveUuid(caster)]
  if not w then return end
  local sid = tostring(storyActionId or "")
  if sid ~= "" and not w.inflight[sid] then
    w.inflight[sid] = true
    w.nInflight = w.nInflight + 1
  end
  w.sawCast = true
  w.lastActivity = SkynetFC.nowMs()
end

function SkynetFC.castResolved(caster, storyActionId)
  local w = SkynetFC.watch[resolveUuid(caster)]
  if not w then return end
  local sid = tostring(storyActionId or "")
  if sid ~= "" and w.inflight[sid] then
    w.inflight[sid] = nil
    w.nInflight = w.nInflight - 1
  end
  local t = SkynetFC.nowMs()
  w.lastActivity = t
  w.lastResolved = t
end

function SkynetFC.turnEnded(character)
  local key = resolveUuid(character)
  local w = SkynetFC.watch[key]
  SkynetFC.watch[key] = nil
  -- The engine ended the turn before Skynet handed it back: the enemy must not be left without an archetype.
  if w and not w.handedBack then Skynet_ReleaseBaseAI(key) end
end

-- ==================== PASS #62: SPELL LIST ORDER, AID ACTIONS, LEFTOVER ACTIONS ====================
-- Reported live (Minthara): she only ever used Distract / Shove / Help, Help on the player's own character, and
-- Disengage without moving away.
-- (1) GetEnemyAvailableSpells kept the FIRST 20 entries of the spell book. The book starts with the common actions
--     every character has (Throw, Help, Distract, three Shoves, Unarmed, Grapple, Dash, Disengage, Hide, Jump, Dip,
--     ...), so a character with a big book (Minthara: 76) never had her weapon attacks or real spells looked at —
--     she was not out of spells, Skynet never saw them. Order now: weapon attacks, the character's own spells (up to
--     the cap), the movement/utility actions other Skynet systems rely on (always), then the leftover common actions
--     only while there is room. See Skynet_SpellListTier.
-- (2) Aid actions (Help, Distract) and Throw are never attack choices; Help is never cast on an enemy (chokepoint).
-- (3) The Shove / Help / Disengage in that log were the BASE GAME AI using what Skynet left over. User's rule: once
--     the base game AI misuses an enemy's leftovers (Help on someone it is fighting, Disengage and then not moving
--     away), Skynet stops handing that enemy's leftovers back: from its next turn Skynet spends a leftover bonus action
--     on something useful itself, or ends the turn when its own actions are done. Turns where Skynet has no attack at
--     all still go to the base game AI (pass #60).
Skynet_KeepLeftovers = Skynet_KeepLeftovers or {}   -- resolved uuid -> reason (rest of the session)
Skynet_DisengageWatch = Skynet_DisengageWatch or {} -- resolved uuid -> { x, z } where Disengage was used this turn
Skynet_DisengageMoveM = 1.5                          -- moving less than this after Disengage = "stayed put"

function Skynet_IsHelpSpell(spellId)
  local s = string.lower(tostring(spellId or ""))
  return s == "target_help" or s:find("^target_help_") ~= nil
end

-- Never an attack choice: Help / Distract only aid someone else's attack, and Throw / Improvised Weapon need an
-- object (or a light creature) to pick up — aimed at a fighter they just fail.
function Skynet_IsAidAction(spellId)
  local s = string.lower(tostring(spellId or ""))
  if Skynet_IsHelpSpell(s) then return true end
  if s:find("distract", 1, true) then return true end
  if s == "throw_throw" or s:find("improvisedweapon", 1, true) then return true end
  return false
end

-- 0 = weapon attack, 1 = the character's own spells/abilities, 2 = utility other systems need (movement, hide,
-- shove/grapple for pushes and rope tie-ups), 3 = common filler actions.
function Skynet_SpellListTier(spellId)
  local s = string.lower(tostring(spellId or ""))
  if s:find("mainhandattack", 1, true) or s:find("offhandattack", 1, true) then return 0 end
  if Skynet_IsAidAction(s) or s:find("unarmedattack", 1, true) or (Skynet_IsDipSpell and Skynet_IsDipSpell(s)) then return 3 end
  if s:find("jump", 1, true) or s:find("dash", 1, true) or s:find("disengage", 1, true) or s:find("tumble", 1, true)
     or s == "shout_hide" or s:find("^shout_hide_") or s:find("shove", 1, true) or s:find("grapple", 1, true) then
    return 2
  end
  return 1
end

-- spells: spell book ids in book order. Returns the list Skynet considers (see (1) above).
function Skynet_OrderSpellList(spells, maxSpells)
  local weapon, own, utility, unarmed, filler, seen = {}, {}, {}, {}, {}, {}
  for _, spellId in ipairs(spells or {}) do
    if not seen[spellId] then
      seen[spellId] = true
      local tier = Skynet_SpellListTier(spellId)
      if tier == 0 then weapon[#weapon + 1] = spellId
      elseif tier == 1 then own[#own + 1] = spellId
      elseif tier == 2 then utility[#utility + 1] = spellId
      elseif string.lower(spellId):find("unarmedattack", 1, true) then unarmed[#unarmed + 1] = spellId
      else filler[#filler + 1] = spellId end
    end
  end
  local list = {}
  for _, s in ipairs(weapon) do list[#list + 1] = s end
  -- No weapon attack in the book: the unarmed attack IS the weapon attack (monks, brawlers).
  if #weapon == 0 then
    for _, s in ipairs(unarmed) do list[#list + 1] = s end
  end
  for _, s in ipairs(own) do
    if #list >= maxSpells then break end
    list[#list + 1] = s
  end
  for _, s in ipairs(utility) do list[#list + 1] = s end
  if #weapon > 0 then
    for _, s in ipairs(unarmed) do
      if #list >= maxSpells then break end
      list[#list + 1] = s
    end
  end
  for _, s in ipairs(filler) do
    if #list >= maxSpells then break end
    list[#list + 1] = s
  end
  return list
end

function Skynet_KeepsLeftovers(uuid)
  return Skynet_KeepLeftovers[resolveUuid(uuid)]
end

function Skynet_FlagBaseAIMisuse(uuid, reason)
  local key = resolveUuid(uuid)
  if key == "" or Skynet_KeepLeftovers[key] then return end
  Skynet_KeepLeftovers[key] = reason
  log("BASE AI MISUSE: " .. key:sub(1, 40) .. " " .. reason .. " — from its next turn Skynet keeps this enemy's leftover actions instead of handing them to the base game AI")
end

-- UsingSpellOnTarget feed: an enemy casting Help on someone it is fighting. Skynet's own casts never get here
-- (Skynet_UseSpellOnTarget refuses them), so this is the base game AI.
function Skynet_OnPossibleMisuseCast(caster, target, spell)
  if not Skynet_IsHelpSpell(spell) then return end
  if caster == "" or target == "" or resolveUuid(caster) == resolveUuid(target) then return end
  if not IsActualEnemy(caster) then return end
  local ok, rel = pcall(function() return Osi.IsEnemy(caster, target) end)
  if ok and (rel == 1 or rel == true) then
    Skynet_FlagBaseAIMisuse(caster, "used Help on " .. tostring(target):sub(1, 40) .. ", someone it is fighting")
  end
end

-- CastSpell feed: remember where an enemy stood when it used Disengage this turn.
function Skynet_OnDisengageCast(caster, spell)
  if not string.lower(tostring(spell or "")):find("disengage", 1, true) then return end
  if caster == "" or not IsActualEnemy(caster) then return end
  local ok, x, _, z = pcall(function() return Osi.GetPosition(caster) end)
  if ok and x ~= nil and z ~= nil then
    Skynet_DisengageWatch[resolveUuid(caster)] = { x = x, z = z }
  end
end

-- TurnEnded feed: Disengage and then (nearly) the same spot = the point of Disengage was wasted.
function Skynet_CheckDisengageMoved(character)
  local key = resolveUuid(character)
  local rec = Skynet_DisengageWatch[key]
  if not rec then return end
  Skynet_DisengageWatch[key] = nil
  local ok, x, _, z = pcall(function() return Osi.GetPosition(character) end)
  if not (ok and x ~= nil and z ~= nil) then return end
  local moved = math.sqrt((x - rec.x) ^ 2 + (z - rec.z) ^ 2)
  if moved < Skynet_DisengageMoveM then
    Skynet_FlagBaseAIMisuse(character, string.format("used Disengage and then stayed where it was (moved %.1fm)", moved))
  end
end

-- Leftover bonus action for an enemy whose leftovers Skynet keeps: a bonus-action attack (off-hand attack, a
-- damaging bonus spell) on a valid target, or a bonus-action heal on itself when hurt. Returns true if one was cast.
-- Never Help/Distract/Throw, shoves, grapples, movement, Hide, Dip, or anything a Skynet gate refuses.
function Skynet_SpendLeftoverBonus(enemyId, players, summonPairs)
  local hp = Skynet_HpPct and Skynet_HpPct(enemyId) or 100
  local heal = nil
  for _, spell in ipairs(GetEnemyAvailableSpells(enemyId) or {}) do
    local tier = Skynet_SpellListTier(spell)
    local props = (tier == 0 or tier == 1) and GetSpellProperties(spell, enemyId) or nil
    local uc = props and string.lower(tostring(props.useCosts or "")) or ""
    local usable = props and uc:find("bonusactionpoint", 1, true)
      and not Skynet_HasUsedLimitedSpell(enemyId, spell)
      and not LOSCache["__castThisTurn__" .. spell]
      and not Skynet_MobilityPattern(spell) and not Skynet_NeedsPositionTarget(spell)
      and not (Skynet_ExtraordinaryAllowed and not Skynet_ExtraordinaryAllowed(enemyId, spell))
    if usable then
      local vi = string.lower(tostring(props.verbalIntent or ""))
      if tier == 0 or vi == "damage" then
        local target = PickBestTarget(enemyId, spell, players, summonPairs)
        if target then
          log("  LEFTOVER BONUS: " .. spell .. " -> " .. tostring(target):sub(1, 30) .. " (Skynet keeps this enemy's leftovers)")
          if Skynet_UseSpellOnTarget(enemyId, target, spell) then return true end
        end
      elseif vi == "healing" and not heal and hp < 50 then
        heal = spell
      end
    end
  end
  if heal then
    log("  LEFTOVER BONUS: " .. heal .. " on itself (" .. math.floor(hp) .. "% HP)")
    if Skynet_UseSpellOnTarget(enemyId, enemyId, heal) then return true end
  end
  log("  LEFTOVER BONUS: nothing useful — bonus action left unused (not handed to the base game AI)")
  return false
end

-- ==================== PASS #65: UNLOADED CROSSBOWS COST A BONUS ACTION TOO (apcs_RestSystem) ====================
-- The user's apcs_RestSystem mod makes crossbows need loading (Shared/Crossbows.lua, Status_Crossbows.txt). An NPC's
-- crossbow is unloaded (status apcs_CROSSBOW_UNLOADED) unless it has Bolt Loaded (apcs_CROSSBOW_LOADED, from the
-- bonus-action Load Bolt, apcs_Shout_LoadBolt); while unloaded, every ranged weapon attack that costs an Action also
-- costs a Bonus Action (UnlockSpellVariant(apcs_CrossbowRangedAttackCheck(), ModifyUseCosts(Add,BonusActionPoint,1,0))).
-- Skynet's own ledger only took an Action off for such a shot, so it went on planning bonus actions the enemy no
-- longer had (or a second unloaded shot the engine would refuse). Now every such shot Skynet casts also takes a
-- Bonus Action off the ledger, and an unloaded shot with no Bonus Action left is not cast. Without that mod the
-- statuses never exist and nothing changes.
-- "Ranged weapon attack that costs an Action" is the mod's own rule (apcs_Crossbows.khn / isLoadedShot in
-- Crossbows.lua): SpellRoll mentions RangedWeaponAttack (or one of three special shots), not a Throw_ spell, and
-- UseCosts has ActionPoint.
Skynet_XbowUnloaded = "apcs_CROSSBOW_UNLOADED"
Skynet_XbowLoaded = "apcs_CROSSBOW_LOADED"
Skynet_XbowSpecialShots = { projectile_arrowofsmokepowder = true, projectile_arcaneshot_seekingarrow = true, zone_arcaneshot_piercingarrow = true }
Skynet_XbowShotCache = Skynet_XbowShotCache or {}
Skynet_XbowExtraBonus = {}   -- resolved uuid -> Bonus Actions crossbow shots took this turn, not yet off the ledger
Skynet_XbowLoadQueued = {}   -- resolved uuid -> true: Skynet queued Load Bolt this turn, the next shot is loaded
Skynet_LedgerBonus = {}      -- resolved uuid -> the turn ledger's Bonus Actions left (set by Skynet_AITurn)

function Skynet_XbowText(v)
  if type(v) == "table" or type(v) == "userdata" then
    local parts = {}
    pcall(function() for _, x in pairs(v) do parts[#parts + 1] = tostring(x) end end)
    return table.concat(parts, ";")
  end
  return tostring(v or "")
end

function Skynet_IsXbowShot(spellId)
  local id = tostring(spellId or "")
  if Skynet_XbowShotCache[id] ~= nil then return Skynet_XbowShotCache[id] end
  local result = false
  pcall(function()
    local lower = string.lower(id)
    if lower:sub(1, 6) == "throw_" then return end
    local stats = Ext.Stats.Get(id)
    if not stats then return end
    local ranged = Skynet_XbowSpecialShots[lower] == true
      or Skynet_XbowText(stats.SpellRoll):find("RangedWeaponAttack", 1, true) ~= nil
    if not ranged then return end
    local costs = ";" .. Skynet_XbowText(stats.UseCosts):gsub("%s", "")
    result = costs:find(";ActionPoint:", 1, true) ~= nil
  end)
  Skynet_XbowShotCache[id] = result
  return result
end

function Skynet_XbowHas(uuid, status)
  local ok, r = pcall(function() return Osi.HasActiveStatus(uuid, status) end)
  return ok and (r == 1 or r == true)
end

-- True when this cast is an unloaded-crossbow shot that costs an extra Bonus Action.
function Skynet_XbowNeedsBonus(caster, spellId)
  if not Skynet_IsXbowShot(spellId) then return false end
  if not Skynet_XbowHas(caster, Skynet_XbowUnloaded) or Skynet_XbowHas(caster, Skynet_XbowLoaded) then return false end
  return not Skynet_XbowLoadQueued[resolveUuid(caster)]
end

-- Chokepoint check before a cast. Returns false, reason when an unloaded shot cannot be paid for.
function Skynet_XbowCanAfford(caster, spellId)
  if not Skynet_XbowNeedsBonus(caster, spellId) then return true end
  local key = resolveUuid(caster)
  local left = Skynet_LedgerBonus[key]
  if left == nil then return true end   -- not inside a Skynet-planned turn: the engine decides
  if left - (Skynet_XbowExtraBonus[key] or 0) <= 0 then
    return false, "unloaded crossbow and no Bonus Action left to load it"
  end
  return true
end

-- A cast was queued: book the extra Bonus Action of an unloaded shot / remember a queued Load Bolt.
function Skynet_XbowNoteCast(caster, spellId)
  local key = resolveUuid(caster)
  local lower = string.lower(tostring(spellId or ""))
  if lower:find("loadbolt", 1, true) then
    Skynet_XbowLoadQueued[key] = true
    return
  end
  if not Skynet_IsXbowShot(spellId) then return end
  if Skynet_XbowLoadQueued[key] then
    Skynet_XbowLoadQueued[key] = nil   -- this shot uses the bolt Skynet just loaded
    return
  end
  if Skynet_XbowHas(caster, Skynet_XbowUnloaded) and not Skynet_XbowHas(caster, Skynet_XbowLoaded) then
    Skynet_XbowExtraBonus[key] = (Skynet_XbowExtraBonus[key] or 0) + 1
    log("  CROSSBOW: " .. key:sub(1, 30) .. " fires " .. tostring(spellId) .. " unloaded — it also costs a Bonus Action (apcs_RestSystem)")
  end
end

-- Skynet_AITurn's ledger: take the booked Bonus Actions. Returns how many.
function Skynet_XbowTakeBonus(uuid)
  local key = resolveUuid(uuid)
  local n = Skynet_XbowExtraBonus[key] or 0
  Skynet_XbowExtraBonus[key] = nil
  return n
end

function Skynet_XbowBeginTurn(uuid)
  local key = resolveUuid(uuid)
  Skynet_XbowExtraBonus[key] = nil
  Skynet_XbowLoadQueued[key] = nil
  Skynet_LedgerBonus[key] = nil
end

-- ==================== PASS #63: TAKE THE TURN BACK WHEN A RESTRICTION ENDS AS THE TURN STARTS ====================
-- Reported live (Minthara): her turn was logged "BASE GAME CONTROL (incapacitated)" because the bear's Goading Roar
-- (TAUNTED) was still on her when TurnStarted fired — but TAUNTED wore off a moment later, right at the start of that
-- same turn, before she did anything. The base game AI still played the whole turn (Distract + three Shoves). Now:
-- when the last restricting status comes off within Skynet_TakeBackWindowMs of the turn starting, and the character
-- has not cast anything yet this turn, Skynet takes the turn back and plays it normally.
Skynet_BaseControlTurn = Skynet_BaseControlTurn or {}  -- resolved uuid -> { at, reason, cast } for the current turn
Skynet_TakeBackWindowMs = 4000

function Skynet_NoteBaseControlTurn(uuid, reason)
  local t = Ext.Utils.MonotonicTime and Ext.Utils.MonotonicTime() or 0
  Skynet_BaseControlTurn[resolveUuid(uuid)] = { at = t, reason = tostring(reason or "?"), cast = false }
end

function Skynet_NoteTurnCast(uuid)
  local rec = Skynet_BaseControlTurn[resolveUuid(uuid)]
  if rec then rec.cast = true end
end

function Skynet_ClearBaseControlTurn(uuid)
  Skynet_BaseControlTurn[resolveUuid(uuid)] = nil
end

-- Called when the last restricting status came off. True (and the reason) when Skynet should play this turn after
-- all; one chance per turn.
function Skynet_ShouldTakeBackTurn(uuid)
  local key = resolveUuid(uuid)
  local rec = Skynet_BaseControlTurn[key]
  if not rec then return false end            -- not this character's turn (or it already ended)
  Skynet_BaseControlTurn[key] = nil
  local t = Ext.Utils.MonotonicTime and Ext.Utils.MonotonicTime() or 0
  if rec.cast then
    log("  BASE GAME CONTROL: " .. key:sub(1, 40) .. " no longer restricted, but the base game AI is already acting this turn — it keeps the turn")
    return false
  end
  if t - rec.at > Skynet_TakeBackWindowMs then
    log("  BASE GAME CONTROL: " .. key:sub(1, 40) .. " no longer restricted " .. math.floor((t - rec.at) / 1000) .. " s into the turn — too late to take it back")
    return false
  end
  return true, rec.reason
end

local function Skynet_AITurn(enemyId, isAlly)
  if not enemyId or enemyId == "" then return end
  if actedThisTurn[enemyId] then return end
  if SkynetGates then SkynetGates.beginTurn(enemyId) end  -- a new plan: forget what earlier plans queued
  Skynet_NoAttackHandOff[resolveUuid(enemyId)] = nil   -- PASS #60
  SkynetMove.beginTurn(enemyId)                         -- PASS #64: this turn's movement ledger
  Skynet_XbowBeginTurn(enemyId)                         -- PASS #65: crossbow bonus-action bookkeeping
  Skynet_TurnQueued[resolveUuid(enemyId)] = nil

  local tStart = Ext.Utils.MonotonicTime and Ext.Utils.MonotonicTime() or nil

  -- ============================================================
  -- CONTINUOUS EVALUATION LOOP
  -- Track resources, re-evaluate after every action
  -- ============================================================
  -- Seed from the character's REAL current action resources rather than blindly assuming
  -- "1 action + 1 bonus action" — a buff already active at turn start (Haste, a prior
  -- Action Surge, etc.) can mean more is actually available. Falls back to the BG3-standard
  -- 1/1 if the live query fails for any reason.
  local realStartAction, realStartBonus = Skynet_GetRealActionPoints(enemyId)
  local remainingAction = realStartAction or 1      -- BG3 standard: 1 action per turn
  local remainingBonusAction = realStartBonus or 1  -- BG3 standard: 1 bonus action per turn
  -- Highest real resource count observed so far THIS TURN. Used by syncActionResources below
  -- to grant a mid-turn increase exactly once (edge-triggered) instead of on every loop pass
  -- (level-triggered) — see the comment there for why that distinction matters.
  local peakRealAction = remainingAction
  local peakRealBonus = remainingBonusAction
  Skynet_LedgerBonus[resolveUuid(enemyId)] = remainingBonusAction   -- PASS #65
  local totalActionsUsed = 0
  local MAX_ACTIONS_PER_TURN = 5  -- safety limit to prevent infinite loops

  local function canAct()
    return (remainingAction > 0 or remainingBonusAction > 0) and totalActionsUsed < MAX_ACTIONS_PER_TURN
  end

  local function deductAction(costType)
    if costType == "action" then
      remainingAction = remainingAction - 1
    elseif costType == "bonus" then
      remainingBonusAction = remainingBonusAction - 1
    end
    -- PASS #65: an unloaded crossbow shot (apcs_RestSystem) also took a Bonus Action.
    local xbowBonus = Skynet_XbowTakeBonus(enemyId)
    if xbowBonus > 0 then
      remainingBonusAction = math.max(0, remainingBonusAction - xbowBonus)
      log("  RESOURCES: -" .. xbowBonus .. " bonus action (loading the crossbow for that shot)")
    end
    Skynet_LedgerBonus[resolveUuid(enemyId)] = remainingBonusAction
    -- Free actions (movement) don't deduct anything
    totalActionsUsed = totalActionsUsed + 1
    log("  RESOURCES: action=" .. remainingAction .. " bonus=" .. remainingBonusAction .. " used=" .. totalActionsUsed)
  end

  -- Re-check real action-resource state and adopt any INCREASE over the highest real value
  -- we've seen so far this turn (peakRealAction/peakRealBonus) — never a decrease, and never
  -- twice for the same increase. This is edge-triggered on purpose.
  --
  -- Earlier version compared against remainingAction directly (which deductAction ticks down
  -- after every attack). That was a bug: live-testing showed the engine reporting a flat,
  -- non-decrementing resource count for the entire turn (e.g. "3" after every single attack,
  -- 5 attacks in a row) — apparently the resource pool this NPC-forced casting path reads
  -- doesn't reflect per-attack consumption the way it would for a player-driven action. Since
  -- remainingAction drops after each attack while the real reading stayed flat, comparing
  -- against remainingAction made every loop pass look like a brand-new grant, handing out
  -- the same one Enrage-style bonus over and over until the MAX_ACTIONS_PER_TURN safety cap
  -- kicked in — five attacks from what should have been one extra.
  --
  -- Comparing against a monotonic peak instead means a genuine increase (buff grants +1) is
  -- added to remainingAction exactly once via delta, and every subsequent read of that same
  -- flat/stale value is correctly ignored since it's no longer above the peak.
  local function syncActionResources()
    local realAction, realBonus = Skynet_GetRealActionPoints(enemyId)
    if realAction and realAction > peakRealAction then
      local delta = realAction - peakRealAction
      log("  RESOURCES: engine reports " .. realAction .. " action(s) available (previous peak " .. peakRealAction .. ") — picking up " .. delta .. " extra")
      remainingAction = remainingAction + delta
      peakRealAction = realAction
    end
    if realBonus and realBonus > peakRealBonus then
      local delta = realBonus - peakRealBonus
      log("  RESOURCES: engine reports " .. realBonus .. " bonus action(s) available (previous peak " .. peakRealBonus .. ") — picking up " .. delta .. " extra")
      remainingBonusAction = remainingBonusAction + delta
      peakRealBonus = realBonus
      Skynet_LedgerBonus[resolveUuid(enemyId)] = remainingBonusAction   -- PASS #65
    end
  end

  -- Attempt one attack (real spell + target), deducting the action it costs. Returns true if
  -- an attack was actually made. Used in a loop by attackWithRemainingResources below so any
  -- extra attack a mid-turn buff grants gets spent, not just detected.
  local function tryOneAttack(players, summonPairs)
    local attackSpell = Skynet.ChooseBestAction(enemyId)
    if attackSpell and (Skynet_MobilityPattern(attackSpell) or Skynet_NeedsPositionTarget(attackSpell)) then
      attackSpell = nil
    end
    if attackSpell then
      local bt = PickBestTarget(enemyId, attackSpell, players, summonPairs)
      if bt then
        log("  EXTRA ATTACK: " .. attackSpell .. " -> " .. bt:sub(1,30))
        Skynet_StepBackIfInvisible(enemyId, players, attackSpell)
        local castOk, castWhy = Skynet_UseSpellOnTarget(enemyId, bt, attackSpell)
        -- PASS #65: a refused cast (e.g. an unloaded crossbow with no Bonus Action left) is not an attack made.
        if castOk == false and castWhy == "crossbow_needs_bonus" then return false end
        deductAction("action")
        return true
      end
    end
    Skynet_StepBackIfInvisible(enemyId, players, Skynet.ChooseBestAction(enemyId))
    local ok = Skynet_ExecuteDirect(enemyId, players, summonPairs)
    if ok then
      deductAction("action")
      return true
    end
    return false
  end

  -- Called once the normal single-attack sequence below has run its course. Re-syncs real
  -- resources and, while any remain, keeps attacking — this is the actual mechanism that
  -- spends an extra attack from a mid-turn buff, not just the detection of one.
  --
  -- Gates on "canAct() and remainingAction > 0" rather than bare canAct(), same as the
  -- existing Dash-step call site further down. tryOneAttack below only ever deducts the
  -- "action" resource (it has no logic to detect/spend a bonus-action-cost spell), so
  -- remainingBonusAction never moves and sits at its starting value (typically 1) for the
  -- whole turn. Bare canAct()'s "remainingAction > 0 OR remainingBonusAction > 0" check means
  -- that leftover, never-spent bonus action alone kept this loop alive well past a real
  -- action count of zero in live testing — 2 legitimate attacks followed by 3 more the turn
  -- had no actual resource left to pay for, stopped only by hitting MAX_ACTIONS_PER_TURN.
  local function attackWithRemainingResources(players, summonPairs)
    if not players then return end
    syncActionResources()
    while canAct() and remainingAction > 0 do
      if not tryOneAttack(players, summonPairs) then break end
      syncActionResources()
    end
  end

  -- Clear per-turn position/LOS caches (positions may have changed since last creature)
  PositionCache = {}
  LOSCache = {}
  DistanceCache = {}
  SnapshotCache = {}
  CachedThreats = nil
  CachedBattlefield = nil

  -- Surprised units skip their turn entirely (base game control handles incapacitated/frightened)
  if IsSurprised(enemyId) then
    log("  SURPRISED — skipping turn for " .. enemyId:sub(1,40))
    actedThisTurn[enemyId] = true
    return
  end

  -- Check for downed allies and consider healing (weighted alongside other actions)
  if Settings.EnableEnemyDownedSystem and not isAlly then
    local downedAllies = GetDownedAllies(enemyId)
    if #downedAllies > 0 then
      log("  DOWNED ALLIES DETECTED: " .. #downedAllies .. " allies need healing")
      local healScore = 0
      local bestHealSpell = nil
      local healSpells = FindAllyHealSpells(enemyId)
      for _, spell in ipairs(healSpells) do
        if CanHealTarget(enemyId, spell, downedAllies[1].uuid) then
          local sc = ScoreAllyHeal(enemyId, downedAllies[1].uuid, spell)
          if sc > healScore then
            healScore = sc
            bestHealSpell = spell
          end
        end
      end
      if bestHealSpell and healScore > 20 then
        log("  PRIORITY HEAL: score " .. string.format("%.1f", healScore) .. " > threshold")
        Skynet_UseSpellOnTarget(enemyId, downedAllies[1].uuid, bestHealSpell)
        actedThisTurn[enemyId] = true
        return
      end
    end
  end

  -- ==================== SPIDER QUEEN CLUSTER PRIORITY ====================
  -- If this is a Spider Queen with detected egg clusters, prioritize hatching them
  local isSpiderQueen = false
  local tplOk, tpl = pcall(function() return Osi.GetTemplate(enemyId) end)
  if tplOk and tpl then
    local tplStr = tostring(tpl)
    if tplStr:find("SpiderQueen") or tplStr:find("Spider_Queen") or tplStr:find("Matriarch") then
      isSpiderQueen = true
    end
  end

  if isSpiderQueen then
    -- Quick target check for duplicate detection (include combat entities). Invoke
    -- Duplicity duplicates are now included directly by GetPlayerTargets() itself (see its
    -- Method 5 / Skynet_FindNearbyDuplicates — Maintenance history pass #6), so this no
    -- longer needs its own separate duplicate scan.
    local quickAliveTargets, _ = GetPlayerTargets()
    local seenQuick = {}
    for _, existing in ipairs(quickAliveTargets) do
        seenQuick[normalizeUuidKey(existing)] = true
    end
    -- Also check the authoritative combatant list for any other non-enemy combatants
    -- GetPlayerTargets()'s DB queries missed (e.g. non-duplicate summons).
    local combatChars = Skynet_GetKnownCombatants()
    for _, c in ipairs(combatChars) do
        local charUuid = safeStr(c)
        local key = normalizeUuidKey(charUuid)
        if charUuid ~= "" and charUuid ~= enemyId and not seenQuick[key] then
            seenQuick[key] = true
            if not IsActualEnemy(charUuid) then
                quickAliveTargets[#quickAliveTargets + 1] = charUuid
            end
        end
    end
    -- Quick check: skip hatching (and let the normal attack flow run with full action
    -- economy) if she should just attack this turn instead — either because only a
    -- duplicate is visible (she should be fooled by it, not go hunt eggs), or because
    -- something (real target or duplicate) is already within attack range and LOS right
    -- now. Without the second half of this check, she unconditionally spent her whole
    -- turn's action economy on teleport+dash chasing eggs before ever reaching the attack
    -- decision, even when a target was standing close enough to hit immediately.
    local quickAttackRange = 0
    for _, spell in ipairs(GetEnemyAvailableSpells(enemyId) or {}) do
        if not Skynet_MobilityPattern(spell) and not Skynet_NeedsPositionTarget(spell) then
            local p = GetSpellProperties(spell)
            if p and p.rangeMeters and p.rangeMeters > quickAttackRange then
                quickAttackRange = p.rangeMeters
            end
        end
    end
    if quickAttackRange <= 0 then quickAttackRange = 18.0 end

    local quickDuplicateCheck = false
    local quickRealVisible = false
    local quickAttackableNow = false
    log("  SPIDER QUEEN: Checking " .. #quickAliveTargets .. " targets for duplicates")
    for _, p in ipairs(quickAliveTargets or {}) do
        local pid = tostring(p)
        local isDup = IsInvokeDuplicityDuplicate(pid)
        -- Duplicates are decoys and never actually stealthed — only real party members
        -- can be genuinely hidden/sneaking, so only they need the undetected check.
        if (not isDup) and Skynet_IsTargetUndetected(pid) then
            log("  SPIDER QUEEN: Real target hidden/sneaking, not counted visible: " .. pid:sub(1,30))
        elseif CheckLineOfSight(enemyId, pid) then
            local inRange = GetDistanceBetween(enemyId, pid) <= quickAttackRange
            if inRange then quickAttackableNow = true end
            if isDup then
                quickDuplicateCheck = true
                log("  SPIDER QUEEN: Duplicate visible: " .. pid:sub(1,30) .. (inRange and " (in attack range)" or ""))
            else
                quickRealVisible = true
                log("  SPIDER QUEEN: Real target visible: " .. pid:sub(1,30) .. (inRange and " (in attack range)" or " — hatching"))
            end
        end
    end
    -- Only duplicates visible at all → always attack (be fooled by it). Otherwise still
    -- skip hatching if something is already attackable right now, real or duplicate.
    local shouldAttackInstead = (quickDuplicateCheck and not quickRealVisible) or quickAttackableNow
    if shouldAttackInstead then
        log("  SPIDER QUEEN: " .. (quickAttackableNow and "Attackable target already in range" or "Only duplicates visible") .. " — skipping hatching, attacking")
        -- Fall through to main AI for attack
    else
    -- Re-scan for egg clusters every turn (handles hatched + player-destroyed)
    LocatedClusters = {}
    local found = ScanForEggClustersNear(150.0)

    -- Collect all alive clusters from scan
    local aliveClusters = {}
    for clusterStr in pairs(LocatedClusters) do
      table.insert(aliveClusters, clusterStr)
    end

    -- (Duplicate-only / already-attackable check now happens earlier, before this whole
    -- else branch is even entered — see quickAttackRange/shouldAttackInstead above. This
    -- used to be re-checked here too via a `duplicateOnly` flag, but that referenced
    -- hasVisibleDuplicate/hasVisibleAlive before they were ever declared — a forward
    -- reference to a nonexistent global that always evaluated to nil, so the check was
    -- silently dead code. Removed rather than fixed, since the earlier check already
    -- covers this case and more.)

    -- Weighted choice: hatch (70%) vs attack (30%)
    local shouldHatch = true
    if #aliveClusters > 0 then

      -- Sort by distance (nearest first)
      local ex, ey, ez = Osi.GetPosition(enemyId)
      table.sort(aliveClusters, function(a, b)
        local ax, ay, az = Osi.GetPosition(a)
        local bx, by, bz = Osi.GetPosition(b)
        local distA = math.sqrt((ax-ex)^2 + (az-ez)^2)
        local distB = math.sqrt((bx-ex)^2 + (bz-ez)^2)
        return distA < distB
      end)

      local targetCluster = aliveClusters[1]
      local cx, cy, cz = Osi.GetPosition(targetCluster)
      -- Use 2D distance (horizontal only) — she walks on same elevation, height difference is irrelevant
      local dist = math.sqrt((cx-ex)^2 + (cz-ez)^2)

      log("  SPIDER QUEEN: Nearest cluster at " .. string.format("%.1f", dist) .. "m")

      -- Get actual Matriarch's Call range from spell data
      local hatchRange = 9
      local hatchProps = GetSpellProperties("Target_FOR_SpiderQueen_HatchEggs")
      if hatchProps and hatchProps.rangeMeters and hatchProps.rangeMeters > 0 then
        hatchRange = hatchProps.rangeMeters
      end

      -- Try to cast Matriarch's Call directly (within range)
      if dist <= hatchRange then
        log("  SPIDER QUEEN: Casting Matriarch's Call on cluster (range " .. hatchRange .. "m)")
        Skynet_UseSpellOnTarget(enemyId, targetCluster, "Target_FOR_SpiderQueen_HatchEggs")
        SpiderQueenLastAction = "hatch"
        actedThisTurn[enemyId] = true
        return
      end

      -- ============================================================
      -- PHASE 1: EVALUATE — assess all mobility options before acting
      -- ============================================================
      log("  SPIDER QUEEN: Evaluating mobility for " .. string.format("%.1f", dist) .. "m target")

      local walkDist = GetCreatureMovementSpeed(enemyId)
      local spells = GetEnemyAvailableSpells(enemyId) or {}

      -- Find teleport spells and their ranges (all BG3 teleportation actions)
      local teleportSpells = {}
      for _, spell in ipairs(spells) do
        local sl = string.lower(spell or "")
        if sl:find("ethereal") or sl:find("misty") or sl:find("teleport") or
           sl:find("dimension") or sl:find("thunderstep") or sl:find("far step") or
           sl:find("blink") or sl:find("shadow") or sl:find("astral") or
           sl:find("warp") or sl:find("hellcrawl") or sl:find("dark currents") or
           sl:find("benign transposition") or sl:find("fleeting dream") or
           sl:find("shifting winds") or sl:find("supernatural attraction") or
           sl:find("wild magic") or sl:find("mobile flourish") then
          local rangeOk, range = pcall(function() return Ext.Stats.Get(spell).Range end)
          if rangeOk and range and range > 0 then
            table.insert(teleportSpells, {spell = spell, range = range})
          else
            -- Can't read range — assume 22m (BG3 Ethereal Jaunt default)
            table.insert(teleportSpells, {spell = spell, range = 22})
          end
        end
      end

      -- Find dash spell
      local dashSpell = nil
      for _, spell in ipairs(spells) do
        local sl = string.lower(spell or "")
        if sl:find("dash") or sl:find("shout_dash") then
          dashSpell = spell
          break
        end
      end

      -- Evaluate each option: can it get me within hatchRange of the cluster?
      local canWalkAndCast = (walkDist + hatchRange) >= dist
      local canTeleportAndCast = false
      local bestTeleport = nil
      for _, tp in ipairs(teleportSpells) do
        if tp.range >= dist then
          canTeleportAndCast = true
          if not bestTeleport or tp.range < bestTeleport.range then
            bestTeleport = tp  -- shortest range that reaches (saves cooldowns)
          end
        end
      end
      local canDashAndCast = dashSpell ~= nil  -- Dash always helps close distance

      log("  SPIDER QUEEN: Walk+" .. hatchRange .. "m cast: " .. (canWalkAndCast and "YES" or "NO") ..
          " | Teleport: " .. (canTeleportAndCast and "YES (" .. bestTeleport.spell .. ")" or "NO") ..
          " | Dash: " .. (canDashAndCast and "YES" or "NO"))

      -- ============================================================
      -- PHASE 2: EXECUTE — continuous evaluate→execute loop
      -- After every movement, re-evaluate distance and try next option
      -- ============================================================

      -- Helper: move toward cluster
      local function moveTowardCluster()
        -- Opportunity-attack awareness (pass #14): this walk step (unlike the teleport/Dash
        -- options evaluated elsewhere in this loop) is plain movement and had no regard at
        -- all for adjacent party members — she'd walk straight out of melee reach chasing an
        -- egg cluster and eat a free hit for it. Skip the walk (teleport/Dash below don't
        -- provoke the same way) when a real party member is close enough to threaten it.
        if quickAliveTargets and #quickAliveTargets > 0 then
          local adjacentThreats = GetAdjacentThreats(enemyId, quickAliveTargets)
          if #adjacentThreats > 0 then
            local totalThreat = 0
            for _, threat in ipairs(adjacentThreats) do
              totalThreat = totalThreat + GetOpportunityAttackThreat(enemyId, threat.id)
            end
            if totalThreat > 0.3 then
              log("  SPIDER QUEEN: skipping walk toward cluster — opportunity attack risk (threat=" .. string.format("%.2f", totalThreat) .. ")")
              return
            end
          end
        end
        -- Use cluster X/Z but Spider Queen Y to avoid clipping underground
        Skynet_MoveToPosition(enemyId, cx, ey, cz)
      end

      -- Helper: check if we're now in casting range
      local function checkAndCast()
        local nx, ny, nz = Osi.GetPosition(enemyId)
        local newDist = math.sqrt((cx-nx)^2 + (cz-nz)^2)
        if newDist <= hatchRange then
          -- Matriarch's Call costs 1 action
          if remainingAction > 0 then
            log("  SPIDER QUEEN: In range (" .. string.format("%.1f", newDist) .. "m), casting Matriarch's Call")
            Skynet_UseSpellOnTarget(enemyId, targetCluster, "Target_FOR_SpiderQueen_HatchEggs")
            SpiderQueenLastAction = "hatch"
            deductAction("action")
            return true
          else
            log("  SPIDER QUEEN: In range but no action remaining — skipping hatch")
          end
        end
        return false
      end

      -- Step 1: Walk (free, no action cost) — always walk first
      log("  SPIDER QUEEN: Walking toward cluster")
      moveTowardCluster()
      if checkAndCast() then
        -- Walk was enough — skip teleport/dash
      else
        -- Tracks whether Step 2's teleport cast actually fired. The landing position is
        -- deliberately computed to be within hatchRange of the cluster (see below), so a
        -- successful cast means Step 3 (Dash) is unnecessary — but Osi.GetPosition() right
        -- after casting frequently still reports the PRE-teleport position (movement/
        -- teleport resolution isn't synchronous with the script call that triggers it), so
        -- re-checking live distance immediately afterward is unreliable and was previously
        -- causing Dash to fire "to close remaining X.Xm" where X.X was identical to the
        -- turn's very first, pre-any-movement distance — i.e. Dash firing even when the
        -- teleport had already (or was about to) put her in range. Gate Step 3 on this flag
        -- instead of a fresh position read.
        local teleportSucceeded = false

        -- Step 2: Re-evaluate — try teleport if walk wasn't enough (costs bonus action)
        -- Ethereal Jaunt is a POSITION TARGET spell: must use Skynet_ExecuteActionOnPosition
        -- with a landing position near the cluster (not self-target)
        if canAct() and remainingBonusAction > 0 then
          local nx, ny, nz = Osi.GetPosition(enemyId)
          local newDist = math.sqrt((cx-nx)^2 + (cz-nz)^2)
          for _, tp in ipairs(teleportSpells) do
            if tp.range >= newDist then
              -- Calculate landing position: at the cluster, using the cluster's own (known-good,
              -- already-validated-by-the-level) elevation rather than the Queen's current Y —
              -- the cluster can easily be in a different room/pit/alcove at a different height.
              local landX, landZ, landY = cx, cz, cy
              -- If too close, land a bit short of the cluster (within hatch range), on the
              -- Queen's side of it — NOT past it. The vector must point from the cluster
              -- TOWARD the Queen's current position (nx - cx), not the other way around;
              -- using (cx - nx) here previously sent the landing point overshooting past the
              -- cluster, away from the Queen, which is how she ended up teleporting into
              -- unmapped geometry beyond the cluster instead of landing next to it.
              if newDist > hatchRange then
                local dx, dz = nx - cx, nz - cz
                local d = math.sqrt(dx*dx + dz*dz)
                if d > 0 then
                  -- Land hatchRange meters from cluster, back toward the Queen's current pos
                  local ratio = math.min(1, hatchRange / d)
                  landX = cx + dx * ratio
                  landZ = cz + dz * ratio
                end
              end
              log("  SPIDER QUEEN: Teleporting with " .. tp.spell .. " to (" .. string.format("%.1f", landX) .. "," .. string.format("%.1f", landZ) .. ") near cluster")
              local tpOk = Skynet_ExecuteActionOnPosition(enemyId, tp.spell, landX, landY, landZ)
              if tpOk then
                -- Only spend the bonus action if the teleport actually happened —
                -- a failed position cast doesn't consume the real game resource.
                deductAction("bonus")
                -- Landing position was computed to be within hatchRange of the cluster by
                -- construction — treat the teleport as having closed the distance even if
                -- checkAndCast()'s live position read hasn't caught up yet (see note above).
                teleportSucceeded = true
                if checkAndCast() then break end
              else
                log("  SPIDER QUEEN: Teleport failed — bonus action not spent, will try dash/attack instead")
              end
              break
            end
          end
        end

        -- Step 3: Re-evaluate — try dash if teleport wasn't enough (costs action). Skipped
        -- if the teleport already succeeded — its landing position was already computed to
        -- be within hatchRange, so dashing afterward would just be wasting the action on
        -- top of an already-sufficient move (see teleportSucceeded note above).
        if canAct() and remainingAction > 0 and dashSpell and not teleportSucceeded then
          local nx, ny, nz = Osi.GetPosition(enemyId)
          local newDist = math.sqrt((cx-nx)^2 + (cz-nz)^2)
          if newDist > hatchRange then
            log("  SPIDER QUEEN: Dashing to close remaining " .. string.format("%.1f", newDist) .. "m")
            local dashOk = Skynet_UseSpellOnTarget(enemyId, enemyId, dashSpell)
            if dashOk then
              deductAction("action")
              -- Dash only grants extra movement — it doesn't move the caster by itself.
              -- Spend the granted movement immediately, then re-check hatch range.
              moveTowardCluster()
              checkAndCast()
            else
              log("  SPIDER QUEEN: Dash cast failed — action not spent")
            end
          end
        end
      end

      -- Don't set actedThisTurn here — let main AI run for remaining actions (attacks)
      -- The main AI will evaluate if attack is possible with remaining resources
    end -- close if shouldHatch
    end -- close if quickDuplicateCheck else
  end -- close if isSpiderQueen

  -- Get targets: allies target enemies, enemies target players (use cache when available)
  local aliveTargets, downedTargets
  if isAlly then
    local enemyList = GetEnemyTargets(enemyId)
    aliveTargets = enemyList
    downedTargets = {}
  elseif CachedPlayerTargets then
    aliveTargets = CachedPlayerTargets.alive
    downedTargets = CachedPlayerTargets.downed
  else
    aliveTargets, downedTargets = GetPlayerTargets()
    CachedPlayerTargets = {alive = aliveTargets, downed = downedTargets}
  end

  -- ==================== NON-PLAYER HOSTILE TARGETING (pass #29) ====================
  -- Root cause of a reported bug ("enemies gravitate to within ~5m of the player character
  -- before doing anything logical" — the Cambion Commander on the Nautiloid abandoning its
  -- scripted fight with the Mind Flayer to close on the player first, provoking an
  -- opportunity attack in the process; camp-entrance goblins abandoning their fight with
  -- Aradin's allied party to close on the player before throwing ranged attacks back at
  -- Aradin): enemy-side targeting (the `players` list fed into PickBestTarget and
  -- ScoreSpellForEnemy, and used to pick a Phase 1 mobility destination) was ALWAYS built
  -- from GetPlayerTargets() alone — i.e. strictly the literal player-controlled party (see
  -- that function's own Method 1-5, all of which only ever resolve host/party-member
  -- UUIDs). Any enemy whose actual scripted/logical fight is against a DIFFERENT hostile
  -- NPC that is NOT a player character — a rival monster like the Mind Flayer, or an
  -- allied NPC party like Aradin's — was completely invisible to Skynet's own
  -- decision-making. With nothing else to score, Skynet's mobility and attack phases
  -- always closed distance on and targeted the literal player, consuming the enemy's
  -- movement/actions on that before whatever was left of its turn fell through to the
  -- base game AI (which DOES know about the real scripted target) to perform the
  -- "logical" action — matching the reported pattern exactly, including enemies only ever
  -- behaving "correctly" once already near the player (that's simply where Skynet's own
  -- turn-taking stopped interfering and released control).
  --
  -- Fix: alongside the normal player-target list, also gather any OTHER known combatant
  -- this SPECIFIC enemy is hostile to (Osi.IsEnemy(candidate, enemyId) == 1) that is not
  -- itself a player character (players are already covered by GetPlayerTargets() — this
  -- would just double-count them) and not the enemy itself. This mirrors pass #27's
  -- ally-side fix (GetEnemyTargets asking Osi.IsEnemy(uuid, allyUuid) directly instead of
  -- trusting only FactionCache/IsActualEnemy) but for the enemy side, so an NPC-vs-NPC
  -- scripted fight finally becomes a first-class target Skynet can select, path to, and
  -- attack, instead of unconditionally preferring the player. Declared LOCAL TO THIS
  -- FUNCTION (not top-level — the file sits at the 200 top-level-local ceiling, see
  -- Maintenance history pass #23) and computed fresh per enemy here rather than folded
  -- into CachedPlayerTargets, because that cache is shared across every enemy in the round
  -- and Osi.IsEnemy(candidate, enemyId) is specific to the acting enemy — caching it there
  -- would leak one enemy's hostiles onto every other enemy's target list. See Maintenance
  -- history pass #29.
  -- (Defined only inside the enemy branch below — no sense building this closure, or
  -- calling Skynet_GetKnownCombatants a second time, on every ALLY turn too. Perf matters
  -- here; see Maintenance history pass #24.)
  if not isAlly then
    -- ==================== COMBAT-SCOPED PLAYER TARGETING (pass #38) ====================
    -- Root cause of a reported bug: an enemy already fighting real, non-player NPCs (e.g. a
    -- crash-site creature attacking tiefling refugees, or a Waukeen's Rest skirmish) would
    -- still get the FULL, always-on party list from GetPlayerTargets()/CachedPlayerTargets
    -- above, with zero check on whether the party had actually joined that fight. A party
    -- that was merely sneaking nearby — not in combat with this enemy, or not in combat AT
    -- ALL — could still be scored, targeted, and pathed toward, purely because Skynet never
    -- distinguished "party exists somewhere" from "party is an actual combatant in MY
    -- fight." Fixed by requiring every player-controlled candidate to actually appear in
    -- this enemy's own known-combatant set (Skynet_GetKnownCombatants(enemyId) — the same
    -- real, live combat-membership data pass #27/#29 already trust for ally- and
    -- non-player-hostile-side targeting) via the shared Skynet_IsEligibleCombatant predicate
    -- (which also exempts Invoke Duplicity duplicates — see its own comment). This is the
    -- SECOND of two places this same combat-membership gate was needed: the first is inside
    -- Skynet.ChooseBestAction's own `targetParty` overlay, since that function runs its own,
    -- earlier reachability/mobility-selection pass over an independently-sourced, equally
    -- unfiltered player list (PlayerContext) — see its Maintenance history pass #38 note for
    -- why filtering only here would not have been enough on its own to stop the reported
    -- shadowing behavior. See Maintenance history pass #38.
    local enemyCombatantsOk, enemyCombatants = pcall(Skynet_GetKnownCombatants, enemyId)
    enemyCombatants = (enemyCombatantsOk and enemyCombatants) or {}
    local enemyCombatantSet = {}
    for _, c in ipairs(enemyCombatants) do
      local u = safeStr(c)
      if u ~= "" then enemyCombatantSet[u] = true end
    end

    local scopedAlive, scopedDowned = {}, {}
    local excludedNotInCombat = 0
    for _, u in ipairs(aliveTargets) do
      if Skynet_IsEligibleCombatant(safeStr(u), enemyCombatantSet) then
        scopedAlive[#scopedAlive + 1] = u
      else
        excludedNotInCombat = excludedNotInCombat + 1
      end
    end
    for _, u in ipairs(downedTargets) do
      if Skynet_IsEligibleCombatant(safeStr(u), enemyCombatantSet) then
        scopedDowned[#scopedDowned + 1] = u
      else
        excludedNotInCombat = excludedNotInCombat + 1
      end
    end
    if excludedNotInCombat > 0 then
      log("  COMBAT-SCOPED TARGETING: excluded " .. excludedNotInCombat ..
          " player(s) not in combat with " .. enemyId:sub(1,20) .. " (not yet engaged)")
    end
    aliveTargets = scopedAlive
    downedTargets = scopedDowned

    local function GetNonPlayerHostileTargets(forEnemyId, combatants)
      local extraAlive, extraDowned = {}, {}
      if not forEnemyId or forEnemyId == "" then return extraAlive, extraDowned end
      for _, c in ipairs(combatants or {}) do
        local uuid = safeStr(c)
        if uuid ~= "" and uuid ~= forEnemyId and not IsPlayerCharacterSafe(uuid) then
          local eOk, isEnemyOfThis = pcall(function() return Osi.IsEnemy(uuid, forEnemyId) end)
          if eOk and isEnemyOfThis == 1 then
            local deadOk, isDead = pcall(function() return Osi.IsDead(uuid) end)
            if not deadOk or isDead ~= 1 then
              if IsDowned(uuid) then
                extraDowned[#extraDowned + 1] = uuid
              else
                extraAlive[#extraAlive + 1] = uuid
              end
            end
          end
        end
      end
      return extraAlive, extraDowned
    end

    -- PASS #38: reuse the enemyCombatants array already fetched above instead of calling
    -- Skynet_GetKnownCombatants(enemyId) a second time for the same enemy in the same turn.
    local extraAlive, extraDowned = GetNonPlayerHostileTargets(enemyId, enemyCombatants)
    if #extraAlive > 0 or #extraDowned > 0 then
      local mergedAlive = {}
      for _, u in ipairs(aliveTargets) do mergedAlive[#mergedAlive + 1] = u end
      for _, u in ipairs(extraAlive) do mergedAlive[#mergedAlive + 1] = u end
      aliveTargets = mergedAlive
      local mergedDowned = {}
      for _, u in ipairs(downedTargets) do mergedDowned[#mergedDowned + 1] = u end
      for _, u in ipairs(extraDowned) do mergedDowned[#mergedDowned + 1] = u end
      downedTargets = mergedDowned
      log("  NON-PLAYER HOSTILES: +" .. #extraAlive .. " alive, +" .. #extraDowned .. " downed for " .. enemyId:sub(1,40))
    end
  end

  if #aliveTargets == 0 and #downedTargets == 0 then
    -- PASS #27: this was previously a silent, unlogged return — the ONLY early-exit in this
    -- whole function with no log() call at all, which is exactly why an ally finding zero
    -- recognized enemies (see the GetEnemyTargets note above) looked like total silence in the
    -- log rather than a diagnosable message. Every other early-exit in this function already
    -- explains itself; this one now does too.
    log("  NO TARGETS FOUND — " .. (isAlly and "ally found no recognized enemies to fight" or "enemy found no players/downed targets") .. " for " .. enemyId:sub(1,40))
    return
  end

  -- Determine valid targets: prefer alive, allow downed only if no alive in LOS
  local players = aliveTargets
  local hasVisibleAlive = false
  local hasVisibleDuplicate = false
  for _, p in ipairs(aliveTargets) do
    local pid = tostring(p)
    local isDup = IsInvokeDuplicityDuplicate(pid)
    -- PASS #31: dump this target's full raw status list every turn (debug-log only). The
    -- user reported enemies still converging on a genuinely hidden character's real
    -- position even with no other stealth-related mod installed — but Skynet_IsTargetUndetected
    -- already checks every stealth/hidden status name known to be used by this codebase
    -- (HIDDEN/INVISIBLE/SNEAKING/SNEAKING_CLEAR/SNEAKING_HEAVILY_OBSCURED/
    -- SNEAKING_LIGHTLY_OBSCURED/STEALTHED/STEALTH/PASSIVE_HIDD/UNSEEN), and the general
    -- visibility gate right below already hands off to base-game search AI ("NO VISIBLE
    -- TARGETS") whenever none of those are present. Rather than guess at another status
    -- name to add, log every status ID actually on the entity — if BG3's real "successfully
    -- hid in combat" status isn't one of the names already checked, the next debug log
    -- captured while this happens will show its real ID directly instead of us guessing.
    if (not isDup) and Settings.EnableDebugLogging then
      local statOk, statList = pcall(function()
        local ent = Ext.Entity.Get(pid)
        return ent and ent.StatusContainer and ent.StatusContainer.Statuses
      end)
      if statOk and statList then
        local statNames = {}
        for _, sid in pairs(statList) do statNames[#statNames + 1] = tostring(sid) end
        log("  STATUS DUMP for " .. pid:sub(1,20) .. ": " .. table.concat(statNames, ", "))
      end
    end
    -- A genuinely hidden/sneaking/invisible party member is not "visible" just because
    -- raw geometric LOS happens to be clear — that's BG3's real Stealth/Perception check,
    -- and treating them as visible here is what was skipping the base-game "search for
    -- hidden target" fallback. Duplicates are decoys and are never actually stealthed.
    if (not isDup) and Skynet_IsTargetUndetected(pid) then
      -- not visible, skip
    else
      local los = CheckLineOfSight(enemyId, pid)
      if los then
        if isDup then
          hasVisibleDuplicate = true
        else
          hasVisibleAlive = true
        end
      end
    end
  end
  if not hasVisibleAlive and not hasVisibleDuplicate and #downedTargets > 0 then
    local hasVisibleDowned = false
    for _, p in ipairs(downedTargets) do
      local pid = tostring(p)
      if not Skynet_IsTargetUndetected(pid) then
        local los = CheckLineOfSight(enemyId, pid)
        if los then hasVisibleDowned = true; break end
      end
    end
    if hasVisibleDowned then
      players = downedTargets
      log("  NO ALIVE TARGETS IN LOS — targeting downed")
    elseif hasVisibleDuplicate then
      log("  NO REAL TARGETS IN LOS — duplicate visible, will target duplicate")
    else
      log("  NO VISIBLE TARGETS — base game searching for targets")
      WaitingForTarget[enemyId] = true
      actedThisTurn[enemyId] = true
      return
    end
  elseif not hasVisibleAlive and not hasVisibleDuplicate then
    log("  NO VISIBLE TARGETS — base game searching for targets")
    WaitingForTarget[enemyId] = true
    actedThisTurn[enemyId] = true
    return
  end

  -- Detect summon pairs for summon-aware targeting (enemies only)
  local summonPairs = nil
  if not isAlly then
    summonPairs = FindPlayerSummonPairs(aliveTargets, downedTargets)
  end

  local bestSpell = Skynet.ChooseBestAction(enemyId)
  if not bestSpell then
    log("  NO SPELL SELECTED — releasing to base AI for " .. enemyId:sub(1,40))
    actedThisTurn[enemyId] = true
    return
  end

  if SkynetGates then SkynetGates.noteBest(enemyId, bestSpell) end  -- lets Self-prepare skip a buff this attack would break

  -- PHASE 0: Self-prepare (buffs, potions, coatings BEFORE attacking)
  -- PASS #50: third return value, prepareCost2, is nil for every branch except the equip-
  -- looted-gear one — it carries the cost of an Action Surge/Heroic Action Surge cast used
  -- internally to free up the action the equip needed (see Skynet_TryGrantExtraAction). Both
  -- get deducted below since they're two genuinely separate resource spends in the same
  -- prepare-phase call.
  local prepared, prepareCost, prepareCost2 = Skynet_SelfPrepare(enemyId, players)
  if prepared then
    log("  PHASE 0 (SELF-PREPARE): completed — proceeding to attack")
    -- PASS #37: Skynet_SelfPrepare's older branches (self-buff spells, weapon coating, stat
    -- potions, spell-based healing) never told this turn's own resource ledger
    -- (remainingAction/remainingBonusAction, canAct()) what they actually spent — a
    -- pre-existing gap this pass didn't attempt to close everywhere, since
    -- syncActionResources() below only ever picks up INCREASES, never decreases, so it
    -- can't retroactively detect it either. It matters specifically for pass #37's new
    -- item-based branches (condition-cure potions, and the healing potion when its real
    -- cost isn't a bonus action) because they can consume the enemy's real Action —
    -- deducting it here is what lets Phase 2's existing "if not canAct() then ... end"
    -- check correctly skip a now-impossible attack instead of trying and silently failing
    -- at the engine level. `prepareCost` is nil for every pre-existing branch (unchanged
    -- behavior, zero regression risk); only pass #37's branches set it. See Maintenance
    -- history pass #37.
    if prepareCost then
      deductAction(prepareCost)
    end
    if prepareCost2 == "bonus2" then
      -- "2e Spells"' Shout_BonusActionToAction spends TWO bonus actions in one cast — see
      -- Skynet_TryGrantExtraAction — so this ledger needs two deductions, not one.
      deductAction("bonus")
      deductAction("bonus")
    elseif prepareCost2 then
      deductAction(prepareCost2)
    end
    -- A self-buff just cast here (e.g. an Enrage-style shout granting an extra attack) may
    -- have changed real action-resource state — pick that up now so the rest of this turn
    -- already knows about it, rather than only catching it in the end-of-turn mop-up.
    syncActionResources()
    -- PASS #25: `bestSpell` above was computed BEFORE Self-Prepare ran, so if Self-Prepare
    -- just cast that exact same spell as a self-buff (a real bug: Minthara, Full-Illithid,
    -- auto-casting the at-will "Mind Sanctuary" power once here and then AGAIN as the turn's
    -- main attack, burning both her resources on one effect), the stale pick would otherwise
    -- still get executed a second time below. Re-derive it now that Self-Prepare has marked
    -- what it just cast (see the `LOSCache["__castThisTurn__"...]` check in ChooseBestAction's
    -- classification loop) — for the common case where Self-Prepare cast something unrelated
    -- to the best attack spell, this just re-confirms the same pick.
    bestSpell = Skynet.ChooseBestAction(enemyId)
    if not bestSpell then
      log("  NO SPELL SELECTED after self-prepare — releasing to base AI for " .. enemyId:sub(1,40))
      actedThisTurn[enemyId] = true
      return
    end
  end

  -- PHASE 1: Mobility (dash/sprint/teleport/misty/fly/jump/leap)
  if Skynet_MobilityPattern(bestSpell) then
    -- If best spell is Dash but a teleport can reach the target, prefer teleport (avoids wasting action)
    local bestLower = string.lower(bestSpell or "")
    if bestLower:find("dash") or bestLower:find("sprint") then
      local nearestTarget, nearestDist = Skynet_FindNearestPlayer(enemyId, players)
      if nearestTarget and nearestDist then
        local teleportSpells = {}
        for _, s in ipairs(GetEnemyAvailableSpells(enemyId) or {}) do
          local sl = string.lower(s or "")
          if sl:find("teleport") or sl:find("ethereal") or sl:find("misty") or
             sl:find("dimension") or sl:find("thunderstep") or sl:find("far step") or
             sl:find("blink") or sl:find("shadow") or sl:find("astral") or
             sl:find("warp") or sl:find("hellcrawl") or sl:find("dark currents") or
             sl:find("benign transposition") or sl:find("fleeting dream") or
             sl:find("shifting winds") or sl:find("supernatural attraction") or
             sl:find("wild magic") or sl:find("mobile flourish") then
            local props = GetSpellProperties(s)
            local range = nil
            if props and props.rangeMeters and props.rangeMeters > 0 then
              range = props.rangeMeters
            else
              range = 22  -- default teleport range (BG3 Ethereal Jaunt)
            end
            if nearestDist <= range then
              teleportSpells[#teleportSpells + 1] = {spell = s, range = range}
            end
          end
        end
        if #teleportSpells > 0 then
          -- Pick the teleport with the shortest range that still reaches (saves big cooldowns)
          table.sort(teleportSpells, function(a, b) return a.range < b.range end)
          bestSpell = teleportSpells[1].spell
          log("  PHASE 1: Dash replaced with " .. bestSpell .. " (teleport reaches target)")
        end
      end
    end

    -- Check if movement is restricted by status (webbed, restrained, etc.)
    if IsMovementRestricted(enemyId) then
      log("  PHASE 1 SKIPPED: movement restricted by status — attacking from current position")
    else
    log("  PHASE 1 (MOBILITY): " .. bestSpell)

    -- Check for opportunity attacks BEFORE using mobility
    local canMoveSafely = true
    if players and #players > 0 then
      local adjacentThreats = GetAdjacentThreats(enemyId, players)
      if #adjacentThreats > 0 then
        local totalThreat = 0
        for _, threat in ipairs(adjacentThreats) do
          totalThreat = totalThreat + GetOpportunityAttackThreat(enemyId, threat.id)
        end
        -- If high threat and far from target, don't move (would trigger OAs for nothing)
        local nearestTarget, nearestDist = Skynet_FindNearestPlayer(enemyId, players)
        if totalThreat > 0.4 and nearestDist and nearestDist > 6 then
          log("  MOBILITY BLOCKED: opportunity attack risk (threat=" .. string.format("%.2f", totalThreat) .. ") — skipping movement")
          canMoveSafely = false
        end
      end
    end

    if canMoveSafely then

    -- STEP 1: Walk toward target FIRST (free, no action cost)
    -- PASS #33: skip this ground-based free walk entirely when bestSpell is a
    -- position-targeted mobility spell (Fly, Teleport, Jump, Misty Step, etc. — see
    -- Skynet_NeedsPositionTarget, pass #19). Reported live as Cambions doing "a funny
    -- little flying hop/glitch" immediately before flying successfully — the free walk
    -- below unconditionally ran first for every mobility spell, including ones the enemy
    -- only picked BECAUSE nothing was reachable on the ground at all (that's precisely
    -- when Skynet.ChooseBestAction falls back to a mobility spell in the first place).
    -- Ground-pathfinding a creature toward a target it can only actually reach by flying/
    -- teleporting produces exactly this kind of small, doomed, ground-locomotion "hop"
    -- before the real position-targeted cast (Osi.UseSpellAtPosition) takes over and
    -- actually relocates it correctly. Dash/Sprint-type mobility (entity-targeted, not
    -- position-targeted) is unaffected and still gets the free walk first, since that's
    -- the case pass #19 confirmed working correctly. See Maintenance history pass #33.
    if not Skynet_NeedsPositionTarget(bestSpell) then
    local nearestTarget, nearestDist = Skynet_FindNearestPlayer(enemyId, players)
    -- PASS #53: last-line defense, per the user's explicit request this session — the instant
    -- Skynet would move an enemy toward a resolved target, re-verify it isn't hidden/
    -- undetected and, if it is, abort this enemy's ENTIRE turn to the base/vanilla game AI
    -- right here (same WaitingForTarget mechanism the "NO VISIBLE TARGETS" gate earlier in
    -- this function already uses) instead of attempting any Skynet-driven movement at all.
    -- Per the user's own words: "it's supposed to be that they look for the character, they
    -- can't find [them]... the way Skynet handles hidden characters is not good" — i.e. the
    -- vanilla AI's own search behavior is the CORRECT behavior here, and a partial Skynet
    -- workaround (quietly falling back to a different visible target instead) isn't good
    -- enough given how many times this has recurred (pass #13, #31, #32). Deliberately a
    -- FULL turn bail, not just a skip of this one walk step, even though a different, truly
    -- visible target might otherwise exist this turn — the user explicitly asked for a full,
    -- unconditional handoff the instant a hidden target is involved, not a surgical
    -- workaround. Skynet_FindNearestPlayer already filters via IsValidTarget (which itself
    -- now delegates to Skynet_IsTargetUndetected — see that pass #53 fix elsewhere in this
    -- file), so this should normally never actually fire; if it ever does in a live log,
    -- that's concrete proof the resolved target WAS correctly flagged hidden by the time it
    -- would have been acted on, narrowing any future recurrence down to a genuine detection
    -- gap (the real in-game status name not being one of the ten this file already checks)
    -- rather than a missed filtering path. See Maintenance history pass #53.
    if nearestTarget and Skynet_IsTargetUndetected(nearestTarget) then
      log("  HIDDEN TARGET ABORT: " .. tostring(nearestTarget):sub(1,30) .. " is undetected — handing this turn to base-game AI instead of moving toward it")
      WaitingForTarget[enemyId] = true
      actedThisTurn[enemyId] = true
      return
    end
    if nearestTarget and nearestDist then
      local walkDist = GetCreatureMovementSpeed(enemyId)
      if walkDist > 0 then
        -- Walk toward target (free movement)
        local eOk, ex, ey, ez = pcall(function() return Osi.GetPosition(enemyId) end)
        if eOk and ex then
          local jOk, jx, jy, jz = pcall(function() return Osi.GetPosition(nearestTarget) end)
          if jOk and jx then
            local dx, dz = jx - ex, jz - ez
            local d = math.sqrt(dx*dx + dz*dz)
            if d > 1.5 then
              -- Walk partway toward target (don't overshoot)
              local walkFrac = math.min(1, walkDist / d)
              local walkX = ex + dx * walkFrac
              local walkZ = ez + dz * walkFrac
              log("  WALK: Moving " .. string.format("%.1f", walkDist) .. "m toward target")
              Skynet_MoveToPosition(enemyId, walkX, ey, walkZ)
            end
          end
        end
      end
    end
    else
      log("  WALK SKIPPED: " .. bestSpell .. " needs a position target — ground walk would be doomed/glitchy, going straight to the mobility cast")
    end

    -- STEP 2: Re-evaluate after walking — check if still need mobility
    nearestTarget, nearestDist = Skynet_FindNearestPlayer(enemyId, players)

    -- The free walk above may have already closed enough distance that a real attack is now
    -- possible on its own — re-run selection to check before spending the mobility spell
    -- anyway. Without this, an enemy that ends up attack-adjacent purely from the free walk
    -- would still burn its turn casting/self-buffing a mobility spell (e.g. Fly) it no longer
    -- needs, instead of just attacking. See Maintenance history pass #19.
    local mobilityStillNeeded = true
    local reachedByWalkOk, reachedByWalk = pcall(Skynet.ChooseBestAction, enemyId)
    if reachedByWalkOk and reachedByWalk and not Skynet_MobilityPattern(reachedByWalk) and not Skynet_NeedsPositionTarget(reachedByWalk) then
      log("  MOBILITY SKIPPED: free walk already put an attack (" .. reachedByWalk .. ") in range")
      mobilityStillNeeded = false
    end

    if mobilityStillNeeded then

    -- Position-based spells need a target POSITION, not a target entity
    if Skynet_NeedsPositionTarget(bestSpell) then
      local nearestTarget, nearestDist = Skynet_FindNearestPlayer(enemyId, players)
      if nearestTarget then
        local jOk, jx, jy, jz = pcall(function() return Osi.GetPosition(nearestTarget) end)
        if jOk and jx then
          local eOk, ex, ey, ez = pcall(function() return Osi.GetPosition(enemyId) end)
          if eOk and ex then
            local dx, dz = jx - ex, jz - ez
            local d = math.sqrt(dx*dx + dz*dz)
            -- Cap distance to spell's actual range (prevents long-range teleport)
            local spellProps = GetSpellProperties(bestSpell)
            local maxDist = spellProps and spellProps.rangeMeters or 18.0
            -- Interpolate Y toward the target's own (known-valid) elevation rather than just
            -- using the caster's current Y — the two can easily be on different floors/ledges,
            -- and blindly using the caster's Y for a landing point that may be much closer to
            -- the target than to the caster is how teleports end up landing in bad geometry.
            if d > maxDist then
              log("  POSITION SPELL: target too far (" .. math.floor(d) .. "m > " .. math.floor(maxDist) .. "m range), skipping")
            elseif d > 3 then
              local ratio = (d - 3) / d
              local landX, landZ, landY = ex + dx * ratio, ez + dz * ratio, ey + (jy - ey) * ratio
              log(string.format("  POSITION SPELL toward %s: landing at (%.1f, %.1f, %.1f)", nearestTarget:sub(1,20), landX, landY, landZ))
              Skynet_ExecuteActionOnPosition(enemyId, bestSpell, landX, landY, landZ)
            else
              local ratio = math.min(1, 6 / d)
              local landX, landZ, landY = ex + dx * ratio, ez + dz * ratio, ey + (jy - ey) * ratio
              Skynet_ExecuteActionOnPosition(enemyId, bestSpell, landX, landY, landZ)
            end
          else
            log("  POSITION SPELL: cannot get enemy position, skipping (prevents self-cast)")
          end
        else
          log("  POSITION SPELL: cannot get target position, skipping (prevents self-cast)")
        end
      else
        log("  POSITION SPELL: no target found, skipping (prevents self-cast)")
      end
    else
      -- Check if entity can actually fly before casting fly spells
      local isFlySpell = bestSpell and (bestSpell:find("fly") or bestSpell:find("flight"))
      if isFlySpell then
        local canMove = false
        local cmOk, cmVal = pcall(function() return Osi.CanMove(enemyId) end)
        if cmOk and cmVal == 1 then canMove = true end
        if canMove then
          Skynet_ExecuteUseSpell(enemyId, bestSpell, nil)
        else
          log("  FLY SPELL: entity cannot fly — skipping (prevents snap-to-position)")
        end
      else
        Skynet_ExecuteUseSpell(enemyId, bestSpell, nil)
      end
    end

    local nearestTarget, nearestDist = Skynet_FindNearestPlayer(enemyId, players)
    if nearestTarget then
      -- Check if already in attack range — skip movement if so.
      -- PASS #30: this used to check nearestDist against GetSpellProperties(bestSpell)'s
      -- own range — but at this exact point, `bestSpell` is still the Phase 1 MOBILITY
      -- spell (Dash, etc.) that was just used to close distance, not the attack the enemy
      -- actually intends to use once in position (the same distinction the `desiredDist`
      -- calc a few lines below already makes explicit, per pass #20's comment). A mobility
      -- spell's own "range" stat has nothing to do with attack range, so this could — and,
      -- per a live-reported log, did — declare "already in attack range" off Dash's
      -- unrelated range stat while the enemy's real spells were still 0-for-0 reachable all
      -- turn, causing it to stop moving short of anything it could actually use. Also
      -- previously ignored line of sight entirely (`Skynet_FindNearestPlayer` picks nearest
      -- by raw distance only) — a target 8m away behind a wall would count as "in range"
      -- and halt movement despite having no LOS to actually attack through. Now checks the
      -- caster's real equipped-weapon range first (the same `Skynet_GetCasterWeaponRangeInfo`
      -- helper `desiredDist` below already uses), falling back to bestSpell's own range only
      -- when weapon info can't be determined at all, and additionally requires actual line
      -- of sight to the target before considering movement unnecessary. See Maintenance
      -- history pass #30.
      local alreadyInAttackRange = false
      local attackRangeMeters = nil
      local weaponInfoForRange = Skynet_GetCasterWeaponRangeInfo(enemyId)
      if weaponInfoForRange and weaponInfoForRange.rangeMeters and weaponInfoForRange.rangeMeters > 0 then
        attackRangeMeters = weaponInfoForRange.rangeMeters
      elseif bestSpell then
        local bProps = GetSpellProperties(bestSpell)
        if bProps and bProps.rangeMeters and bProps.rangeMeters > 0 then
          attackRangeMeters = bProps.rangeMeters
        end
      end
      if attackRangeMeters and nearestDist <= attackRangeMeters and CheckLineOfSight(enemyId, nearestTarget) then
        alreadyInAttackRange = true
        log("  ALREADY IN ATTACK RANGE (" .. math.floor(nearestDist) .. "m <= " .. math.floor(attackRangeMeters) .. "m, LOS clear) — skipping movement")
      end

      -- Skip additional movement only if already in range or used a position-target spell (not Dash)
      local usedPositionSpell = Skynet_NeedsPositionTarget(bestSpell)

      if not alreadyInAttackRange and not usedPositionSpell then
        -- Determine desired distance. bestSpell here is the Phase 1 MOBILITY spell that was
        -- just used to close distance (Dash, Fly, etc.) — not the attack the enemy actually
        -- intends to use once in position. Dash/Sprint-type spells carry no meaningful
        -- ranged/melee data of their own, so basing desiredDist on bestSpell's properties
        -- silently defaulted every enemy that needed a mobility spell to melee range (2.5m)
        -- regardless of whether they're actually a ranged attacker — reported as archers
        -- charging in to melee instead of shooting from range. Fixed in pass #20 by checking
        -- the enemy's actual equipped weapon first, and only falling back to the old
        -- mobility-spell-based heuristic if that can't be determined.
        local desiredDist = 2.5 -- default: melee range
        local weaponInfo = Skynet_GetCasterWeaponRangeInfo(enemyId)
        if weaponInfo and weaponInfo.isRanged then
          desiredDist = math.max(6, (weaponInfo.rangeMeters or 18) * 0.75)
        elseif weaponInfo and weaponInfo.isMelee then
          desiredDist = 2.5
        elseif bestSpell then
          local bProps = GetSpellProperties(bestSpell, enemyId)
          if bProps then
            if bProps.isRanged or (bProps.rangeMeters and bProps.rangeMeters > 5) then
              -- Ranged character: stay at 70-80% of max range
              desiredDist = math.max(6, (bProps.rangeMeters or 18) * 0.75)
            elseif bProps.isMelee then
              desiredDist = 2.5
            end
          end
        end
        local ok = Skynet_MoveToward(enemyId, nearestTarget, desiredDist, players)
        if ok then
          log(string.format("  MOVED toward %s (was %.1fm)", nearestTarget:sub(1,20), nearestDist))
        else
          log("  STUCK: cannot reach target — releasing to base AI")
          actedThisTurn[enemyId] = true
          return
      end
    end
    end -- close mobilityStillNeeded
    end -- close canMoveSafely
    end -- close IsMovementRestricted

    log("  PHASE 2 (ATTACK after move)")
    -- Check if we have actions remaining before attacking
    if not canAct() then
      log("  PHASE 2: No actions remaining — turn ending")
      actedThisTurn[enemyId] = true
      if tStart then
        local tEnd = Ext.Utils.MonotonicTime()
        log("  PERF: Skynet_AITurn took " .. tostring(tEnd - tStart) .. "ms for " .. (enemyId:sub(1,30)))
      end
      return
    end
    local attackSpell = Skynet.ChooseBestAction(enemyId)
    -- Filter: must be an actual attack/control spell, not mobility or position-target
    if attackSpell and (Skynet_MobilityPattern(attackSpell) or Skynet_NeedsPositionTarget(attackSpell)) then
      attackSpell = nil
    end
    if attackSpell then
      local bt = PickBestTarget(enemyId, attackSpell, players, summonPairs)
      if bt then
        log("  PHASE 2 ATTACK: " .. attackSpell .. " -> " .. bt:sub(1,30))
        Skynet_StepBackIfInvisible(enemyId, players, attackSpell)
        Skynet_UseSpellOnTarget(enemyId, bt, attackSpell)
        deductAction("action")
        local escapeCost = Skynet_PostAttackEscape(enemyId, players, remainingAction, remainingBonusAction)
        if escapeCost then deductAction(escapeCost) end
      else
        -- PASS #60: was Skynet_ExecuteDirect (re-choose, then "any spell that reaches") — now a hand-off.
        Skynet_MarkNoAttack(enemyId, "no valid target for " .. attackSpell .. " after moving")
      end
    else
      -- PASS #60: was a "brute force" scan casting the first spell that reached anyone (how Dip got cast at a
      -- duplicate) — now a hand-off to the base game AI.
      Skynet_MarkNoAttack(enemyId, "no attack reaches any target after moving")
    end
    end

  -- PHASE 1.5: Reposition with free movement to unlock better spells
  elseif Skynet_RepositionForBetterSpell(enemyId, players) then
    log("  PHASE 1.5 (REPOSITION): moved closer, re-evaluating")
    local newBest = Skynet.ChooseBestAction(enemyId)
    if newBest then
      local acted = Skynet_ExecuteDirect(enemyId, players, summonPairs)
      if acted then deductAction("action") end
    else
      Skynet_MarkNoAttack(enemyId, "nothing usable after repositioning")   -- PASS #60
    end
    local escapeCost1_5 = Skynet_PostAttackEscape(enemyId, players, remainingAction, remainingBonusAction)
    if escapeCost1_5 then deductAction(escapeCost1_5) end

  -- PHASE 2: Direct attack (spell is already reachable)
  else
    log("  PHASE 2 (ATTACK): " .. bestSpell)
    Skynet_StepBackIfInvisible(enemyId, players, bestSpell)
    local acted = Skynet_ExecuteDirect(enemyId, players, summonPairs)
    if acted then deductAction("action") end
    local escapeCost2 = Skynet_PostAttackEscape(enemyId, players, remainingAction, remainingBonusAction)
    if escapeCost2 then deductAction(escapeCost2) end
  end

  -- PASS #60: no real attack this turn -> the base game AI takes over. Nothing queued yet: return now (onTurnStarted
  -- releases the base AI for the whole turn). Something already queued (a buff, a potion, a move): stop planning and
  -- fall through to the normal end, where SkynetFC waits for the queue and then hands the rest of the turn back.
  local noAttackKey = resolveUuid(enemyId)
  if Skynet_NoAttackHandOff[noAttackKey] then
    local queued = Skynet_TurnQueued[noAttackKey] or (peakRealAction - remainingAction) > 0
                   or (peakRealBonus - remainingBonusAction) > 0
    if not queued then
      log("  NO ATTACK: nothing queued this turn — the base game AI plays the whole turn")
      actedThisTurn[enemyId] = true
      return
    end
    log("  NO ATTACK: waiting for what Skynet already queued, then the base game AI uses the rest of the turn")
  else
  -- Real resources may still remain (a mid-turn buff like Enrage granting an extra attack,
  -- or simply an action the above never spent) — keep attacking while they do, instead of
  -- unconditionally ending the turn after exactly one action.
  attackWithRemainingResources(players, summonPairs)
  end

  -- PASS #47: same-turn (or carried-over-from-an-earlier-turn) grapple -> tie-up follow-up
  -- for small/rope-eligible enemies. The user's explicit ask: "since small enemies use a
  -- bonus action for the tie-up... [enemies] should now consider grappling because if they
  -- use a grapple and they succeed... they can use the bonus action for the tie-up, and...
  -- the party member has a very difficult time saving against that." Checked here, AFTER
  -- the main attack phase and attackWithRemainingResources' own extra-attack loop, so it
  -- sees whatever grapple the main attack phase (Target_Grapple already carries pass #43's
  -- own scoring lead-in for small/rope-carrying enemies, unchanged) may have just landed
  -- THIS turn, as well as one already in place from an earlier turn that Priority 0.75's
  -- own 40% roll happened to skip. Calls Skynet_TryApcsRopeTieUp with grappledOnly=true so
  -- this never re-attempts the general/incapacitated branches Priority 0.75 already tried
  -- earlier this turn — it only fires for a target the enemy is ACTUALLY grappling right
  -- now, re-syncs real resources first, and passes them in so the function itself refuses
  -- to spend a resource the turn doesn't have. Restricted to the small-tier gate specifically
  -- for THIS same-turn follow-up (PASS #52 note: Priority 0.75 itself is no longer small-tier
  -- -only — see its own comment — but this particular hook still only makes sense for small
  -- casters) since medium/large casters pay a full Action for the tie-up either way — no
  -- same-turn bonus-action combo value for them, consistent with the user's own "it should
  -- just be treated like every other spell for normal/large enemies" instruction. A
  -- medium/large caster that grapples via Priority 0.75 this turn instead gets its follow-up
  -- tie-up naturally on a LATER turn, the normal way: Priority 0.75 runs again, detects
  -- isGrappling via Skynet_TryApcsRopeTieUp's own bridge check, and picks the Grappled variant
  -- directly — no separate hook needed for that path. NOTE: as of this pass, apcs_RestSystem's own Target_apcs_Rope_TieUp_Grappled
  -- still costs a full Action per Spell_Target.txt (not yet split into a Bonus Action tier
  -- the way the other two families were) — confirmed directly against the mod's current
  -- stat data — so this mostly pays off today when a prior-turn grapple is already in place
  -- and a real Action is still free, or once that spell's cost is split to match the
  -- user's framing, at which point this starts landing the genuine same-turn combo
  -- automatically with no further code change, since the cost is read live rather than
  -- assumed. See Maintenance history pass #47.
  if (not IsActualAlly(enemyId)) and Skynet_IsSmallRopeTieUpCandidate(enemyId) then
    syncActionResources()
    local followUpOk, followUpCost = Skynet_TryApcsRopeTieUp(enemyId, true, remainingAction, remainingBonusAction)
    if followUpOk and followUpCost then deductAction(followUpCost) end
  end

  -- PASS #62: an enemy whose leftovers Skynet keeps (the base game AI misused them earlier): Skynet spends a leftover
  -- bonus action on something useful itself; SkynetFC then ends the turn instead of handing it back.
  if not Skynet_NoAttackHandOff[noAttackKey] and Skynet_KeepsLeftovers(enemyId) then
    syncActionResources()
    if remainingBonusAction > 0 and Skynet_SpendLeftoverBonus(enemyId, players, summonPairs) then
      deductAction("bonus")
    end
  end

  actedThisTurn[enemyId] = true
  -- Reaching here means Skynet planned and queued everything it wanted to (every early `return` above is a
  -- deliberate hand-off to the base game AI). Record what its ledger spent and left, so onTurnStarted can
  -- keep control, wait for the queue to drain and end the turn itself (see SkynetFC).
  SkynetFC.ledger[enemyId] = {
    spentAction = math.max(0, peakRealAction - remainingAction),
    spentBonus = math.max(0, peakRealBonus - remainingBonusAction),
    action = remainingAction,
    bonus = remainingBonusAction,
  }
  SkynetFC.completed[enemyId] = true
  if SkynetGates then SkynetGates.noteLedger(enemyId, remainingAction, remainingBonusAction) end
  if tStart then
    local tEnd = Ext.Utils.MonotonicTime()
    log("  PERF: Skynet_AITurn took " .. tostring(tEnd - tStart) .. "ms for " .. (enemyId:sub(1,30)))
  end
end

-- Pulse tick: runs periodically for movement and environmental actions
local function Skynet_PulseTick()
  local stillInCombat = CurrentCombatId and CurrentCombatId ~= ""
  if not stillInCombat then
    -- CurrentCombatId is normally only set by CombatStarted, which won't refire if we loaded
    -- straight into a fight that was already in progress. Fall back to checking whether
    -- anyone is actually still in combat before giving up and killing the timer — otherwise
    -- the pulse tick (which drives most units' turns) stays dead for the rest of that combat.
    local dOk, rows = pcall(function() return Osi.DB_IsCharacterInCombat:Get(nil) end)
    stillInCombat = dOk and rows and next(rows) ~= nil
  end
  if not stillInCombat then
    skynetPulseTimer = nil
    return
  end

  local tPulse = Ext.Utils.MonotonicTime and Ext.Utils.MonotonicTime() or nil

  -- Check if creatures waiting for targets now have visible targets
  for charId, _ in pairs(WaitingForTarget) do
    if not actedThisTurn[charId] then
      local players = GetPlayerTargets()
      local hasVisible = false
      for _, p in ipairs(players) do
        local pid = tostring(p)
        -- PASS #32: this only checked raw geometric line of sight, with none of the
        -- BG3 stealth/perception awareness every OTHER visibility check in this file
        -- already has (pass #13's Skynet_IsTargetUndetected, and the duplicate exemption
        -- that goes with it) — a genuinely hidden/sneaking/invisible party member with an
        -- open-ish sightline could get incorrectly declared "found," prematurely reclaiming
        -- this creature from the base-game search AI Skynet had just deferred to, over and
        -- over on every pulse, purely because raw LOS was clear. Reported live as enemies
        -- ending up right on top of a hidden character even after Skynet had (correctly,
        -- per its own gate) declined to target them that turn. See Maintenance history
        -- pass #32.
        if (IsInvokeDuplicityDuplicate(pid) or not Skynet_IsTargetUndetected(pid)) and CheckLineOfSight(charId, pid) then
          hasVisible = true
          break
        end
      end
      if hasVisible then
        log("  TARGET FOUND: " .. charId:sub(1,30) .. " — Skynet taking over")
        WaitingForTarget[charId] = nil
        actedThisTurn[charId] = nil  -- clear so Skynet can process
        -- Will be processed on next iteration
      end
    else
      WaitingForTarget[charId] = nil  -- creature acted, clear flag
    end
  end

  -- Build or reuse cached enemy list (only rebuild when needed)
  if not CachedEnemyList then
    local units = {}
    local pOk, pRows = pcall(function() return Osi.DB_IsCharacterInCombat:Get(nil) end)
    if pOk and pRows then
      for _, row in pairs(pRows) do
        local char = row and row[1]
        if char and char ~= "" and not actedThisTurn[char] then
          -- Skip already-acted units BEFORE expensive checks
          if ShouldBaseGameControl(char) then
            actedThisTurn[char] = true
          elseif shouldProcessEnemy(char) then
            table.insert(units, {id = char, isAlly = false})
          elseif shouldProcessAlly(char) then
            table.insert(units, {id = char, isAlly = true})
          end
        end
      end
    end
    CachedEnemyList = units
  end

  -- Process only units that haven't acted yet
  local processed = 0
  for _, unit in ipairs(CachedEnemyList) do
    if not actedThisTurn[unit.id] then
      if ShouldBaseGameControl(unit.id) then
        actedThisTurn[unit.id] = true
      else
        Skynet_AITurn(unit.id, unit.isAlly)
        processed = processed + 1
      end
    end
  end

  if tPulse then
    local t1 = Ext.Utils.MonotonicTime()
    if processed > 0 or (t1 - tPulse) > 50 then
      log("  PERF: PulseTick took " .. tostring(t1 - tPulse) .. "ms, processed " .. processed .. "/" .. #CachedEnemyList .. " units")
    end
  end

  skynetPulseTimer = Ext.Timer.WaitFor(3000, Skynet_PulseTick)
end

-- Register Osiris listeners safely from inside SessionLoaded (this is the pattern used
-- by EnemyActionAI, CombatExtenderAI, SmarterAI, and others that reliably produce console output
-- and have working hooks). Direct top-level Osiris registration or very early flush often doesn't stick.

local Skynet_ListenersRegistered = false

-- PASS #49: two GLOBAL tables (no "local" — pass #35 technique, file at/near the 200
-- top-level-local ceiling) backing the new "equip gear looted off a tied-up target"
-- feature — see Skynet_TryEquipLootedGear and the new "AttackedBy"/"Unequipped" listeners
-- inside Skynet_RegisterAllOsirisListeners below. Initialized here, as plain top-level
-- statements outside any function, so both exist immediately at module load regardless of
-- whether/when Skynet_RegisterAllOsirisListeners has actually run yet.
Skynet_LastAttackerOf = Skynet_LastAttackerOf or {}
Skynet_PendingLootedGear = Skynet_PendingLootedGear or {}

-- ==================== ENEMY BUFFS (replaces Tactician Enhanced) ====================
-- Tactician Enhanced re-checked every entity on every EnteredCombat / targeted spell and rescanned
-- all characters within 60 m every 5 s. This does the same job ONCE per enemy per combat: when an
-- enemy enters a combat that the party is part of, it gets one permanent status per buff
-- (SKYNET_TOUGH_*, ends when the combat ends). No timers, no sweeps, no removal statuses.
-- Status data: Public/Skynet/Stats/Generated/Data/Skynet_EnemyBuffs.txt
Skynet_EnemyBuffed = Skynet_EnemyBuffed or {}            -- guid -> combat id it was buffed in
Skynet_EnemyBuffPending = Skynet_EnemyBuffPending or {}  -- guid -> true while a re-check is scheduled
Skynet_PartyCombatCache = Skynet_PartyCombatCache or {}  -- combat id -> { t = ms, v = bool }
Skynet_PartySizeCache = nil

function Skynet_PartySize()
    if Skynet_PartySizeCache then return Skynet_PartySizeCache end
    local n = 0
    pcall(function()
        for _ in pairs(Osi.DB_Players:Get(nil) or {}) do n = n + 1 end
    end)
    if n < 1 then n = 4 end
    Skynet_PartySizeCache = n
    return n
end

function Skynet_CombatHasParty(cid)
    if cid == nil or cid == "" then return false end
    local now = Ext.Utils.MonotonicTime()
    local c = Skynet_PartyCombatCache[cid]
    if c and now - c.t < 3000 then return c.v end
    local has = false
    pcall(function()
        for _, row in pairs(Osi.DB_Players:Get(nil) or {}) do
            local p = row and row[1]
            if p and tostring(Osi.CombatGetGuidFor(p)) == cid then
                has = true
                break
            end
        end
    end)
    Skynet_PartyCombatCache[cid] = { t = now, v = has }
    return has
end

--- Returns hpPercent (0-100, steps of 5), extraActions (0-3), extraBonusActions (0-3).
function Skynet_EnemyBuffTiers()
    local hp = tonumber(Settings.EnemyBuffHPPercent) or 0
    local act = tonumber(Settings.EnemyBuffExtraActions) or 0
    local bon = tonumber(Settings.EnemyBuffExtraBonusActions) or 0
    if Settings.EnemyBuffScaling then
        local f = Skynet_PartySize() / 4
        hp, act, bon = hp * f, act * f, bon * f
    end
    hp = math.max(0, math.min(100, math.floor(hp / 5 + 0.5) * 5))
    act = math.max(0, math.min(3, math.floor(act + 0.5)))
    bon = math.max(0, math.min(3, math.floor(bon + 0.5)))
    return hp, act, bon
end

function Skynet_TryBuffEnemy(charStr, combatid, isRetry)
    if not Settings.EnableEnemyBuffs then return end
    if charStr == nil or charStr == "" or Skynet_EnemyBuffed[charStr] then return end
    local cid = tostring(combatid or "")

    local ok, isChar = pcall(Osi.IsCharacter, charStr)
    if not ok or isChar ~= 1 then return end
    local dOk, dead = pcall(Osi.IsDead, charStr)
    if dOk and dead == 1 then return end
    local hOk, host = pcall(Osi.GetHostCharacter)
    if not hOk or not host then return end
    local eOk, isEnemy = pcall(Osi.IsEnemy, charStr, host)
    if not eOk or isEnemy ~= 1 then return end

    if not Skynet_CombatHasParty(cid) then
        -- The party member may not have joined this combat yet: look once more shortly.
        if not isRetry and not Skynet_EnemyBuffPending[charStr] then
            Skynet_EnemyBuffPending[charStr] = true
            Ext.Timer.WaitFor(1500, function()
                Skynet_EnemyBuffPending[charStr] = nil
                Skynet_TryBuffEnemy(charStr, cid, true)
            end)
        end
        return
    end

    local hp, act, bon = Skynet_EnemyBuffTiers()
    if hp == 0 and act == 0 and bon == 0 then return end

    Skynet_EnemyBuffed[charStr] = cid
    local hpBefore = Osi.GetHitpoints(charStr)
    local maxBefore = Osi.GetMaxHitpoints(charStr)
    if hp > 0 then pcall(Osi.ApplyStatus, charStr, "SKYNET_TOUGH_HP_" .. hp, -1, 1) end
    if act > 0 then pcall(Osi.ApplyStatus, charStr, "SKYNET_TOUGH_ACT_" .. act, -1, 1) end
    if bon > 0 then pcall(Osi.ApplyStatus, charStr, "SKYNET_TOUGH_BONUS_" .. bon, -1, 1) end

    -- Keep the same HP fraction against the new maximum (Tactician Enhanced did this too).
    if hp > 0 and hpBefore and maxBefore and maxBefore > 0 then
        Ext.Timer.WaitFor(300, function()
            local deadNow = Osi.IsDead(charStr)
            local maxAfter = Osi.GetMaxHitpoints(charStr)
            if deadNow ~= 1 and maxAfter and maxAfter > maxBefore then
                pcall(Osi.SetHitpoints, charStr, math.max(1, math.floor(hpBefore / maxBefore * maxAfter + 0.5)))
            end
        end)
    end
    log("  ENEMY BUFF: " .. charStr:sub(1, 40) .. " +" .. hp .. "% HP, +" .. act .. " action, +" .. bon .. " bonus action")
end

local function Skynet_RegisterAllOsirisListeners()
    if Skynet_ListenersRegistered then return end

    Ext.Utils.Print(LOG_PREFIX .. "Registering Osiris listeners (from SessionLoaded or direct call)...")

    local function safeRegister(name, arity, timing, cb)
        local ok, err = pcall(function()
            Ext.Osiris.RegisterListener(name, arity, timing, cb)
        end)
        if not ok then
            Ext.Utils.Print(LOG_PREFIX .. "  WARNING: failed to register " .. name .. ": " .. tostring(err))
        end
        return ok
    end

    -- Returns a BASE_GAME_STATUSES-style reason ("incapacitated"/"frightened"/
    -- "movement_restricted") for statusId, or nil if it isn't a tracked base-game-control
    -- trigger — same logic as (and must be kept in sync with) ShouldBaseGameControl's own
    -- inline copy further up the file; duplicated rather than factored into one shared
    -- top-level helper because this file's top-level local count is already at Lua's 200
    -- ceiling. See Maintenance history pass #23.
    local function Skynet_ClassifyBaseGameStatus(statusId)
        if not statusId or statusId == "" then return nil end
        local reason = BASE_GAME_STATUSES[statusId]
        if reason then return reason end
        local ok, isParalyzeGroup = pcall(function() return Osi.IsStatusFromGroup(statusId, "SG_Paralyzed") end)
        if ok and isParalyzeGroup == 1 then return "incapacitated" end
        -- PASS #39: general SG_Incapacitated group fallback — kept in sync with
        -- ShouldBaseGameControl's own copy above. See its comment and Maintenance history
        -- pass #39 for the DSleep-mod bug this closes.
        local iOk, isIncapGroup = pcall(function() return Osi.IsStatusFromGroup(statusId, "SG_Incapacitated") end)
        if iOk and isIncapGroup == 1 then return "incapacitated" end
        return nil
    end

    -- PASS #43: "is uuid a small/sneaky rope-tie-up candidate" — the classification the
    -- user's own "apcs_RestSystem" mod built for its redesigned rope tie-up feature
    -- (RopeTieUpClassifier.lua: Goblin/Kobold/Imp/Gnome races, an actual Rogue class, or
    -- that mod's own bandit-ambusher flag all count as "small"). PREFERS calling that
    -- mod's own real classifier when it's loaded (via the Mods.apcs_RestSystem cross-mod
    -- table it publishes itself — soft dependency, pcall-guarded, exactly like this file's
    -- existing "Third-party integrations recognized by name" pattern), since it's
    -- authoritative for exactly this question and also covers Rogue/ambusher cases this
    -- fallback doesn't. FALLS BACK to a local, lightweight race-name check (same four
    -- names, same technique that mod's own classifier uses — Ext.Entity.Get(uuid).Race.Race
    -- resolved via Ext.StaticData.Get(id,"Race"), walking ParentGuid to the root race name)
    -- when apcs_RestSystem isn't loaded at all, so this still works for a user running
    -- Gray's Bondage on its own. Declared as a bare GLOBAL function (no "local") per pass
    -- #35's technique — the file is at the 200 top-level-local ceiling, and this needs to
    -- be callable both from onTurnStarted's rope-tie-up deferral gate below and from
    -- ScoreSpellForEnemy's grapple-lead-in bonus earlier in the file. See Maintenance
    -- history pass #43.
    function Skynet_IsSmallRopeTieUpCandidate(uuid)
        if not uuid or uuid == "" then return false end

        local bridgeOk, bridgeResult = pcall(function()
            if Mods and Mods.apcs_RestSystem and Mods.apcs_RestSystem.APCSRopeTieUp
               and Mods.apcs_RestSystem.APCSRopeTieUp.GetSizeCategory then
                return Mods.apcs_RestSystem.APCSRopeTieUp.GetSizeCategory(uuid)
            end
            return nil
        end)
        if bridgeOk and bridgeResult ~= nil then
            return bridgeResult == "small"
        end

        -- Fallback: apcs_RestSystem not loaded — same four race names Gray's Bondage's own
        -- rope-grant eligibility is restricted to (HUMANOID/FEY/FIEND), narrowed to the
        -- small-bodied subset the user specifically asked for.
        local smallRaceNames = { "goblin", "kobold", "imp", "gnome" }
        local nameOk, raceName = pcall(function()
            local entity = Ext.Entity.Get(uuid)
            if not entity or not entity.Race or not entity.Race.Race then return nil end
            local raceId = tostring(entity.Race.Race)
            for _ = 1, 4 do  -- bounded walk up the ParentGuid chain to the root race
                local raceDesc = Ext.StaticData.Get(raceId, "Race")
                if not raceDesc then return nil end
                local parentGuid = raceDesc.ParentGuid
                if parentGuid and tostring(parentGuid) ~= "" and tostring(parentGuid) ~= "00000000-0000-0000-0000-000000000000" then
                    raceId = tostring(parentGuid)
                else
                    return raceDesc.Name
                end
            end
            return nil
        end)
        if nameOk and raceName then
            local key = string.lower(tostring(raceName))
            for _, candidate in ipairs(smallRaceNames) do
                if key:find(candidate, 1, true) then return true end
            end
        end
        return false
    end

    -- PASS #52: risk-aware "grapple first vs. go direct" decision for MEDIUM/LARGE-tier rope
    -- tie-up candidates. Per the user's own explanation this session: a small-tier caster's
    -- general tie-up is already a Bonus Action, same cost as the Grappled variant, so
    -- grappling first (Action) and finishing with the Bonus Action the SAME turn is a strict
    -- upgrade for them (no interrupt risk, target gets disadvantage instead) — no risk
    -- calculus needed, they should just always prefer it. A medium/large caster's general
    -- tie-up is ALSO an Action, same as grappling itself, so grappling first costs them a
    -- whole extra turn (grapple this turn, tie up next turn) instead of a free combo — only
    -- worth it when the interrupt risk looks genuinely worth avoiding. Per the user's
    -- explicit choice when asked directly ("risk-aware" over "always safe"/"always direct"),
    -- that's true when EITHER: the caster is already somewhat hurt (a free counter-attack
    -- landing could matter more to a wounded caster), OR the likely target is a known hard
    -- hitter. "Hard hitter" is judged via the existing persistent `PlayerProfile.characters`
    -- average damage-per-combat, compared RELATIVE to the rest of the tracked party — the
    -- same relative-signal technique `Skynet_GetPlayerThreatBonus` already uses elsewhere in
    -- this file — rather than treated as a literal single-hit damage estimate, since
    -- `avg_damage_per_combat` is a whole-combat running total, not a per-hit figure, and no
    -- per-hit data exists anywhere in this file to compare against instead. Declared as a
    -- bare global (pass #35 technique, 200-local ceiling) since it's called from both
    -- `ScoreSpellForEnemy`'s Grapple lead-in nudge and `Skynet_SelfPrepare`'s Priority 0.75.
    -- See Maintenance history pass #52.
    function Skynet_ShouldGrappleBeforeTieUp(enemyId)
        if not enemyId or enemyId == "" then return false end

        local selfHpOk, selfHpPct = pcall(function() return Osi.GetHitpointsPercentage(enemyId) end)
        if selfHpOk and type(selfHpPct) == "number" and selfHpPct <= 50 then
            return true
        end

        if PlayerProfile and PlayerProfile.characters then
            local totalAvg, trackedCount = 0, 0
            for _, cp in pairs(PlayerProfile.characters) do
                totalAvg = totalAvg + (cp.avg_damage_per_combat or 0)
                trackedCount = trackedCount + 1
            end
            if trackedCount > 0 then
                local partyAvg = totalAvg / trackedCount
                if partyAvg > 0 then
                    local targetsOk, aliveTargets = pcall(function() return GetPlayerTargets() end)
                    if targetsOk and aliveTargets then
                        for _, candidate in ipairs(aliveTargets) do
                            local cp = PlayerProfile.characters[candidate]
                            if cp and (cp.combats_seen or 0) > 0 and (cp.avg_damage_per_combat or 0) >= partyAvg * 1.5 then
                                return true
                            end
                        end
                    end
                end
            end
        end

        return false
    end

    -- PASS #46 (corrects pass #45's spell choice — the mod itself changed this session):
    -- directly casts apcs_RestSystem's own rope tie-up spell on a party member, the way
    -- Shared/BanditBehavior.lua casts its own spell (a bare Osi.UseSpell call, no
    -- spellbook/HasSpell check, and — per the user's explicit choice this session — no
    -- inventory-rope check either, to see how the tactic feels before tying it to actual
    -- item possession). The user reworked apcs_RestSystem mid-session to add a SECOND
    -- spell family alongside the original DC-roll one: a no-roll, auto-succeed version
    -- that only works against an already-incapacitated target (DOWNED/LIE_DYING/
    -- KNOCKED_OUT/PRONE/KNOCKED_DOWN/SLEEPING/SG_Sleeping/NATURAL_SLEEPING/AD_DEFEATED —
    -- confirmed by direct read of apcs_RestSystem's own Spell_Target.txt, same state list
    -- Shared/BanditBehavior.lua's own IsBanditTieEligibleState checks, same no-interrupt
    -- behavior as the bandit spell it's modeled on), and BOTH families are now tiered by
    -- the caster's own size (via APCSRopeTieUp.GetTieUpDCTier). Selection priority:
    -- already-grappled target (Target_apcs_Rope_TieUp_Grappled — flat DC16, unconditional,
    -- no interrupt, matching the user's "no interrupt once grappled" rule) beats
    -- already-incapacitated (the no-roll auto-succeed family — a guaranteed tie-up when
    -- available) beats the general opposed-DEX-roll family otherwise. Hard soft-dependency
    -- on apcs_RestSystem being loaded: without it none of these spells exist to cast at
    -- all, so this returns false immediately and the caller falls back to Gray's Bondage's
    -- own mechanism (if present). Picks the nearest alive, not-already-tied party target
    -- via the same GetPlayerTargets() list this file's own targeting code uses elsewhere —
    -- deliberately does NOT check the caster's own inventory for a rope item, per the
    -- user's explicit request this session to test the tactic without that gate for now.
    --
    -- PASS #47 changes: (1) the per-spell cost is no longer hardcoded by name — it's read
    -- live from whichever spell is actually chosen, via GetSpellProperties' own UseCosts
    -- field (same technique Skynet_PostAttackEscape/pass #42 already uses), so a future
    -- mod-side cost change (this exact family's cost has already changed three times this
    -- session across pass #44->#45->#46) takes effect automatically instead of needing
    -- another pass. (2) two new optional parameters: grappledOnly, when true, makes this
    -- ONLY proceed if the selected target is actually grappled right now (used by the new
    -- post-attack grapple-follow-up hook — see attackWithRemainingResources's call site —
    -- so that hook never re-attempts the general/incapacitated branches Priority 0.75
    -- already tried earlier this turn); remainingAction/remainingBonusAction, when
    -- provided, make this refuse to cast something the turn can't actually afford instead
    -- of assuming a fresh budget — Priority 0.75's own call site still omits both (Self-
    -- Prepare runs before anything this turn has spent a resource, the same fresh-budget
    -- assumption its other branches already make), so its behavior is unchanged. Returns
    -- (success, costType) — "action" or "bonus" (or nil if the real cost couldn't be
    -- determined, e.g. a free/unknown UseCosts) on a successful cast — so the caller can
    -- correctly deduct the right resource from this turn's real ledger, the same
    -- established pattern pass #37/#42 already use. Declared as a bare global (pass #35
    -- technique, 200-local ceiling) since it's called from both Skynet_SelfPrepare and
    -- Skynet_AITurn. See Maintenance history pass #43/#44/#45/#46/#47.
    --
    -- PASS #51 (corrects pass #46-#48's assumptions — the user removed a whole spell family
    -- this session): the no-roll, auto-succeed "Incapacitated" tie-up family described in the
    -- PASS #46 comment above has been REMOVED entirely from apcs_RestSystem — per the user's
    -- own words, "that one just removed that. It doesn't make sense, it's too much" (confirmed
    -- directly in apcs_RestSystem's current Spell_Target.txt and Shared/Rope.lua — no
    -- "Target_apcs_Rope_TieUp_Incapacitated[_BonusAction]" entries exist anymore). The
    -- isIncapacitated branch and its spell IDs below are gone; incapacitation state no longer
    -- affects which tie-up spell is chosen at all (only isGrappling vs. general now do).
    -- Separately, the general/medium-large spell ID changed from the bare
    -- "Target_apcs_Rope_TieUp" to "Target_apcs_Rope_TieUp_MediumLarge": the user repurposed the
    -- bare ID to be the spell embedded directly in the rope item itself (cast via the rope's own
    -- RootTemplates/_merged.lsf.lsx OnUsePeaceActions binding), explicitly NOT auto-granted to
    -- any caster's spellbook ("it should not be auto-granted, it should just be what's embedded
    -- in the rope"), so a granted character can no longer cast it at all — a new, separate,
    -- mechanically-identical entry "Target_apcs_Rope_TieUp_MediumLarge" (confirmed via
    -- Shared/Rope.lua's ropeTieUpSpellBySizeTier table: medium_large = "Target_apcs_Rope_
    -- TieUp_MediumLarge") is what's actually granted and castable now. The small-tier
    -- ("Target_apcs_Rope_TieUp_Small") and both grappled-tier spell IDs are unchanged. See
    -- Maintenance history pass #51.
    --
    -- PASS #52: new 5th parameter `preferGrappleSetup`. When true and the caster isn't
    -- already grappling the chosen target (and isn't a `grappledOnly` call), this casts
    -- `Target_Grapple` instead of any tie-up spell at all, returning ("action", if successful)
    -- — per the user's explicit framing this session of Grapple-first as the smarter setup
    -- move (no interrupt, target gets disadvantage) versus a direct tie-up attempt (one turn
    -- faster, but risks the victim's free counter-attack reaction). Priority 0.75 passes
    -- `true` unconditionally for small-tier casters (grappling first costs them nothing extra
    -- — their general tie-up is already a Bonus Action, so a successful grapple this turn's
    -- Action still leaves the Bonus Action free to finish the job the SAME turn via the
    -- existing `attackWithRemainingResources` follow-up hook) and conditionally for
    -- medium/large casters, gated on the new risk-aware `Skynet_ShouldGrappleBeforeTieUp`
    -- helper (grappling first costs them a whole extra turn, since their general tie-up is
    -- also Action-cost — only worth it when the interrupt risk looks genuinely worth
    -- avoiding). If the Grapple cast isn't attempted or fails, execution falls through to the
    -- normal tie-up selection below unchanged, so this is a pure addition with no regression
    -- when `preferGrappleSetup` is omitted/false. See Maintenance history pass #52.
    function Skynet_TryApcsRopeTieUp(enemyId, grappledOnly, remainingAction, remainingBonusAction, preferGrappleSetup)
        if not enemyId or enemyId == "" then return false, nil end
        if Mods == nil or Mods.apcs_RestSystem == nil then return false, nil end

        local targetsOk, aliveTargets = pcall(function() return GetPlayerTargets() end)
        if not targetsOk or not aliveTargets or #aliveTargets == 0 then return false, nil end

        local bestTarget, bestDistance = nil, nil
        for _, candidate in ipairs(aliveTargets) do
            local deadOk, isDead = pcall(function() return Osi.IsDead(candidate) end)
            local tiedOk, isTied = pcall(function() return Osi.HasActiveStatus(candidate, "apcs_ROPE_TIED_UP") end)
            -- PASS #55: this picked the nearest party member straight from the raw
            -- GetPlayerTargets() list with no IsValidTarget gate at all — so a hidden or
            -- invisible party member standing right next to a small enemy could be grappled
            -- or tied up by a forced Osi.UseSpell. Now gated like every other target path.
            if deadOk and isDead ~= 1 and not (tiedOk and isTied == 1) and IsValidTarget(enemyId, candidate) then
                local distOk, distance = pcall(function() return Osi.GetDistanceTo(enemyId, candidate) end)
                if distOk and distance ~= nil and (bestDistance == nil or distance < bestDistance) then
                    bestTarget = candidate
                    bestDistance = distance
                end
            end
        end
        if not bestTarget then return false, nil end

        -- Caster's own size tier (small -> Bonus Action variants, medium_large -> Action
        -- variants of both spell families). Skynet_IsSmallRopeTieUpCandidate's own caller
        -- already restricts this whole feature to "small" classification today, but this
        -- asks apcs_RestSystem's own tier function directly rather than assuming, so this
        -- function stays correct on its own terms if that gate is ever loosened later.
        local tierOk, tier = pcall(function()
            if Mods.apcs_RestSystem.APCSRopeTieUp and Mods.apcs_RestSystem.APCSRopeTieUp.GetTieUpDCTier then
                return Mods.apcs_RestSystem.APCSRopeTieUp.GetTieUpDCTier(enemyId)
            end
            return nil
        end)
        local isSmallTier = not (tierOk and tier == "medium_large")

        local isGrappling = false
        local bridgeOk, bridgeResult = pcall(function()
            if Mods.apcs_RestSystem.APCSGrapplingBridge and Mods.apcs_RestSystem.APCSGrapplingBridge.IsGrapplingTarget then
                return Mods.apcs_RestSystem.APCSGrapplingBridge.IsGrapplingTarget(enemyId, bestTarget)
            end
            return false
        end)
        if bridgeOk then isGrappling = (bridgeResult == true) end

        -- PASS #47: a grappledOnly caller (the post-attack follow-up hook) only cares about
        -- finishing off a target it's actually grappling right now — refusing early here
        -- means it never falls through to a fresh general/incapacitated attempt on some
        -- OTHER nearest target, which would just duplicate what Priority 0.75 already tried
        -- earlier this turn.
        if grappledOnly and not isGrappling then return false, nil end

        -- PASS #52: grapple-first setup, when requested and not already grappling. See the
        -- big comment above this function for the full reasoning. Only attempted when the
        -- caster actually has Target_Grapple (soft-dependency on DrKekyll_GrapplingFramework
        -- or similar, same as the existing ROPE TIE-UP GRAPPLE LEAD-IN scoring nudge checks);
        -- if that's unavailable, or the cast itself fails, falls straight through to the
        -- normal tie-up selection below instead of returning early, so a caller still gets
        -- SOMETHING attempted this call rather than nothing.
        if preferGrappleSetup and not grappledOnly and not isGrappling then
            local hasGrappleOk, hasGrapple = pcall(function() return Osi.HasSpell(enemyId, "Target_Grapple") end)
            if hasGrappleOk and hasGrapple == 1 then
                local grappleCastOk = pcall(function() return Osi.UseSpell(enemyId, "Target_Grapple", bestTarget) end)
                if grappleCastOk then
                    log("  APCS ROPE TIE-UP: " .. tostring(enemyId) .. " grapples " .. tostring(bestTarget) ..
                        " first (setup for a safer, interrupt-less tie-up)")
                    return true, "action"
                end
            end
        end

        -- PASS #48: the user split the grappled family by caster size tier too, mirroring
        -- the general/incapacitated families — Target_apcs_Rope_TieUp_Grappled_BonusAction
        -- (using Target_apcs_Rope_TieUp_Grappled, UseCosts "BonusActionPoint:1") now exists
        -- alongside the original medium/large Action-cost entry, confirmed directly in
        -- apcs_RestSystem's own Spell_Target.txt and Shared/Rope.lua's new
        -- ropeTieUpGrappledSpellBySizeTier table. This is exactly the data change pass #47
        -- anticipated as needed for the user's same-turn grapple+tie-up combo to actually
        -- work for a 1-action small-tier enemy — with it in place, and this function's cost
        -- resolution already dynamic (reads whichever spell's real UseCosts, below), the
        -- post-attack follow-up hook now genuinely lands the combo instead of only firing on
        -- a leftover prior-turn grapple. See Maintenance history pass #48.
        -- PASS #51: the incapacitated branch that used to sit here is gone (see the PASS #51
        -- comment above this function) — only isGrappling vs. general remain. The general
        -- medium/large spell ID is now "Target_apcs_Rope_TieUp_MediumLarge", not the bare
        -- "Target_apcs_Rope_TieUp" (that bare ID is item-embedded only now, never granted).
        local spellId
        if isGrappling then
            spellId = isSmallTier and "Target_apcs_Rope_TieUp_Grappled_BonusAction" or "Target_apcs_Rope_TieUp_Grappled"
        else
            spellId = isSmallTier and "Target_apcs_Rope_TieUp_Small" or "Target_apcs_Rope_TieUp_MediumLarge"
        end

        -- PASS #47: resolve the REAL cost from the chosen spell's own UseCosts stat at cast
        -- time (same parsing Skynet_PostAttackEscape/pass #42 already uses) instead of
        -- hardcoding "action"/"bonus" per spell name — this family's costs have already
        -- changed three times this session purely because the user's own mod kept changing
        -- them, so reading the real stat means a future change takes effect automatically.
        local costType = nil
        local propsOk, spellProps = pcall(GetSpellProperties, spellId, enemyId)
        if propsOk and spellProps and spellProps.useCosts and spellProps.useCosts ~= "" then
            local uc = string.lower(spellProps.useCosts)
            if uc:find("bonusactionpoint") then
                costType = "bonus"
            elseif uc:find("actionpoint") then
                costType = "action"
            end
        end

        -- When the caller supplied real resource counts (the post-attack follow-up hook
        -- does; Priority 0.75 doesn't — see the big comment above this function), refuse to
        -- cast something the turn can no longer actually pay for.
        if remainingAction ~= nil or remainingBonusAction ~= nil then
            if costType == "action" and (remainingAction or 0) <= 0 then return false, nil end
            if costType == "bonus" and (remainingBonusAction or 0) <= 0 then return false, nil end
        end

        local castOk = pcall(function() return Osi.UseSpell(enemyId, spellId, bestTarget) end)
        if castOk then
            log("  APCS ROPE TIE-UP: " .. tostring(enemyId) .. " attempts " .. spellId .. " on " .. tostring(bestTarget) ..
                (isGrappling and " (already grappled — no interrupt)" or ""))
            return true, costType
        end
        return false, nil
    end

    -- PASS #49: "equip gear looted off a tied-up target" — the user's own request: "when
    -- attacking a tied up character... the items are stripped... I want Skynet to also
    -- consider equipping those items because actually equipping items costs an action, at
    -- least in my mod setup... on the next turn, if the enemy is a reasonable enough
    -- distance away that they can spare an action to equip, or they maybe have two action
    -- points, they should consider equipping the item they took... the enemy can now use it
    -- against the party."
    --
    -- Skynet_PendingLootedGear[attacker] is a GLOBAL (no "local" — pass #35 technique, the
    -- file is at/near the 200 top-level-local ceiling) queue of item UUIDs, populated by a
    -- new "Unequipped" Osiris listener registered in Skynet_RegisterAllOsirisListeners
    -- below. That event (confirmed-real 2-arity: Unequipped(item, character), per
    -- docs.baldursgate3.game) fires the instant apcs_RestSystem's own
    -- Shared/TieUpStripSystem.lua unequips a stripped item off the tied-up victim — this
    -- gives Skynet the EXACT item identity directly, with no cross-file event-ordering
    -- dependency and no need to enumerate inventory contents afterward (confirmed against
    -- the Osiris Queries reference that no generic "list everything in X's inventory"
    -- primitive even exists — only by-tag/by-template lookups do). Skynet_LastAttackerOf is
    -- a second, independent GLOBAL cache Skynet maintains itself via its own "AttackedBy"
    -- listener (mirroring, not reading, TieUpStripSystem.lua's own identical-purpose
    -- private local of the same name — that one is a separate file's local and not
    -- reachable from here).
    -- PASS #50: vanilla Action Surge and apcs_RestSystem's Heroic Action Surge both grant an
    -- extra real action point as a self-target buff. Per the user's own framing this pass:
    -- "if it costs an action point to equip, and the enemy has action surge... they can equip
    -- an item, then use action surge, then they have another action to use." Tried in this
    -- fixed priority order (vanilla first, since a Fighter-type enemy might have both);
    -- apcs_RestSystem's own two other once-per-rest resources (Hyper Focus, Dig Deeper) don't
    -- grant an extra action so they don't belong in this family.
    --
    -- PASS #50 FOLLOW-UP: the user pointed to the "2e Spells" mod at
    -- C:\Users\Draik\Personal\GitHub\Apcs_RestSystem\2eSpells. Confirmed directly via its own
    -- stat data (Spell_Cantrips.txt/Status_Cantrips.txt): "Shout_BonusActionToAction" costs
    -- BonusActionPoint:2 and applies a status granting ActionResource(ActionPoint,1,0) — exactly
    -- the conversion this family needs. Its sibling, "Shout_ActionToBonusAction" (costs
    -- ActionPoint:1, grants 2 Bonus Actions), goes the OPPOSITE direction and would actually
    -- CONSUME the one real Action this feature is trying to free up — it doesn't belong here,
    -- and isn't wired into any decision yet since nothing in this file currently needs a spare
    -- Bonus Action this way (a future candidate: the rope tie-up Bonus-Action-cost combo).
    -- Neither spell has a real Cooldown (no once-per-rest limit at all — confirmed, the stat
    -- entries have no Cooldown field) — purely gated by whether the caster actually has the
    -- resource to spend, which Skynet_HasUsedLimitedSpell already handles correctly for a
    -- Cooldown-less spell (Skynet_GetSpellLimitBucket returns nil for it, so the "already used"
    -- check never blocks it, same as it never blocks an ordinary at-will spell).
    --
    -- That mod's own BootstrapServer.lua only grants both spells to the party
    -- (DB_PartOfTheTeam via AddSpell) — confirmed no enemy has either by default, unlike Heroic
    -- Action Surge/Hyper Focus/Dig Deeper (apcs_RestSystem's own ExtraordinaryActions.lua grants
    -- those to ANY humanoid-race NPC, hostile or not). Per the user's explicit choice when asked
    -- directly, Skynet now grants Shout_BonusActionToAction to eligible humanoid enemies itself
    -- (Skynet_EnsureHasSpell below) — the first time this file has ever granted a spell to
    -- anyone rather than just using what's already there, done lazily (only right before an
    -- actual attempt to use it) to keep the new behavior narrowly scoped.
    --
    -- Gated through Skynet_HasUsedLimitedSpell/Skynet_MarkLimitedSpellUsed, same as every other
    -- limited-use resource in this file — now correctly enforcing "once per LONG rest" since the
    -- Skynet_GetSpellLimitBucket fix above, and resettable early by a simulated rest via
    -- Skynet_ResetAllRestLimitedSpellsForMeditate. Real cost/benefit is resolved empirically via
    -- a before/after Skynet_GetRealActionPoints diff, the same technique already used just below
    -- for the equip itself and in Skynet_TryApcsRopeTieUp, rather than assuming a UseCosts value
    -- that wasn't directly confirmable for vanilla Shout_ActionSurge (not present in any of the
    -- user's own mod files — only Heroic Action Surge's "using Shout_ActionSurge" inheritance
    -- line is, and Ext.Stats.Get resolves that inheritance at runtime regardless).
    Skynet_ActionSurgeFamily = { "Shout_ActionSurge", "Shout_HeroicActionSurge", "Shout_BonusActionToAction" }

    -- Mirrors apcs_RestSystem's own ExtraordinaryActions.lua EA_HasPlayableRaceTag exactly (the
    -- same race-tag check that mod already uses to decide which hostile NPCs get Heroic Action
    -- Surge/Hyper Focus/Dig Deeper), so Skynet's own granting matches that mod's existing
    -- definition of "eligible humanoid" instead of inventing a different one.
    Skynet_PlayableRaceTokens = {
        DRAGONBORN = true, DROW = true, DWARF = true, ELF = true, GITHYANKI = true,
        GNOME = true, HALFELF = true, HALFORC = true, HALFLING = true, HUMAN = true,
        TIEFLING = true,
    }

    function Skynet_HasPlayableRaceTag(character)
        local entityOk, entity = pcall(function() return Ext.Entity.Get(character) end)
        if not entityOk or not entity then return false end
        local compOk, components = pcall(function() return entity:GetAllComponents() end)
        if not compOk or not components then return false end
        for componentName, component in pairs(components) do
            if tostring(componentName):find("Tag") then
                local tagsOk, tags = pcall(function() return component.Tags end)
                if tagsOk and tags then
                    for _, tag in pairs(tags) do
                        local staticOk, tagData = pcall(Ext.StaticData.Get, tag, "Tag")
                        if staticOk and tagData and tagData.Name then
                            local token = tostring(tagData.Name):upper():gsub("[^A-Z0-9]", "")
                            if Skynet_PlayableRaceTokens[token] then return true end
                        end
                    end
                end
            end
        end
        return false
    end

    -- Skynet has never granted a spell to anyone before this — see the note above for why this
    -- one case is a deliberate, user-confirmed exception. Checks first and only grants if truly
    -- missing; excludes summons (mirroring EA_IsSummon's own exclusion for the same grant).
    function Skynet_EnsureHasSpell(enemyId, spellId)
        local hasOk, hasSpell = pcall(function() return Osi.HasSpell(enemyId, spellId, 0) end)
        if hasOk and hasSpell == 1 then return true end
        if not Skynet_HasPlayableRaceTag(enemyId) then return false end
        local summonOk, isSummon = pcall(function() return Osi.IsSummon(enemyId) end)
        if summonOk and isSummon == 1 then return false end
        -- Arg shape (character, spell, 1, 1) mirrors 2e Spells' own confirmed-working call in
        -- its BootstrapServer.lua exactly, rather than guessing at Osiris AddSpell's signature.
        pcall(function() return Osi.AddSpell(enemyId, spellId, 1, 1) end)
        local reOk, reHas = pcall(function() return Osi.HasSpell(enemyId, spellId, 0) end)
        local granted = reOk and reHas == 1
        if granted then
            log("  2E SPELLS: granted " .. spellId .. " to eligible humanoid " .. tostring(enemyId):sub(1,40))
        end
        return granted
    end

    function Skynet_TryGrantExtraAction(enemyId)
        if not enemyId or enemyId == "" then return false, nil end
        for _, spellId in ipairs(Skynet_ActionSurgeFamily) do
            local hasOk, hasSpell = pcall(function() return Osi.HasSpell(enemyId, spellId, 0) end)
            local usable = hasOk and hasSpell == 1
            if not usable and spellId == "Shout_BonusActionToAction" then
                usable = Skynet_EnsureHasSpell(enemyId, spellId)
            end
            -- PASS #56: Heroic Action Surge only when the HP rule allows it, even to equip looted gear.
            if usable and spellId == "Shout_HeroicActionSurge" then
                local allowedHas, whyHas = Skynet_ExtraordinaryAllowed(enemyId, spellId)
                if not allowedHas then
                    log("  EXTRAORDINARY GATE: not surging to equip gear — " .. tostring(whyHas))
                    usable = false
                end
            end
            if usable and not Skynet_HasUsedLimitedSpell(enemyId, spellId) then
                local beforeAction, beforeBonus = Skynet_GetRealActionPoints(enemyId)
                local castOk = pcall(function() return Osi.UseSpell(enemyId, spellId, enemyId) end)
                if castOk then
                    Skynet_MarkLimitedSpellUsed(enemyId, spellId)
                    local afterAction, afterBonus = Skynet_GetRealActionPoints(enemyId)
                    local costType = nil
                    if beforeBonus ~= nil and afterBonus ~= nil and afterBonus < beforeBonus then
                        -- PASS #50: Shout_BonusActionToAction spends TWO bonus actions, not one
                        -- — "bonus2" tells the caller (Skynet_AITurn's deductAction call site)
                        -- to deduct twice rather than once, so the turn's own resource ledger
                        -- doesn't overstate remaining bonus actions by one after this specific
                        -- spell.
                        if (beforeBonus - afterBonus) >= 2 then
                            costType = "bonus2"
                        else
                            costType = "bonus"
                        end
                    elseif beforeAction ~= nil and afterAction ~= nil and afterAction < beforeAction then
                        costType = "action"
                    end
                    local gained = beforeAction ~= nil and afterAction ~= nil and afterAction > beforeAction
                    log("  RESOURCE SURGE: " .. tostring(enemyId) .. " casts " .. spellId ..
                        (costType and (" (cost=" .. costType .. ")") or "") ..
                        (gained and " — gained an action point" or " — no action-point gain detected"))
                    return true, costType
                end
            end
        end
        return false, nil
    end

    function Skynet_TryEquipLootedGear(enemyId, players)
        if not enemyId or enemyId == "" then return false, nil end
        local queue = Skynet_PendingLootedGear[enemyId]
        if not queue or #queue == 0 then return false, nil end

        -- "Reasonable distance... or two action points" gate, straight from the user's own
        -- framing: don't burn a resource equipping loot when adjacent to a party member who'd
        -- rather be attacked this turn, UNLESS there's real action economy to spare for both.
        local realAction = Skynet_GetRealActionPoints(enemyId)
        local hasSpareAction = realAction ~= nil and realAction >= 2
        local adjacentThreats = GetAdjacentThreats(enemyId, players or {})
        local surgeCost = nil
        if (#adjacentThreats > 0) and not hasSpareAction then
            -- PASS #50: before giving up for lack of a spare action, see if Action Surge /
            -- Heroic Action Surge can free one up first.
            local surged
            surged, surgeCost = Skynet_TryGrantExtraAction(enemyId)
            if surged then
                realAction = Skynet_GetRealActionPoints(enemyId)
                hasSpareAction = realAction ~= nil and realAction >= 2
            end
            if not hasSpareAction then
                -- Surge may still have been cast even though it wasn't enough (e.g. it granted
                -- a bonus action, not the real action this equip needed) — if so, a resource
                -- genuinely was spent this prepare-phase and must still be told to the ledger,
                -- even though the item stays queued for a later turn.
                return (surgeCost ~= nil), nil, surgeCost
            end
        end

        local item = table.remove(queue, 1)
        if not item or item == "" then return (surgeCost ~= nil), nil, surgeCost end

        -- Resolve the REAL cost by reading the engine's own action-resource counts before and
        -- after the Equip call, rather than assuming a fixed cost — per the user's own
        -- explicit framing this pass ("some people might have mod setups where equipping
        -- items doesn't cost an action... first item... free, second item... costs an
        -- action"), the same "read what the engine actually did" philosophy pass #47/#48
        -- already established for spell costs, applied here since equip costs are engine/
        -- install-specific behavior, not a queryable per-item stat the way spell UseCosts is.
        local beforeAction, beforeBonus = Skynet_GetRealActionPoints(enemyId)
        local equipOk = pcall(function() return Osi.Equip(enemyId, item) end)
        if not equipOk then
            log("  EQUIP LOOTED GEAR: " .. tostring(enemyId) .. " failed to equip " .. tostring(item))
            return (surgeCost ~= nil), nil, surgeCost
        end

        local afterAction, afterBonus = Skynet_GetRealActionPoints(enemyId)
        local costType = nil
        if beforeAction ~= nil and afterAction ~= nil and afterAction < beforeAction then
            costType = "action"
        elseif beforeBonus ~= nil and afterBonus ~= nil and afterBonus < beforeBonus then
            costType = "bonus"
        end

        log("  EQUIP LOOTED GEAR: " .. tostring(enemyId) .. " equips " .. tostring(item) ..
            " (looted off a tied-up target)" .. (costType and (", cost=" .. costType) or ", no resource cost detected"))
        return true, costType, surgeCost
    end

    local function onTurnStarted(character)
        local characterStr = safeStr(character)
        local characterResolved = resolveUuid(character)
        if characterResolved == "" then return end

        -- PASS #66: anything the player controls (party, custom avatar, modded companion, the player's summons
        -- and familiars) is the player's turn: no ally logic, no archetype, no base-AI suppression. One log line,
        -- except for the origin/avatar names that were always skipped silently.
        local pcReason = Skynet_PlayerControlledReason(characterResolved)
        if pcReason then
            local lc = string.lower(characterResolved)
            if not (lc:find("s_player_", 1, true) or lc:find("s_gustav", 1, true)) then
                log("TurnStarted SKIP: " .. characterResolved .. " is player-controlled (" .. pcReason .. ")")
            end
            return
        end

        -- Check allies FIRST so broken-faction allies aren't misclassified as enemies
        local isAlly = IsActualAlly(characterResolved)
        local isEnemy = false
        if not isAlly then
            isEnemy = IsActualEnemy(characterResolved)
        end
        if not isEnemy and not isAlly then
            if characterResolved:find("Spider_Eggs_Cluster") or characterResolved:find("Spider_Egg_Cluster") then
                AliveEggClusters[characterResolved] = true
            end
            log("TurnStarted SKIP: " .. characterResolved:sub(1,30) .. " is neither enemy nor ally")
            return
        end

        if isEnemy and not shouldProcessEnemy(characterResolved) then return end
        if isAlly and not shouldProcessAlly(characterResolved) then return end

        if IsSurprised(characterResolved) then
            log("TurnStarted for " .. (isAlly and "ALLY" or "ENEMY") .. ": " .. characterResolved .. " — SURPRISED, skipping")
            return
        end
        if IsNecromite(characterResolved) then
            log("TurnStarted for " .. (isAlly and "ALLY" or "ENEMY") .. ": " .. characterResolved .. " — NECROMITE, using base AI for Apostle encounter")
            return
        end

        -- Skip downed enemies (they're rolling death saves, not acting)
        if Settings.EnableEnemyDownedSystem and IsDowned(characterResolved) then
            log("TurnStarted for " .. (isAlly and "ALLY" or "ENEMY") .. ": " .. characterResolved .. " — DOWNED, skipping turn (death saves)")
            actedThisTurn[characterResolved] = true
            return
        end

        -- Skip characters controlled by base game (incapacitated, frightened, etc.)
        if ShouldBaseGameControl(characterResolved) then
            log("TurnStarted for " .. (isAlly and "ALLY" or "ENEMY") .. ": " .. characterResolved .. " — BASE GAME CONTROL (" .. (BaseGameControlled[characterResolved] or "?") .. ")")
            actedThisTurn[characterResolved] = true
            pcall(Skynet_NoteBaseControlTurn, characterResolved, BaseGameControlled[characterResolved])   -- PASS #63
            return
        end

        -- PASS #45 (corrects pass #44's spell choice, and relocates the apcs_RestSystem
        -- attempt out of this function entirely): the user confirmed directly that
        -- Target_apcs_Bandit_Rope_TieUp (free, UseCosts "") is Shared/BanditBehavior.lua's
        -- OWN EXCLUSIVE spell for flagged bandit ambushers specifically — NOT a generic
        -- spell any small/sneaky creature should use. "The tie up everywhere else [i.e. the
        -- version small creatures, the player, and normal/large creatures all use] costs an
        -- action in that mod." Since the real small-creature mechanism
        -- (Target_apcs_Rope_TieUp_Small / its grappled variant) costs a genuine Action, it
        -- needs this file's real per-turn resource ledger to deduct it correctly — which
        -- this onTurnStarted function runs too early to have (that bookkeeping lives inside
        -- Skynet_AITurn). So the apcs_RestSystem attempt itself has moved to
        -- Skynet_SelfPrepare's new Priority 0.75 (below, in that function), where
        -- `deductAction` is already the established pattern (see pass #42). This gate here
        -- now ONLY covers Gray's Bondage's own native item-use fallback, for an install
        -- that has Gray's Bondage but NOT apcs_RestSystem loaded at all — apcs_RestSystem,
        -- when loaded, is always the preferred/exclusive path, so this is skipped entirely
        -- whenever Mods.apcs_RestSystem is present. See Skynet_IsSmallRopeTieUpCandidate
        -- above and Maintenance history pass #43/#44/#45.
        if isEnemy and (Mods == nil or Mods.apcs_RestSystem == nil) and Skynet_IsSmallRopeTieUpCandidate(characterResolved) then
            local ropeOk, ropeItem = pcall(function() return Osi.GetItemByTagInInventory("OBJ_Rope_Pier", characterResolved) end)
            if ropeOk and ropeItem ~= nil and ropeItem ~= "" and math.random(100) <= 40 then
                log("TurnStarted for ENEMY: " .. characterResolved .. " — ROPE TIE-UP: deferring to base AI (Gray's Bondage native item, no apcs_RestSystem loaded)")
                actedThisTurn[characterResolved] = true
                return
            end
        end

        local characterRaw = characterResolved
        local spells = GetEnemyAvailableSpells(characterRaw)
        -- Skynet only ever looks at the first 20 (see GetEnemyAvailableSpells), so "20 spells" is a cap, not a count. The base
        -- game AI sees the WHOLE spell book; log how big it really is.
        local bookCount = 0
        pcall(function() bookCount = #Ext.Entity.Get(characterRaw).SpellBook.Spells end)
        log("TurnStarted for " .. (isAlly and "ALLY" or "ENEMY") .. ": " .. characterRaw .. " (" .. #spells .. " spells considered, " .. bookCount .. " in the spell book)")

        SkynetFC.completed[characterRaw] = nil
        Skynet_SuppressBaseAI(characterRaw)
        Skynet_AITurn(characterRaw, isAlly)
        if SkynetFC.completed[characterRaw] then
            -- Skynet planned a full turn: it stays in control until the queued actions resolve, then ends
            -- the turn itself. The base game AI is never handed a half-finished turn.
            SkynetFC.finishWhenDone(characterRaw)
        else
            -- A deliberate hand-off (no visible targets, no spell selected, hidden target, stuck...) —
            -- the base game AI takes over, as before.
            Skynet_ReleaseBaseAI(characterRaw)
            -- PASS #61: movement diagnostics (only does anything when enabled in MCM)
            if SkynetMoveDiag and SkynetMoveDiag.onHandOff then
                local why = Skynet_NoAttackHandOff and Skynet_NoAttackHandOff[resolveUuid(characterRaw)]
                pcall(SkynetMoveDiag.onHandOff, characterRaw, why and ("no attack: " .. tostring(why))
                    or "whole turn (see the Skynet line above: NO VISIBLE TARGETS / HIDDEN TARGET / STUCK / ...)")
            end
        end
    end

    -- Register both arities
    safeRegister("TurnStarted", 1, "before", onTurnStarted)
    safeRegister("TurnStarted", 2, "before", onTurnStarted)

    -- Feed for SkynetFC (Skynet ends its own turns): a cast starts with UsingSpell, resolves with CastSpell,
    -- and TurnEnded cancels any watch still running for that character.
    safeRegister("UsingSpell", 5, "after", function(caster, spell, _, _, storyActionId)
        SkynetFC.castStarted(safeStr(caster), storyActionId)
        pcall(Skynet_NoteTurnCast, safeStr(caster))   -- PASS #63
        pcall(SkynetMove.noteCast, safeStr(caster), safeStr(spell))   -- PASS #64
    end)
    safeRegister("TurnEnded", 1, "after", function(character)
        SkynetFC.turnEnded(safeStr(character))
        pcall(Skynet_CheckDisengageMoved, safeStr(character))   -- PASS #62
        pcall(Skynet_ClearBaseControlTurn, safeStr(character))  -- PASS #63
        pcall(SkynetMove.turnEnded, safeStr(character))         -- PASS #64
    end)

    -- PASS #62: watch for the base game AI misusing an enemy's leftovers (Help on someone it is fighting,
    -- Disengage without moving away) -> Skynet keeps that enemy's leftovers from then on.
    safeRegister("UsingSpellOnTarget", 6, "after", function(caster, target, spell)
        pcall(Skynet_OnPossibleMisuseCast, safeStr(caster), safeStr(target), safeStr(spell))
    end)
    safeRegister("CastSpell", 5, "after", function(caster, spell)
        pcall(Skynet_OnDisengageCast, safeStr(caster), safeStr(spell))
    end)

    -- PASS #56: per-fight attack record for the Hyper Focus rule (Skynet_IsOffenseFailing). An attempt is a
    -- damage-intent spell or weapon attack cast at someone the caster is hostile to; a hit is that same story
    -- action dealing damage (AttackedBy). Counted for every caster, whoever planned the turn, and reset per fight.
    function Skynet_OffenseRecordFor(attacker)
        local key = resolveUuid(attacker)
        if key == "" then return nil end
        local combat = tostring(CurrentCombatId or "")
        local rec = Skynet_OffenseRecord[key]
        if not rec or rec.combat ~= combat then
            rec = { combat = combat, attempts = {}, hits = {}, nAttempts = 0, nHits = 0, damage = 0, seq = 0 }
            Skynet_OffenseRecord[key] = rec
        end
        return rec
    end
    safeRegister("UsingSpellOnTarget", 6, "after", function(caster, target, spell, _, _, storyActionID)
        local casterStr, targetStr = safeStr(caster), safeStr(target)
        if casterStr == "" or targetStr == "" or resolveUuid(casterStr) == resolveUuid(targetStr) then return end
        local enOk, hostile = pcall(function() return Osi.IsEnemy(casterStr, targetStr) end)
        if not (enOk and hostile == 1) then return end
        local props = GetSpellProperties(safeStr(spell))
        local isAttack = BASIC_WEAPON_ATTACK_SPELLS[string.lower(safeStr(spell))]
            or (props and string.lower(props.verbalIntent or "") == "damage")
        if not isAttack then return end
        local rec = Skynet_OffenseRecordFor(casterStr)
        if not rec then return end
        local sa = safeStr(storyActionID)
        if sa == "" then rec.seq = rec.seq + 1; sa = "noid" .. rec.seq end
        if not rec.attempts[sa] then
            rec.attempts[sa] = true
            rec.nAttempts = rec.nAttempts + 1
        end
    end)
    safeRegister("AttackedBy", 7, "after", function(defender, attackerOwner, attacker, _, damageAmount, _, storyActionID)
        local atk = safeStr(attackerOwner)
        if atk == "" then atk = safeStr(attacker) end
        local amount = tonumber(damageAmount) or 0
        if atk == "" or amount <= 0 then return end
        local rec = Skynet_OffenseRecordFor(atk)
        if not rec then return end
        local sa = safeStr(storyActionID)
        if sa == "" then rec.seq = rec.seq + 1; sa = "noid" .. rec.seq end
        if not rec.hits[sa] then
            rec.hits[sa] = true
            rec.nHits = rec.nHits + 1
        end
        rec.damage = rec.damage + amount
    end)

    safeRegister("CastSpell", 5, "after", function(caster, spell, spellType, spellElement, storyActionId)
        SkynetFC.castResolved(safeStr(caster), storyActionId)
        local casterStr = safeStr(caster)
        local isPlayer = IsPlayerCharacterSafe(casterStr)
        local isEnemy = IsActualEnemy(casterStr)
        local isAlly = IsActualAlly(casterStr)
        if isPlayer then
            CombatHistory[spell] = (CombatHistory[spell] or 0) + 1
            log("Player cast tracked: " .. tostring(spell))

            -- Remember this action's story ID so the AttackedBy-based basic-attack tracker
            -- below doesn't double-count a spell's damage hit as a separate "basic attack" —
            -- see PlayerCastStoryActions declaration and Maintenance history pass #14.
            local saId = safeStr(storyActionId)
            if saId ~= "" then PlayerCastStoryActions[saId] = true end

            local props = GetSpellProperties(spell)
            if props then
                if props.isMelee then
                    PlayerProfile.style.melee_count = PlayerProfile.style.melee_count + 1
                elseif props.isRanged then
                    PlayerProfile.style.ranged_count = PlayerProfile.style.ranged_count + 1
                end
            end
        elseif isEnemy then
            log("Enemy cast: " .. tostring(spell) .. " by " .. casterStr:sub(1,40))
        elseif isAlly then
            log("Ally cast: " .. tostring(spell) .. " by " .. casterStr:sub(1,40))
        end
    end)

    -- Basic (non-spell) weapon-attack tracking for the player behavior profile. CastSpell
    -- above only ever fires for real Osiris spells — in BG3, ranged weapon attacks are
    -- implemented as spells internally, so bow/crossbow/thrown-weapon shots are already
    -- caught there, but plain melee weapon attacks (main-hand, off-hand, unarmed strikes,
    -- and Wild Shape natural weapon attacks) are resolved through the base "Attack" action
    -- and never fire CastSpell at all — confirmed by a mod user (bababadadadada, Nexus
    -- comments) whose wildshape monk's main-hand attacks never once showed up in
    -- player_profile.json while their bow attacks did. AttackedBy fires for every hit
    -- regardless of cause (spell or plain attack), so it's used here as the catch-all,
    -- with PlayerCastStoryActions (populated above) used to skip any hit that was already
    -- part of a spell cast we've already counted — see Maintenance history pass #14.
    safeRegister("AttackedBy", 7, "after", function(defender, attackerOwner, attacker, damageType, damageAmount, damageCause, storyActionID)
        local atkStr = safeStr(attackerOwner)
        if atkStr == "" then atkStr = safeStr(attacker) end
        if atkStr == "" then return end
        if not IsPlayerCharacterSafe(atkStr) then return end

        local saId = safeStr(storyActionID)
        if saId ~= "" and PlayerCastStoryActions[saId] then
            return  -- already counted via CastSpell — don't double-count this hit
        end

        local defStr = safeStr(defender)
        if defStr == "" then return end

        -- No spell involved, so classify melee vs ranged the same way the rest of the file
        -- already estimates reach: by actual distance between attacker and target.
        local dist = GetDistanceBetween(atkStr, defStr)
        local isMeleeAttack = dist <= 3.0

        -- Deliberately NOT double-underscore-prefixed (unlike e.g. "__obstacle_present__")
        -- since those are treated as non-spell metadata flags and skipped by
        -- UpdateProfileFromCombat's spell_frequency aggregation — these synthetic keys are
        -- meant to flow through that same aggregation so basic attacks actually show up as
        -- named, counted entries in player_profile.json, addressing the reported gap.
        local historyKey = isMeleeAttack and "Skynet_BasicMeleeWeaponAttack" or "Skynet_BasicRangedWeaponAttack"
        CombatHistory[historyKey] = (CombatHistory[historyKey] or 0) + 1
        if isMeleeAttack then
            PlayerProfile.style.melee_count = PlayerProfile.style.melee_count + 1
        else
            PlayerProfile.style.ranged_count = PlayerProfile.style.ranged_count + 1
        end
        log("Player basic attack tracked: " .. historyKey .. " (dist=" .. string.format("%.1f", dist) .. "m, cause=" .. tostring(damageCause) .. ")")
    end)

    -- Adaptive targeting (Intelligence/Wisdom tiers — see Maintenance history pass #21): tally
    -- every point of damage a player character lands on an actual enemy this combat, regardless
    -- of source (spell or basic attack — unlike the style tracker above, this one does NOT skip
    -- hits already counted via CastSpell, since it needs the full damage total, not a count).
    -- Skynet_LiveDamageByPlayer is reset each combat in CombatStarted and read by
    -- Skynet_GetPlayerThreatBonus / folded into the persistent per-character profile at
    -- CombatEnded.
    safeRegister("AttackedBy", 7, "after", function(defender, attackerOwner, attacker, damageType, damageAmount, damageCause, storyActionID)
        if not Settings.EnableAdaptiveTargeting then return end
        local atkStr = safeStr(attackerOwner)
        if atkStr == "" then atkStr = safeStr(attacker) end
        if atkStr == "" then return end
        if not IsPlayerCharacterSafe(atkStr) then return end

        local defStr = safeStr(defender)
        if defStr == "" then return end
        if not IsActualEnemy(defStr) then return end  -- only damage against real enemies counts

        local dmg = tonumber(damageAmount) or 0
        if dmg <= 0 then return end

        Skynet_LiveDamageByPlayer[atkStr] = (Skynet_LiveDamageByPlayer[atkStr] or 0) + dmg
    end)

    -- PASS #49: Skynet's own lightweight "last attacker" cache, feeding the new "equip
    -- looted gear" feature below. Mirrors apcs_RestSystem's own Shared/TieUpStripSystem.lua
    -- "lastAttackerOf" cache (same AttackedBy event, same idea) but is an entirely
    -- independent, Skynet-owned registration — that file's own cache is a private Lua local
    -- and isn't reachable across mods/files. Deliberately the opposite attacker-type filter
    -- from the two AttackedBy listeners just above (those only care about PLAYER-caused
    -- attacks; this one only cares about NPC-caused attacks, since only a Skynet-controlled
    -- character would ever need to consider equipping looted gear).
    safeRegister("AttackedBy", 7, "after", function(defender, attackerOwner, attacker, _, _, _, _)
        local defStr = safeStr(defender)
        if defStr == "" then return end
        local owner = safeStr(attackerOwner)
        if owner == "" then owner = safeStr(attacker) end
        if owner == "" then return end
        if IsPlayerCharacterSafe(owner) then return end  -- only NPC-caused attacks matter here
        Skynet_LastAttackerOf[defStr] = owner
    end)

    -- Confirmed-real 2-arity Osiris event: Unequipped(item, character) — fires whenever any
    -- item is unequipped from any character, for any cause. Used to detect, precisely and
    -- with no cross-file event-ordering dependency, exactly which item
    -- Shared/TieUpStripSystem.lua just moved off a tied-up victim (rather than re-deriving
    -- "what got stripped" afterward via inventory enumeration, which Osiris has no generic
    -- primitive for — confirmed against the Osiris Queries reference: only by-tag/
    -- by-template lookups exist, nothing that lists arbitrary inventory contents). Gated on
    -- the unequipping character currently wearing apcs_ROPE_TIED_UP (the strip-cascade
    -- precondition) and the cached last attacker being a living non-player character — an
    -- unrelated manual gear swap by a tied-up player is a rare edge case (tied-up isn't full
    -- incapacitation), and even if one slips through, Osi.Equip simply fails harmlessly on
    -- an item the queued character doesn't actually possess. See Maintenance history pass
    -- #49.
    safeRegister("Unequipped", 2, "after", function(item, character)
        local charStr = safeStr(character)
        if charStr == "" then return end
        local itemStr = safeStr(item)
        if itemStr == "" then return end

        local tiedOk, isTied = pcall(function() return Osi.HasActiveStatus(charStr, "apcs_ROPE_TIED_UP") end)
        if not (tiedOk and isTied == 1) then return end

        local attacker = Skynet_LastAttackerOf[charStr]
        if not attacker or attacker == "" then return end
        if IsPlayerCharacterSafe(attacker) then return end
        local deadOk, isDead = pcall(function() return Osi.IsDead(attacker) end)
        if deadOk and isDead == 1 then return end

        local queue = Skynet_PendingLootedGear[attacker]
        if not queue then
            queue = {}
            Skynet_PendingLootedGear[attacker] = queue
        end
        queue[#queue + 1] = itemStr
        log("  LOOTED GEAR QUEUED: " .. attacker:sub(1,30) .. " took " .. itemStr:sub(1,30) .. " off tied-up " .. charStr:sub(1,30))
    end)

    safeRegister("LevelGameplayStarted", 2, "after", function(levelName, isEditor)
        if isEditor == 1 or isEditor == true then return end
        Ext.Utils.Print(LOG_PREFIX .. "LevelGameplayStarted: " .. tostring(levelName))
    end)

    -- Combat context modeled after Logging mod
    safeRegister("CombatStarted", 1, "after", function(combatGuid)
        Ext.Utils.Print(LOG_PREFIX .. "CombatStarted: " .. tostring(combatGuid))
        CurrentCombatId = tostring(combatGuid or "unknown")
        PlayerContext = AnalyzePlayerParty()
        CombatHistory = {}
        PlayerCastStoryActions = {}
        actedThisTurn = {}
        ClearCreatureTypeCache()
        ClearMinionCache()
        FactionCache = {}  -- clear faction checks cache
        CachedPlayerTargets = nil
        CachedEnemyList = nil
        AvailableSpellsCache = {}
        LoadProfile()
        Skynet_LiveDamageByPlayer = {}  -- fresh per-combat damage tally for adaptive targeting
        CurrentCombatRound = 0
        local obOk, obstacles = pcall(FindObstaclesInCombat)
        if not obOk then obstacles = {globes = {}, walls = {}, doors = {}, other = {}} end
        Ext.Utils.Print(LOG_PREFIX .. "Combat context reset. Globes: " .. #obstacles.globes)
        if #obstacles.globes > 0 then
            CombatHistory["__obstacle_present__"] = 1
        end
        -- Start pulse tick
        skynetPulseTimer = Ext.Timer.WaitFor(3000, Skynet_PulseTick)
    end)

    safeRegister("CombatRoundStarted", 2, "after", function(combatGuid, round)
        Ext.Utils.Print(LOG_PREFIX .. "CombatRoundStarted round " .. tostring(round))
        CurrentCombatRound = tonumber(round) or CurrentCombatRound or 0  -- adaptive targeting round gate
        -- Clear turn action flags for new round
        actedThisTurn = {}
        CachedPlayerTargets = nil  -- refresh player positions/targets each round
        CachedEnemyList = nil      -- refresh enemy list (new creatures may have entered)
        AvailableSpellsCache = {}  -- refresh spell lists (spells may have been added/removed)
        -- Update profile every 3 rounds
        if round and round % 3 == 0 then
            local ok, err = pcall(UpdateProfileFromCombat)
            if not ok then
                Ext.Utils.Print(LOG_PREFIX .. "Round profile update FAILED: " .. tostring(err))
            end
        end
    end)

    safeRegister("EnteredCombat", 2, "after", function(character, combatid)
        local charStr = safeStr(character)
        if charStr == "" then return end

        -- Items (burning bottles, furniture, etc.) also fire EnteredCombat - one wine bottle
        -- did so ~300 times in a single fight. They can't change who is fighting, so don't
        -- throw away the target caches (and force a rebuild) for them.
        local icOk, icVal = pcall(Osi.IsCharacter, charStr)
        if icOk and icVal ~= 1 then return end

        -- Enemy buffs (replaces Tactician Enhanced): once per enemy per combat.
        if Settings.EnableEnemyBuffs then pcall(Skynet_TryBuffEnemy, charStr, combatid) end

        -- Wildshape option off: remove form spells so the base game AI can't cast them either.
        if not Settings.EnemyAllowWildshape then
            local swOk, nStripped = pcall(Skynet_StripEnemyWildshape, charStr)
            if swOk and nStripped and nStripped > 0 then
                for k in pairs(AvailableSpellsCache) do AvailableSpellsCache[k] = nil end
                log("  WILDSHAPE STRIP: removed " .. tostring(nStripped) .. " form spell(s) from " .. charStr:sub(1, 40))
            end
        end

        -- Invalidate enemy list cache so new creature is included
        CachedEnemyList = nil
        -- Also invalidate the player-target cache — CachedPlayerTargets is otherwise only
        -- refreshed once per round (CombatRoundStarted), so a player-side entrant that joins
        -- mid-round (an Invoke Duplicity duplicate, a new summon, etc.) would be invisible to
        -- every enemy's targeting for the rest of that round even while standing right in
        -- front of them.
        CachedPlayerTargets = nil

        -- Opportunistically (re)establish CurrentCombatId and restart the pulse tick.
        -- CurrentCombatId is normally only set by CombatStarted, which does NOT refire when
        -- loading a save straight into a fight that was already in progress — leaving the
        -- pulse tick dead (it self-stops without a combat id — see Skynet_PulseTick) and
        -- GetDownedAllies/GetEnemyTargets running on their DB-scan fallback for the rest of
        -- that combat. EnteredCombat still fires with a real combat GUID whenever a character
        -- (re)joins combat, so use it here to self-heal without waiting for a new combat.
        local combatIdStr = safeStr(combatid)
        if combatIdStr ~= "" and (not CurrentCombatId or CurrentCombatId == "") then
            CurrentCombatId = combatIdStr
            log("EnteredCombat: recovered CurrentCombatId = " .. combatIdStr:sub(1,40))
        end
        if not skynetPulseTimer then
            skynetPulseTimer = Ext.Timer.WaitFor(3000, Skynet_PulseTick)
        end

        -- Apply identification boost status so CE-assigned identification passives render in UI
        local e = safeCall(Ext.Entity.Get, charStr)
        if e and e.PassiveContainer and e.PassiveContainer.Passives then
            for _, p in ipairs(e.PassiveContainer.Passives) do
                if p and p.Passive and p.Passive.PassiveId then
                    local pid = p.Passive.PassiveId
                    if string.find(pid, "Skynet_Identification_") then
                        local boostStatus = pid .. "_Boost"
                        pcall(ApplyStatus, charStr, boostStatus, -1)
                        log("Identification boost " .. boostStatus .. " -> " .. charStr:sub(1,40))
                    end
                end
            end
        end
    end)

    safeRegister("CombatEnded", 1, "after", function(combatGuid)
        Ext.Utils.Print(LOG_PREFIX .. "CombatEnded: " .. tostring(combatGuid))
        CurrentCombatId = nil
        actedThisTurn = {}
        ClearCreatureTypeCache()
        ClearMinionCache()
        FactionCache = {}
        CachedPlayerTargets = nil
        CachedEnemyList = nil
        AvailableSpellsCache = {}
        AliveEggClusters = {}
        LocatedClusters = {}
        SpiderQueenLastAction = nil
        SpiderQueenControlledBySkynet = true
        WaitingForTarget = {}
        if SpiderQueenBaseGameTimer then
            pcall(function() SpiderQueenBaseGameTimer:Cancel() end)
            SpiderQueenBaseGameTimer = nil
        end
        skynetPulseTimer = nil
        local ok, err = pcall(UpdateProfileFromCombat)
        if not ok then
            Ext.Utils.Print(LOG_PREFIX .. "CombatEnded profile update FAILED: " .. tostring(err))
        end

        -- Fold this combat's live per-player damage (Skynet_LiveDamageByPlayer) into the
        -- persistent per-character profile for the "intelligent" adaptive-targeting tier.
        -- Done here (once, at combat end) rather than inside UpdateProfileFromCombat's
        -- every-3-rounds cadence, since that cadence re-adds the same un-reset CombatHistory
        -- repeatedly across a long fight — fine for the existing rough frequency counters, but
        -- would badly skew a running damage average. See Maintenance history pass #21.
        local charOk, charErr = pcall(function()
            if not PlayerProfile.characters then PlayerProfile.characters = {} end
            for uuid, dmg in pairs(Skynet_LiveDamageByPlayer) do
                if dmg and dmg > 0 then
                    local cp = PlayerProfile.characters[uuid]
                    if not cp then
                        cp = {
                            combats_seen = 0, total_damage_dealt = 0, avg_damage_per_combat = 0,
                            melee_count = 0, ranged_count = 0, control_count = 0, heal_count = 0,
                            last_updated = 0,
                        }
                        PlayerProfile.characters[uuid] = cp
                    end
                    cp.combats_seen = cp.combats_seen + 1
                    cp.total_damage_dealt = cp.total_damage_dealt + dmg
                    cp.avg_damage_per_combat = cp.avg_damage_per_combat + (dmg - cp.avg_damage_per_combat) / cp.combats_seen
                    cp.last_updated = PlayerProfile.combats_analyzed
                    log("  ADAPTIVE PROFILE: " .. uuid:sub(1,20) .. " combats_seen=" .. cp.combats_seen .. " avg_dmg=" .. string.format("%.1f", cp.avg_damage_per_combat))
                end
            end
            SaveProfile()
        end)
        if not charOk then
            Ext.Utils.Print(LOG_PREFIX .. "CombatEnded adaptive per-character profile update FAILED: " .. tostring(charErr))
        end
    end)

    -- ==================== BASE GAME CONTROL TRACKING ====================
    -- Mark characters with incapacitating/frightening statuses so Skynet stops controlling them

    safeRegister("StatusApplied", 4, "after", function(guid, status, causee, storyactionid)
        local charStr = safeStr(guid)
        if charStr == "" then return end
        local statusStr = tostring(status)
        local reason = Skynet_ClassifyBaseGameStatus(statusStr)
        if reason then
            BaseGameControlled[charStr] = reason
            log("  BASE GAME CONTROL: " .. charStr:sub(1,40) .. " marked (" .. reason .. " via " .. statusStr .. ")")
        end
    end)

    safeRegister("StatusRemoved", 4, "after", function(guid, status, causee, storyactionid)
        local charStr = safeStr(guid)
        if charStr == "" then return end
        local statusStr = tostring(status)
        if Skynet_ClassifyBaseGameStatus(statusStr) and BaseGameControlled[charStr] then
            local stillRestricted = false
            local ok, entity = pcall(function() return Ext.Entity.Get(charStr) end)
            if ok and entity and entity.ServerCharacter and entity.ServerCharacter.StatusManager and entity.ServerCharacter.StatusManager.Statuses then
                for _, s in pairs(entity.ServerCharacter.StatusManager.Statuses) do
                    if Skynet_ClassifyBaseGameStatus(tostring(s.StatusId)) then
                        stillRestricted = true
                        break
                    end
                end
            end
            if not stillRestricted then
                BaseGameControlled[charStr] = nil
                log("  BASE GAME CONTROL: " .. charStr:sub(1,40) .. " released (no more restricting statuses)")
                -- PASS #63: the restriction ran out right as this character's turn started -> Skynet plays the turn.
                local tbOk, takeBack, why = pcall(Skynet_ShouldTakeBackTurn, charStr)
                if tbOk and takeBack then
                    local key = resolveUuid(charStr)
                    BaseGameControlled[key] = nil
                    actedThisTurn[key] = nil
                    actedThisTurn[charStr] = nil
                    log("  BASE GAME CONTROL ended at the start of the turn (" .. statusStr .. " wore off; was: " .. tostring(why) .. ") — Skynet takes the turn back for " .. key:sub(1,40))
                    local runOk, runErr = pcall(onTurnStarted, charStr)
                    if not runOk then log("  TAKE BACK failed: " .. tostring(runErr)) end
                end
            else
                log("  BASE GAME CONTROL: " .. charStr:sub(1,40) .. " still restricted (other statuses active)")
            end
        end
    end)

    -- ==================== ENEMY DOWNED SYSTEM LISTENERS ====================

    -- Apply passives to eligible enemies when PRONE_DOWNED is applied
    safeRegister("StatusApplied", 4, "after", function(guid, status, causee, storyactionid)
        -- Party Downed System: Downed Condition 5E's "PRONE_DOWNED -> PRONE_DOWNED_CHECK" rule.
        if status == "PRONE_DOWNED" then
            if Settings.EnablePartyDownedSystem then
                local pg = safeStr(guid)
                pcall(function() Osi.ApplyStatus(pg, "PRONE_DOWNED_CHECK", 0.0, 1, pg) end)
            end
            return
        end
        -- Invoke Duplicity duplicate tracking (replaces the per-rebuild whole-level scan).
        if status == "DWE_UADUPLICITY_DUPLICATE_INIT"
            or status == "DWE_UADUPLICITY_ID_1_DUPLICATE" or status == "DWE_UADUPLICITY_ID_2_DUPLICATE"
            or status == "DWE_UADUPLICITY_ID_3_DUPLICATE" or status == "DWE_UADUPLICITY_ID_4_DUPLICATE" then
            local dg = safeStr(guid)
            if dg ~= "" then Skynet_TrackedDuplicates[dg] = true end
            return
        end
        if not Settings.EnableEnemyDownedSystem then return end
        if status ~= "SKYNET_PRONE_DOWNED" then return end
        local charStr = safeStr(guid)
        if charStr == "" then return end
        if not ShouldHaveDownedSystem(charStr) then return end
        pcall(function()
            if Osi.HasPassive(charStr, "Skynet_DownedTurnTracker") == 0 then
                Osi.AddPassive(charStr, "Skynet_DownedTurnTracker")
            end
            if Osi.HasPassive(charStr, "Skynet_DownedTurnTracker2") == 0 then
                Osi.AddPassive(charStr, "Skynet_DownedTurnTracker2")
            end
        end)
        log("  DOWNED SYSTEM: Applied turn tracker passives to " .. charStr:sub(1,40))
    end)

    -- ==================== SPIDER QUEEN CLUSTER DETECTION ====================
    -- Direct entity scan using Ext.Entity (like LocateItems mod)

    function ScanForEggClustersNear(maxDist)
        maxDist = maxDist or 150.0
        local found = 0
        local ex, ey, ez = nil, nil, nil
        -- Scan ServerItem entities (egg clusters are items)
        local ok, entities = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("ServerItem") end)
        if ok and entities then
            for _, entity in pairs(entities) do
                pcall(function()
                    local uuid = tostring(entity.Uuid.EntityUuid)
                    if uuid ~= "" and not LocatedClusters[uuid] then
                        -- Check template name for egg cluster
                        local tpl = entity.ServerItem and entity.ServerItem.Template
                        if tpl then
                            local tplName = tostring(tpl.Name or "")
                            local tplPath = tostring(tpl.Stats or "")
                        if tplName:find("Spider_Egg") or tplName:find("SpiderCluster") or tplName:find("Eggs_Cluster") or
                               tplPath:find("Spider_Egg") or tplPath:find("SpiderCluster") or tplPath:find("Eggs_Cluster") then
                                -- Exclude hanging eggs (not hatchable)
                                if not tplName:find("Hanging") and not tplPath:find("Hanging") then
                                    LocatedClusters[uuid] = true
                                    found = found + 1
                                    log("  SPIDER QUEEN SCAN: Found egg cluster " .. uuid:sub(1,30) .. " (" .. tplName .. ")")
                                end
                            end
                        end
                    end
                end)
            end
        end
        -- Also scan ServerCharacter entities (fallback: clusters may be characters)
        local ok2, entities2 = pcall(function() return Ext.Entity.GetAllEntitiesWithComponent("ServerCharacter") end)
        if ok2 and entities2 then
            for _, entity in pairs(entities2) do
                pcall(function()
                    local uuid = tostring(entity.Uuid.EntityUuid)
                    if uuid ~= "" and not LocatedClusters[uuid] then
                        local sc = entity.ServerCharacter
                        if sc and sc.Template then
                            local tplName = tostring(sc.Template.Name or "")
                            local tplPath = tostring(sc.Template.Stats or "")
                            if tplName:find("Spider_Egg") or tplName:find("SpiderCluster") or tplName:find("Eggs_Cluster") or
                               tplPath:find("Spider_Egg") or tplPath:find("SpiderCluster") or tplPath:find("Eggs_Cluster") then
                                -- Exclude hanging eggs (not hatchable)
                                if not tplName:find("Hanging") and not tplPath:find("Hanging") then
                                    LocatedClusters[uuid] = true
                                    found = found + 1
                                    log("  SPIDER QUEEN SCAN: Found egg cluster (char) " .. uuid:sub(1,30) .. " (" .. tplName .. ")")
                                end
                            end
                        end
                    end
                end)
            end
        end
        return found
    end

    -- Clean up downed statuses on death
    safeRegister("Died", 1, "after", function(character)
        local charStr = safeStr(character)
        if charStr == "" then return end
        if AliveEggClusters[charStr] then
            AliveEggClusters[charStr] = nil
        end
        Skynet_TrackedDuplicates[charStr] = nil
        Skynet_EnemyBuffed[charStr] = nil
        if not Settings.EnableEnemyDownedSystem then return end
        pcall(function() Osi.RemoveStatus(charStr, "SKYNET_DOWNED") end)
        pcall(function() Osi.RemoveStatus(charStr, "SKYNET_PRONE_DOWNED") end)
        pcall(function() Osi.RemoveStatus(charStr, "SKYNET_DOWNED_TECHNICAL_HIDDEN") end)
        pcall(function() Osi.RemoveStatus(charStr, "SKYNET_DOWNED5E_ACTIVE_TURN") end)
        pcall(function() Osi.RemoveStatus(charStr, "DEATHDOOR") end)
        pcall(function() Osi.RemovePassive(charStr, "Skynet_DownedTurnTracker") end)
        pcall(function() Osi.RemovePassive(charStr, "Skynet_DownedTurnTracker2") end)
        Skynet_ExpectedDeathDoor[charStr] = nil
    end)

    -- Track HP before hits on downed enemies for instant death calculation
    safeRegister("AttackedBy", 7, "before", function(defender, attackerOwner, attacker, _, _, _, _)
        if not Settings.EnableEnemyDownedSystem then return end
        local defStr = safeStr(defender)
        if defStr == "" then return end
        if not ShouldHaveDownedSystem(defStr) then return end
        if not IsDowned(defStr) then return end
        PendingDownedHPBefore[defStr] = Osi.GetHitpoints(defStr) or 0
    end)

    -- Instant death: damage > currentHP + maxHP while downed
    safeRegister("AttackedBy", 7, "after", function(defender, _, _, damageType, damageAmount, damageCause, _)
        if not Settings.EnableEnemyDownedSystem then return end
        local defStr = safeStr(defender)
        if defStr == "" then return end
        if not ShouldHaveDownedSystem(defStr) then return end
        if not IsDowned(defStr) then return end

        local hpBefore = PendingDownedHPBefore[defStr]
        PendingDownedHPBefore[defStr] = nil
        if hpBefore == nil then
            local hpAfter = Osi.GetHitpoints(defStr) or 0
            hpBefore = hpAfter + (damageAmount or 0)
        end

        local maxHP = Osi.GetMaxHitpoints(defStr) or 0
        local threshold = (hpBefore or 0) + maxHP
        if (damageAmount or 0) > threshold then
            local deathType = Skynet_DeathTypeForDamage(damageType)
            log("  INSTANT DEATH: " .. defStr:sub(1,30) .. " took " .. tostring(damageAmount) .. " > threshold " .. tostring(threshold) .. " (" .. deathType .. ")")
            local okDie, errDie = pcall(function() Osi.Die(defStr, Skynet_DeathTypeId(deathType), Skynet_NullGuid, 0, 0, 3.0) end)
            if not okDie then log("  INSTANT DEATH: Osi.Die failed: " .. tostring(errDie)) end
        end
    end)

    -- ==================== ENEMY DOWNED SYSTEM: TRIGGER THE DOWN ====================
    -- This is the actual redirect that makes the downed system engage at all: without it,
    -- eligible enemies simply die like normal — nothing above this point ever puts them into
    -- SKYNET_DOWNED in the first place, it only reacts to a downed state that already exists.
    safeRegister("AttackedBy", 7, "after", function(defender, _, _, damageType, damageAmount, damageCause, _)
        if not Settings.EnableEnemyDownedSystem then return end
        local defStr = safeStr(defender)
        if defStr == "" then return end
        if not ShouldHaveDownedSystem(defStr) then return end
        if IsDowned(defStr) then return end -- already downed — the overkill listener above handles this case

        local deadOk, isDead = pcall(function() return Osi.IsDead(defStr) end)
        if deadOk and isDead == 1 then return end -- too late, the engine already killed them

        local hpNow = Osi.GetHitpoints(defStr) or 0
        if hpNow > 0 then return end -- this hit wasn't lethal, nothing to do

        -- "Downed 5E"-style overkill: a single hit big enough to one-shot from full HP skips
        -- the downed system entirely and kills outright, same as a critical/massive blow would.
        local maxHP = Osi.GetMaxHitpoints(defStr) or 0
        if maxHP > 0 and (damageAmount or 0) >= maxHP then
            log("  DOWNED SYSTEM: overkill hit on " .. defStr:sub(1,30) .. " (" .. tostring(damageAmount) .. " >= max HP " .. tostring(maxHP) .. ") — no down, instant death")
            return
        end

        -- Death's Door: this enemy already went down and recovered once this life. No second
        -- chance — they die for real this time, mirroring the 5e "Death's Door" house rule.
        local ddOk, hasDeathDoor = pcall(function() return Osi.HasStatus(defStr, "DEATHDOOR") end)
        if ddOk and hasDeathDoor == 1 then
            local deathType = Skynet_DeathTypeForDamage(damageType)
            log("  DOWNED SYSTEM: " .. defStr:sub(1,30) .. " is marked Death's Door — dying instead of going down again (" .. deathType .. ")")
            local okDie, errDie = pcall(function() Osi.Die(defStr, Skynet_DeathTypeId(deathType), Skynet_NullGuid, 0, 0, 3.0) end)
            if not okDie then log("  DOWNED SYSTEM: Osi.Die failed: " .. tostring(errDie)) end
            return
        end

        -- Otherwise: keep them alive at 1 HP and put them into the real downed state, exactly
        -- like a player character going down — death saving throws, ally healing AI, the works.
        -- Both statuses are applied explicitly rather than relying on SKYNET_DOWNED's own
        -- OnRemoveFunctors chain (SKYNET_DOWNED -> SKYNET_DOWNED_TECHNICAL_HIDDEN ->
        -- Skynet_DownedTechPassive -> SKYNET_PRONE_DOWNED) to eventually grant PRONE_DOWNED:
        -- that chain only fires when SKYNET_DOWNED is *removed*, not applied, mirroring how
        -- Downed5E's own DOWNED/PRONE_DOWNED pair (which this stat data was copied from) is
        -- structured — for a real player, the base game's own engine-side downed transition
        -- applies both together, which a plain Osi.ApplyStatus("SKYNET_DOWNED") call doesn't
        -- replicate on its own. Applying PRONE_DOWNED here directly guarantees the actual
        -- "falls down, incapacitated, plays the downed animation" state enemies need to look
        -- and behave like a downed player, rather than depending on an indirect, removal-
        -- triggered chain that was never confirmed to fire on the way in.
        pcall(function() Osi.SetHitpoints(defStr, 1) end)
        pcall(function() Osi.ApplyStatus(defStr, "SKYNET_DOWNED", -1, 0) end)
        pcall(function() Osi.ApplyStatus(defStr, "SKYNET_PRONE_DOWNED", -1, 0) end)
        log("  DOWNED SYSTEM: " .. defStr:sub(1,30) .. " downed instead of killed (was about to die from " .. tostring(damageAmount) .. " " .. tostring(damageType) .. " damage)")
    end)

    -- Grant Death's Door once an eligible enemy recovers from being downed (stabilized/healed
    -- back up, SKYNET_DOWNED removed while still alive). From here on, a second down kills them
    -- for real — handled by the DEATHDOOR check in the listener above.
    safeRegister("StatusRemoved", 4, "after", function(guid, status, causee, storyactionid)
        if not Settings.EnableEnemyDownedSystem then return end
        if status ~= "SKYNET_DOWNED" then return end
        local charStr = safeStr(guid)
        if charStr == "" then return end
        if not ShouldHaveDownedSystem(charStr) then return end
        local deadOk, isDead = pcall(function() return Osi.IsDead(charStr) end)
        if deadOk and isDead == 1 then return end -- died while downed, not a recovery
        local ddOk, hasDeathDoor = pcall(function() return Osi.HasStatus(charStr, "DEATHDOOR") end)
        if ddOk and hasDeathDoor == 1 then return end -- already marked, nothing to do
        Skynet_ExpectedDeathDoor[charStr] = true
        pcall(function() Osi.ApplyStatus(charStr, "DEATHDOOR", -1, 0) end)
        log("  DOWNED SYSTEM: " .. charStr:sub(1,40) .. " recovered from downed — marked Death's Door")
        -- Safety net: if StatusApplied never fires for some reason (immunity, blocked, etc.),
        -- don't leave the interceptor permanently disarmed for this uuid.
        Ext.Timer.WaitFor(1000, function() Skynet_ExpectedDeathDoor[charStr] = nil end)
    end)

    -- ==================== ROGUE TEST COMPATIBILITY: DEATH'S DOOR ====================
    -- Rogue Test's "Combat Mastery" overhaul grants every level-1+ combatant — allies AND
    -- enemies alike — a passive that slaps its "DEATHDOOR" status on them the moment they'd
    -- naturally reach the vanilla DOWNED state. That's correct for the player's party (Rogue
    -- Test's own 5e house rule), but it isn't ours to hand to enemies: Skynet manages its own
    -- downed-then-Death's-Door lifecycle above. Strip DEATHDOOR from any non-player character
    -- unless Skynet itself just granted it.
    safeRegister("StatusApplied", 4, "after", function(guid, status, causee, storyactionid)
        if status ~= "DEATHDOOR" then return end
        local charStr = safeStr(guid)
        if charStr == "" then return end
        if Skynet_ExpectedDeathDoor[charStr] then
            Skynet_ExpectedDeathDoor[charStr] = nil
            return -- this is Skynet's own grant, leave it
        end
        local plOk, isPlayer = pcall(function() return Osi.IsPlayer(charStr) end)
        if plOk and isPlayer == 1 then return end -- real party members keep Rogue Test's own mechanic
        pcall(function() Osi.RemoveStatus(charStr, "DEATHDOOR") end)
        log("  DOWNED SYSTEM: stripped Death's Door from non-player " .. charStr:sub(1,40) .. " (not downed via Skynet)")
    end)

    -- ==================== PARTY DOWNED SYSTEM (replaces the Downed Condition 5E mod) ====================
    -- Downed Condition 5E does this with ~14 Osiris rules (including a HitpointsChanged rule that
    -- runs for EVERY entity's HP change, and 10 AttackedBy rules). Here the same rules run as a few
    -- Lua listeners that exit on a cached table lookup unless the target is a party member:
    --   * massive damage: a hit larger than (HP before the hit + max HP) kills outright instead of downing
    --   * (PRONE_DOWNED -> PRONE_DOWNED_CHECK is handled in the StatusApplied listener above)
    --   * turn-tracker passives are given to party members (they record which resources were used,
    --     so getting back up from Downed restores the unused ones)
    -- The status/passive DATA lives in Skynet_PartyDowned5E_*.txt (same IDs as Downed Condition 5E,
    -- so DISABLE that mod when using this). Requires EnablePartyDownedSystem in MCM.
    safeRegister("AttackedBy", 7, "before", function(defender, attackerOwner, attacker, _, _, _, _)
        if not Settings.EnablePartyDownedSystem then return end
        local defStr = safeStr(defender)
        if not Skynet_IsPartyDownedTarget(defStr) then return end
        Skynet_PendingPartyHP[defStr] = Osi.GetHitpoints(defStr)
    end)

    safeRegister("AttackedBy", 7, "after", function(defender, attackerOwner, attacker, damageType, damageAmount, damageCause, _)
        if not Settings.EnablePartyDownedSystem then return end
        local defStr = safeStr(defender)
        if not Skynet_IsPartyDownedTarget(defStr) then return end
        local hpBefore = Skynet_PendingPartyHP[defStr]
        Skynet_PendingPartyHP[defStr] = nil
        if hpBefore == nil or damageAmount == nil then return end
        local maxHP = Osi.GetMaxHitpoints(defStr) or 0
        if not (damageAmount > hpBefore + maxHP) then return end
        local deadOk, isDead = pcall(function() return Osi.IsDead(defStr) end)
        if deadOk and isDead == 1 then return end
        local dt = string.lower(damageType or "")
        -- Disintegrate has its own death handling; leave it alone (matches Downed Condition 5E).
        if dt:find("force") and tostring(damageCause) == "Projectile_Disintegrate" then return end
        local deathType = Skynet_DeathTypeForDamage(damageType)
        if dt:find("force") or dt:find("thunder") then deathType = "KnockedDown" end
        log("  PARTY DOWNED: massive damage on " .. defStr:sub(1,30) .. " (" .. tostring(damageAmount) .. " > " .. tostring(hpBefore + maxHP) .. ") - instant death (" .. deathType .. ")")
        local killer = safeStr(attackerOwner)
        if killer == "" then killer = Skynet_NullGuid end
        local okDie, errDie = pcall(function() Osi.Die(defStr, Skynet_DeathTypeId(deathType), killer, 0, 0, 3.0) end)
        if not okDie then log("  PARTY DOWNED: Osi.Die failed: " .. tostring(errDie)) end
    end)

    safeRegister("LevelGameplayReady", 0, "after", function()
        -- Invoke Duplicity duplicates already in the level when it loads (statuses persist in saves,
        -- so no StatusApplied fires for them): one scan per level load instead of one per cache rebuild.
        pcall(function()
            Skynet_TrackedDuplicates = {}
            for _, d in ipairs(Skynet_FindNearbyDuplicates(nil, nil)) do Skynet_TrackedDuplicates[d] = true end
        end)
        Skynet_PartyTargetCache = {}
        if not Settings.EnablePartyDownedSystem then return end
        pcall(function()
            for _, row in pairs(Osi.DB_Players:Get(nil) or {}) do
                if row and row[1] then Skynet_ApplyPartyDownedPassives(row[1]) end
            end
        end)
    end)

    safeRegister("CharacterJoinedParty", 1, "after", function(character)
        Skynet_PartyTargetCache = {}
        Skynet_PartySizeCache = nil
        if Settings.EnablePartyDownedSystem then Skynet_ApplyPartyDownedPassives(safeStr(character)) end
    end)

    safeRegister("CharacterLeftParty", 1, "after", function(character)
        Skynet_PartyTargetCache = {}
        Skynet_PartySizeCache = nil
    end)

    -- Enemy buffs: the statuses end with the combat (RemoveEvents OnCombatEnded); forget who had them.
    safeRegister("CombatEnded", 1, "after", function(combatGuid)
        local cid = tostring(combatGuid or "")
        for g, c in pairs(Skynet_EnemyBuffed) do
            if c == cid then Skynet_EnemyBuffed[g] = nil end
        end
        Skynet_PartyCombatCache[cid] = nil
    end)

    -- Apply passives to eligible enemies on level load
    safeRegister("LevelGameplayReady", 0, "after", function()
        if not Settings.EnableEnemyDownedSystem then return end
        local chars = Osi.GetRegionCharacters(nil) or {}
        for i = 1, #chars do
            local c = chars[i]
            if ShouldHaveDownedSystem(c) then
                pcall(function()
                    if Osi.HasPassive(c, "Skynet_DownedTurnTracker") == 0 then
                        Osi.AddPassive(c, "Skynet_DownedTurnTracker")
                    end
                    if Osi.HasPassive(c, "Skynet_DownedTurnTracker2") == 0 then
                        Osi.AddPassive(c, "Skynet_DownedTurnTracker2")
                    end
                end)
            end
        end
    end)

    -- PASS #54: the entire "out-of-combat investigation" system (AttackedBy-driven monitor/
    -- search/Osi.EnterCombat chain, plus its EnteredCombat cleanup listener and the
    -- OutOfCombatAttacks state table) was removed at the user's explicit request. Skynet no
    -- longer does anything when a player attacks a non-player, out-of-combat character —
    -- that's left entirely to the base game's own AI to notice the attack, investigate, and
    -- decide whether to enter combat, with zero Skynet involvement. See Maintenance history
    -- pass #54 for the removed code (previously added pre-pass-#1, patched in pass #39/#40).

    -- NOTE: this used to unconditionally Osi.AddPassive(charStr, "DeathDoor_CM") here, but that
    -- passive's own trigger condition only matches the literal vanilla "DOWNED" status ID —
    -- never "SKYNET_DOWNED" — so it could never actually fire for Skynet's enemies. Rogue Test
    -- already grants DeathDoor_CM to every combatant on its own; Skynet now manages Death's
    -- Door for enemies directly (see the SKYNET_DOWNED / DEATHDOOR listeners above), so this
    -- block was removed rather than fixed in place.

    -- Reset "once per combat" limited-spell usage (Action Surge and similar) whenever a
    -- character enters a NEW combat, so a fresh fight lets them use it again. Deliberately
    -- separate from the longRest/shortRest buckets, which must survive across combats and
    -- only clear on an actual rest. combatid is passed through so the reset itself can tell a
    -- genuinely new fight apart from this same fight's EnteredCombat re-firing after a
    -- mid-combat save/load — see Skynet_ResetCombatLimitedSpells for why that distinction matters.
    safeRegister("EnteredCombat", 2, "after", function(character, combatid)
        local charStr = safeStr(character)
        if charStr == "" then return end
        local icOk, icVal = pcall(Osi.IsCharacter, charStr)
        if icOk and icVal ~= 1 then return end -- items have no limited spells to reset
        Skynet_ResetCombatLimitedSpells(charStr, combatid)
    end)

    -- Reset "until long rest" limited-spell usage for everyone once the party wakes up.
    -- LongRestFinished fires globally with no per-character parameter.
    safeRegister("LongRestFinished", 0, "after", function()
        Skynet_ResetAllLongRestLimitedSpells()
        log("LongRestFinished: reset all long-rest-scoped limited spell usage")
    end)

    -- Reset "until short rest" limited-spell usage for the specific character who just took one.
    safeRegister("ShortRested", 1, "after", function(character)
        local charStr = safeStr(character)
        if charStr == "" then return end
        Skynet_ResetShortRestLimitedSpells(charStr)
        log("ShortRested: reset short-rest-scoped limited spell usage for " .. charStr:sub(1,30))
    end)

    -- PASS #50: apcs_RestSystem's "Meditate" simulates a long rest for the party without a real
    -- engine LongRestFinished ever firing. apsc_DEEPMEDITAT is the status it applies the moment
    -- that simulated rest completes (confirmed via Status_BOOST.txt's apcs_MEDITAT
    -- OnRemoveFunctors — gated to Player()+Party() there, so real LongRestFinished/ShortRested
    -- never cover enemies either way). Give every tracked enemy the equivalent refresh. See
    -- Skynet_ResetAllRestLimitedSpellsForMeditate above and Maintenance history pass #50.
    safeRegister("StatusApplied", 4, "after", function(guid, status, causee, storyactionid)
        if status ~= "apsc_DEEPMEDITAT" then return end
        Skynet_ResetAllRestLimitedSpellsForMeditate()
    end)

    Ext.Utils.Print(LOG_PREFIX .. "Osiris listeners registered.")
    Skynet_ListenersRegistered = true
end

_G.Skynet_RegisterAllOsirisListeners = Skynet_RegisterAllOsirisListeners

-- SessionLoaded: guaranteed place for prints + safe Osiris registration (the key to "seeing something in console")
Ext.Events.SessionLoaded:Subscribe(function()
    print(LOG_PREFIX .. "SessionLoaded (main) - Skynet active. This + the lines above prove the mod loaded.")
    if Ext and Ext.Utils and Ext.Utils.Print then
        Ext.Utils.Print(LOG_PREFIX .. "SessionLoaded (main) - Skynet active. Expect TurnStarted logs in combat.")
    end

    -- Register the Osiris hooks here so they are live
    pcall(Skynet_RegisterAllOsirisListeners)
end)

-- Note: registration also happens inside SessionLoaded (matching your Logging mod's setup() on SessionLoaded).
-- Direct early registration removed to avoid timing issues.

-- Note: Combat/Spell/OnTurn logic moved into Osiris listeners registered via Skynet_RegisterAllOsirisListeners (and EnteredCombat inside it).
-- Direct Ext.Events subscriptions were removed because they don't exist in this SE version.

-- ==================== MCM SUPPORT ====================

-- MCM is now primarily driven by MCM_blueprint.json (modern structure).
-- The code below is kept for compatibility / loading values if needed.
-- Wrapped to avoid load-time crashes if MCM not ready yet (common).

pcall(function()
    if Mods and Mods.BG3MCM and Mods.BG3MCM.MCMAPI then
        local modUUID = "e883778e-f8ae-9d7c-aa01-e738c7fb1040"  -- Skynet UUID from meta.lsx
        Settings.EnableReactiveCounters = Mods.BG3MCM.MCMAPI:GetSettingValue("EnableReactiveCounters", modUUID) or false
        Settings.EnableDebugLogging = Mods.BG3MCM.MCMAPI:GetSettingValue("EnableDebugLogging", modUUID) or true
        Settings.EnableEnemyDownedSystem = Mods.BG3MCM.MCMAPI:GetSettingValue("EnableEnemyDownedSystem", modUUID) or false
        Settings.EnablePartyDownedSystem = Mods.BG3MCM.MCMAPI:GetSettingValue("EnablePartyDownedSystem", modUUID) or false
        Settings.EnableEnemyBuffs = Mods.BG3MCM.MCMAPI:GetSettingValue("EnableEnemyBuffs", modUUID) or false
        Settings.EnemyBuffScaling = Mods.BG3MCM.MCMAPI:GetSettingValue("EnemyBuffScaling", modUUID) or false
        Settings.EnemyBuffHPPercent = Mods.BG3MCM.MCMAPI:GetSettingValue("EnemyBuffHPPercent", modUUID) or 0
        Settings.EnemyBuffExtraActions = Mods.BG3MCM.MCMAPI:GetSettingValue("EnemyBuffExtraActions", modUUID) or 0
        Settings.EnemyBuffExtraBonusActions = Mods.BG3MCM.MCMAPI:GetSettingValue("EnemyBuffExtraBonusActions", modUUID) or 0
        local awVal = Mods.BG3MCM.MCMAPI:GetSettingValue("EnemyAllowWildshape", modUUID)
        if awVal ~= nil then Settings.EnemyAllowWildshape = awVal end
        Settings.EnablePassiveCapping = Mods.BG3MCM.MCMAPI:GetSettingValue("EnablePassiveCapping", modUUID) or 20
        -- Adaptive targeting (pass #21). Boolean uses an explicit nil-check rather than the
        -- "value or default" idiom used above, since that idiom can't distinguish a real
        -- `false` from "not set" and would silently ignore the player disabling this in MCM.
        local atVal = Mods.BG3MCM.MCMAPI:GetSettingValue("EnableAdaptiveTargeting", modUUID)
        if atVal ~= nil then Settings.EnableAdaptiveTargeting = atVal end
        Settings.AdaptiveTargetingIntThreshold = Mods.BG3MCM.MCMAPI:GetSettingValue("AdaptiveTargetingIntThreshold", modUUID) or Settings.AdaptiveTargetingIntThreshold
        Settings.AdaptiveTargetingWisThreshold = Mods.BG3MCM.MCMAPI:GetSettingValue("AdaptiveTargetingWisThreshold", modUUID) or Settings.AdaptiveTargetingWisThreshold
        Settings.AdaptiveTargetingSessionRounds = Mods.BG3MCM.MCMAPI:GetSettingValue("AdaptiveTargetingSessionRounds", modUUID) or Settings.AdaptiveTargetingSessionRounds
        log("MCM settings loaded for Skynet")
    end
end)

print(LOG_PREFIX .. "Skynet Tactical AI fully loaded at end of Server/Skynet.lua (require time)")
-- Local helpers SkynetGates.lua needs to judge an enemy's kit (it cannot see this file's locals).
Skynet.Export = { GetAvailableSpells = GetEnemyAvailableSpells, ClassifySpell = ClassifySpell, FindHealSpell = FindHealSpell }
-- Invisible enemy + ranged attack + only see-invisibility-blind party members adjacent: walk away first (SkynetGates.stepBack)
function Skynet_StepBackIfInvisible(enemyId, players, spell)
  if not (SkynetGates and SkynetGates.stepBack) then return false end
  local ok, moved = pcall(SkynetGates.stepBack, enemyId, players, spell, {
    move = Skynet_MoveToPosition, hazards = Skynet_PathHasHazards, props = GetSpellProperties, adjacent = GetAdjacentThreats })
  return ok and moved or false
end

Ext.Utils.Print(LOG_PREFIX .. "Skynet Tactical AI loaded. Archetype system active — base AI nullified for Skynet-controlled enemies.")
Ext.Utils.Print(LOG_PREFIX .. "MCM toggles: Reactive Counters (off), Enemy Downed System (off), Passive Capping (on).")

-- Direct registration at module load time ensures listeners are live before SessionLoaded fires.
local regOk, regErr = pcall(Skynet_RegisterAllOsirisListeners)
if regOk then
    Ext.Utils.Print(LOG_PREFIX .. "Module-load registration: SUCCESS")
else
    Ext.Utils.Print(LOG_PREFIX .. "Module-load registration: FAILED - " .. tostring(regErr))
end