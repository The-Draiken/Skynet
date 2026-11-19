-- Skynet BootstrapServer.lua
-- Kept minimal + very loud prints. Following patterns from Total AI Control (simple require),
-- EnemyActionAI / CombatExtenderAI / SmarterAI (prints + Osiris inside SessionLoaded).

local function skynet_print(msg)
    print("[Skynet] " .. tostring(msg))
    if Ext and Ext.Utils and Ext.Utils.Print then
        Ext.Utils.Print("[Skynet] " .. tostring(msg))
    end
end

local function skynet_error(msg)
    print("[Skynet] ERROR: " .. tostring(msg))
    if Ext and Ext.Utils and Ext.Utils.PrintError then
        Ext.Utils.PrintError("[Skynet] ERROR: " .. tostring(msg))
    end
end

if not _G.Skynet_BootstrapRan then
    _G.Skynet_BootstrapRan = true
    skynet_print("BootstrapServer.lua executing (first line)")

    -- Load the gates first (concentration / already-affected checks). Skynet.lua guards every call into it,
    -- so if this fails Skynet simply behaves as it did before.
    local okG, errG = pcall(function()
        Ext.Require("Server/SkynetGates.lua")
    end)

    if not okG then
        skynet_error("pcall Ext.Require('Server/SkynetGates.lua') FAILED: " .. tostring(errG))
    else
        skynet_print("Ext.Require('Server/SkynetGates.lua') succeeded")
    end

    -- Turn trace (MCM toggle): loaded before Skynet.lua so its TurnStarted listener runs before Skynet's own.
    local okT, errT = pcall(function()
        Ext.Require("Server/SkynetTrace.lua")
    end)
    if not okT then
        skynet_error("pcall Ext.Require('Server/SkynetTrace.lua') FAILED: " .. tostring(errT))
    end

    -- Load Skynet AI logic
    local ok, err = pcall(function()
        Ext.Require("Server/Skynet.lua")
    end)

    if not ok then
        skynet_error("pcall Ext.Require('Server/Skynet.lua') FAILED: " .. tostring(err))
    else
        skynet_print("Ext.Require('Server/Skynet.lua') succeeded")
    end

    -- Load Logging (JSON combat logs)
    local ok2, err2 = pcall(function()
        Ext.Require("Server/Logging.lua")
    end)

    if not ok2 then
        skynet_error("pcall Ext.Require('Server/Logging.lua') FAILED: " .. tostring(err2))
    else
        skynet_print("Ext.Require('Server/Logging.lua') succeeded")
    end

    -- Load Skynet Auto Save (its own file and settings tab; does nothing until enabled in MCM, except
    -- the optional "unsafe moment to save" warnings)
    local okA, errA = pcall(function()
        Ext.Require("Server/SkynetAutoSave.lua")
    end)

    if not okA then
        skynet_error("pcall Ext.Require('Server/SkynetAutoSave.lua') FAILED: " .. tostring(errA))
    else
        skynet_print("Ext.Require('Server/SkynetAutoSave.lua') succeeded")
    end

    -- Load Skynet movement diagnostics (logs only; does nothing unless "Movement diagnostics" is on in MCM)
    local okD, errD = pcall(function()
        Ext.Require("Server/SkynetMoveDiag.lua")
    end)

    if not okD then
        skynet_error("pcall Ext.Require('Server/SkynetMoveDiag.lua') FAILED: " .. tostring(errD))
    else
        skynet_print("Ext.Require('Server/SkynetMoveDiag.lua') succeeded")
    end

    -- Load CX High Level Spell Slots (independent L7/L8/L9 bonus slot grant,
    -- doesn't touch or depend on Combat Extender's own Lua)
    local ok3, err3 = pcall(function()
        Ext.Require("Server/CXHighLevelSlots.lua")
    end)

    if not ok3 then
        skynet_error("pcall Ext.Require('Server/CXHighLevelSlots.lua') FAILED: " .. tostring(err3))
    else
        skynet_print("Ext.Require('Server/CXHighLevelSlots.lua') succeeded")
    end

    skynet_print("BootstrapServer.lua finished (end of file)")
end

-- Extra safety net SessionLoaded print + ensure listeners (match Logging mod pattern)
Ext.Events.SessionLoaded:Subscribe(function()
    skynet_print("SessionLoaded from bootstrap")
    if _G.Skynet_RegisterAllOsirisListeners then
        pcall(_G.Skynet_RegisterAllOsirisListeners)
    end
end)