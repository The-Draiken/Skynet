-- Skynet: CX High Level Spell Slots
--
-- Combat Extender's own bonus-spell-slot mechanism (GiveSpellSlots) only
-- knows about CX_Spells_L1 through L6, and it lives entirely inside Combat
-- Extender's own BootstrapServer.lua, in a Lua sandbox Skynet cannot reach
-- into or modify. So rather than "patching" it, this file independently
-- reimplements the same idea for CX_Spells_L7/L8/L9 - checking for the
-- passive and granting a fixed number of bonus spell slots.
--
-- This is deliberately NOT reading Combat Extender's runtime JSON config.
-- It uses a fixed table of slot counts, set once here:
--   CX_Spells_L7 -> 3 extra level-7 spell slots
--   CX_Spells_L8 -> 2 extra level-8 spell slots
--   CX_Spells_L9 -> 1 extra level-9 spell slot
-- Change the numbers below if you ever want to adjust them.

local APPLIED_STATUS = "SKYNET_CX_L789_APPLIED"

local TIERS = {
    { passive = "CX_Spells_L7", level = 7, slots = 3 },
    { passive = "CX_Spells_L8", level = 8, slots = 2 },
    { passive = "CX_Spells_L9", level = 9, slots = 1 },
}

local function skynet_cx_print(msg)
    print("[Skynet][CX_L789] " .. tostring(msg))
end

local function HasPassiveSafe(guid, passive)
    local ok, has = pcall(function() return Osi.HasPassive(guid, passive) end)
    return ok and has == 1
end

local function HasAppliedSafe(guid)
    local ok, has = pcall(function() return Osi.HasActiveStatus(guid, APPLIED_STATUS) end)
    return ok and has == 1
end

-- Grants each matching tier's fixed bonus slots. skipAppliedGate lets the
-- LevelGameplayStarted re-grant path (below) call this for characters that
-- ALREADY carry the marker, without the normal "already applied" bailout.
local function GrantHighLevelSlots(guid, skipAppliedGate)
    if not guid or guid == "" then return end
    if not skipAppliedGate and HasAppliedSafe(guid) then return end

    local grantedAny = false
    for _, tier in ipairs(TIERS) do
        if HasPassiveSafe(guid, tier.passive) then
            local boost = string.format("ActionResource(SpellSlot,%d,%d)", tier.slots, tier.level)
            local ok, err = pcall(function()
                Osi.AddBoosts(guid, boost, "skynet_cx_l789", "1")
            end)
            if ok then
                grantedAny = true
                skynet_cx_print(string.format(
                    "Granted %d level-%d spell slot(s) to %s (via %s)%s",
                    tier.slots, tier.level, tostring(guid), tier.passive,
                    skipAppliedGate and " [reload re-grant]" or ""))
            else
                skynet_cx_print("ERROR granting boost for " .. tostring(guid) .. ": " .. tostring(err))
            end
        end
    end

    if grantedAny and not skipAppliedGate then
        local ok, err = pcall(function()
            Osi.ApplyStatus(guid, APPLIED_STATUS, -1)
        end)
        if not ok then
            skynet_cx_print("ERROR applying marker status to " .. tostring(guid) .. ": " .. tostring(err))
        end
    end
end

-- Same trigger Combat Extender itself uses for the L1-L6 version of this.
-- The APPLIED_STATUS guard (inside GrantHighLevelSlots) keeps repeat combat
-- entries from stacking the same boost more than once.
Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(guid, combatId)
    GrantHighLevelSlots(guid, false)
end)

-- ============================================================================
-- Save/reload re-grant
--
-- ActionResource boosts added via AddBoosts do NOT persist in the save file
-- on their own - only applied statuses do. So a character who already
-- received their bonus slots mid-fight, if you save and reload while still
-- in that fight, would silently lose them on reload without this. Combat
-- Extender handles this the same way for its own L1-L6 slots: on
-- LevelGameplayStarted, scan nearby characters and re-apply to anyone who
-- already carries the marker.
--
-- GetNearbyCharacters below is a direct reimplementation of Combat
-- Extender's own function of the same name - every call inside it
-- (Osi.GetHostCharacter, Ext.Entity.Get, Ext.Entity.GetAllEntitiesWithComponent,
-- Ext.Loca.GetTranslatedString) is a plain engine API, not anything private
-- to Combat Extender's own mod, so it's safe to copy the same approach here.
-- ============================================================================

local function GetNearbyCharacters(radius)
    local sourceEntity = Ext.Entity.Get(Osi.GetHostCharacter())
    local nearbyCharacters = {}
    if sourceEntity then
        local pos = sourceEntity.Transform.Transform.Translate
        for _, entity in ipairs(Ext.Entity.GetAllEntitiesWithComponent("BaseHp")) do
            if entity.ServerCharacter ~= nil then
                local target = entity.Transform.Transform.Translate
                local distance = math.sqrt((pos[1] - target[1])^2 + (pos[2] - target[2])^2 + (pos[3] - target[3])^2)
                if distance <= radius then
                    table.insert(nearbyCharacters, {
                        Guid = entity.Uuid.EntityUuid,
                        Name = entity.ServerCharacter.Template.Name,
                    })
                end
            end
        end
    end
    return nearbyCharacters
end

Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function(levelName, isEditorMode)
    local ok, nearbyCharacters = pcall(GetNearbyCharacters, 100)
    if not ok then
        skynet_cx_print("ERROR scanning nearby characters on level load: " .. tostring(nearbyCharacters))
        return
    end

    for _, character in ipairs(nearbyCharacters) do
        local guid = character.Name .. "_" .. character.Guid
        if HasAppliedSafe(guid) then
            GrantHighLevelSlots(guid, true)
        end
    end
end)

skynet_cx_print("CXHighLevelSlots.lua loaded (L7:3 / L8:2 / L9:1 bonus spell slots)")

return true
