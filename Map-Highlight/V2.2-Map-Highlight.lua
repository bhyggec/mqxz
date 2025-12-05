-- Soft Lighting (Ultimate Optimized) - v3
-- 终极优化：最低CPU开销、全功能保留、极致防错、纯本地运行

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace

-- ====================== 极致优化配置 ======================
local BASE_DEBOUNCE = 0.5
local TARGET_FPS = 60
local ADAPTIVE_CALL_MIN = 2.5
local PERFORMANCE_ADJUST_INTERVAL = 5.0

local PROCESS_FPS_LIMIT = 15  -- 进一步降低处理频率
local processMinDt = 1 / PROCESS_FPS_LIMIT

-- 预计算所有常量（避免运行时计算）
local COLOR_135 = Color3.fromRGB(135,135,135)
local COLOR_230_220_210 = Color3.fromRGB(230,220,210)
local COLOR_210 = Color3.fromRGB(210,210,210)
local COLOR_225 = Color3.fromRGB(225,225,225)

-- 亮度转换预计算
local LUM_R = 0.2126 / 255
local LUM_G = 0.7152 / 255
local LUM_B = 0.0722 / 255
local ONE_THIRD_255 = 1 / (3 * 255)

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

-- 配置键数组（直接硬编码避免表操作）
local SOFT_CONFIG_KEYS = {
    "Brightness", "GlobalShadows", "Ambient", "ColorShift_Top",
    "ClockTime", "FogEnd", "FogColor", "FogStart"
}

-- 效果配置（最小化内存占用）
local EFFECTS = {
    ColorCorrection = {class = "ColorCorrectionEffect", settings = {Brightness = -0.04, Contrast = 0.03, Saturation = 0.03}},
    SunRays = {class = "SunRaysEffect", settings = {Intensity = 0.01}},
    Atmosphere = {class = "Atmosphere", settings = {Density = 0.23, Offset = 0.55, Color = COLOR_225}},
    Bloom = {class = "BloomEffect", settings = {Intensity = 0.07, Threshold = 0.8, Size = 16}}
}

-- 自适应参数预计算
local ADAPT_RATE = 0.12
local BLOOM_RANGE = 0.9  -- MAX_BLOOM_SCALE - MIN_BLOOM_SCALE (1.2 - 0.3)
local BRIGHT_CORR_RANGE = 0.09  -- MIN_BRIGHT_CORR - MAX_BRIGHT_CORR (-0.1 - (-0.01))

-- ====================== 极致优化状态管理 ======================
local DEBUG = false
local effectInstances = {}
local dirtyFlag = false
local lastApplyTime = 0
local smoothFPS = TARGET_FPS
local FPS_ALPHA = 0.15
local lastAdaptiveTime = 0
local lastPerformanceAdjustTime = 0
local adaptiveState = 0.5
local activeConnections = {}
local performanceLevel = 1

-- 重用表对象（完全避免运行时分配）
local rayDirs = {}
local effectKeys = {}

