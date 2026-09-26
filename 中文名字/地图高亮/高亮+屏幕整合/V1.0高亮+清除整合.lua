--地图高亮+屏幕清除 v1.0
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerGui = nil

local DEBOUNCE_TIME = 0.5
local lastUpdateTime = 0
local updatePending = false

local SOFT_CONFIG = {
    Brightness = 0.9,
    GlobalShadows = true,
    Ambient = Color3.fromRGB(140, 140, 140),
    ColorShift_Top = Color3.fromRGB(235, 225, 215),
    ClockTime = 15,
    FogEnd = 900,
    FogColor = Color3.fromRGB(200, 200, 200),
}

local SOFT_EFFECTS = {
    ColorCorrection = {
        enabled = true,
        className = "ColorCorrectionEffect",
        settings = { 
            Brightness = -0.02, 
            Contrast = 0.04, 
            Saturation = 0.05,
            Name = "SoftLighting_ColorCorrection"
        }
    },
    SunRays = {
        enabled = true,
        className = "SunRaysEffect",
        settings = { 
            Intensity = 0.01,
            Name = "SoftLighting_SunRays"
        }
    },
    Atmosphere = {
        enabled = true,
        className = "Atmosphere",
        settings = { 
            Density = 0.25, 
            Offset = 0.6, 
            Color = Color3.fromRGB(220, 220, 220),
            Name = "SoftLighting_Atmosphere"
        }
    },
    Bloom = {
        enabled = true,
        className = "BloomEffect",
        settings = { 
            Intensity = 0.1, 
            Threshold = 0.75, 
            Size = 18,
            Name = "SoftLighting_Bloom"
        }
    }
}

local INFECTION_EFFECTS = {
    ScreenGuiNames = {
        "InfectionEffect",
        "InfectionScreen",
        "VirusEffect",
        "BloodEffect",
        "RedFilter",
        "DamageEffect",
        "PoisonEffect",
        "ScreenFilter"
    },
    LightingEffectClasses = {
        "BlurEffect",
        "DepthOfFieldEffect"
    }
}

local softEffectInstances = {}

local function safeCall(func, ...)
    local success, result = pcall(func, ...)
    if not success then
        warn("安全调用失败:", result)
    end
    return success, result
end

local function propertyExists(object, property)
    return pcall(function() 
        local _ = object[property]
        return true 
    end)
end

local function safeSetProperty(object, property, value)
    if object and propertyExists(object, property) then
        local current = object[property]
        if typeof(current) == typeof(value) and current ~= value then
            pcall(function()
                object[property] = value
            end)
        end
    end
end

local function applyConfigToObject(object, config)
    for prop, value in pairs(config) do
        safeSetProperty(object, prop, value)
    end
end

local function getOrCreateSoftEffect(name, className, settings)
    if softEffectInstances[name] and softEffectInstances[name].Parent then
        return softEffectInstances[name]
    end
    
    local effectName = settings.Name or name
    local existing = Lighting:FindFirstChild(effectName)
    
    if existing and existing:IsA(className) then
        softEffectInstances[name] = existing
        return existing
    end
    
    if existing then
        existing:Destroy()
    end
    
    local effect = Instance.new(className)
    effect.Name = effectName
    effect.Parent = Lighting
    
    applyConfigToObject(effect, settings)
    
    pcall(function()
        effect:SetAttribute("IsSoftLightingEffect", true)
    end)
    
    softEffectInstances[name] = effect
    return effect
end

local function applySoftLighting()
    local now = tick()
    
    if now - lastUpdateTime < DEBOUNCE_TIME then
        if not updatePending then
            updatePending = true
            task.delay(DEBOUNCE_TIME, function()
                updatePending = false
                applySoftLighting()
            end)
        end
        return
    end
    
    lastUpdateTime = now
    updatePending = false
    
    applyConfigToObject(Lighting, SOFT_CONFIG)
    
    for name, data in pairs(SOFT_EFFECTS) do
        if data.enabled then
            local effect = getOrCreateSoftEffect(name, data.className, data.settings)
            applyConfigToObject(effect, data.settings)
        end
    end
    
    safeSetProperty(Lighting, "FogEnd", 900)
    safeSetProperty(Lighting, "FogStart", 0)
