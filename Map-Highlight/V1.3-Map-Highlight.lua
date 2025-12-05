-- Soft Lighting (final) — Client-only, FPS-friendly, with debug & cleanup
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

-- 配置（包含 FogStart）
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

-- 调试开关（false 为生产模式）
local DEBUG = false
local function debugPrint(...)
    if not DEBUG then return end
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        parts[#parts + 1] = tostring(v)
    end
    -- print("[SoftLighting]", table.concat(parts, " "))
end

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
local scriptRef = script

-- 更健壮的浅比较：处理 Color3、Vector3、number、boolean、string
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

-- 安全写入（只有在不同的情况下写），带调试输出
local function safeSetProperty(object, property, value)
    if not object then return end
    local ok, current = pcall_local(function() return object[property] end)
    if not ok then
        debugPrint("读取属性失败:", tostring(property))
        return
    end
    if shallowEqual(current, value) then
        debugPrint("跳过相同值:", property, tostring(current))
        return
    end
    debugPrint("设置属性:", property, "从", tostring(current), "到", tostring(value))
    pcall_local(function() object[property] = value end)
end

-- 批量设置（使用缓存；用 == nil 判定缓存未初始化）
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

-- 真正的应用函数（已移除冗余保底代码；SOFT_CONFIG 已包含 FogStart/FogEnd）
local function applySoftLightingInternal()
    -- 先应用 Lighting 配置（缓存判断会避免不必要写入）
    applyConfigToObjectWithCache(Lighting, SOFT_CONFIG, lastAppliedLighting)

    -- 应用 / 清理 Effects
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
end

-- 标记需要应用（不直接执行）
local function requestApply()
    dirty = true
end

-- Lighting Changed 只处理重要属性（ChildAdded/ChildRemoved 单独处理）
local function onLightingChanged(prop)
    if type(prop) ~= "string" then return end
    if importantPropsSet[prop] then
        requestApply()
    end
end

-- 连接管理：避免内存泄漏，方便清理
local connections = {}
local function addConnection(conn)
    if conn and typeof(conn) == "RBXScriptConnection" then
        table.insert(connections, conn)
    end
end
local function cleanup()
    debugPrint("SoftLighting: 清理连接与实例")
    for _, conn in ipairs(connections) do
        if conn and conn.Disconnect then
            pcall_local(function() conn:Disconnect() end)
        end
    end
    connections = {}
    -- 不销毁 Lighting 中 user effects 自动产生的实例，保持客户端状态稳定
    effectInstances = {}
end

-- ChildAdded/Removed 单独触发，并加入 connections 管理
addConnection(Lighting.ChildAdded:Connect(function(child)
    if EFFECTS[child.Name] and child:IsA(EFFECTS[child.Name].class) then
        requestApply()
    end
end))
addConnection(Lighting.ChildRemoved:Connect(function(child)
    if EFFECTS[child.Name] then
        requestApply()
    end
end))

addConnection(Lighting.Changed:Connect(function(prop)
    onLightingChanged(prop)
end))

-- Heartbeat 驱动节流（简化：以 tick 判断时间），也加入 connections 管理
addConnection(RunService.Heartbeat:Connect(function()
    if not dirty then return end
    if tick_local() - lastUpdateTick >= DEBOUNCE_TIME then
        lastUpdateTick = tick_local()
        dirty = false
        applySoftLightingInternal()
    end
end))

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

-- 定期保底检查（每 60s）
addConnection(task.spawn(function()
    while true do
        task.wait(60)
        requestApply()
    end
end))

-- 在脚本从游戏树移除时清理连接
if scriptRef then
    addConnection(scriptRef.AncestryChanged:Connect(function()
        if not scriptRef:IsDescendantOf(game) then
            cleanup()
        end
    end))
end

debugPrint("Soft Lighting (final) initialized.")
return applySoftLightingInternal