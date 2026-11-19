-- Mods/Logging/ScriptExtender/Lua/Server/Logging.lua
-- JSON Combat Logger (Turn-Based)
--
-- Writes structured JSON that preserves Osiris dynamic IDs ("story IDs")
-- like S_TUT_..., S_DEN_..., etc.
--
-- Files are written to Script Extender's "user" domain, under:
--   logging/combat_<combatGuid>_<timestamp>.json
--
-- Notes:
-- - This logger is intended for *turn-based* encounters (vanilla TB).
-- - If you use real-time overhauls (e.g. Brawl), you can relax/adjust the
--   gating in isTurnBasedFor().

local MOD_PREFIX = "[Logging]"

-- User-domain folder
local LOG_DIR = "skynet"

-- Buffering: keep memory reasonable.
local FLUSH_AT_EVENTS = 200

-- Current combat session
local current = nil
local pendingFlush = false

-- Track recent casts for heuristics (success/failure + concentration binding)
local lastCastByCaster = {}

-- Track pending "spell results" by StoryActionID (best unique key we have)
local pendingSpellResults = {}

-- Track concentration state per caster
local concentrationByCaster = {}

-- Track prepared spells and spell slots per combatant
local combatantSpells = {}
local combatantSpellSlots = {}

-- Track action/bonus action usage per combatant per turn
local combatantActions = {}

-- Cache for spell analysis to avoid repeated lookups
local spellAnalysisCache = {}

-- Track combatant classes, passives, abilities, and current statuses
local combatantClasses = {}
local combatantPassives = {}
local combatantAbilities = {}
local combatantCurrentStatuses = {}
local combatantResistances = {}

-- Globe of Invulnerability tracking
local GLOBE_SPELL = "Target_GlobeOfInvulnerability"
local GLOBE_TEMPLATE = "d3da7020-9c7a-47bb-84cc-c69e41a758cd"
local GLOBE_VISUAL_STATUS = "GOI_GLOBE_VISUAL"
local BLOCKER_STATUS = "GOI_RIM_BLOCKER_MAGICAL_PHYSICAL_RESISTANCE"
local BLOCKER_TEMPLATES = {
  ["a8e6b7d1-4c2e-4d9a-9f3d-1b2c3d4e5f60"] = "North",
  ["b7c9a3e2-5d1f-4a8b-9c2e-6f705a1b3c4d"] = "South",
  ["c4d2e8f3-6a9b-4f1c-8d7e-2a3b4c5d6e70"] = "West",
  ["d5e3f9a4-7b8c-4e2d-9a1f-3b4c5d6e7f80"] = "East",
}
local activeGlobes = {}

-- Damage type names for resistance tracking
local DAMAGE_TYPES = {
  "Piercing", "Slashing", "Bludgeoning",
  "Fire", "Cold", "Lightning", "Thunder", "Acid", "Poison",
  "Radiant", "Necrotic", "Psychic", "Force"
}

-- Surface tracking identifiers (from UTAM)
local TRACKED_SURFACES = {
  -- Fire surfaces
  ["Fire"] = true,
  ["HolyFire"] = true,
  ["Hellfire"] = true,
  ["TrialFire"] = true,

  -- Ice/Water surfaces
  ["Water"] = true,
  ["WaterFrozen"] = true,
  ["Deepwater"] = true,

  -- Electrified surfaces
  ["WaterElectrified"] = true,
  ["BloodElectrified"] = true,

  -- Lava
  ["Lava"] = true,

  -- Acid
  ["Acid"] = true,
  ["InvisibleGithAcid"] = true,

  -- Web
  ["Web"] = true,
  ["InvisibleWeb"] = true,

  -- Blood/Bloodmist
  ["Blood"] = true,
  ["BloodFrozen"] = true,
  ["BloodSilver"] = true,
  ["BloodExploding"] = true,
  ["SurfaceBloodragemist"] = true,

  -- Fog/Darkness clouds
  ["FogCloud"] = true,
  ["DarknessCloud"] = true,

  -- Ectoplasm
  ["SurfaceEctoplasm"] = true,

  -- Other hazardous surfaces
  ["Poison"] = true,
  ["Oil"] = true,
  ["Grease"] = true,
  ["Alcohol"] = true,
  ["Mud"] = true,
  ["Vines"] = true,
  ["ShadowCursedVines"] = true,
  ["SpikeGrowth"] = true,
}

-- Surface template IDs (BG3 template GUIDs for common surfaces)
local SURFACE_TEMPLATE_IDS = {
  ["Fire"] = "5c3e4a0c-4c7e-4c9a-8c0e-4c7e4c9a8c0e",
  ["Water"] = "6d4e5b1d-5d8f-4d0a-9d1e-5d8f4d0a9d1e",
  ["WaterElectrified"] = "7e5f6c2e-6e9a-4e1b-ae2f-6e9a4e1bae2f",
  ["WaterFrozen"] = "8f6a7d3f-7f0b-4f2c-bf3a-7f0b4f2cbf3a",
  ["Lava"] = "9a7b8e4a-8a1c-4a3d-ca4b-8a1c4a3dca4b",
  ["Acid"] = "ab8c9f5b-9b2d-4b4e-db5c-9b2d4b4edb5c",
  ["Web"] = "bc9d0a6c-ac3e-4c5f-ec6d-ac3e4c5fec6d",
  ["Blood"] = "cd0e1b7d-bd4f-4d6a-fd7e-bd4f4d6afd7e",
  ["FogCloud"] = "de1f2c8e-ce5a-4e7b-0e8f-ce5a4e7b0e8f",
  ["DarknessCloud"] = "ef2a3d9f-df6b-4f8c-1f9a-df6b4f8c1f9a",
  ["Poison"] = "fa3b4e0a-ea7c-4a9d-2a0b-ea7c4a9d2a0b",
  ["Oil"] = "0b4c5f1b-fb8d-4b0e-3b1c-fb8d4b0e3b1c",
  ["Grease"] = "1c5d6a2c-0c9e-4c1f-4c2d-0c9e4c1f4c2d",
}

-- Track detected surfaces during combat
local detectedSurfaces = {}

-- Explosive/Interactive Object Identifiers (BG3 Template Names)
local EXPLOSIVE_OBJECTS = {
  -- Smokepowder
  ["SMOKEPOWDER_BARREL"] = true,
  ["SMOKEPOWDER_SATCHEL"] = true,
  ["SMOKEPOWDER_POUCH"] = true,
  ["SMOKEPOWDER_BOMB"] = true,
  ["SMOKEPOWDER_GRENADE"] = true,
  ["SMOKEPOWDER_CHARGE"] = true,
  ["Explosive_Barrel_Smokepowder"] = true,
  ["WYR_SMOKING Barrel"] = true,

  -- Firewine
  ["FIREWINE_BARREL"] = true,
  ["Explosive_Barrel_Firewine"] = true,

  -- Oil
  ["OIL_BARREL"] = true,
  ["Oil_Barrel"] = true,

  -- Greek Fire
  ["GREEKFIRE_BARREL"] = true,
  ["GreekFire_Barrel"] = true,

  -- Water barrels (for electrical combos)
  ["WATER_BARREL"] = true,
  ["Water_Barrel"] = true,

  -- Void Bulbs
  ["VOID_BULB"] = true,

  -- Runepowder
  ["RUNEPOWDER_BARREL"] = true,
  ["RUNEPOWDER_VIAL"] = true,
  ["RUNEPOWDER_BOMB"] = true,
  ["RUNEPOWDER_CHARGE"] = true,
  ["Runepowder Barrel"] = true,

  -- Nautiloid tanks
  ["NAUTILOID_TANK"] = true,
  ["NautiloidTank"] = true,
  ["TANK_NAUTILOID"] = true,

  -- Mines
  ["PROXIMITY_MINE"] = true,
  ["EXPLOSIVE_MINE"] = true,

  -- Alchemical fire
  ["ALCHEMICAL_FIRE"] = true,
  ["ALCHEMISTS_FIRE"] = true,
  ["Bottle_AlchemicalFire"] = true,

  -- Arrows (explosive)
  ["ARROW_OF_FIRE"] = true,
  ["ARROW_OF_EXPLODING"] = true,
  ["ARROW_OF_LIGHTNING"] = true,
  ["ARROW_OF_ICE"] = true,

  -- Throwing potions/grenades
  ["Grenade_Fireball"] = true,
  ["Grenade_Acid"] = true,
  ["Grenade_Poison"] = true,
  ["Grenade_Thunder"] = true,
  ["Grenade_Force"] = true,
  ["Grenade_Flash"] = true,
  ["Grenade_Smoke"] = true,
}

-- Interactive Object Types
local INTERACTIVE_OBJECTS = {
  -- Containers
  ["BARREL"] = true,
  ["CRATE"] = true,
  ["CHEST"] = true,
  ["BAG"] = true,

  -- Doors
  ["DOOR"] = true,
  ["WOODEN_DOOR"] = true,
  ["IRON_DOOR"] = true,
  ["GATE"] = true,

  -- Environmental
  ["CHAIR"] = true,
  ["TABLE"] = true,
  ["LADDER"] = true,
  ["LEVER"] = true,
  ["BUTTON"] = true,
  ["PRESSURE_PLATE"] = true,

  -- Destructible
  ["WOODEN_PLANKS"] = true,
  ["WOODEN_BEAM"] = true,
  ["STONE_PILLAR"] = true,
  ["CHANDELIER"] = true,
}

-- Track detected obstacles during combat
local detectedObstacles = {}

local function nowIso()
  local ok, t = pcall(function()
    return Ext.Utils.MonotonicTime()
  end)
  if ok and type(t) == "number" then
    return tostring(t)
  end
  return ""
end

local function nowMsNumber()
  local ok, t = pcall(function()
    return Ext.Utils.MonotonicTime()
  end)
  if ok and type(t) == "number" then
    return t
  end
  return 0
end

local function isConcentrationStatus(status)
  status = safeStr(status)
  local up = status:upper()
  return up:find("CONCENTR") ~= nil
