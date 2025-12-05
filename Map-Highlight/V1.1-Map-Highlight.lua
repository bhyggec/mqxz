-- Soft Lighting with Optimized Auto-Restore (Client Safe)
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

-- 防抖配置（防止频繁更新）
local DEBOUNCE_TIME = 0.5  -- 防抖时间（秒）
local lastUpdateTime = 0
local updatePending = false

-- 软光照配置
local SOFT_CONFIG = {
    Brightness = 0.9,
    GlobalShadows = true,
    Ambient = Color3.fromRGB(140, 140, 140),
    ColorShift_Top = Color3.fromRGB(235, 225, 215),
    ClockTime = 15,
    FogEnd = 900,
    FogColor = Color3.fromRGB(200, 200, 200),
}

-- 效果配置（使用布尔值标记是否需要该效果）
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

-- 缓存已创建的效果实例
local effectInstances = {}

-- 检查并应用单个属性（避免不必要的设置）
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

-- 批量设置属性（减少调用次数）
local function applyConfigToObject(object, config)
    for prop, value in pairs(config) do
        safeSetProperty(object, prop, value)
    end
end

-- 创建或获取效果实例（带缓存）
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

-- 优化的应用函数（只在必要时更新）
local function applySoftLighting()
    local now = tick()
    
    -- 防抖检查
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
    
    -- 应用基础光照设置
    applyConfigToObject(Lighting, SOFT_CONFIG)
    
    -- 应用效果设置
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
    
    -- 确保雾被正确移除
    if Lighting.FogEnd > 900 then
        safeSetProperty(Lighting, "FogEnd", 900)
    end
    if Lighting.FogStart ~= 0 then
        safeSetProperty(Lighting, "FogStart", 0)
    end
end

-- 初始化函数（带安全检查）
local function initializeSoftLighting()
    -- 初次应用
    applySoftLighting()
    
    -- 设置属性变化监听（优化版本）
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
    
    -- 监听关键属性变化（而不是所有变化）
    local importantProperties = {
        "Brightness", "GlobalShadows", "Ambient", "ColorShift_Top",
        "ClockTime", "FogEnd", "FogColor", "FogStart"
    }
    
    for _, prop in ipairs(importantProperties) do
        if pcall(function() return Lighting[prop] end) then
            Lighting:GetPropertyChangedSignal(prop):Connect(onLightingChanged)
        end
    end
    
    -- 监听子项变化
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
    
    -- 可选：定期检查（每10秒一次）
    task.spawn(function()
        while true do
            task.wait(10)
            applySoftLighting()
        end
    end)
    
    print("Soft Lighting initialized successfully!")
    return applySoftLighting
end

-- 安全初始化
local success, result = pcall(initializeSoftLighting)
if not success then
    warn("Soft Lighting initialization failed:", result)
    -- 尝试最基本的设置
    pcall(function()
        Lighting.Brightness = 0.9
        Lighting.FogEnd = 900
        Lighting.FogStart = 0
    end)
end

return applySoftLighting