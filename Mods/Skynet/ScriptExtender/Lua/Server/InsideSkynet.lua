-- ==================== INSIDE SKYNET (Proximity-Based Combat Grouping) ====================
-- When a character enters combat, nearby enemies within ClusterRadius are pulled in via BFS.
-- Based on "Combat Grouping By Proximity" mod, integrated into Skynet.
-- Max radius: 150m (configurable via MCM).

local InsideSkynet = {}

-- Dependencies injected from Skynet.lua
local deps = {}

function InsideSkynet.Init(dependencies)
    deps = dependencies
end

-- Status maps for character condition checks
local BLIND_STATUSES = {
    BLINDED = true, BLINDED_DARKNESS = true, BLINDING_SMITE_BLINDED = true, BLINDNESS = true,
}
local SLEEP_STATUSES = {
    SLEEPING = true, SLEEPING_MAGICAL = true, SLEEP = true,
}
local UNCONSCIOUS_STATUSES = {
    KNOCKED_OUT = true, DOWNED = true, UNCONSCIOUS = true,
}
local SILENCE_STATUSES = {
    SILENCED = true,
}

local function HasAnyStatus(uuid, statusMap)
    for status, _ in pairs(statusMap) do
        local ok, has = pcall(function() return Osi.HasActiveStatus(uuid, status) end)
        if ok and has == 1 then return true end
    end
    return false
end

local function IsBlinded(uuid) return HasAnyStatus(uuid, BLIND_STATUSES) end
local function IsSleeping(uuid) return HasAnyStatus(uuid, SLEEP_STATUSES) end
local function IsUnconscious(uuid) return HasAnyStatus(uuid, UNCONSCIOUS_STATUSES) end
local function IsSilenced(uuid) return HasAnyStatus(uuid, SILENCE_STATUSES) end

-- Check if character can be pulled into combat (not allied, not sleeping, not opt-out)
local function CanBePulled(uuid)
    if not uuid or uuid == "" then return false end
    if deps.IsPlayerCharacterSafe(uuid) then return false end
    if deps.IsActualAlly(uuid) then return false end
    local ok, has = pcall(function() return Osi.HasPassive(uuid, "SKYNET_CGBP_IGNORE") end)
    if ok and has == 1 then return false end
    if IsSleeping(uuid) or IsUnconscious(uuid) then return false end
    return true
end

-- Check if character can pull others (not silenced, not sleeping)
local function CanPull(uuid)
    if not CanBePulled(uuid) then return false end
    if IsSilenced(uuid) then return false end
    return true
end

-- Check if source can detect target via sight or hearing
local function CanDetect(sourceUuid, targetUuid, radius)
    if not sourceUuid or not targetUuid then return false, "none", -1 end
    local sx, sy, sz = Osi.GetPosition(sourceUuid)
    local tx, ty, tz = Osi.GetPosition(targetUuid)
    if not sx or not tx then return false, "none", -1 end
    local dx, dz = tx - sx, tz - sz
    local distance = math.sqrt(dx * dx + dz * dz)

    if IsSleeping(sourceUuid) or IsUnconscious(sourceUuid) then
        return false, "none", distance
    end

    if not IsBlinded(sourceUuid) then
        local canSeeOk, canSee = pcall(function() return Osi.CanSee(sourceUuid, targetUuid) end)
        if canSeeOk and canSee == 1 then
            return true, "sight", distance
        end
    end

    if not IsSilenced(sourceUuid) and distance <= radius then
        return true, "hearing", distance
    end

    return false, "none", distance
end

-- BFS to form a combat cluster from a seed character
function InsideSkynet.FormCluster(seedUuid, radius)
    if not seedUuid or seedUuid == "" then return {} end
    radius = radius or 150

    local visited = {}
    local queue = { seedUuid }
    local cluster = { seedUuid }
    visited[seedUuid] = true

    while #queue > 0 do
        local current = table.remove(queue, 1)

        if not CanPull(current) then
            goto continue
        end

        -- Scan all characters in combat for nearby eligible targets
        local allOk, allRows = pcall(function() return Osi.DB_IsCharacterInCombat:Get(nil) end)
        if allOk and allRows then
            for _, row in pairs(allRows) do
                local char = row and row[1]
                if char and char ~= "" and not visited[char] and CanBePulled(char) then
                    local canDetect, detType, dist = CanDetect(current, char, radius)
                    if canDetect then
                        visited[char] = true
                        table.insert(cluster, char)
                        table.insert(queue, char)
                    end
                end
            end
        end

        ::continue::
    end

    return cluster
end

-- Process cluster: mark non-combat characters as temporarily hostile so they join combat
function InsideSkynet.ProcessCluster(cluster)
    if #cluster <= 1 then return end

    local anyInCombat = false
    for _, uuid in ipairs(cluster) do
        local icOk, icVal = pcall(function() return Osi.IsInCombat(uuid) end)
        if icOk and icVal == 1 then anyInCombat = true; break end
    end
    if not anyInCombat then return end

    local host = Osi.GetHostCharacter()
    for _, uuid in ipairs(cluster) do
        local icOk, icVal = pcall(function() return Osi.IsInCombat(uuid) end)
        if not (icOk and icVal == 1) then
            local eOk = pcall(function() return Ext.Entity.Get(uuid) end)
            if eOk then
                pcall(function() Osi.SetRelationTemporaryHostile(uuid, host) end)
                deps.log("  INSIDE SKYNET: Pulled " .. uuid:sub(1,30) .. " into combat (cluster)")
            end
        end
    end
end

-- Main entry point: called when a character enters combat
function InsideSkynet.OnEnteredCombat(character, combatGuid)
    if not character or character == "" then return end
    local uuid = tostring(character)
    if not deps.IsActualEnemy(uuid) then return end
    local icOk, icVal = pcall(function() return Osi.IsInCombat(uuid) end)
    if icOk and icVal == 1 then return end

    local radius = deps.GetClusterRadius and deps.GetClusterRadius() or 150
    local cluster = InsideSkynet.FormCluster(uuid, radius)
    if #cluster > 1 then
        deps.log("  INSIDE SKYNET: Formed cluster of " .. #cluster .. " characters from " .. uuid:sub(1,30))
        InsideSkynet.ProcessCluster(cluster)
    end
end

return InsideSkynet