end

local function safeStr(v)
  if v == nil then return "" end
  return tostring(v)
end

local function extractGuidFromStoryId(storyId)
  if not storyId or storyId == "" then return "" end
  local guid = storyId:match("([0-9a-fA-F%-]+)$")
  return guid or ""
end

local function isInCombat(uuid)
  local ok, res = pcall(Osi.IsInCombat, uuid)
  return ok and res == 1
end

local function isTurnBasedFor(uuid)
  local ok, res = pcall(Osi.IsInForceTurnBasedMode, uuid)
  if ok and res ~= nil then
    return res == 1
  end
  return isInCombat(uuid)
end

local function sanitizeForFilename(s)
  s = safeStr(s)
  s = s:gsub("[^%w%-%_]", "_")
  return s
end

local function beginCombat(combatGuid)
  local ts = 0
  local ok, t = pcall(function()
    return Ext.Utils.MonotonicTime()
  end)
  if ok and type(t) == "number" then
    ts = math.floor(t)
  else
    ts = math.floor(math.random() * 1000000000)
  end
  local cg = sanitizeForFilename(combatGuid ~= nil and combatGuid or "unknown")
  current = {
    schemaVersion = 16,
    generatedAt = nowIso(),
    combatGuid = safeStr(combatGuid),
    file = string.format("%s/combat_%s_%d.json", LOG_DIR, cg, ts),
    events = {},
    eventCount = 0,
  }
  pendingFlush = true
end

local function ensureSession(combatGuidMaybe)
  if current == nil then
    beginCombat(combatGuidMaybe)
  end
end

local function scheduleFlush()
  if pendingFlush then return end
  pendingFlush = true

  Ext.Timer.WaitFor(250, function()
    if not current then
      pendingFlush = false
      return
    end

    local ok, err = pcall(function()
      local json = Ext.Json.Stringify({
        schemaVersion = current.schemaVersion,
        generatedAt = current.generatedAt,
        combatGuid = current.combatGuid,
        eventCount = current.eventCount,
        events = current.events,
      })
      Ext.IO.SaveFile(current.file, json, "user")
    end)

    if not ok then
      Ext.Utils.PrintError(MOD_PREFIX, "Flush failed:", err)
    end

    pendingFlush = false
  end)
end

local GLOBAL_STATE_EVENTS = {
  ["SurfaceState"] = true,
  ["ObstacleState"] = true,
  ["ExplosiveState"] = true,
  ["GlobeState"] = true,
  ["ExplosionDetonated"] = true,
  ["ExplosionDamage"] = true,
}

