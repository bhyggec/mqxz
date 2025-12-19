--地图高亮 v1.2
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local DEBOUNCE_TIME = 0.5
local SOFT_CONFIG = {
    Brightness = 0.9,
    GlobalShadows = true,
    Ambient = Color3.fromRGB(140, 140, 140),
    ColorShift_Top = Color3.fromRGB(235, 225, 215),
    ClockTime = 15,
    FogEnd = 900,
    FogColor = Color3.fromRGB(200, 200, 200),
    FogStart = 0,
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
local lastAppliedLighting = {}
local lastAppliedEffects = {}
local lastUpdateTick = 0
local dirty = false

local importantPropsSet = {
    Brightness = true, GlobalShadows = true, Ambient = true, ColorShift_Top = true,
    ClockTime = true, FogEnd = true, FogColor = true, FogStart = true
}

local pcall_local = pcall
local tick_local = tick

local function shallowEqual(a, b)
    if a == b then
        return true
    end
    local ta = typeof(a)
    local tb = typeof(b)
    if ta ~= tb then return false end
    if ta == "Color3" then
        return a.R == b.R and a.G == b.G and a.B == b.B
    end
    if ta == "Vector3" then
        return a.X == b.X and a.Y == b.Y and a.Z == b.Z
    end
    if ta == "number" or ta == "boolean" or ta == "string" then
        return a == b
    end
    return false
end

local function safeSetProperty(object, property, value)
    if not object then return end
    local ok, current = pcall_local(function() return object[property] end)
    if not ok then return end
    if shallowEqual(current, value) then return end
    pcall_local(function() object[property] = value end)
end

local function applyConfigToObjectWithCache(object, config, cache)
    for prop, value in pairs(config) do
        if cache[prop] == nil or not shallowEqual(cache[prop], value) then
            safeSetProperty(object, prop, value)
            cache[prop] = value
        end
    end
end

local function getOrCreateEffect(name, className)
    local inst = effectInstances[name]
    if inst and inst.Parent then return inst end

    local existing = Lighting:FindFirstChild(name)
    if existing and existing:IsA(className) then
        effectInstances[name] = existing
        return existing
    end

    if existing then existing:Destroy() end

    local effect = Instance.new(className)
    effect.Name = name
    effect.Parent = Lighting
    effectInstances[name] = effect
    return effect
end

local function applySoftLightingInternal()
    applyConfigToObjectWithCache(Lighting, SOFT_CONFIG, lastAppliedLighting)

    for name, data in pairs(EFFECTS) do
        if data.enabled then
            local effect = getOrCreateEffect(name, data.class)
            lastAppliedEffects[name] = lastAppliedEffects[name] or {}
            applyConfigToObjectWithCache(effect, data.settings, lastAppliedEffects[name])
        else
            local existing = Lighting:FindFirstChild(name)
            if existing then existing:Destroy() end
            effectInstances[name] = nil
            lastAppliedEffects[name] = nil
        end
    end

    if lastAppliedLighting.FogEnd == nil or lastAppliedLighting.FogEnd > 900 then
        safeSetProperty(Lighting, "FogEnd", 900)
        lastAppliedLighting.FogEnd = 900
    end
    if lastAppliedLighting.FogStart == nil or lastAppliedLighting.FogStart ~= 0 then
        safeSetProperty(Lighting, "FogStart", 0)
        lastAppliedLighting.FogStart = 0
    end
end

local function requestApply()
    dirty = true
end

local function onLightingChanged(prop)
    if type(prop) ~= "string" then return end
    if importantPropsSet[prop] then
        requestApply()
    end
end

Lighting.ChildAdded:Connect(function(child)
    if EFFECTS[child.Name] and child:IsA(EFFECTS[child.Name].class) then
        requestApply()
    end
end)
Lighting.ChildRemoved:Connect(function(child)
    if EFFECTS[child.Name] then
        requestApply()
    end
end)

Lighting.Changed:Connect(function(prop)
    onLightingChanged(prop)
end)

RunService.Heartbeat:Connect(function()
    if not dirty then return end
    if tick_local() - lastUpdateTick >= DEBOUNCE_TIME then
        lastUpdateTick = tick_local()
        dirty = false
        applySoftLightingInternal()
    end
end)

local function initializeCaches()
    for prop, _ in pairs(SOFT_CONFIG) do
        local ok, v = pcall_local(function() return Lighting[prop] end)
        if ok then
            lastAppliedLighting[prop] = v
        else
            lastAppliedLighting[prop] = nil
        end
    end

    for name, data in pairs(EFFECTS) do
        lastAppliedEffects[name] = nil
        if data.enabled then
            local existing = Lighting:FindFirstChild(name)
            if existing and existing:IsA(data.class) then
                effectInstances[name] = existing
                lastAppliedEffects[name] = {}
                for k, _ in pairs(data.settings) do
                    local ok, v = pcall_local(function() return existing[k] end)
                    if ok then lastAppliedEffects[name][k] = v end
                end
            end
        else
            effectInstances[name] = nil
        end
    end
end

local success, err = pcall_local(function()
    initializeCaches()
    applySoftLightingInternal()
end)
if not success then
    warn("Soft Lighting initialization failed: ", err)
    pcall_local(function()
        Lighting.Brightness = SOFT_CONFIG.Brightness or 0.9
        Lighting.FogEnd = SOFT_CONFIG.FogEnd or 900
        Lighting.FogStart = SOFT_CONFIG.FogStart or 0
    end)
end

task.spawn(function()
    while true do
        task.wait(60)
        requestApply()
    end
end)