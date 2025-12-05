-- Soft Lighting (FPS-Optimized Final)
-- 综合 deepseek 建议：采样降频+采样缓存+Stepped 限制+性能降级+预建 effects
-- 纯本地运行，保留所有功能，旨在最大化运行时流畅度

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace

-- ====================== 配置（优化后） ======================
local BASE_DEBOUNCE = 0.35
local MAX_DEBOUNCE_SCALE = 4
local TARGET_FPS = 60
local ADAPTIVE_CALL_MIN = 0.9
local ADAPTIVE_CALL_MAX = 6

-- 采样相关（显著降低开销）
local RAY_SAMPLE_DIRECTIONS = 3     -- 从 6 降到 3
local RAY_DISTANCE = 50             -- 缩短检测距离以降低开销
local SAMPLE_INTERVAL_MIN = 2.0     -- 最小采样间隔（秒）
local SAMPLE_INTERVAL_MAX = 6.0     -- 最大采样间隔
local lastSampleTime = 0
local cachedSampleResult = nil

-- Stepped 限频（避免每帧处理）
local STEPPED_PROCESS_FPS_LIMIT = 30  -- 最多每秒执行多少次主逻辑

-- 预计算颜色常量
local COLOR_135 = Color3.fromRGB(135,135,135)
local COLOR_230_220_210 = Color3.fromRGB(230,220,210)
local COLOR_210 = Color3.fromRGB(210,210,210)
local COLOR_225 = Color3.fromRGB(225,225,225)

local SOFT_CONFIG = {
    Brightness = 0.85,
    GlobalShadows = true,
    Ambient = COLOR_135,
    ColorShift_Top = COLOR_230_220_210,
    ClockTime = 15,
    FogEnd = 850,
    FogColor = COLOR_210,
    FogStart = 0,
}

local SOFT_CONFIG_KEYS = {
    "Brightness","GlobalShadows","Ambient","ColorShift_Top",
    "ClockTime","FogEnd","FogColor","FogStart"
}

local EFFECTS_DATA = {
    {
        name = "ColorCorrection",
        enabled = true,
        class = "ColorCorrectionEffect",
        settings = {Brightness = -0.04, Contrast = 0.03, Saturation = 0.03}
    },
    {
        name = "SunRays",
        enabled = true,
        class = "SunRaysEffect",
        settings = {Intensity = 0.01}
    },
    {
        name = "Atmosphere",
        enabled = true,
        class = "Atmosphere",
        settings = {Density = 0.23, Offset = 0.55, Color = COLOR_225}
    },
    {
        name = "Bloom",
        enabled = true,
        class = "BloomEffect",
        settings = {Intensity = 0.07, Threshold = 0.8, Size = 16}
    }
}
local EFFECTS_LOOKUP = {}
for i,d in ipairs(EFFECTS_DATA) do EFFECTS_LOOKUP[d.name] = i end

-- ========== 自适应参数 ==========
local ADAPT_RATE = 0.20  -- 降低响应速度以减少频繁修改
local MAX_BLOOM_SCALE = 1.2
local MIN_BLOOM_SCALE = 0.35
local MAX_BRIGHT_CORR = -0.01
local MIN_BRIGHT_CORR = -0.09

-- ====================== 内部状态 ======================
local DEBUG = false
local function debugPrint(...) if DEBUG then print("[SoftLighting]", ...) end end

local effectInstances = {}
local lastAppliedLighting = {}
local lastAppliedEffects = {}
local IMPORTANT_PROPS = {
    Brightness=true, GlobalShadows=true, Ambient=true,
    ColorShift_Top=true, ClockTime=true, FogEnd=true,
    FogColor=true, FogStart=true
}

local dirtyFlag = false
local lastApplyTime = 0

local smoothFPS = TARGET_FPS
local FPS_ALPHA = 0.08

local lastAdaptiveTime = 0
local adaptiveState = 0.5

local activeConnections = {}
local lastSteppedTime = 0
local steppedMinDt = 1 / STEPPED_PROCESS_FPS_LIMIT