local function addEvent(kind, caster, target, spell, spellType, spellElement, storyActionID, extra)
  -- Global state events don't need a caster
  if not GLOBAL_STATE_EVENTS[kind] then
    if not caster or caster == "" then return end
    if not isInCombat(caster) then return end
  end

  ensureSession(nil)

  local ev = {
    time = nowIso(),
    kind = safeStr(kind),
    caster = safeStr(caster),
    casterGuid = extractGuidFromStoryId(caster),
    target = safeStr(target),
    targetGuid = extractGuidFromStoryId(target),
    spell = safeStr(spell),
    spellType = safeStr(spellType),
    spellElement = safeStr(spellElement),
    storyActionID = safeStr(storyActionID),
    extra = (type(extra) == "table") and extra or safeStr(extra),
  }

  current.eventCount = current.eventCount + 1
  current.events[#current.events + 1] = ev

  if current.eventCount % FLUSH_AT_EVENTS == 0 then
    scheduleFlush()
  else
    pendingFlush = true
    scheduleFlush()
  end
end

local function flushNow()
  if not current then return end
  local ok, err = pcall(function()
    local json = Ext.Json.Stringify({
      schemaVersion = current.schemaVersion,
      generatedAt = current.generatedAt,
      combatGuid = current.combatGuid,
      eventCount = current.eventCount,
      events = current.events,
    })
    Ext.IO.SaveFile(current.file, json, "user")
  end)
  if not ok then
    Ext.Utils.PrintError(MOD_PREFIX, "Flush failed:", err)
  end
end

local function endCombat()
  flushNow()
  current = nil
  pendingFlush = false
  combatantSpells = {}
  combatantSpellSlots = {}
  combatantActions = {}
  combatantClasses = {}
  combatantPassives = {}
  combatantAbilities = {}
  combatantCurrentStatuses = {}
  combatantResistances = {}
  activeGlobes = {}
  trackedExplosiveHP = {}
  detectedSurfaces = {}
end

-- Surface Detection Functions

local function isTrackedSurface(surfaceType)
  return TRACKED_SURFACES[surfaceType] == true
end

local function getSurfacePosition(surfaceId)
  local ok, x, y, z = pcall(function()
    return Osi.GetPosition(surfaceId)
  end)
  if ok and x and y and z then
    return {x = x, y = y, z = z}
  end
  return nil
end

local function calculateDistanceToSurface(characterPos, surfacePos)
  if not characterPos or not surfacePos then return nil end

  local dx = surfacePos.x - characterPos.x
  local dy = surfacePos.y - characterPos.y
  local dz = surfacePos.z - characterPos.z

  local horizontalDist = math.sqrt(dx*dx + dy*dy)
  local verticalDist = dz
  local totalDist = math.sqrt(dx*dx + dy*dy + dz*dz)

  return {
    horizontal = horizontalDist,
    vertical = verticalDist,
    total = totalDist,
  }
end

local function isCharacterOnSurface(characterPos, surfacePos, surfaceRadius)
  if not characterPos or not surfacePos then return false end
  surfaceRadius = surfaceRadius or 1.0

  local dx = surfacePos.x - characterPos.x
  local dy = surfacePos.y - characterPos.y
  local dist = math.sqrt(dx*dx + dy*dy)

  return dist <= surfaceRadius
end

local function detectSurfacesInArea(centerX, centerY, centerZ, radius)
  local surfaces = {}

  -- Use Osiris query to get surfaces in the area
  local ok, result = pcall(function()
    return Osi.GetSurfacesInArea(centerX, centerY, centerZ, radius)
  end)

  if ok and result then
    for _, surface in ipairs(result) do
      local surfaceType = surface.Type or ""
      if isTrackedSurface(surfaceType) then
        local pos = getSurfacePosition(surface.Id)
        if pos then
          table.insert(surfaces, {
            id = surface.Id,
            type = surfaceType,
            position = pos,
            radius = surface.Radius or 1.0,
            storyId = surface.StoryId or "",
          })
        end
      end
    end
  end

  return surfaces
end

local function logSurfaceState(phase)
  if current == nil then return end

  local combatants = getCombatantsInCombat()
  if #combatants == 0 then return end

  -- Get center position from first combatant (or average of all)
  local centerX, centerY, centerZ = 0, 0, 0
  local count = 0
  for _, combatant in ipairs(combatants) do
    local ok, x, y, z = pcall(function()
      return Osi.GetPosition(combatant)
    end)
    if ok and x and y and z then
      centerX = centerX + x
      centerY = centerY + y
      centerZ = centerZ + z
      count = count + 1
    end
  end

  if count > 0 then
    centerX = centerX / count
    centerY = centerY / count
    centerZ = centerZ / count
  end

  -- Detect surfaces in the combat area (large radius to cover arena)
  local surfaces = detectSurfacesInArea(centerX, centerY, centerZ, 50.0)

  -- For each combatant, calculate distance to each surface
  local combatantSurfaceData = {}
  for _, combatant in ipairs(combatants) do
    local charPos = nil
    local ok, x, y, z = pcall(function()
      return Osi.GetPosition(combatant)
    end)
    if ok and x and y and z then
      charPos = {x = x, y = y, z = z}
    end

    local surfaceDistances = {}
    local insideSurfaces = {}

    for _, surface in ipairs(surfaces) do
      local dist = calculateDistanceToSurface(charPos, surface.position)
      local isInside = isCharacterOnSurface(charPos, surface.position, surface.radius)

      table.insert(surfaceDistances, {
        surfaceId = surface.id,
        surfaceType = surface.type,
        distance = dist and dist.total or nil,
        horizontalDistance = dist and dist.horizontal or nil,
        heightDifference = dist and dist.vertical or nil,
        isInside = isInside,
        surfaceRadius = surface.radius,
      })

      if isInside then
        table.insert(insideSurfaces, surface.type)
      end
    end

    table.insert(combatantSurfaceData, {
      combatant = combatant,
      position = charPos,
      surfaceDistances = surfaceDistances,
      insideSurfaces = insideSurfaces,
    })
  end

  addEvent("SurfaceState", "", "", "", "", "", "", {
    phase = phase,
    surfaces = surfaces,
    combatantSurfaceData = combatantSurfaceData,
  })
end

-- Obstacle Detection Functions

local function isExplosiveObject(templateName)
  if not templateName then return false end
  local upperName = string.upper(templateName)
  for key, _ in pairs(EXPLOSIVE_OBJECTS) do
    if string.upper(key) == upperName then
      return true
    end
  end
  return false
end

local function isInteractiveObject(templateName)
  if not templateName then return false end
  local upperName = string.upper(templateName)
  for key, _ in pairs(INTERACTIVE_OBJECTS) do
    if string.upper(key) == upperName then
      return true
    end
  end
  return false
end

local function getObjectType(entityId)
  local ok, objectType = pcall(function()
    return Osi.GetEntityType(entityId)
  end)
  return ok and objectType or ""
end

local function getObjectTemplateName(entityId)
  local ok, templateName = pcall(function()
    return Osi.GetTemplate(entityId)
  end)
  return ok and templateName or ""
end

local function getObjectPosition(entityId)
  local ok, x, y, z = pcall(function()
    return Osi.GetPosition(entityId)
  end)
  if ok and x and y and z then
    return {x = x, y = y, z = z}
  end
  return nil
end

local function getObjectHP(entityId)
  local ok, hp = pcall(function()
    return Osi.GetHitPoints(entityId)
  end)
  local ok2, maxHp = pcall(function()
    return Osi.GetMaxHitPoints(entityId)
  end)
  return {
    current = ok and hp or 0,
    max = ok2 and maxHp or 0,
  }
end

local function getObjectDamageType(entityId)
  local ok, templateName = pcall(function()
    return Osi.GetTemplate(entityId)
  end)
  if not ok or not templateName then return "" end

  local upperName = string.upper(templateName)
  if string.find(upperName, "SMOKEPOWDER") or string.find(upperName, "FIRE") or string.find(upperName, "GREEK") then
    return "Fire"
  elseif string.find(upperName, "OIL") then
    return "Fire"
  elseif string.find(upperName, "WATER") then
    return "Lightning"
  elseif string.find(upperName, "ACID") then
    return "Acid"
  elseif string.find(upperName, "POISON") then
    return "Poison"
  end
  return ""
end

local function calculateDistanceToObject(characterPos, objectPos)
  if not characterPos or not objectPos then return nil end

  local dx = objectPos.x - characterPos.x
  local dy = objectPos.y - characterPos.y
  local dz = objectPos.z - characterPos.z

  local horizontalDist = math.sqrt(dx*dx + dy*dy)
  local verticalDist = dz
  local totalDist = math.sqrt(dx*dx + dy*dy + dz*dz)

  return {
    horizontal = horizontalDist,
    vertical = verticalDist,
    total = totalDist,
  }
end

local function detectObstaclesInArea(centerX, centerY, centerZ, radius)
  local obstacles = {}

  -- Use Osiris query to get objects in the area
  local ok, result = pcall(function()
    return Osi.GetObjectsInArea(centerX, centerY, centerZ, radius)
  end)

  if ok and result then
    for _, entityId in ipairs(result) do
      local templateName = getObjectTemplateName(entityId)
      local objectType = getObjectType(entityId)

      -- Check if this is an obstacle we care about
      local isExplosive = isExplosiveObject(templateName)
      local isInteractive = isInteractiveObject(templateName)
      local isWall = string.lower(objectType) == "wall" or string.find(string.lower(templateName), "wall") ~= nil
      local isDoor = string.find(string.lower(templateName), "door") ~= nil or string.find(string.lower(templateName), "gate") ~= nil

      if isExplosive or isInteractive or isWall or isDoor then
        local pos = getObjectPosition(entityId)
        local hp = getObjectHP(entityId)
        local damageType = getObjectDamageType(entityId)

        table.insert(obstacles, {
          id = entityId,
          templateName = templateName,
          objectType = objectType,
          position = pos,
          hp = hp,
          damageType = damageType,
          isExplosive = isExplosive,
          isInteractive = isInteractive,
          isWall = isWall,
          isDoor = isDoor,
        })
      end
    end
  end

  return obstacles
end

local function logObstacleState(phase)
  if current == nil then return end

  local combatants = getCombatantsInCombat()
  if #combatants == 0 then return end

  -- Get center position from average of all combatants
  local centerX, centerY, centerZ = 0, 0, 0
  local count = 0
  for _, combatant in ipairs(combatants) do
    local ok, x, y, z = pcall(function()
      return Osi.GetPosition(combatant)
    end)
    if ok and x and y and z then
      centerX = centerX + x
      centerY = centerY + y
      centerZ = centerZ + z
      count = count + 1
    end
  end

  if count > 0 then
    centerX = centerX / count
    centerY = centerY / count
    centerZ = centerZ / count
  end

  -- Detect obstacles in the combat area
  local obstacles = detectObstaclesInArea(centerX, centerY, centerZ, 50.0)

  -- For each combatant, calculate distance to each obstacle
  local combatantObstacleData = {}
  for _, combatant in ipairs(combatants) do
    local charPos = nil
    local ok, x, y, z = pcall(function()
      return Osi.GetPosition(combatant)
    end)
    if ok and x and y and z then
      charPos = {x = x, y = y, z = z}
    end

    local obstacleDistances = {}
    for _, obstacle in ipairs(obstacles) do
      local dist = calculateDistanceToObject(charPos, obstacle.position)

      table.insert(obstacleDistances, {
        obstacleId = obstacle.id,
        templateName = obstacle.templateName,
        objectType = obstacle.objectType,
        distance = dist and dist.total or nil,
        horizontalDistance = dist and dist.horizontal or nil,
        heightDifference = dist and dist.vertical or nil,
        isExplosive = obstacle.isExplosive,
        isInteractive = obstacle.isInteractive,
        isWall = obstacle.isWall,
        isDoor = obstacle.isDoor,
        hp = obstacle.hp,
        damageType = obstacle.damageType,
      })
    end

    table.insert(combatantObstacleData, {
      combatant = combatant,
      position = charPos,
      obstacleDistances = obstacleDistances,
    })
  end

  -- Categorize obstacles for summary
  local explosiveObstacles = {}
  local interactiveObstacles = {}
  local wallObstacles = {}
  local doorObstacles = {}

  for _, obstacle in ipairs(obstacles) do
    if obstacle.isExplosive then
      table.insert(explosiveObstacles, {
        id = obstacle.id,
        templateName = obstacle.templateName,
        position = obstacle.position,
        hp = obstacle.hp,
        damageType = obstacle.damageType,
      })
    elseif obstacle.isWall then
      table.insert(wallObstacles, {
        id = obstacle.id,
        templateName = obstacle.templateName,
        position = obstacle.position,
      })
    elseif obstacle.isDoor then
      table.insert(doorObstacles, {
        id = obstacle.id,
        templateName = obstacle.templateName,
        position = obstacle.position,
        hp = obstacle.hp,
      })
    elseif obstacle.isInteractive then
      table.insert(interactiveObstacles, {
        id = obstacle.id,
        templateName = obstacle.templateName,
        position = obstacle.position,
        hp = obstacle.hp,
      })
    end
  end

  addEvent("ObstacleState", "", "", "", "", "", "", {
    phase = phase,
    obstacles = obstacles,
    explosiveObstacles = explosiveObstacles,
    interactiveObstacles = interactiveObstacles,
    wallObstacles = wallObstacles,
    doorObstacles = doorObstacles,
    combatantObstacleData = combatantObstacleData,
  })
end

-- Explosion Tracking

local trackedExplosiveHP = {}

local function logExplosiveState(phase)
  if current == nil then return end
  local combatants = getCombatantsInCombat()
  if #combatants == 0 then return end

  local centerX, centerY, centerZ = 0, 0, 0
  local count = 0
  for _, combatant in ipairs(combatants) do
    local ok, x, y, z = pcall(function()
      return Osi.GetPosition(combatant)
    end)
    if ok and x and y and z then
      centerX = centerX + x
      centerY = centerY + y
      centerZ = centerZ + z
      count = count + 1
    end
  end
  if count > 0 then
    centerX = centerX / count
    centerY = centerY / count
    centerZ = centerZ / count
  end

  local obstacles = detectObstaclesInArea(centerX, centerY, centerZ, 50.0)
  local explosives = {}
  for _, obs in ipairs(obstacles) do
    if obs.isExplosive then
      -- Track HP for next-tick explosion detection
      trackedExplosiveHP[obs.id] = obs.hp.current
      table.insert(explosives, obs)
    end
  end

  if #explosives == 0 then return end

  -- For each combatant, calculate distance to each explosive
  local combatantExplosiveData = {}
  for _, combatant in ipairs(combatants) do
    local okPos, cx, cy, cz = pcall(function()
      return Osi.GetPosition(combatant)
    end)
    if not okPos or not cx then
      table.insert(combatantExplosiveData, {
        combatant = combatant,
        position = nil,
        explosiveDistances = {},
      })
    else
      local explosiveDistances = {}
      for _, explosive in ipairs(explosives) do
        if explosive.position then
          local dx = cx - explosive.position.x
          local dy = cy - explosive.position.y
          local dz = cz - explosive.position.z
          table.insert(explosiveDistances, {
            explosiveId = explosive.id,
            templateName = explosive.templateName,
            distance = math.sqrt(dx*dx + dy*dy + dz*dz),
            horizontalDistance = math.sqrt(dx*dx + dy*dy),
            heightDifference = dz,
            hp = explosive.hp,
          })
        end
      end

      table.insert(combatantExplosiveData, {
        combatant = combatant,
        position = {x = cx, y = cy, z = cz},
        explosiveDistances = explosiveDistances,
      })
    end
  end

  addEvent("ExplosiveState", "", "", "", "", "", "", {
    phase = phase,
    explosives = explosives,
    combatantExplosiveData = combatantExplosiveData,
  })
end

local function detectExplosion(objectUuid)
  if current == nil then return end
  local combatants = getCombatantsInCombat()
  if #combatants == 0 then return end

  local ok, templateName = pcall(function()
    return Osi.GetTemplate(objectUuid)
  end)
  if not ok or not templateName then return end
  if not isExplosiveObject(templateName) then return end

  local ox, oy, oz
  local okPos, x, y, z = pcall(function()
    return Osi.GetPosition(objectUuid)
  end)
  if okPos and x and y and z then
    ox, oy, oz = x, y, z
  end

  -- Determine cause: check which combatant is nearest or was last attacking
  local causeChar = ""
  local minDist = 999999
  for _, combatant in ipairs(combatants) do
    local okC, cx, cy, cz = pcall(function()
      return Osi.GetPosition(combatant)
    end)
    if okC and cx and cy and cz and ox then
      local dx = cx - ox
      local dy = cy - oy
      local dz = cz - oz
      local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
      if dist < minDist then
        minDist = dist
        causeChar = combatant
      end
    end
  end

  -- Log the explosion event
  addEvent("ExplosionDetonated", causeChar, "", "", "", "", "", {
    explosiveObject = objectUuid,
    templateName = templateName,
    position = ox and {x = ox, y = oy, z = oz} or nil,
    blastRadius = 12,
  })

  -- After a short delay, check which combatants took damage from the explosion
  local checkDelay = 300
  Ext.Timer.WaitFor(checkDelay, function()
    if current == nil then return end
    local damagedCombatants = {}
    for _, combatant in ipairs(combatants) do
      if ox then
        local okC, cx, cy, cz = pcall(function()
          return Osi.GetPosition(combatant)
        end)
        if okC and cx and cy and cz then
          local dx = cx - ox
          local dy = cy - oy
          local dz = cz - oz
          local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
          if dist <= 15 then
            table.insert(damagedCombatants, {
              combatant = combatant,
              distance = dist,
            })
          end
        end
      end
    end
    if #damagedCombatants > 0 then
      addEvent("ExplosionDamage", causeChar, "", "", "", "", "", {
        explosiveObject = objectUuid,
        templateName = templateName,
        position = ox and {x = ox, y = oy, z = oz} or nil,
        damagedCombatants = damagedCombatants,
      })
    end
  end)
end

-- Line of Sight Functions

local function hasLineOfSight(source, target)
  local ok, result = pcall(function()
    return Osi.HasLineOfSight(source, target)
  end)
  return ok and result == 1
end

local function isVisibleFor(source, target)
  local ok, result = pcall(function()
    return Osi.IsVisibleFor(source, target)
  end)
  return ok and result == 1
end

local function getVisibilityState(character, target)
  local los = hasLineOfSight(character, target)
  local visible = isVisibleFor(character, target)

  return {
    hasLineOfSight = los,
    isVisible = visible,
    canSeeTarget = los and visible,
  }
end

local function logLineOfSight(phase)
  if current == nil then return end

  local combatants = getCombatantsInCombat()
  if #combatants < 2 then return end

  local lineOfSightData = {}

  -- Check LoS for each pair of combatants
  for i = 1, #combatants do
    local char1 = combatants[i]
    local char1Data = {
      combatant = char1,
      canSee = {},
      hiddenFrom = {},
      mutualLoS = {},
    }

    for j = 1, #combatants do
      if i ~= j then
        local char2 = combatants[j]
        local visibility = getVisibilityState(char1, char2)

        -- Store what char1 sees of char2
        table.insert(char1Data.canSee, {
          target = char2,
          hasLineOfSight = visibility.hasLineOfSight,
          isVisible = visibility.isVisible,
          canSeeTarget = visibility.canSeeTarget,
        })

        -- Check if char2 can see char1 (for hidden tracking)
        local reverseVisibility = getVisibilityState(char2, char1)
        if not reverseVisibility.canSeeTarget then
          table.insert(char1Data.hiddenFrom, {
            target = char2,
            isHiddenFrom = true,
          })
        end

        -- Store mutual LoS info
        if visibility.hasLineOfSight and reverseVisibility.hasLineOfSight then
          table.insert(char1Data.mutualLoS, {
            target = char2,
            mutualLoS = true,
          })
        end
      end
    end

    table.insert(lineOfSightData, char1Data)
  end

  -- Check LoS to surfaces
  local centerX, centerY, centerZ = 0, 0, 0
  local count = 0
  for _, combatant in ipairs(combatants) do
    local ok, x, y, z = pcall(function()
      return Osi.GetPosition(combatant)
    end)
    if ok and x and y and z then
      centerX = centerX + x
      centerY = centerY + y
      centerZ = centerZ + z
      count = count + 1
    end
  end

  if count > 0 then
    centerX = centerX / count
    centerY = centerY / count
    centerZ = centerZ / count
  end

  local surfaces = detectSurfacesInArea(centerX, centerY, centerZ, 50.0)

  -- Add surface visibility data for each combatant
  for i, combatantData in ipairs(lineOfSightData) do
    local combatant = combatants[i]
    combatantData.surfaceVisibility = {}

    for _, surface in ipairs(surfaces) do
      -- Check if combatant has line of sight to surface center
      local surfaceEntityId = surface.id
      local ok, hasLOS = pcall(function()
        return Osi.HasLineOfSight(combatant, surfaceEntityId)
      end)

      table.insert(combatantData.surfaceVisibility, {
        surfaceId = surface.id,
        surfaceType = surface.type,
        hasLineOfSight = ok and hasLOS == 1,
      })
    end
  end

  addEvent("LineOfSight", "", "", "", "", "", "", {
    phase = phase,
    lineOfSightData = lineOfSightData,
  })
end

local function safeRegisterListener(eventName, arity, timing, fn)
  local ok, err = pcall(function()
    Ext.Osiris.RegisterListener(eventName, arity, timing, fn)
  end)
  if not ok then
    Ext.Utils.PrintError(MOD_PREFIX, ("Failed to register %s/%d (%s): %s")
      :format(eventName, arity, timing, tostring(err)))
  end
  return ok
end

local function registerFirst(eventName, variants)
  for _, v in ipairs(variants) do
    local arity, timing, fn = v[1], v[2], v[3]
    if safeRegisterListener(eventName, arity, timing, fn) then
      return true
    end
  end
  return false
end

-- Spell Analysis Functions

local function getSpellCastingType(stats)
  if not stats then return "Unknown" end

  -- Safely check SpellFlags
  local okFlags, flags = pcall(function() return stats.SpellFlags end)
  if okFlags and flags then
    for _, flag in pairs(flags) do
      if flag == "IsBonusAction" then
        return "BonusAction"
      elseif flag == "IsAction" then
        return "Action"
      elseif flag == "IsReaction" then
        return "Reaction"
      end
    end
  end

  -- Safely check SpellActionType
  local okActionType, actionType = pcall(function() return stats.SpellActionType end)
  if okActionType and actionType then
    local actionTypeLower = string.lower(actionType)
    if string.find(actionTypeLower, "bonus") then
      return "BonusAction"
    elseif string.find(actionTypeLower, "action") then
      return "Action"
    elseif string.find(actionTypeLower, "reaction") then
      return "Reaction"
    end
  end

  -- Safely check SpellType
  local okSpellType, spellType = pcall(function() return stats.SpellType end)
  if okSpellType and spellType then
    local spellTypeLower = string.lower(spellType)
    if string.find(spellTypeLower, "bonus") then
      return "BonusAction"
    end
  end

  return "Action"
end

local function getSpellResourceType(stats)
  if not stats then return "SpellSlot" end

  local okLevel, level = pcall(function() return stats.Level end)
  if okLevel and level and level > 0 then
    return "SpellSlot"
  end

  -- Safely check for SpellCostID property
  local hasSpellCostID, spellCostID = pcall(function()
    return stats.SpellCostID
  end)

  if hasSpellCostID and spellCostID and spellCostID ~= "" then
    local ok, cost = pcall(function()
      return Ext.Stats.Get(spellCostID)
    end)
    if ok and cost then
      local hasGlyph, glyph = pcall(function()
        return cost.ActionResourceGlyph
      end)
      if hasGlyph and glyph then
        if string.find(string.lower(glyph), "bonus") then
          return "BonusAction"
        elseif string.find(string.lower(glyph), "action") then
          return "Action"
        end
      end
    end
  end

  local okLevel2, level2 = pcall(function() return stats.Level end)
  if okLevel2 and level2 and level2 > 0 then
    return "SpellSlot"
  else
    return "Action"
  end
end

local function isAbilitySpellCasting(spellId)
  local stats = Ext.Stats.Get(spellId)
  if not stats then return false end

  -- Safely check SpellFlags
  local okFlags, flags = pcall(function() return stats.SpellFlags end)
  if okFlags and flags then
    for _, flag in pairs(flags) do
      if flag == "IsSpell" or flag == "IsConcentration" or flag == "HasSpellResult" then
        return true
      end
    end
  end

  return false
end

local function analyzeSpell(spellId)
  if not spellId or spellId == "" then return nil end

  -- Check cache first
  if spellAnalysisCache[spellId] then
    return spellAnalysisCache[spellId]
  end

  local stats = Ext.Stats.Get(spellId)
  if not stats then return nil end

  -- Helper to safely get stats property
  local function safeGet(prop, default)
    local ok, val = pcall(function() return stats[prop] end)
    return ok and val ~= nil and val or default
  end

  local analysis = {
    id = spellId,
    name = safeGet("DisplayName", spellId),
    description = safeGet("Description", ""),
    spellType = safeGet("SpellType", ""),
    spellSchool = safeGet("SpellSchool", ""),
    level = safeGet("Level", 0),
    castingType = getSpellCastingType(stats),
    resourceType = getSpellResourceType(stats),
    isSpellCasting = isAbilitySpellCasting(spellId),

    -- Range and targeting
    range = safeGet("Range", 0),
    targetRadius = safeGet("TargetRadius", 0),
    targetType = safeGet("TargetType", ""),
    areaOfEffect = safeGet("AreaRadius", 0),
    aoeType = safeGet("AoEType", ""),

    -- Damage information
    damage = {},
    damageType = safeGet("DamageType", ""),
    damageVersatile = safeGet("VersatileDamage", false),

    -- Healing
    healAmount = safeGet("HealValue", 0),
    healType = safeGet("HealType", ""),

    -- Status effects applied
    statuses = {},
    statusesApplyToTargets = safeGet("StatusApplyToTargets", false),

    -- Saving throw
    saveDC = safeGet("SaveDC", ""),
    saveType = safeGet("AbilitySaveType", ""),

    -- Concentration
    concentration = false,
    concentrationDuration = safeGet("ConcentrationDuration", 0),

    -- Duration
    duration = safeGet("Duration", 0),
    durationType = safeGet("DurationType", ""),

    -- Stats modifiers
    statsBoosts = {},

    -- Flags
    flags = {},
    tags = {},

    -- Casting requirements
    requiresLineOfSight = safeGet("RequireLineOfSight", false),
    requiresVision = safeGet("RequireVision", false),

    -- Attack type
    attackType = safeGet("AttackType", ""),
    attackRoll = safeGet("AttackRoll", false),

    -- Projectiles
    projectileCount = safeGet("ProjectileCount", 1),
    projectileType = safeGet("ProjectileType", ""),
  }

  -- Extract damage data (safely)
  local okDamage, damageData = pcall(function() return stats.Damage end)
  if okDamage and damageData then
    for _, dmg in ipairs(damageData) do
      table.insert(analysis.damage, {
        type = dmg.Type or "",
        dice = dmg.Dice or "",
        amount = dmg.Amount or 0,
      })
    end
  end

  -- Extract status effects (safely)
  local okStatuses, statusData = pcall(function() return stats.Statuses end)
  if okStatuses and statusData then
    for _, status in ipairs(statusData) do
      table.insert(analysis.statuses, {
        id = status.StatusId or "",
        duration = status.Duration or 0,
        chance = status.Chance or 100,
        saveDC = status.SaveDC or "",
      })
    end
  end

  -- Extract stat boosts (safely)
  local okBoosts, boostData = pcall(function() return stats.StatsBoosts end)
  if okBoosts and boostData then
    for _, boost in ipairs(boostData) do
      table.insert(analysis.statsBoosts, {
        stat = boost.Stat or "",
        value = boost.Value or 0,
        type = boost.Type or "",
      })
    end
  end

  -- Extract flags (safely)
  local okFlags, flagData = pcall(function() return stats.SpellFlags end)
  if okFlags and flagData then
    for _, flag in ipairs(flagData) do
      table.insert(analysis.flags, flag)
      if flag == "IsConcentration" then
        analysis.concentration = true
      end
    end
  end

  -- Extract tags (safely)
  local okTags, tagData = pcall(function() return stats.Tags end)
  if okTags and tagData then
    for _, tag in ipairs(tagData) do
      table.insert(analysis.tags, tag)
    end
  end

  -- Generate semantic tags based on analysis
  local semanticTags = {}
  if analysis.level == 0 then
    table.insert(semanticTags, "cantrip")
  end
  if analysis.damage and #analysis.damage > 0 then
    table.insert(semanticTags, "damage")
    for _, dmg in ipairs(analysis.damage) do
      if dmg.type ~= "" then
        table.insert(semanticTags, "damage_" .. string.lower(dmg.type))
      end
    end
  end
  if analysis.healAmount > 0 then
    table.insert(semanticTags, "healing")
  end
  if analysis.areaOfEffect > 0 then
    table.insert(semanticTags, "aoe")
  end
  if analysis.concentration then
    table.insert(semanticTags, "concentration")
  end
  if analysis.range > 0 then
    table.insert(semanticTags, "ranged")
  else
    table.insert(semanticTags, "melee")
  end
  if analysis.targetType == "Self" then
    table.insert(semanticTags, "self_target")
  end
  if analysis.saveType ~= "" then
    table.insert(semanticTags, "save_" .. string.lower(analysis.saveType))
  end
  if analysis.castingType == "BonusAction" then
    table.insert(semanticTags, "bonus_action")
  elseif analysis.castingType == "Reaction" then
    table.insert(semanticTags, "reaction")
  end
  if #analysis.statuses > 0 then
    table.insert(semanticTags, "applies_status")
    for _, status in ipairs(analysis.statuses) do
      if status.id ~= "" then
        table.insert(semanticTags, "status_" .. string.lower(status.id))
      end
    end
  end
  analysis.semanticTags = semanticTags

  -- Cache the analysis
  spellAnalysisCache[spellId] = analysis

  return analysis
end

local function noteCast(caster, target, spell, storyActionID)
  local t = nowMsNumber()
  lastCastByCaster[caster] = {
    time = t,
    spell = safeStr(spell),
    target = safeStr(target),
    storyActionID = safeStr(storyActionID),
  }

  -- Get spell analysis for this cast
  local spellAnalysis = analyzeSpell(spell)

  -- Track resource usage when a spell/ability is cast
  if current and caster and caster ~= "" then
    local stats = Ext.Stats.Get(spell)
    if stats then
      local castingType = getSpellCastingType(stats)
      local resourceType = getSpellResourceType(stats)
      local okLevel, spellLevel = pcall(function() return stats.Level end)
      spellLevel = okLevel and spellLevel or 0

      -- Track action/bonus action usage
      if castingType == "Action" or castingType == "BonusAction" then
        if not combatantActions[caster] then
          combatantActions[caster] = { action = 0, bonusAction = 0 }
        end

        if castingType == "Action" then
          combatantActions[caster].action = combatantActions[caster].action + 1
          addEvent("ActionUsed", caster, "", spell, "", "", storyActionID, {
            actionType = "Action",
            totalUsed = combatantActions[caster].action,
            spellAnalysis = spellAnalysis,
          })
        elseif castingType == "BonusAction" then
          combatantActions[caster].bonusAction = combatantActions[caster].bonusAction + 1
          addEvent("ActionUsed", caster, "", spell, "", "", storyActionID, {
            actionType = "BonusAction",
            totalUsed = combatantActions[caster].bonusAction,
            spellAnalysis = spellAnalysis,
          })
        end
      end

      -- Track spell slot usage for leveled spells
      if resourceType == "SpellSlot" and spellLevel > 0 then
        local slots = combatantSpellSlots[caster]
        if slots and slots[spellLevel] and slots[spellLevel] > 0 then
          slots[spellLevel] = slots[spellLevel] - 1
          addEvent("SpellSlotUsed", caster, "", spell, "", "", storyActionID, {
            spellLevel = spellLevel,
            remaining = slots[spellLevel],
            spellAnalysis = spellAnalysis,
          })
        end
      end
    end
  end

  -- Log the cast with full spell analysis
  addEvent("SpellCast", caster, target, spell, "", "", storyActionID, {
    spellAnalysis = spellAnalysis,
  })

  -- Track a pending outcome for on-target spells
  if storyActionID and storyActionID ~= "" and target and target ~= "" then
    pendingSpellResults[storyActionID] = {
      caster = caster,
      target = target,
      spell = safeStr(spell),
      time = t,
      resolved = false,
    }

    Ext.Timer.WaitFor(1500, function()
      local p = pendingSpellResults[storyActionID]
      if p and not p.resolved then
        addEvent("SpellResult", p.caster, p.target, p.spell, "", "", storyActionID, {
          result = "unknown_or_failed",
          reason = "no_status_applied_within_window",
          windowMs = 1500,
        })
        pendingSpellResults[storyActionID] = nil
      end
    end)
  end
end

local function getCharacterSpells(characterGuid)
  local spells = {}
  local ok, result = pcall(function()
    return Ext.Stats.GetCharacterSpells(characterGuid)
  end)
  if ok and result then
    for _, spell in ipairs(result) do
      local spellStats = Ext.Stats.Get(spell.Id)
      local castingType = getSpellCastingType(spellStats)
      local resourceType = getSpellResourceType(spellStats)
      local analysis = analyzeSpell(spell.Id)

      local spellData = {
        id = spell.Id or "",
        name = spell.Name or "",
        spellType = spell.SpellType or "",
        spellSchool = spell.SpellSchool or "",
        level = spell.Level or 0,
        prepared = spell.Prepared or false,
        known = spell.Known or false,
        canCast = spell.CanCast or false,
        castingType = castingType,
        resourceType = resourceType,
        isSpellCasting = isAbilitySpellCasting(spell.Id),
        analysis = analysis,
      }
      table.insert(spells, spellData)
    end
  end
  return spells
end

local function getCharacterClasses(characterGuid)
  local classes = {}
  local ok, result = pcall(function()
    return Ext.Stats.GetCharacterClasses(characterGuid)
  end)
  if ok and result then
    for _, class in ipairs(result) do
      local classData = {
        name = class.Name or "",
        subclass = class.Subclass or "",
        level = class.Level or 1,
        spellcastingAbility = class.SpellcastingAbility or "",
        spellSaveDC = class.SpellSaveDC or 0,
        spellAttackBonus = class.SpellAttackBonus or 0,
      }
      table.insert(classes, classData)
    end
  end
  return classes
end

local function getCharacterPassives(characterGuid)
  local passives = {}
  local ok, result = pcall(function()
    return Ext.Stats.GetCharacterPassives(characterGuid)
  end)
  if ok and result then
    for _, passive in ipairs(result) do
      local passiveData = {
        id = passive.Id or "",
        name = passive.Name or "",
        description = passive.Description or "",
        enabled = passive.Enabled or false,
        isToggle = passive.IsToggle or false,
        isActive = passive.IsActive or false,
        cooldown = passive.Cooldown or 0,
        cooldownType = passive.CooldownType or "",
      }
      table.insert(passives, passiveData)
    end
  end
  return passives
end

local function getCharacterAbilities(characterGuid)
  local abilities = {}
  local ok, result = pcall(function()
    return Ext.Stats.GetCharacterAbilities(characterGuid)
  end)
  if ok and result then
    for _, ability in ipairs(result) do
      local abilityData = {
        id = ability.Id or "",
        name = ability.Name or "",
        description = ability.Description or "",
        type = ability.Type or "",
        actionCost = ability.ActionCost or 0,
        bonusActionCost = ability.BonusActionCost or 0,
        reactionCost = ability.ReactionCost or 0,
        spellSlotCost = ability.SpellSlotCost or 0,
        cooldown = ability.Cooldown or 0,
        cooldownType = ability.CooldownType or "",
        range = ability.Range or 0,
        areaOfEffect = ability.AreaOfEffect or 0,
        requiresConcentration = ability.RequiresConcentration or false,
      }
      table.insert(abilities, abilityData)
    end
  end
  return abilities
end

local function getCharacterResistances(characterGuid)
  local resistances = {}
  if not characterGuid or characterGuid == "" then return resistances end

  local ok, stats = pcall(function()
    return Ext.Stats.Get(characterGuid)
  end)
  if not ok or not stats then return resistances end

  -- Helper to parse resistance list (string or table)
  local function parseResistanceList(value)
    local list = {}
    if type(value) == "string" then
      for _, dt in ipairs(DAMAGE_TYPES) do
        if string.find(string.lower(value), string.lower(dt), 1, true) then
          table.insert(list, dt)
        end
      end
    elseif type(value) == "table" then
      for _, item in ipairs(value) do
        table.insert(list, item)
      end
    end
    return list
  end

  -- Check innate Resistance
  local okRes, resVal = pcall(function() return stats.Resistance end)
  if okRes and resVal then
    for _, dt in ipairs(parseResistanceList(resVal)) do
      if not resistances[dt] then
        resistances[dt] = "Resistance"
      end
    end
  end

  -- Check innate Immunity
  local okImm, immVal = pcall(function() return stats.ImmuneToDamage end)
  if okImm and immVal then
    for _, dt in ipairs(parseResistanceList(immVal)) do
      resistances[dt] = "Immunity"
    end
  end

  -- Check innate Vulnerability
  local okVul, vulVal = pcall(function() return stats.VulnerableToDamage end)
  if okVul and vulVal then
    for _, dt in ipairs(parseResistanceList(vulVal)) do
      resistances[dt] = "Vulnerability"
    end
  end

  return resistances
end

local function getCharacterCurrentStatuses(characterGuid)
  local statuses = {}
  local ok, result = pcall(function()
    return Ext.Stats.GetCharacterStatuses(characterGuid)
  end)
  if ok and result then
    for _, status in ipairs(result) do
      local statusData = {
        id = status.Id or "",
        name = status.Name or "",
        description = status.Description or "",
        statusType = status.StatusType or "",
        duration = status.Duration or 0,
        remainingDuration = status.RemainingDuration or 0,
        source = status.Source or "",
        stackCount = status.StackCount or 1,
        isDebuff = status.IsDebuff or false,
        isBuff = status.IsBuff or false,
        canSave = status.CanSave or false,
        saveType = status.SaveType or "",
        saveDC = status.SaveDC or 0,
      }
      table.insert(statuses, statusData)
    end
  end
  return statuses
end

local function getCharacterSpellSlots(characterGuid)
  local slots = {}
  local ok, result = pcall(function()
    return Ext.Stats.GetCharacterSpellSlots(characterGuid)
  end)
  if ok and result then
    for level = 1, 9 do
      if result[level] then
        slots[level] = {
          max = result[level].Max or 0,
          remaining = result[level].Current or 0,
        }
      else
        slots[level] = { max = 0, remaining = 0 }
      end
    end
  end
  return slots
end

local function captureCombatantState(characterGuid)
  if not characterGuid or characterGuid == "" then return end
  if not isInCombat(characterGuid) then return end

  local spells = getCharacterSpells(characterGuid)
  local spellSlots = getCharacterSpellSlots(characterGuid)
  local classes = getCharacterClasses(characterGuid)
  local passives = getCharacterPassives(characterGuid)
  local abilities = getCharacterAbilities(characterGuid)
  local currentStatuses = getCharacterCurrentStatuses(characterGuid)
  local resistances = getCharacterResistances(characterGuid)

  combatantSpells[characterGuid] = spells
  combatantSpellSlots[characterGuid] = {}
  combatantClasses[characterGuid] = classes
  combatantPassives[characterGuid] = passives
  combatantAbilities[characterGuid] = abilities
  combatantCurrentStatuses[characterGuid] = currentStatuses
  combatantResistances[characterGuid] = resistances

  for level = 1, 9 do
    if spellSlots[level] then
      combatantSpellSlots[characterGuid][level] = spellSlots[level].remaining
    else
      combatantSpellSlots[characterGuid][level] = 0
    end
  end

  combatantActions[characterGuid] = { action = 0, bonusAction = 0 }

  -- Log classes
  if #classes > 0 then
    addEvent("CombatantClasses", characterGuid, "", "", "", "", "", {
      classes = classes,
    })
  end

  -- Log passives
  if #passives > 0 then
    addEvent("CombatantPassives", characterGuid, "", "", "", "", "", {
      passives = passives,
    })
  end

  -- Log abilities
  if #abilities > 0 then
    addEvent("CombatantAbilities", characterGuid, "", "", "", "", "", {
      abilities = abilities,
    })
  end

  -- Log current statuses
  if #currentStatuses > 0 then
    addEvent("CombatantCurrentStatuses", characterGuid, "", "", "", "", "", {
      statuses = currentStatuses,
    })
  end

  -- Log resistances
  if next(resistances) then
    addEvent("CombatantResistances", characterGuid, "", "", "", "", "", {
      resistances = resistances,
    })
  end

  -- Log prepared spells with full analysis
  local preparedSpells = {}
  for _, spell in ipairs(spells) do
    if spell.prepared or spell.known then
      table.insert(preparedSpells, {
        id = spell.id,
        name = spell.name,
        spellType = spell.spellType,
        spellSchool = spell.spellSchool,
        level = spell.level,
        castingType = spell.castingType,
        resourceType = spell.resourceType,
        isSpellCasting = spell.isSpellCasting,
        analysis = spell.analysis,
      })
    end
  end

  if #preparedSpells > 0 then
    addEvent("CombatantSpellsPrepared", characterGuid, "", "", "", "", "", {
      spells = preparedSpells,
    })
  end

  addEvent("CombatantSpellSlots", characterGuid, "", "", "", "", "", {
    slots = spellSlots,
  })

  addEvent("CombatantActionsAvailable", characterGuid, "", "", "", "", "", {
    action = { max = 1, remaining = 1 },
    bonusAction = { max = 1, remaining = 1 },
  })
end

-- Globe of Invulnerability Tracking

local function normalizeGlobeGuid(value)
  return string.lower(tostring(value)):match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)")