-- 预计算效果键名
for name, data in pairs(EFFECTS) do
    local keys = {}
    for k in pairs(data.settings) do
        keys[#keys + 1] = k
    end
    effectKeys[name] = keys
end

-- ====================== 安全函数（最小化开销） ======================
local function safeConnect(signal, handler)
    if not signal then return nil end
    local ok, conn = pcall(function() return signal:Connect(handler) end)
    if ok then
        activeConnections[#activeConnections + 1] = conn
        return conn
    end
    return nil
end

-- 快速值比较（内联优化）
local function valuesEqual(a, b)
    if a == b then return true end
    local ta = typeof(a)
    if ta ~= typeof(b) then return false end
    if ta == "Color3" then
        return math.abs(a.R - b.R) < 0.001 and 
               math.abs(a.G - b.G) < 0.001 and 
               math.abs(a.B - b.B) < 0.001
    end
    return false
end

-- ====================== 效果实例管理（极致优化） ======================
local function getEffectInstance(name)
    local cached = effectInstances[name]
    if cached and cached.Parent then
        return cached
    end
    
    local data = EFFECTS[name]
    if not data then return nil end
    
    local existing = Lighting:FindFirstChild(name)
    if existing and existing.ClassName == data.class then
        effectInstances[name] = existing
        return existing
    end
    
    local ok, inst = pcall(function()
        local i = Instance.new(data.class)
        i.Name = name
        for k, v in pairs(data.settings) do
            i[k] = v
        end
        i.Parent = Lighting
        return i
    end)
    
    if ok then
        effectInstances[name] = inst
        return inst
    end
    
    return nil
end

-- ====================== 场景采样（超低开销） ======================
local lastSampleTime = 0
local cachedSampleResult = nil

local function simpleAmbEstimate()
    local amb = Lighting.Ambient
    return (amb.R + amb.G + amb.B) * ONE_THIRD_255
end

local function sampleSceneBrightness()
    -- 低性能时完全跳过采样
    if performanceLevel >= 2 then
        return simpleAmbEstimate()
    end
    
    local now = tick()
    if cachedSampleResult and (now - lastSampleTime) < 5.0 then
        return cachedSampleResult
    end
    
    local cam = Workspace.CurrentCamera
    if not cam then
        cachedSampleResult = simpleAmbEstimate()
        return cachedSampleResult
    end
    
    local origin = cam.CFrame.Position
    local fwd = cam.CFrame.LookVector
    
    -- 仅使用1-2个方向（极简采样）
    rayDirs[1] = fwd
    rayDirs[2] = (cam.CFrame * CFrame.Angles(0.1, 0.1, 0)).LookVector
    
    local total = 0
    local count = 0
    
    for i = 1, 2 do
        local dir = rayDirs[i]
        if not dir then break end
        
        local ok, result = pcall(function()
            return Workspace:Raycast(origin, dir * 40, RaycastParams.new())
        end)
        
        if ok and result then
            local lum
            local inst = result.Instance
            if inst and inst:IsA("BasePart") then
                local col = inst.Color
                lum = LUM_R * col.R + LUM_G * col.G + LUM_B * col.B
            else
                local amb = Lighting.Ambient
                lum = LUM_R * amb.R + LUM_G * amb.G + LUM_B * amb.B
            end
            total = total + lum
            count = count + 1
        end
    end
    
    cachedSampleResult = count > 0 and total / count or simpleAmbEstimate()
    lastSampleTime = now
    return cachedSampleResult
end

-- ====================== 自适应亮度（超低频率） ======================
local function applyAdaptiveBrightness()
    if performanceLevel >= 3 then return end
    
    local cc = effectInstances.ColorCorrection or Lighting:FindFirstChild("ColorCorrection")
    local bloom = effectInstances.Bloom or Lighting:FindFirstChild("Bloom")
    if not cc or not bloom then return end
    
    local env = performanceLevel == 1 and sampleSceneBrightness() or simpleAmbEstimate()
    adaptiveState = adaptiveState + (env - adaptiveState) * ADAPT_RATE
    local inv = 1 - adaptiveState
    
    -- 根据性能等级调整强度
    local intensityScale = performanceLevel == 1 and 1.0 or 0.5
    
    local bloomIntensity = 0.07 * (0.3 + BLOOM_RANGE * inv) * intensityScale
    local ccBrightness = -0.1 + BRIGHT_CORR_RANGE * inv * intensityScale
    
    pcall(function()
        if not valuesEqual(bloom.Intensity, bloomIntensity) then
            bloom.Intensity = bloomIntensity
        end
        if not valuesEqual(cc.Brightness, ccBrightness) then
            cc.Brightness = ccBrightness
        end
    end)
end

-- ====================== 主应用逻辑（最小化属性设置） ======================
local function applySoftLighting()
    -- 基础光照设置（仅修改必要属性）
    for i = 1, 8 do
        local key = SOFT_CONFIG_KEYS[i]
        local value = SOFT_CONFIG[key]
        local current = Lighting[key]
        
        if not valuesEqual(current, value) then
            pcall(function() Lighting[key] = value end)
        end
    end
    
    -- 效果设置（按需创建和更新）
    for name, data in pairs(EFFECTS) do
        local effect = getEffectInstance(name)
        if effect then
            local settings = data.settings
            local keys = effectKeys[name]
            
            for j = 1, #keys do
                local key = keys[j]
                local value = settings[key]
                local current = effect[key]
                
                if not valuesEqual(current, value) then
                    pcall(function() effect[key] = value end)
                end
            end
        end
    end
    
    lastApplyTime = tick()
    dirtyFlag = false
end

-- ====================== 性能调整（极简） ======================
local function adjustPerformanceLevel()
    local newLevel
    if smoothFPS < 20 then
        newLevel = 3
    elseif smoothFPS < 30 then
        newLevel = 2
    else
        newLevel = 1
    end
    
    if newLevel ~= performanceLevel then
        performanceLevel = newLevel
        
        -- 根据性能等级调整效果
        local sun = effectInstances.SunRays or Lighting:FindFirstChild("SunRays")
        if sun then
            pcall(function()
                sun.Enabled = performanceLevel <= 2
            end)
        end
    end
end

-- ====================== 事件监听（最小化） ======================
local function requestApply()
    dirtyFlag = true
end

-- 监听主要属性变化
for i = 1, 8 do
    local prop = SOFT_CONFIG_KEYS[i]
    local signal = Lighting:GetPropertyChangedSignal(prop)
    if signal then
        safeConnect(signal, requestApply)
    end
end

-- 统一监听效果实例变化
local childSignal = Lighting.ChildAdded
if childSignal then
    safeConnect(childSignal, function(child)
        if EFFECTS[child.Name] then
            effectInstances[child.Name] = child
            requestApply()
        end
    end)
end

-- ====================== 主循环（超低频率） ======================
local lastProcessTime = 0
local frameCounter = 0

local heartbeatConn = RunService.Heartbeat:Connect(function(dt)
    frameCounter = frameCounter + 1
    
    -- 每4帧处理一次（进一步降低频率）
    if frameCounter < 4 then return end
    frameCounter = 0
    
    local now = tick()
    
    -- 限制处理频率
    if (now - lastProcessTime) < processMinDt then return end
    lastProcessTime = now
    
    -- 简化FPS计算
    if dt > 0 then
        local instantFPS = 1 / dt
        smoothFPS = smoothFPS + (instantFPS - smoothFPS) * FPS_ALPHA
    end
    
    -- 动态防抖
    local dynamicDebounce = BASE_DEBOUNCE * math.clamp(TARGET_FPS / math.max(smoothFPS, 1), 1, 3)
    
    -- 应用设置
    if dirtyFlag and (now - lastApplyTime) >= dynamicDebounce then
        pcall(applySoftLighting)
    end
    
    -- 自适应亮度（低频）
    if (now - lastAdaptiveTime) >= ADAPTIVE_CALL_MIN then
        lastAdaptiveTime = now
        pcall(applyAdaptiveBrightness)
    end
    
    -- 性能调整（最低频率）
    if (now - lastPerformanceAdjustTime) >= PERFORMANCE_ADJUST_INTERVAL then
        lastPerformanceAdjustTime = now
        pcall(adjustPerformanceLevel)
    end
end)

table.insert(activeConnections, heartbeatConn)

-- ====================== 初始化（极简） ======================
local function initialize()
    -- 预创建主要效果
    pcall(function() getEffectInstance("Bloom") end)
    pcall(function() getEffectInstance("ColorCorrection") end)
    
    -- 延迟应用初始设置
    task.wait(0.5)
    pcall(applySoftLighting)
end

pcall(initialize)

-- 周期保底触发
task.spawn(function()
    while true do
        task.wait(45)  -- 更长间隔
        if not dirtyFlag then
            dirtyFlag = true
        end
    end
end)

-- ====================== 清理机制 ======================
local function cleanup()
    for i = #activeConnections, 1, -1 do
        local conn = activeConnections[i]
        if conn then
            pcall(function() conn:Disconnect() end)
        end
    end
    
    for name, inst in pairs(effectInstances) do
        if inst and inst.Parent == Lighting then
            pcall(function() inst.Parent = nil end)
        end
    end
    
    activeConnections = {}
    effectInstances = {}
end

-- 脚本卸载时清理
if script then
    safeConnect(script.AncestryChanged, function()
        if not script:IsDescendantOf(game) then
            cleanup()
        end
    end)
end

-- 游戏关闭时清理
if game.BindToClose then
    pcall(function()
        game:BindToClose(function()
            cleanup()
        end)
    end)
end

if DEBUG then
    print("[SoftLighting] 终极优化版 v3 已加载")
end

return applySoftLighting