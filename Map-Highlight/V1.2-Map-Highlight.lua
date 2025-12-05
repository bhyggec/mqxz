-- Soft Lighting with Corrected Fixes (Client-only, FPS-friendly)
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

-- 配置（增加 FogStart）
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

-- 内部状态与缓存
local effectInstances = {}
local lastAppliedLighting = {}
local lastAppliedEffects = {}
local lastUpdateTick = 0
local dirty = false

-- 重要属性集合（用于 Changed 事件过滤）
local importantPropsSet = {
    Brightness = true, GlobalShadows = true, Ambient = true, ColorShift_Top = true,
    ClockTime = true, FogEnd = true, FogColor = true, FogStart = true
}

-- 本地引用优化
local pcall_local = pcall
local tick_local = tick

-- 更健壮的浅比较：处理 Color3、Vector3、number、boolean 等
local function shallowEqual(a, b)
    if a == b then
        return true
    end
    local ta = typeof(a)
    local tb = typeof(b)
    if ta ~= tb then return false end

    if ta == "Color3" then
        -- 精确比较组件（Color3 内部为浮点，但通常由 fromRGB 或固定值生成）
        return a.R == b.R and a.G == b.G and a.B == b.B
    end
    if ta == "Vector3" then
        return a.X == b.X and a.Y == b.Y and a.Z == b.Z
    end
    if ta == "number" or ta == "boolean" or ta == "string" then
        return a == b
    end
    -- 默认回退：不相等
    return false
end

-- 安全写入（只有在不同的情况下写）
local function safeSetProperty(object, property, value)
    if not object then return end
    local ok, current = pcall_local(function() return object[property] end)
    if not ok then return end
    if shallowEqual(current, value) then return end
    pcall_local(function() object[property] = value end)
end

-- 批量设置（使用缓存；注意：用 == nil 判定缓存未初始化）
local function applyConfigToObjectWithCache(object, config, cache)
    for prop, value in pairs(config) do
        if cache[prop] == nil or not shallowEqual(cache[prop], value) then
            safeSetProperty(object, prop, value)
            cache[prop] = value
        end
    end
end

-- 获取或创建 effect（本地 Lighting）
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

-- 真正的应用函数（最小化写入）
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

    -- 额外保底：确保 FogStart/FogEnd 在期望范围（只在必要时写）
    if lastAppliedLighting.FogEnd == nil or lastAppliedLighting.FogEnd > 900 then
        safeSetProperty(Lighting, "FogEnd", 900)
        lastAppliedLighting.FogEnd = 900
    end
    if lastAppliedLighting.FogStart == nil or lastAppliedLighting.FogStart ~= 0 then
        safeSetProperty(Lighting, "FogStart", 0)
        lastAppliedLighting.FogStart = 0
    end
end

-- 标记需要应用（不直接执行）
local function requestApply()
    dirty = true
end

-- Lighting Changed 只处理重要属性（ChildAdded/Removed 已独立连接）
local function onLightingChanged(prop)
    if type(prop) ~= "string" then return end
    if importantPropsSet[prop] then
        requestApply()
    end
end

-- ChildAdded/Removed 单独触发
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

-- Heartbeat 驱动节流（简化：以 tick 判断时间）
RunService.Heartbeat:Connect(function()
    if not dirty then return end
    if tick_local() - lastUpdateTick >= DEBOUNCE_TIME then
        lastUpdateTick = tick_local()
        dirty = false
        applySoftLightingInternal()
    end
end)

-- 初始化缓存（从当前 Lighting/Effects 读取值，避免首次重复写入）
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

-- 合并初始化（避免重复立即应用）
local success, err = pcall_local(function()
    initializeCaches()
    -- 只在缓存与期望值不同的时候写入（apply 内部已处理）
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

-- 定期保底检查（每 60s），仍在客户端循环
task.spawn(function()
    while true do
        task.wait(60)
        requestApply()
    end
end)

print("Soft Lighting (fixed) initialized.")
return applySoftLightingInternal