end

local function isGlobeTemplate(rootTemplate)
  return normalizeGlobeGuid(rootTemplate) == GLOBE_TEMPLATE
end

local function getBlockerDirection(rootTemplate)
  local normalized = normalizeGlobeGuid(rootTemplate)
  return BLOCKER_TEMPLATES[normalized]
end

local function getObjectPosition(objectUuid)
  local ok, x, y, z = pcall(Osi.GetPosition, objectUuid)
  if ok and x and y and z then
    return x, y, z
  end
  return nil, nil, nil
end

local function registerGlobe(globeUuid)
  local key = normalizeGlobeGuid(globeUuid)
  if not key or key == "" then return end
  if activeGlobes[key] then return end

  local x, y, z = getObjectPosition(globeUuid)
  activeGlobes[key] = {
    uuid = tostring(globeUuid),
    direction = "Center",
    x = x,
    y = y,
    z = z,
    blockerCount = 0,
  }
end

local function registerGlobeBlocker(blockerUuid, direction)
  local x, y, z = getObjectPosition(blockerUuid)
  if not x then return end

  -- Try to match to nearest active globe center
  local nearestKey = nil
  local nearestDist = 36
  for key, globe in pairs(activeGlobes) do
    if globe.x and globe.y and globe.z then
      local dx = x - globe.x
      local dy = y - globe.y
      local dz = z - globe.z
      local distSq = dx*dx + dy*dy + dz*dz
      if distSq <= nearestDist then
        nearestDist = distSq
        nearestKey = key
      end
    end
  end

  if nearestKey then
    local globe = activeGlobes[nearestKey]
    globe.blockerCount = globe.blockerCount + 1
    if not globe.blockers then globe.blockers = {} end
    table.insert(globe.blockers, {
      uuid = tostring(blockerUuid),
      direction = direction,
      x = x,
      y = y,
      z = z,
    })
  end
