-- Soft Lighting — 客户端专用，FPS 优化，强健错误处理，完整清理
-- 放置位置：LocalScript（客户端）或按需调整为 ModuleScript
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local task = task

-- ====== 配置区 ======
local DEBOUNCE_TIME = 0.5            -- Heartbeat 节流（秒）
local CHILD_EVENT_DEBOUNCE = 0.25    -- ChildAdded/Removed 防抖（秒）
local PERIODIC_APPLY_INTERVAL = 60   -- 周期性保底重申请隔离（秒）
local DEBUG = false                  -- true 打开调试打印（开发时使用）

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

-- ====== 内部状态/缓存 ======
local effectInstances = {}          -- name -> instance
local lastAppliedLighting = {}      -- Lighting 属性缓存
local lastAppliedEffects = {}       -- effectName -> { prop -> value }
local connections = {}              -- 存放 RBXScriptConnection
local dirty = false
local lastUpdateTick = 0
local lastChildEventTime = 0

-- 重要属性查找表（Changed 事件过滤）
local importantPropsSet = {
    Brightness = true, GlobalShadows = true, Ambient = true, ColorShift_Top = true,
    ClockTime = true, FogEnd = true, FogColor = true, FogStart = true
}

-- 本地化常用函数/常量以减少开销
local pcall_local = pcall
local typeof_local = typeof
local tick_local = tick
local tostring_local = tostring

local function dprint(...)
    if not DEBUG then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring_local(select(i, ...)) end
    print("[SoftLighting]", table.concat(parts, " "))
end

-- ====== 辅助函数 ======
-- 更健壮的浅比较（支持 Color3, Vector3, number, boolean, string）
local function shallowEqual(a, b)
    if a == b then return true end
    local ta = typeof_local(a)
    if ta ~= typeof_local(b) then return false end

    if ta == "Color3" then
        return a.R == b.R and a.G == b.G and a.B == b.B
    end
    if ta == "Vector3" then
        return a.X == b.X and a.Y == b.Y and a.Z == b.Z
    end
    if ta == "number" or ta == "boolean" or ta == "string" then
        return a == b
    end
    -- 其它类型不尝试精确比较，保守返回 false 以便写入确保一致性
    return false
end

-- 安全读取属性（pcall 包装）
local function safeRead(obj, prop)
    if not obj then return nil, false end
    local ok, val = pcall_local(function() return obj[prop] end)
    if ok then return val, true end
    return nil, false
end

-- 安全写属性（只有在值与缓存不等时进行）
local function safeWriteIfDiff(obj, prop, value, cacheTable)
    if not obj then return false end
    local cached = cacheTable[prop]
    if cached ~= nil and shallowEqual(cached, value) then
        return false
    end

    -- 尝试写入（保护性 pcall）
    local ok = pcall_local(function()
        obj[prop] = value
    end)

    if ok then
        cacheTable[prop] = value
        dprint("Set", prop, "=", tostring_local(value))
        return true
    else
        dprint("Failed to set", prop, "on", obj, "to", tostring_local(value))
        return false
    end
end

-- 批量应用配置到对象（利用缓存）
local function applyConfigToObjectWithCache(obj, config, cache)
    if not obj then return false end
    local anyChanged = false
    for prop, value in pairs(config) do
        if safeWriteIfDiff(obj, prop, value, cache) then
            anyChanged = true
        end
    end
    return anyChanged
end

-- 获取或创建 effect（保持本地 Lighting 下）
local function getOrCreateEffect(name, className)
    -- 如果缓存中存在并且父级有效，直接返回
    local inst = effectInstances[name]
    if inst and inst.Parent then return inst end

    -- 尝试查找同名实例
    local existing, ok = nil, false
    ok, existing = pcall_local(function() return Lighting:FindFirstChild(name) end)
    if ok and existing and existing:IsA(className) then
        effectInstances[name] = existing
        return existing
    end

    -- 清理（如果找到同名但类型不符，尝试销毁）
    if existing then
        pcall_local(function() existing:Destroy() end)
    end

    -- 创建新实例（严格在客户端 Lighting 下）
    local success, newEffect = pcall_local(function()
        local e = Instance.new(className)
        e.Name = name
        e.Parent = Lighting
        return e
    end)
    if success and newEffect then
        effectInstances[name] = newEffect
        return newEffect
    end

    return nil
end

-- ====== 主应用流程 ======
local function applySoftLightingInternal()
    if not Lighting then return false end
    local changed = false

    -- 应用 Lighting 属性
    if applyConfigToObjectWithCache(Lighting, SOFT_CONFIG, lastAppliedLighting) then
        changed = true
    end

    -- 应用或销毁 Effects
    for name, data in pairs(EFFECTS) do
        if data.enabled then
            local effect = getOrCreateEffect(name, data.class)
            if effect then
                lastAppliedEffects[name] = lastAppliedEffects[name] or {}
                if applyConfigToObjectWithCache(effect, data.settings, lastAppliedEffects[name]) then
                    changed = true
                end
            end
        else
            -- 若用户禁用，销毁现存实例并清理缓存
            local inst = effectInstances[name]
            if inst then
                pcall_local(function() inst:Destroy() end)
                effectInstances[name] = nil
                lastAppliedEffects[name] = nil
                changed = true
            else
                -- 也尝试从 Lighting 中查找并移除（安全）
                local existing, ok = safeRead(Lighting, name)
                if ok and existing and typeof_local(existing) == "Instance" then
                    pcall_local(function() existing:Destroy() end)
                    changed = true
                end
            end
        end
    end

    return changed