end

local function waitForPlayerGui()
    if not localPlayer or not localPlayer:IsDescendantOf(Players) then
        return false
    end
    
    playerGui = safeCall(function()
        return localPlayer:WaitForChild("PlayerGui", 10) or localPlayer:FindFirstChild("PlayerGui")
    end)
    
    return playerGui ~= nil
end

local function clearInfectionEffects()
    safeCall(function()
        for _, className in ipairs(INFECTION_EFFECTS.LightingEffectClasses) do
            local effects = Lighting:GetChildren()
            for _, effect in ipairs(effects) do
                if effect:IsA(className) then
                    local isSoftEffect = pcall(function()
                        return effect:GetAttribute("IsSoftLightingEffect") == true
                    end)
                    
                    if not isSoftEffect then
                        effect:Destroy()
                    end
                end
            end
        end
    end)
    
    if waitForPlayerGui() then
        safeCall(function()
            for _, guiName in ipairs(INFECTION_EFFECTS.ScreenGuiNames) do
                local screenGui = playerGui:FindFirstChild(guiName)
                while screenGui do
                    screenGui:Destroy()
                    screenGui = playerGui:FindFirstChild(guiName)
                end
            end
        end)
    end
end

local function applyVisualManagement()
    applySoftLighting()
    
    clearInfectionEffects()
end

local function initialize()
    if not localPlayer then
        localPlayer = Players.LocalPlayer
        if not localPlayer then
            Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
            localPlayer = Players.LocalPlayer
        end
    end
    
    applyVisualManagement()
    
    local function onLightingChanged()
        local now = tick()
        if now - lastUpdateTime >= DEBOUNCE_TIME then
            applyVisualManagement()
        elseif not updatePending then
            updatePending = true
            task.delay(DEBOUNCE_TIME - (now - lastUpdateTime), function()
                if updatePending then
                    updatePending = false
                    applyVisualManagement()
                end
            end)
        end
    end
    
    local importantProperties = {
        "Brightness", "GlobalShadows", "Ambient", "ColorShift_Top",
        "ClockTime", "FogEnd", "FogColor", "FogStart"
    }
    
    for _, prop in ipairs(importantProperties) do
        if propertyExists(Lighting, prop) then
            Lighting:GetPropertyChangedSignal(prop):Connect(onLightingChanged)
        end
    end
    
    Lighting.ChildAdded:Connect(function(child)
        for _, className in ipairs(INFECTION_EFFECTS.LightingEffectClasses) do
            if child:IsA(className) then
                local isSoftEffect = pcall(function()
                    return child:GetAttribute("IsSoftLightingEffect") == true
                end)
                
                if not isSoftEffect then
                    task.wait(0.5)
                    child:Destroy()
                end
                break
            end
        end
    end)
    
    local function onPlayerGuiChildAdded()
        task.wait(0.5)
        clearInfectionEffects()
    end
    
    if waitForPlayerGui() then
        playerGui.ChildAdded:Connect(onPlayerGuiChildAdded)
    end
    
    task.spawn(function()
        while true do
            task.wait(15)
            applyVisualManagement()
        end
    end)
    
    UserInputService.InputBegan:Connect(function(input, processed)
        if not processed and input.KeyCode == Enum.KeyCode.F5 then
            applyVisualManagement()
        end
    end)
    
end

local success, err = pcall(initialize)
if not success then
    warn("视觉管理系统初始化失败:", err)
    
    task.delay(2, function()
        safeCall(function()
            Lighting.Brightness = 0.9
            Lighting.FogEnd = 900
            Lighting.FogStart = 0
        end)
    end)
end

return {
    ApplyVisualManagement = applyVisualManagement,
    ApplySoftLighting = applySoftLighting,
    ClearInfectionEffects = clearInfectionEffects,
    
    GetSoftLightingConfig = function() return SOFT_CONFIG end,
    GetSoftEffectsConfig = function() return SOFT_EFFECTS end,
    
    IsInitialized = success
}