end

local function unregisterGlobeObject(objectUuid)
  local key = normalizeGlobeGuid(objectUuid)
  if not key or key == "" then return end

  -- Check if it's a globe center
  if activeGlobes[key] then
    activeGlobes[key] = nil
    return
  end

  -- Check if it's a blocker in any globe
  for gKey, globe in pairs(activeGlobes) do
    if globe.blockers then
      for i = #globe.blockers, 1, -1 do
        if normalizeGlobeGuid(globe.blockers[i].uuid) == key then
          table.remove(globe.blockers, i)
          globe.blockerCount = globe.blockerCount - 1
          return
        end
      end
    end
  end
end

local function logGlobeState(phase)
  if current == nil then return end
  local combatants = getCombatantsInCombat()
  if #combatants == 0 then return end

  local hasGlobes = false
  for _, globe in pairs(activeGlobes) do
    if globe.x then hasGlobes = true; break end
  end
  if not hasGlobes then return end

  -- For each combatant, calculate distance to each globe center and blocker
  local globeData = {}
  for gKey, globe in pairs(activeGlobes) do
    if globe.x then
      local combatantDistances = {}
      for _, combatant in ipairs(combatants) do
        local cx, cy, cz = getObjectPosition(combatant)
        if cx then
          local dx = cx - globe.x
          local dy = cy - globe.y
          local dz = cz - globe.z
          local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
          local horiz = math.sqrt(dx*dx + dy*dy)
          local entry = {
            combatant = combatant,
            distanceToCenter = dist,
            horizontalDistance = horiz,
            heightDifference = dz,
          }

          -- Add blocker distances
          local blockerDists = {}
          if globe.blockers then
            for _, blocker in ipairs(globe.blockers) do
              if blocker.x then
                local bx = cx - blocker.x
                local by = cy - blocker.y
                local bz = cz - blocker.z
                table.insert(blockerDists, {
                  direction = blocker.direction,
                  distance = math.sqrt(bx*bx + by*by + bz*bz),
                  horizontalDistance = math.sqrt(bx*bx + by*by),
                  heightDifference = bz,
                })
              end
            end
          end
          entry.blockerDistances = blockerDists

          table.insert(combatantDistances, entry)
        end
      end

      table.insert(globeData, {
        globeUuid = globe.uuid,
        position = {x = globe.x, y = globe.y, z = globe.z},
        blockerCount = globe.blockerCount,
        blockers = globe.blockers,
        combatantDistances = combatantDistances,
      })
    end
  end

  if #globeData > 0 then
    addEvent("GlobeState", "", "", "", "", "", "", {
      phase = phase,
      globes = globeData,
    })
  end