end

-- 外部请求应用（标记）
local function requestApply()
    dirty = true
end

-- ====== 监听与节流管理 ======
local function addConnection(conn)
    if conn and typeof_local(conn) == "RBXScriptConnection" then
        connections[#connections + 1] = conn
    end
end

local function disconnectAll()
    for i = #connections, 1, -1 do
        local c = connections[i]
        if c then
            pcall_local(function() c:Disconnect() end)
        end
        connections[i] = nil
    end
    -- 删掉本地对 effectInstances 的强引用（不强行销毁 Lighting 下的实例）
    effectInstances = {}
    lastAppliedEffects = {}
    lastAppliedLighting = {}
end

-- Lighting.ChildAdded / ChildRemoved 去抖处理
local function onLightingChildEvent(child)
    local now = tick_local()
    if now - lastChildEventTime < CHILD_EVENT_DEBOUNCE then
        -- 合并多次事件，延迟一次统一处理
        lastChildEventTime = now
        return
    end
    lastChildEventTime = now
    -- 简短延迟后统一申请，防止短时间内重复触发
    task.spawn(function()
        task.wait(CHILD_EVENT_DEBOUNCE)
        requestApply()
    end)
end

-- Lighting.Changed 仅处理重要属性
local function onLightingChanged(prop)
    if type(prop) ~= "string" then return end
    if importantPropsSet[prop] then
        requestApply()
    end
end

-- Heartbeat 节流（最关键的性能路径）
local heartbeatConn
heartbeatConn = RunService.Heartbeat:Connect(function()
    if not dirty then return end
    local now = tick_local()
    if now - lastUpdateTick >= DEBOUNCE_TIME then
        lastUpdateTick = now
        dirty = false
        -- pcall 保证即便出错也不会阻塞 Heartbeat
        pcall_local(function()
            applySoftLightingInternal()
        end)
    end
end)
addConnection(heartbeatConn)

-- ====== 初始化缓存并首次应用 ======
local function initializeCaches()
    -- Lighting 属性
    for prop, _ in pairs(SOFT_CONFIG) do
        local ok, val = safeRead(Lighting, prop)
        if ok then
            lastAppliedLighting[prop] = val
        else
            -- 若读取失败，先设置为 nil 以强制首次写入
            lastAppliedLighting[prop] = nil
        end
    end

    -- Effects 缓存（只缓存已存在实例的属性）
    for name, data in pairs(EFFECTS) do
        lastAppliedEffects[name] = lastAppliedEffects[name] or {}
        if data.enabled then
            local ok, existing = pcall_local(function() return Lighting:FindFirstChild(name) end)
            if ok and existing and existing:IsA(data.class) then
                effectInstances[name] = existing
                for k in pairs(data.settings) do
                    local v, ok2 = safeRead(existing, k)
                    if ok2 then lastAppliedEffects[name][k] = v end
                end
            end
        else
            effectInstances[name] = nil
            lastAppliedEffects[name] = nil
        end
    end
end

-- 初始化入口（保护性 pcall）
local function safeInitialize()
    local ok, err = pcall_local(function()
        initializeCaches()

        -- 连接事件
        addConnection(Lighting.ChildAdded:Connect(onLightingChildEvent))
        addConnection(Lighting.ChildRemoved:Connect(onLightingChildEvent))
        addConnection(Lighting.Changed:Connect(onLightingChanged))

        -- 周期性保底检查（延迟 spawn 启动以减小启动峰值）
        task.delay(1, function()
            while script and script.Parent and script:IsDescendantOf(game) do
                task.wait(PERIODIC_APPLY_INTERVAL)
                requestApply()
            end
        end)

        -- 立即应用一次（在 Heartbeat 驱动下也会再次应用）
        applySoftLightingInternal()
    end)
    if not ok then
        -- 极简保底设置，尽量确保关键属性生效
        pcall_local(function()
            Lighting.Brightness = SOFT_CONFIG.Brightness or 0.9
            Lighting.FogEnd = SOFT_CONFIG.FogEnd or 900
            Lighting.FogStart = SOFT_CONFIG.FogStart or 0
        end)
        warn("Soft Lighting init failed (fallback applied):", err)
    end
end

-- ====== 清理函数（导出） ======
local function cleanup()
    dprint("SoftLighting: cleanup start")
    disconnectAll()
    dprint("SoftLighting: cleanup done")
end

-- 若脚本被移除（AncestryChanged）时执行清理
if script then
    addConnection(script.AncestryChanged:Connect(function()
        if not script:IsDescendantOf(game) then
            cleanup()
        end
    end))
end

-- 启动
safeInitialize()

-- 返回清理函数以便外部调用（或 require 的模块可以调用）
return cleanup