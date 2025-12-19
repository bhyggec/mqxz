--地图高亮 v1.1
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

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

local EFFECTS = {
    ColorCorrection = {
        enabled = true,
        class = "ColorCorrectionEffect",
        settings = { Brightness = -0.02, Contrast = 0.04, Saturation = 0.05 }
    },
    SunRays = {
        enabled = true,
        class = "SunRaysEffect",
        settings = { Intensity = 0.01 }
    },
    Atmosphere = {
        enabled = true,
        class = "Atmosphere",
        settings = { Density = 0.25, Offset = 0.6, Color = Color3.fromRGB(220, 220, 220) }
    },
    Bloom = {
        enabled = true,
        class = "BloomEffect",
        settings = { Intensity = 0.1, Threshold = 0.75, Size = 18 }
    }
}

local effectInstances = {}

local function safeSetProperty(object, property, value)
    if object and pcall(function() return object[property] end) then
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

local function getOrCreateEffect(name, className)
    if effectInstances[name] and effectInstances[name].Parent then
        return effectInstances[name]
    end
    
    local existing = Lighting:FindFirstChild(name)
    if existing and existing:IsA(className) then
        effectInstances[name] = existing
        return existing
    end
    
    if existing then
        existing:Destroy()
    end
    
    local effect = Instance.new(className)
    effect.Name = name
    effect.Parent = Lighting
    effectInstances[name] = effect
    
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
    
    for name, data in pairs(EFFECTS) do
        if data.enabled then
            local effect = getOrCreateEffect(name, data.class)
            applyConfigToObject(effect, data.settings)
        else
            local effect = Lighting:FindFirstChild(name)
            if effect then
                effect:Destroy()
                effectInstances[name] = nil
            end
        end
    end
    
    if Lighting.FogEnd > 900 then
        safeSetProperty(Lighting, "FogEnd", 900)
    end
    if Lighting.FogStart ~= 0 then
        safeSetProperty(Lighting, "FogStart", 0)
    end
end

local function initializeSoftLighting()
    applySoftLighting()
    
    local function onLightingChanged()
        local now = tick()
        if now - lastUpdateTime >= DEBOUNCE_TIME then
            applySoftLighting()
        elseif not updatePending then
            updatePending = true
            task.delay(DEBOUNCE_TIME - (now - lastUpdateTime), function()
                if updatePending then
                    updatePending = false
                    applySoftLighting()
                end
            end)
        end
    end
    
    local importantProperties = {
        "Brightness", "GlobalShadows", "Ambient", "ColorShift_Top",
        "ClockTime", "FogEnd", "FogColor", "FogStart"
    }
    
    for _, prop in ipairs(importantProperties) do
        if pcall(function() return Lighting[prop] end) then
            Lighting:GetPropertyChangedSignal(prop):Connect(onLightingChanged)
        end
    end
    
    Lighting.ChildAdded:Connect(function(child)
        if EFFECTS[child.Name] and child:IsA(EFFECTS[child.Name].class) then
            onLightingChanged()
        end
    end)
    
    Lighting.ChildRemoved:Connect(function(child)
        if EFFECTS[child.Name] then
            onLightingChanged()
        end
    end)
    
    task.spawn(function()
        while true do
            task.wait(10)
            applySoftLighting()
        end
    end)
    
    print("Soft Lighting initialized successfully!")
    return applySoftLighting
end

local success, result = pcall(initializeSoftLighting)
if not success then
    warn("Soft Lighting initialization failed:", result)
    pcall(function()
        Lighting.Brightness = 0.9
        Lighting.FogEnd = 900
        Lighting.FogStart = 0
    end)
end

return applySoftLighting