end

local function setup()

  local function registerStatusListener(eventNames, variants)
    for _, name in ipairs(eventNames) do
      if registerFirst(name, variants) then
        return true, name
      end
    end
    return false, ""
  end

  safeRegisterListener("UsingSpellOnTarget", 6, "after", function(caster, target, spell, spellType, spellElement, storyActionID)
    addEvent("UsingSpellOnTarget", caster, target, spell, spellType, spellElement, storyActionID, "")
    noteCast(caster, target, spell, storyActionID)
  end)

  safeRegisterListener("CastSpell", 5, "after", function(caster, spell, spellType, spellElement, storyActionID)
    addEvent("CastSpell", caster, "", spell, spellType, spellElement, storyActionID, "no_target_event")
    noteCast(caster, "", spell, storyActionID)
  end)

  registerStatusListener({"CharacterStatusApplied","StatusApplied","ApplyStatus"}, {
    {3, "after", function(character, status, causee)
      local src = safeStr(causee)
      local caster = (src ~= "") and src or safeStr(character)
      addEvent("StatusApplied", caster, character, "", "", "", "", {
        status = safeStr(status),
        source = src,
      })

      if isConcentrationStatus(status) then
        local last = lastCastByCaster[character]
        concentrationByCaster[character] = {
          status = safeStr(status),
          spell = last and last.spell or "",
          storyActionID = last and last.storyActionID or "",
          time = nowMsNumber(),
        }
        addEvent("ConcentrationStarted", character, "", concentrationByCaster[character].spell, "", "", concentrationByCaster[character].storyActionID, {
          status = safeStr(status),
        })
      end

      if src ~= "" then
        local now = nowMsNumber()
        for storyId, p in pairs(pendingSpellResults) do
          if p and not p.resolved and p.caster == src and p.target == character and (now - (p.time or 0)) <= 1500 then
            p.resolved = true
            addEvent("SpellResult", p.caster, p.target, p.spell, "", "", storyId, {
              result = "success_status",
              status = safeStr(status),
            })
            pendingSpellResults[storyId] = nil
            break
          end
        end
      end
    end},
    {4, "after", function(character, status, causee, _applyStoryAction)
      local src = safeStr(causee)
      local caster = (src ~= "") and src or safeStr(character)
      addEvent("StatusApplied", caster, character, "", "", "", "", {
        status = safeStr(status),
        source = src,
      })
      if isConcentrationStatus(status) then
        local last = lastCastByCaster[character]
        concentrationByCaster[character] = {
          status = safeStr(status),
          spell = last and last.spell or "",
          storyActionID = last and last.storyActionID or "",
          time = nowMsNumber(),
        }
        addEvent("ConcentrationStarted", character, "", concentrationByCaster[character].spell, "", "", concentrationByCaster[character].storyActionID, {
          status = safeStr(status),
        })
      end
    end},
    {5, "after", function(character, status, causee, _applyStoryAction, _unused)
      local src = safeStr(causee)
      local caster = (src ~= "") and src or safeStr(character)
      addEvent("StatusApplied", caster, character, "", "", "", "", {
        status = safeStr(status),
        source = src,
      })
      if isConcentrationStatus(status) then
        local last = lastCastByCaster[character]
        concentrationByCaster[character] = {
          status = safeStr(status),
          spell = last and last.spell or "",
          storyActionID = last and last.storyActionID or "",
          time = nowMsNumber(),
        }
        addEvent("ConcentrationStarted", character, "", concentrationByCaster[character].spell, "", "", concentrationByCaster[character].storyActionID, {
          status = safeStr(status),
        })
      end
    end},
    {6, "after", function(character, status, causee, _applyStoryAction, _unused, _unused2)
      local src = safeStr(causee)
      local caster = (src ~= "") and src or safeStr(character)
      addEvent("StatusApplied", caster, character, "", "", "", "", {
        status = safeStr(status),
        source = src,
      })
      if isConcentrationStatus(status) then
        local last = lastCastByCaster[character]
        concentrationByCaster[character] = {
          status = safeStr(status),
          spell = last and last.spell or "",
          storyActionID = last and last.storyActionID or "",
          time = nowMsNumber(),
        }
        addEvent("ConcentrationStarted", character, "", concentrationByCaster[character].spell, "", "", concentrationByCaster[character].storyActionID, {
          status = safeStr(status),
        })
      end
    end},
  })

  registerStatusListener({"CharacterStatusRemoved","StatusRemoved","RemoveStatus"}, {
    {3, "after", function(character, status, causee)
      local src = safeStr(causee)
      local caster = (src ~= "") and src or safeStr(character)
      addEvent("StatusRemoved", caster, character, "", "", "", "", {
        status = safeStr(status),
        source = src,
      })

      if isConcentrationStatus(status) then
        local c = concentrationByCaster[character]
        if c then
          addEvent("ConcentrationEnded", character, "", c.spell or "", "", "", c.storyActionID or "", {
            status = safeStr(status),
            ended = "status_removed",
          })
          concentrationByCaster[character] = nil
        end
      end
    end},
    {4, "after", function(character, status, causee, _applyStoryAction)
      local src = safeStr(causee)
      local caster = (src ~= "") and src or safeStr(character)
      addEvent("StatusRemoved", caster, character, "", "", "", "", {
        status = safeStr(status),
        source = src,
      })
      if isConcentrationStatus(status) then
        local c = concentrationByCaster[character]
        if c then
          addEvent("ConcentrationEnded", character, "", c.spell or "", "", "", c.storyActionID or "", {
            status = safeStr(status),
            ended = "status_removed",
          })
          concentrationByCaster[character] = nil
        end
      end
    end},
    {5, "after", function(character, status, causee, _applyStoryAction, _unused)
      local src = safeStr(causee)
      local caster = (src ~= "") and src or safeStr(character)
      addEvent("StatusRemoved", caster, character, "", "", "", "", {
        status = safeStr(status),
        source = src,
      })
      if isConcentrationStatus(status) then
        local c = concentrationByCaster[character]
        if c then
          addEvent("ConcentrationEnded", character, "", c.spell or "", "", "", c.storyActionID or "", {
            status = safeStr(status),
            ended = "status_removed",
          })
          concentrationByCaster[character] = nil
        end
      end
    end},
    {6, "after", function(character, status, causee, _applyStoryAction, _unused, _unused2)
      local src = safeStr(causee)
      local caster = (src ~= "") and src or safeStr(character)
      addEvent("StatusRemoved", caster, character, "", "", "", "", {
        status = safeStr(status),
        source = src,
      })
      if isConcentrationStatus(status) then
        local c = concentrationByCaster[character]
        if c then
          addEvent("ConcentrationEnded", character, "", c.spell or "", "", "", c.storyActionID or "", {
            status = safeStr(status),
            ended = "status_removed",
          })
          concentrationByCaster[character] = nil
        end
      end
    end},
  })

  safeRegisterListener("CombatStarted", 1, "after", function(combatGuid)
    if current ~= nil then
      endCombat()
    end
    beginCombat(combatGuid)
  end)

  safeRegisterListener("CombatEnded", 1, "after", function(_combatGuid)
    endCombat()
  end)

  safeRegisterListener("TurnStarted", 2, "after", function(char)
    if current == nil then return end
    captureCombatantState(char)
    logSurfaceState("turn_start")
    logLineOfSight("turn_start")
    logObstacleState("turn_start")
    logExplosiveState("turn_start")
    logGlobeState("turn_start")
  end)

  safeRegisterListener("enteredcombat", 2, "after", function(char, combatGuid)
    if current == nil then return end
    captureCombatantState(char)
  end)

  -- Globe of Invulnerability detection
  safeRegisterListener("EnteredLevel", 3, "after", function(object, rootTemplate, _)
    if current == nil then return end
    if isGlobeTemplate(rootTemplate) then
      registerGlobe(object)
      return
    end
    local direction = getBlockerDirection(rootTemplate)
    if direction then
      registerGlobeBlocker(object, direction)
    end
  end)

  safeRegisterListener("StatusApplied", 4, "after", function(object, status, _, _)
    if current == nil then return end
    if status == GLOBE_VISUAL_STATUS then
      registerGlobe(object)
    elseif status == BLOCKER_STATUS then
      registerGlobeBlocker(object, "status")
    end
  end)

  safeRegisterListener("StatusRemoved", 4, "after", function(object, status, _, _)
    if current == nil then return end
    if status == GLOBE_VISUAL_STATUS or status == BLOCKER_STATUS then
      unregisterGlobeObject(object)
    end
  end)

  -- Explosion detection: track when objects are destroyed
  safeRegisterListener("ObjectDestroyed", 1, "after", function(object)
    if current == nil then return end
    detectExplosion(object)
  end)

  safeRegisterListener("UsingAction", 2, "after", function(char, actionId)
    if current == nil then return end
    if not isInCombat(char) then return end

    if not combatantActions[char] then
      combatantActions[char] = { action = 0, bonusAction = 0 }
    end

    local actionType = "Action"
    local actionLower = string.lower(actionId)
    if string.find(actionLower, "bonus") then
      actionType = "BonusAction"
      combatantActions[char].bonusAction = combatantActions[char].bonusAction + 1
    else
      combatantActions[char].action = combatantActions[char].action + 1
    end

    addEvent("ActionUsed", char, "", actionId, "", "", "", {
      actionType = actionType,
      totalUsed = actionType == "Action" and combatantActions[char].action or combatantActions[char].bonusAction,
      isSpellCasting = false,
    })
  end)

  Ext.Utils.Print(MOD_PREFIX, "Loaded. Writing JSON logs to user-domain folder:", LOG_DIR)