-- 性能降级
local PERFORMANCE_THRESHOLD = 30
local performanceLevel = 1  -- 1 = 全效, 2 = 中效, 3 = 低效

-- RaycastParams 重用（尽量避免每次分配）
local rayParams = RaycastParams.new()
rayParams.FilterDescendantsInstances = {}
rayParams.FilterType = Enum.RaycastFilterType.Blacklist
rayParams.IgnoreWater = false

-- 安全连接包装
local function safeConnect(signal, handler)
    local conn = signal:Connect(function(...)
        local ok, err = pcall(handler, ...)
        if not ok and DEBUG then warn("[SoftLighting] connection handler error:", err) end
    end)
    table.insert(activeConnections, conn)
    return conn
end

-- 预计算 effect setting keys
for _, data in ipairs(EFFECTS_DATA) do
    local keys = {}
    for k,_ in pairs(data.settings) do keys[#keys+1] = k end
    data._settings_keys = keys
end

-- ====================== 辅助函数 ======================
local function valuesEqual(a,b)
    if a == b then return true end
    local ta = typeof(a)
    if ta ~= typeof(b) then return false end
    if ta == "Color3" then return a.R==b.R and a.G==b.G and a.B==b.B end
    if ta == "Vector3" then return a.X==b.X and a.Y==b.Y and a.Z==b.Z end
    return false
end

local function safeSetProperty(obj, prop, value, cache)
    if not obj then return false end
    local ok, current = pcall(function() return obj[prop] end)
    if not ok then return false end
    if valuesEqual(current, value) then
        if cache then cache[prop] = value end
        return true
    end
    local setOk = pcall(function() obj[prop] = value end)
    if setOk and cache then cache[prop] = value end
    return setOk
end

local function applyConfigBatch(obj, config, cache, keys)
    for i = 1, #keys do
        local key = keys[i]
        local value = config[key]
        if value ~= nil then
            safeSetProperty(obj, key, value, cache)
        end
    end
end

local function getOrCreateEffect(name, className)
    local cached = effectInstances[name]
    if cached and cached.Parent and cached.ClassName == className then return cached end
    local existing = Lighting:FindFirstChild(name)
    if existing and existing.ClassName == className then effectInstances[name] = existing return existing end
    if existing then pcall(function() existing:Destroy() end) end
    local ok, inst = pcall(function()
        local i = Instance.new(className)
        i.Name = name
        i.Parent = Lighting
        return i
    end)
    if ok and inst then effectInstances[name] = inst return inst end
    return nil
end

-- 预创建 effects，避免运行时创建开销（在初始化阶段调用）
local function preCreateEffects()
    for _, d in ipairs(EFFECTS_DATA) do
        if d.enabled then
            pcall(function() getOrCreateEffect(d.name, d.class) end)
        end
    end
end

-- ====================== 场景采样（低频，带缓存） ======================
local function luminanceFromColor3(col)
    -- 输入 Color3 （0..1），输出感知亮度 0..1
    return 0.2126 * col.R + 0.7152 * col.G + 0.0722 * col.B
end

local function sampleSceneBrightnessOnce()
    -- 原始采样函数（一次完整采样，不做频繁调用）
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local origin = cam.CFrame.Position

    -- 少量方向（中心 + 两侧）
    local dirs = {}
    local fwd = cam.CFrame.LookVector
    dirs[1] = fwd
    dirs[2] = (cam.CFrame * CFrame.Angles(math.rad(10), math.rad(10), 0)).LookVector
    dirs[3] = (cam.CFrame * CFrame.Angles(math.rad(-10), math.rad(-10), 0)).LookVector

    local total = 0
    local count = 0

    for i = 1, #dirs do
        local ok, result = pcall(function() return Workspace:Raycast(origin, dirs[i] * RAY_DISTANCE, rayParams) end)
        if ok and result then
            local inst = result.Instance
            local mat = result.Material
            local lum = 0
            local reflect = 0

            if inst and inst:IsA("BasePart") then
                local okc, col = pcall(function() return inst.Color end)
                if okc and typeof(col) == "Color3" then
                    lum = luminanceFromColor3(Color3.new(col.R/255, col.G/255, col.B/255))
                end
                local okr, refl = pcall(function() return inst.Reflectance end)
                if okr and type(refl) == "number" then reflect = refl end
            else
                -- terrain or nil, fallback to ambient
                local amb = Lighting.Ambient
                lum = luminanceFromColor3(Color3.new(amb.R/255, amb.G/255, amb.B/255))
                if mat and typeof(mat) == "EnumItem" then
                    if mat == Enum.Material.Snow or mat == Enum.Material.Ice then reflect = 0.6 end
                end
            end

            local sampleVal = math.clamp(lum * (1 + (reflect or 0)), 0, 1)
            total = total + sampleVal
            count = count + 1
        end
    end

    if count == 0 then return nil end
    return total / count
end

-- 缓存采样：受 lastSampleTime 与采样间隔控制
local function sampleSceneBrightness()
    local now = tick()
    local sampleInterval = math.clamp(SAMPLE_INTERVAL_MIN, SAMPLE_INTERVAL_MIN, SAMPLE_INTERVAL_MAX)
    -- If low FPS, increase interval (done in performance adjust); else use MIN
    if cachedSampleResult and (now - lastSampleTime) < sampleInterval then
        return cachedSampleResult
    end
    local res = nil
    local ok, val = pcall(sampleSceneBrightnessOnce)
    if ok then res = val end
    cachedSampleResult = res
    lastSampleTime = now
    return res
end

-- ====================== 亮度估计（轻量或进阶自动切换） ======================
local function simpleAmbEstimate()
    local amb = Lighting.Ambient
    return ((amb.R + amb.G + amb.B) / 3) / 255
end

local function advancedEstimateBrightness()
    local baseAmb = simpleAmbEstimate()
    local samp = sampleSceneBrightness()
    if samp == nil then return math.clamp(baseAmb, 0, 1) end
    -- weight sample more but keep ambient influence
    local weightSample = 0.7
    local combined = samp * weightSample + baseAmb * (1 - weightSample)
    return math.clamp(combined, 0, 1)
end

-- ====================== 自适应亮度（低频） ======================
local function applyAdaptiveBrightnessAdvanced()
    local cc = Lighting:FindFirstChild("ColorCorrection")
    local bloom = Lighting:FindFirstChild("Bloom")
    if not cc or not bloom then return end

    -- 根据 performanceLevel 决定使用简单估计还是进阶估计
    local env
    if performanceLevel >= 3 then
        env = simpleAmbEstimate()
    else
        env = advancedEstimateBrightness()
    end
    adaptiveState = adaptiveState + (env - adaptiveState) * ADAPT_RATE
    local inv = 1 - adaptiveState

    local bloomScale = MIN_BLOOM_SCALE + (MAX_BLOOM_SCALE - MIN_BLOOM_SCALE) * inv
    local ccBrightness = MIN_BRIGHT_CORR + (MAX_BRIGHT_CORR - MIN_BRIGHT_CORR) * inv
    local ccSaturation = 0.03 * (0.6 + 0.4 * inv)

    pcall(function()
        -- 在性能较差时降低写操作频率和幅度
        if performanceLevel == 1 then
            bloom.Intensity = (EFFECTS_DATA[4] and EFFECTS_DATA[4].settings.Intensity or 0.07) * bloomScale
            cc.Brightness = ccBrightness
            cc.Saturation = ccSaturation
        elseif performanceLevel == 2 then
            -- 中等级别：减弱变化幅度
            bloom.Intensity = math.max(0.02, (EFFECTS_DATA[4] and EFFECTS_DATA[4].settings.Intensity or 0.07) * (bloomScale * 0.7))
            cc.Brightness = ccBrightness * 0.7
            cc.Saturation = ccSaturation * 0.7
        else
            -- 低等级：非常保守
            bloom.Intensity = 0.02
            cc.Brightness = ccBrightness * 0.4
            cc.Saturation = math.max(0, ccSaturation * 0.4)
        end

        -- 温和调整曝光与 Ambient，仅在最亮场景轻微下降
        if env > 0.78 then
            Lighting.ExposureCompensation = (Lighting.ExposureCompensation or 0) - 0.02
        end
    end)
end

-- ====================== 主应用逻辑 ======================
local function applySoftLightingInternal()
    applyConfigBatch(Lighting, SOFT_CONFIG, lastAppliedLighting, SOFT_CONFIG_KEYS)
    for _, data in ipairs(EFFECTS_DATA) do
        if data.enabled then
            local effect = getOrCreateEffect(data.name, data.class)
            if effect then
                if not lastAppliedEffects[data.name] then lastAppliedEffects[data.name] = {} end
                local cache = lastAppliedEffects[data.name]
                applyConfigBatch(effect, data.settings, cache, data._settings_keys)
            end
        else
            local existing = Lighting:FindFirstChild(data.name)
            if existing then pcall(function() existing:Destroy() end) end
            effectInstances[data.name] = nil
            lastAppliedEffects[data.name] = nil
        end
    end
    lastApplyTime = tick()
    dirtyFlag = false
end

-- ====================== 性能监控与自动降级 ======================
local function adjustPerformanceLevel()
    if smoothFPS < PERFORMANCE_THRESHOLD then
        if performanceLevel < 3 then
            performanceLevel = performanceLevel + 1
            -- 降级动作：关闭/减弱部分效果以节省开销
            local bloom = Lighting:FindFirstChild("Bloom")
            if bloom then pcall(function() bloom.Intensity = 0.02 end) end
            local sun = Lighting:FindFirstChild("SunRays")
            if sun then pcall(function() sun.Enabled = false end) end
            -- 缩短采样精度（尽量减少射线）
            RAY_SAMPLE_DIRECTIONS = math.max(1, RAY_SAMPLE_DIRECTIONS - 1)
            SAMPLE_INTERVAL_MIN = math.min(6.0, SAMPLE_INTERVAL_MIN * 1.5)
        end
    else
        -- 性能回升，尝试恢复逐级提升效果
        if performanceLevel > 1 and smoothFPS > (PERFORMANCE_THRESHOLD + 10) then
            performanceLevel = performanceLevel - 1
            -- 恢复一部分设置（不过不强制覆盖全部用户改动）
            RAY_SAMPLE_DIRECTIONS = math.max(1, RAY_SAMPLE_DIRECTIONS + 1)
            SAMPLE_INTERVAL_MIN = math.max(1.5, SAMPLE_INTERVAL_MIN / 1.5)
            -- 尝试恢复 SunRays, Bloom 温和值
            local sun = Lighting:FindFirstChild("SunRays")
            if sun then pcall(function() sun.Enabled = true end) end
            local bloom = Lighting:FindFirstChild("Bloom")
            if bloom then pcall(function() bloom.Intensity = 0.05 end) end
        end
    end
end

-- ====================== 事件监听 ======================
local function requestApply()
    if not dirtyFlag then dirtyFlag = true end
end

safeConnect(Lighting.Changed, function(prop)
    if type(prop) == "string" and IMPORTANT_PROPS[prop] then requestApply() end
end)

safeConnect(Lighting.ChildAdded, function(child)
    if child and EFFECTS_LOOKUP[child.Name] then requestApply() end
end)
safeConnect(Lighting.ChildRemoved, function(child)
    if child and EFFECTS_LOOKUP[child.Name] then requestApply() end
end)

-- ====================== Stepped 驱动（替代 Heartbeat，带频率限制） ======================
local steppedConn = RunService.Stepped:Connect(function(_, dt)
    local now = tick()
    -- 限制执行频率，避免每帧运行（按 STEPPED_PROCESS_FPS_LIMIT）
    if (now - lastSteppedTime) < steppedMinDt then return end
    lastSteppedTime = now

    -- 平滑 FPS 估算
    if dt and dt > 0 then
        local instantFPS = 1 / dt
        smoothFPS = smoothFPS + (instantFPS - smoothFPS) * FPS_ALPHA
    end

    -- 动态防抖计算
    local fpsRatio = math.clamp(TARGET_FPS / math.max(smoothFPS, 1), 1, MAX_DEBOUNCE_SCALE)
    local dynamicDebounce = BASE_DEBOUNCE * fpsRatio

    -- 应用设置（受动态间隔控制）
    if dirtyFlag and (now - lastApplyTime) >= dynamicDebounce then
        pcall(applySoftLightingInternal)
    end

    -- 自适应亮度（低频）
    local adaptiveInterval = math.clamp(dynamicDebounce * 1.5, ADAPTIVE_CALL_MIN, ADAPTIVE_CALL_MAX)
    if (now - lastAdaptiveTime) >= adaptiveInterval then
        lastAdaptiveTime = now
        -- 采样与自适应
        pcall(function()
            -- 在低性能等级使用更保守的采样频率与方法
            if performanceLevel >= 3 then
                -- 仅使用 Ambient 简化估计
                adaptiveState = adaptiveState + (simpleAmbEstimate() - adaptiveState) * ADAPT_RATE
            else
                -- 常规使用进阶算法（内部有采样缓存）
                applyAdaptiveBrightnessAdvanced()
            end
        end)
    end

    -- 性能动态调整（根据 smoothFPS）
    adjustPerformanceLevel()
end)
table.insert(activeConnections, steppedConn)

-- ====================== 初始化与缓存 ======================
local function initializeCaches()
    for i = 1, #SOFT_CONFIG_KEYS do
        local k = SOFT_CONFIG_KEYS[i]
        lastAppliedLighting[k] = Lighting[k]
    end
    for _, data in ipairs(EFFECTS_DATA) do
        if data.enabled then
            local existing = Lighting:FindFirstChild(data.name)
            if existing and existing.ClassName == data.class then
                effectInstances[data.name] = existing
                lastAppliedEffects[data.name] = {}
                local cache = lastAppliedEffects[data.name]
                for si = 1, #data._settings_keys do
                    local sk = data._settings_keys[si]
                    local ok, cur = pcall(function() return existing[sk] end)
                    if ok then cache[sk] = cur end
                end
            end
        end
    end
end

local okInit, errInit = pcall(function()
    -- 预创建 effects（减少首次运行时创建开销）
    preCreateEffects()
    initializeCaches()
    applySoftLightingInternal()
    applyAdaptiveBrightnessAdvanced()
end)
if not okInit then
    warn("[SoftLighting] Initialization failed:", errInit)
    pcall(function()
        Lighting.Brightness = SOFT_CONFIG.Brightness or 0.85
        Lighting.FogEnd = SOFT_CONFIG.FogEnd or 850
        Lighting.FogStart = SOFT_CONFIG.FogStart or 0
        Lighting.GlobalShadows = true
    end)
end

-- 周期保底触发
task.spawn(function()
    while task.wait(60) do requestApply() end
end)

-- ====================== 清理机制 ======================
local function cleanup()
    debugPrint("SoftLighting: cleanup start")
    for i = #activeConnections, 1, -1 do
        local c = activeConnections[i]
        if c and typeof(c) == "RBXScriptConnection" then
            pcall(function() c:Disconnect() end)
        end
        activeConnections[i] = nil
    end
    effectInstances = {}
    lastAppliedLighting = {}
    lastAppliedEffects = {}
    debugPrint("SoftLighting: cleanup done")
end

if script and script.AncestryChanged then
    safeConnect(script.AncestryChanged, function() if not script:IsDescendantOf(game) then cleanup() end end)
end
pcall(function() game:BindToClose(cleanup) end)

debugPrint("Soft Lighting (FPS-Optimized Final) initialized")
return applySoftLightingInternal