end

Ext.Events.SessionLoaded:Subscribe(function()
  setup()
end)

Ext.Events.GameStateChanged:Subscribe(function(e)
  if e.FromState == "Running" and e.ToState ~= "Running" then
    flushNow()
  end
end)


Ext.Osiris.RegisterListener("StatusApplied", 5, "after", function(target, statusId, source, statusHandle, causeType)
  if current == nil then return end
  if statusId and string.find(string.lower(statusId), "concentration") then
    table.insert(current.events, {
      kind = "ConcentrationStarted",
      caster = source,
      target = target,
      status = statusId,
      timeMs = Ext.Utils.MonotonicTime()
    })
  end
end)

Ext.Osiris.RegisterListener("StatusRemoved", 5, "after", function(target, statusId, source, statusHandle, causeType)
  if current == nil then return end
  if statusId and string.find(string.lower(statusId), "concentration") then
    table.insert(current.events, {
      kind = "ConcentrationEnded",
      caster = source,
      target = target,
      status = statusId,
      timeMs = Ext.Utils.MonotonicTime()
    })
  end
end)

local startPosByChar = {}

local function getCombatantsInCombat()
  local combatants = {}
  if current == nil then return combatants end

  local combatGuid = current.combatGuid
  if combatGuid == "" then return combatants end

  local ok, result = pcall(function()
    return Osi.GetCombatantsInCombat(combatGuid)
  end)

  if ok and result then
    for _, combatant in ipairs(result) do
      table.insert(combatants, combatant)
    end
  end

  return combatants
end

local function calculateDistanceBetween(char1, char2)
  local x1, y1, z1 = Osi.GetPosition(char1)
  local x2, y2, z2 = Osi.GetPosition(char2)

  local dx = x2 - x1
  local dy = y2 - y1
  local dz = z2 - z1

  local horizontalDist = math.sqrt(dx*dx + dy*dy)
  local verticalDist = dz
  local totalDist = math.sqrt(dx*dx + dy*dy + dz*dz)

  return {
    horizontal = horizontalDist,
    vertical = verticalDist,
    total = totalDist,
    pos1 = {x = x1, y = y1, z = z1},
    pos2 = {x = x2, y = y2, z = z2},
  }
end

local function logCombatantDistances(phase)
  if current == nil then return end

  local combatants = getCombatantsInCombat()
  if #combatants < 2 then return end

  local distances = {}

  for i = 1, #combatants do
    for j = i + 1, #combatants do
      local char1 = combatants[i]
      local char2 = combatants[j]

      local distData = calculateDistanceBetween(char1, char2)

      table.insert(distances, {
        char1 = char1,
        char2 = char2,
        horizontalDistance = distData.horizontal,
        heightDifference = distData.vertical,
        totalDistance = distData.total,
        pos1 = distData.pos1,
        pos2 = distData.pos2,
      })
    end
  end

  addEvent("CombatantDistances", "", "", "", "", "", "", {
    phase = phase,
    distances = distances,
  })
end

Ext.Osiris.RegisterListener("TurnStarted", 2, "after", function(char)
  if current == nil then return end
  local x, y, z = Osi.GetPosition(char)
  startPosByChar[char] = {x = x, y = y, z = z}

  logCombatantDistances("turn_start")
  logSurfaceState("turn_start")
  logLineOfSight("turn_start")
  logObstacleState("turn_start")
end)

Ext.Osiris.RegisterListener("TurnEnded", 2, "after", function(char)
  if current == nil then return end
  local sx, sy, sz = 0, 0, 0
  local sp = startPosByChar[char]
  if sp then sx, sy, sz = sp.x, sp.y, sp.z end
  local ex, ey, ez = Osi.GetPosition(char)
  local dx = ex - sx
  local dy = ey - sy
  local dz = ez - sz
  local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
  if dist > 0.5 then
    table.insert(current.events, {
      kind = "Movement",
      character = char,
      startPos = {sx, sy, sz},
      endPos = {ex, ey, ez},
      distance = dist,
      timeMs = Ext.Utils.MonotonicTime()
    })
  end

  logCombatantDistances("turn_end")
  logSurfaceState("turn_end")
  logLineOfSight("turn_end")
  logObstacleState("turn_end")
end)

Ext.Osiris.RegisterListener("TemplateUseFinished", 4, "after", function(char, template, item, result)
  if current == nil then return end
  table.insert(current.events, {
    kind = "ItemUsed",
    user = char,
    item = template,
    result = result,
    timeMs = Ext.Utils.MonotonicTime()
  })
end)


Ext.Osiris.RegisterListener("UsingSpell", 6, "after", function(caster, spellId, element, spellType, _, storyActionID)
  if current == nil then return end
  local stats = Ext.Stats.Get(spellId)
  if stats then
    local okFlags, flags = pcall(function() return stats.SpellFlags end)
    if okFlags and flags then
      for _, flag in pairs(flags) do
        if flag == "IsConcentration" then
          concentrationByCaster[caster] = {
            spell = spellId,
            storyActionID = storyActionID,
            timeMs = Ext.Utils.MonotonicTime()
          }
          table.insert(current.events, {
            kind = "ConcentrationStarted",
            caster = caster,
            spell = spellId,
            timeMs = Ext.Utils.MonotonicTime()
          })
          break
        end
      end
    end
  end
end)

Ext.Osiris.RegisterListener("StatusRemoved", 5, "after", function(target, statusId, source, statusHandle, causeType)
  if current == nil then return end
  local record = concentrationByCaster[source]
  if record then
    concentrationByCaster[source] = nil
    table.insert(current.events, {
      kind = "ConcentrationEnded",
      caster = source,
      status = statusId,
      spell = record.spell,
      timeMs = Ext.Utils.MonotonicTime()
    })
  end
end)


local concentrationSpellAllowlist = {
  Shout_LuringSong_Harpy = true
}

Ext.Osiris.RegisterListener("UsingSpell", 6, "after", function(caster, spellId, element, spellType, _, storyActionID)
  if current == nil then return end
  local isConcentration = false
  local stats = Ext.Stats.Get(spellId)
  if stats then
    local okFlags, flags = pcall(function() return stats.SpellFlags end)
    if okFlags and flags then
      for _, flag in pairs(flags) do
        if flag == "IsConcentration" then
          isConcentration = true
          break
        end
      end
    end
  end
  if concentrationSpellAllowlist[spellId] then
    isConcentration = true
  end
  if isConcentration then
    concentrationByCaster[caster] = {
      spell = spellId,
      storyActionID = storyActionID,
      timeMs = Ext.Utils.MonotonicTime()
    }
    table.insert(current.events, {
      kind = "ConcentrationStarted",
      caster = caster,
      spell = spellId,
      timeMs = Ext.Utils.MonotonicTime()
    })
  end
end)


local concentrationByCaster = {}

Ext.Osiris.RegisterListener("StatusApplied", 5, "after", function(target, statusId, source, statusHandle, causeType)
  if current == nil then return end
  local record = concentrationByCaster[target]
  if record and record.status == nil and statusId ~= nil then
    record.status = statusId
    concentrationByCaster[target] = record
  end
end)

Ext.Osiris.RegisterListener("StatusRemoved", 5, "after", function(target, statusId, source, statusHandle, causeType)
  if current == nil then return end
  local record = concentrationByCaster[target]
  if record and record.status == statusId then
    concentrationByCaster[target] = nil
    table.insert(current.events, {
      kind = "ConcentrationEnded",
      caster = target,
      status = statusId,
      spell = record.spell,
      timeMs = Ext.Utils.MonotonicTime()
    })
  end
end)

-- Surface Event Listeners

-- Track when surfaces are created
Ext.Osiris.RegisterListener("SurfaceGroundAction", 4, "after", function(actionType, surfaceType, position, radius)
  if current == nil then return end
  if isTrackedSurface(surfaceType) then
    table.insert(current.events, {
      kind = "SurfaceCreated",
      surfaceType = surfaceType,
      actionType = actionType,
      position = position,
      radius = radius,
      timeMs = Ext.Utils.MonotonicTime()
    })
  end
end)

-- Track when characters enter surfaces
Ext.Osiris.RegisterListener("SurfaceGroundEnter", 2, "after", function(character, surfaceId)
  if current == nil then return end
  if not isInCombat(character) then return end

  -- Get surface info
  local ok, surfaceType = pcall(function()
    return Osi.GetSurfaceType(surfaceId)
  end)

  if ok and surfaceType and isTrackedSurface(surfaceType) then
    local surfacePos = getSurfacePosition(surfaceId)
    local charPos = nil
    local ok2, x, y, z = pcall(function()
      return Osi.GetPosition(character)
    end)
    if ok2 and x and y and z then
      charPos = {x = x, y = y, z = z}
    end

    table.insert(current.events, {
      kind = "SurfaceEnter",
      character = character,
      surfaceType = surfaceType,
      surfaceId = surfaceId,
      characterPosition = charPos,
      surfacePosition = surfacePos,
      timeMs = Ext.Utils.MonotonicTime()
    })
  end
end)

-- Track when characters leave surfaces
Ext.Osiris.RegisterListener("SurfaceGroundLeave", 2, "after", function(character, surfaceId)
  if current == nil then return end
  if not isInCombat(character) then return end

  -- Get surface info
  local ok, surfaceType = pcall(function()
    return Osi.GetSurfaceType(surfaceId)
  end)

  if ok and surfaceType and isTrackedSurface(surfaceType) then
    local surfacePos = getSurfacePosition(surfaceId)
    local charPos = nil
    local ok2, x, y, z = pcall(function()
      return Osi.GetPosition(character)
    end)
    if ok2 and x and y and z then
      charPos = {x = x, y = y, z = z}
    end

    table.insert(current.events, {
      kind = "SurfaceLeave",
      character = character,
      surfaceType = surfaceType,
      surfaceId = surfaceId,
      characterPosition = charPos,
      surfacePosition = surfacePos,
      timeMs = Ext.Utils.MonotonicTime()
    })
  end
end)

-- Track surface damage
Ext.Osiris.RegisterListener("SurfaceGroundDamaged", 3, "after", function(character, surfaceType, damage)
  if current == nil then return end
  if not isInCombat(character) then return end

  if isTrackedSurface(surfaceType) then
    table.insert(current.events, {
      kind = "SurfaceDamaged",
      character = character,
      surfaceType = surfaceType,
      damage = damage,
      timeMs = Ext.Utils.MonotonicTime()
    })
  end
end)