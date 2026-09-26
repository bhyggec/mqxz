--地图高亮 v2.0.3
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace

local MATH_CLAMP = math.clamp or function(x,a,b) if x < a then return a elseif x > b then return b else return x end end
local MATH_ABS = math.abs
local TICK = tick
local TASK_WAIT = (task and task.wait) or wait
local SPAWN = spawn or function(f) task.spawn(f) end

local TARGET_FPS = 60
local BASE_DEBOUNCE = 0.5
local PERFORMANCE_ADJUST_INTERVAL = 60.0

local LUM_R = 0.2126 / 255
local LUM_G = 0.7152 / 255
local LUM_B = 0.0722 / 255
local ONE_THIRD_255 = 1 / (3 * 255)

local SOFT_CONFIG = {
    Brightness = 0.85,
    GlobalShadows = true,
    Ambient = Color3.fromRGB(135,135,135),
    ColorShift_Top = Color3.fromRGB(230,220,210),
    ClockTime = 15,
    FogEnd = 850,
    FogColor = Color3.fromRGB(210,210,210),
    FogStart = 0,
}
local SOFT_CONFIG_KEYS = {
    "Brightness","GlobalShadows","Ambient","ColorShift_Top",
    "ClockTime","FogEnd","FogColor","FogStart"
}

local EFFECTS = {
    ColorCorrection = {class = "ColorCorrectionEffect", settings = {Brightness = -0.04, Contrast = 0.03, Saturation = 0.03}},
    SunRays = {class = "SunRaysEffect", settings = {Intensity = 0.01, Enabled = true}},
    Atmosphere = {class = "Atmosphere", settings = {Density = 0.23, Offset = 0.55, Color = Color3.fromRGB(225,225,225)}},
    Bloom = {class = "BloomEffect", settings = {Intensity = 0.07, Threshold = 0.8, Size = 16}}
}

local ADAPT_RATE = 0.12
local BLOOM_RANGE = 0.9
local BRIGHT_CORR_RANGE = 0.09
local BRIGHT_CORR_BASE = -0.04

local DEBUG = false

local effectInstances = {}
local effectKeys = {}
local lastAppliedValues = {}
local activeDirty = false
local lastApplyTime = 0
local smoothFPS = TARGET_FPS
local lastAdaptiveTime = 0
local lastPerformanceAdjustTime = 0
local adaptiveState = 0.5
local performanceLevel = 1

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
raycastParams.IgnoreWater = true

local precomputedAngles = { CFrame.Angles(0.1,0.1,0), CFrame.Angles(-0.08,0.06,0) }
local rayResults = { nil, nil }
local sampleCounter = 0
local sampleSkipFrames = 0
local lastValidSampleTime = 0

local lastCameraPosition = Vector3.new()
local cameraMovedThreshold = 1.5

local performanceMonitor = {
    frameTimes = {},
    count = 0,
    maxSamples = 120,
    reset = function(self)
        self.frameTimes = {}
        self.count = 0
    end,
    record = function(self, dt)
        if dt and dt > 0 then
            if #self.frameTimes >= self.maxSamples then table.remove(self.frameTimes, 1) end
            table.insert(self.frameTimes, dt)
            self.count = self.count + 1
        end
    end,
    score = function(self)
        if #self.frameTimes < 20 then return 1 end
        local total, maxDt, minDt = 0, 0, 1e9
        for _, dt in ipairs(self.frameTimes) do
            total = total + dt
            if dt > maxDt then maxDt = dt end
            if dt < minDt then minDt = dt end
        end
        local avg = total / #self.frameTimes
        local consistency = (maxDt - minDt) / (avg ~= 0 and avg or 1)
        local fpsRel = MATH_CLAMP((1 / avg) / 60, 0, 1)
        local consistencyScore = MATH_CLAMP(1 - consistency * 0.5, 0, 1)
        return (fpsRel * 0.7 + consistencyScore * 0.3)
    end
}

for name,data in pairs(EFFECTS) do
    local ks = {}
    for k in pairs(data.settings) do ks[#ks+1] = k end
    effectKeys[name] = ks
end

local weakConnections = setmetatable({}, { __mode = "k" })
local strongConnections = {}

local function safeConnect(signal, handler)
    if not signal then return nil end
    local ok, conn = pcall(function() return signal:Connect(handler) end)
    if ok and conn then table.insert(strongConnections, conn); return conn end
    return nil
end

local function safeConnectWeak(signal, handler)
    if not signal then return nil end
    local ok, conn = pcall(function() return signal:Connect(handler) end)
    if ok and conn then weakConnections[conn] = true; return conn end
    return nil
end

local function delayFunc(seconds, callback)
    if task and task.delay then
        task.delay(seconds, callback)
    else
        SPAWN(function() TASK_WAIT(seconds); callback() end)
    end
end

local function valuesEqual(a,b)
    if a == b then return true end
    local ta = typeof(a)
    if ta ~= typeof(b) then return false end
    if ta == "Color3" then
        return MATH_ABS(a.R - b.R) < 0.02 and MATH_ABS(a.G - b.G) < 0.02 and MATH_ABS(a.B - b.B) < 0.02
    elseif ta == "number" then
        return MATH_ABS(a - b) < 0.02
    elseif ta == "boolean" then
        return a == b
    end
    return false
end

local function getEffectInstance(name)
    local cached = effectInstances[name]
    if cached and cached.Parent then return cached end
    local data = EFFECTS[name]
    if not data then return nil end
    local existing = Lighting:FindFirstChild(name)
    if existing and existing.ClassName == data.class then effectInstances[name] = existing; return existing end
    local ok, inst = pcall(function()
        local i = Instance.new(data.class)
        i.Name = name
        for k,v in pairs(data.settings) do i[k] = v end
        i.Parent = Lighting
        return i
    end)
    if ok and inst then effectInstances[name] = inst; return inst end
    return nil
end

local function simpleAmbEstimate()
    local amb = Lighting.Ambient
    return (amb.R + amb.G + amb.B) * ONE_THIRD_255
end

local cachedSampleResult = nil
local lastSampleTime = 0

local function sampleSceneBrightness()
    if performanceLevel >= 2 then return simpleAmbEstimate() end

    local now = TICK()

    sampleSkipFrames = sampleSkipFrames - 1
    if sampleSkipFrames > 0 and cachedSampleResult then return cachedSampleResult end
    if sampleSkipFrames <= 0 then sampleSkipFrames = (performanceLevel == 1) and 2 or 4 end

    local cam = Workspace.CurrentCamera
    if not cam then cachedSampleResult = simpleAmbEstimate(); lastSampleTime = now; return cachedSampleResult end

    local camCFrame = cam.CFrame
    local currentPos = camCFrame.Position
    local currentLook = camCFrame.LookVector

    local posDiff = currentPos - lastCameraPosition
    local positionMoved = (posDiff.X * posDiff.X + posDiff.Y * posDiff.Y + posDiff.Z * posDiff.Z) > (cameraMovedThreshold * cameraMovedThreshold)

    if not positionMoved and cachedSampleResult and (now - lastSampleTime) < 15 then
        lastSampleTime = now
        return cachedSampleResult
    end

    lastCameraPosition = currentPos
    local amb = Lighting.Ambient
    local ambLum = LUM_R * amb.R + LUM_G * amb.G + LUM_B * amb.B

    sampleCounter = sampleCounter + 1
    local rayCount = ((performanceLevel == 1 and (sampleCounter % 3 == 0)) and 2) or 1
    rayCount = MATH_CLAMP(rayCount, 1, 2)

    local total = ambLum * rayCount
    local validHits = 0

    raycastParams.FilterDescendantsInstances = {cam}
    
    for i = 1, rayCount do
        local dir = (i == 1) and currentLook or (camCFrame * precomputedAngles[i]).LookVector
        
        if not rayResults[i] or (now - lastSampleTime) > 20 then
            local ok, r = pcall(function() 
                return Workspace:Raycast(currentPos, dir * 40, raycastParams) 
            end)
            rayResults[i] = ok and r or nil
        end
        
        local result = rayResults[i]
        if result and result.Instance and result.Instance:IsA("BasePart") then
            local col = result.Instance.Color
            local partLum = LUM_R * col.R + LUM_G * col.G + LUM_B * col.B
            total = total - ambLum + partLum
            validHits = validHits + 1
            lastValidSampleTime = now
        end
    end

    if validHits > 0 and (now - lastValidSampleTime) < 30 then
        cachedSampleResult = total / rayCount
    else
        cachedSampleResult = ambLum
    end

    lastSampleTime = now
    return cachedSampleResult
end

local function applyAdaptiveBrightness()
    if performanceLevel >= 3 then return end
    local cc = getEffectInstance("ColorCorrection")
    local bloom = getEffectInstance("Bloom")
    if not cc or not bloom then return end

    local env = (performanceLevel == 1) and sampleSceneBrightness() or simpleAmbEstimate()
    adaptiveState = adaptiveState + (env - adaptiveState) * ADAPT_RATE
    local inv = 1 - adaptiveState
    local intensityScale = (performanceLevel == 1) and 1.0 or 0.5

    local bloomIntensity = 0.07 * (0.3 + BLOOM_RANGE * inv) * intensityScale
    local ccBrightness = BRIGHT_CORR_BASE + BRIGHT_CORR_RANGE * inv * intensityScale

    if not valuesEqual(bloom.Intensity, bloomIntensity) then 
        pcall(function() bloom.Intensity = bloomIntensity end) 
    end
    if not valuesEqual(cc.Brightness, ccBrightness) then 
        pcall(function() cc.Brightness = ccBrightness end) 
    end
end

local function analyzePerformanceTrend()
    return performanceMonitor:score()
end

local function adjustPerformanceLevel()
    local score = analyzePerformanceTrend()
    local fpsBasedLevel
    if smoothFPS < 18 then fpsBasedLevel = 3
    elseif smoothFPS < 28 then fpsBasedLevel = 2
    else fpsBasedLevel = 1
    end

    local newLevel = fpsBasedLevel
    if score < 0.35 then newLevel = MATH_CLAMP(newLevel + 1, 1, 3) end

    if newLevel ~= performanceLevel then
        performanceLevel = newLevel
        
        rayResults = { nil, nil }
        
        activeDirty = true
    end
end

local function createApplySoftLightingOptimized()
    local lastCheckTime = 0
    local checkInterval = 2.0

    return function()
        local now = TICK()
        if not activeDirty and (now - lastCheckTime) < checkInterval then return end
        lastCheckTime = now

        if not activeDirty and (now - lastApplyTime) < 20 then return end

        local needsUpdate = false

        if not valuesEqual(Lighting.Brightness, SOFT_CONFIG.Brightness)
           or not valuesEqual(Lighting.Ambient, SOFT_CONFIG.Ambient)
           or not valuesEqual(Lighting.FogColor, SOFT_CONFIG.FogColor) then
            needsUpdate = true
        end

        if not needsUpdate then
            for i = 1, #SOFT_CONFIG_KEYS do
                local key = SOFT_CONFIG_KEYS[i]
                if key ~= "Brightness" and key ~= "Ambient" and key ~= "FogColor" then
                    if not valuesEqual(Lighting[key], SOFT_CONFIG[key]) then 
                        needsUpdate = true; 
                        break 
                    end
                end
            end
        end

        if not needsUpdate then
            local bloom = getEffectInstance("Bloom")
            local colorCorrection = getEffectInstance("ColorCorrection")
            if not bloom or not colorCorrection then
                needsUpdate = true
            end
        end

        if not needsUpdate then 
            activeDirty = false; 
            lastApplyTime = now; 
            return 
        end

        local function applyAll()
            for i = 1, #SOFT_CONFIG_KEYS do
                local key = SOFT_CONFIG_KEYS[i]
                Lighting[key] = SOFT_CONFIG[key]
                lastAppliedValues[key] = SOFT_CONFIG[key]
            end
            
            for name, data in pairs(EFFECTS) do
                local effect = getEffectInstance(name)
                if effect then
                    local ks = effectKeys[name]
                    for j = 1, #ks do
                        local k = ks[j]
                        effect[k] = data.settings[k]
                        lastAppliedValues[name .. "_" .. k] = data.settings[k]
                    end
                end
            end
        end

        local ok = pcall(applyAll)
        if ok then 
            lastApplyTime = now; 
            activeDirty = false 
        end
    end
end

local applySoftLighting = createApplySoftLightingOptimized()

local function createOptimizedLoop()
    local accumulated = 0
    local updateInterval = 0.05
    local lastFPSUpdate = 0
    local debounceFactors = {}
    for i = 1, 60 do 
        debounceFactors[i] = BASE_DEBOUNCE * (TARGET_FPS / math.max(i, 20)) 
    end

    return function(time, dt)
        if not dt or dt <= 0 then return end

        if performanceLevel == 3 and smoothFPS > 15 then return end

        accumulated = accumulated + dt

        if performanceLevel == 1 then 
            updateInterval = 0.05
        elseif performanceLevel == 2 then 
            updateInterval = 0.083
        else 
            updateInterval = 0.125 
        end

        if accumulated < updateInterval then return end

        local actualDt = accumulated
        accumulated = 0
        local now = TICK()

        if actualDt > 0.002 and (now - lastFPSUpdate) > 0.5 then
            local instantFPS = 1 / actualDt
            if instantFPS > 300 then instantFPS = 300 end
            smoothFPS = smoothFPS * 0.9 + instantFPS * 0.1
            lastFPSUpdate = now
        end

        performanceMonitor:record(actualDt)

        local debounceIndex = MATH_CLAMP(math.floor(MATH_CLAMP(smoothFPS, 1, 60)), 1, 60)
        local debounceThreshold = debounceFactors[debounceIndex]

        if activeDirty and (now - lastApplyTime) >= debounceThreshold then 
            pcall(applySoftLighting) 
        end

        local adaptiveInterval = (performanceLevel == 1 and 3) or (performanceLevel == 2 and 4) or 6
        if (now - lastAdaptiveTime) >= adaptiveInterval then 
            lastAdaptiveTime = now; 
            pcall(applyAdaptiveBrightness) 
        end

        if (now - lastPerformanceAdjustTime) >= PERFORMANCE_ADJUST_INTERVAL then 
            lastPerformanceAdjustTime = now; 
            pcall(adjustPerformanceLevel) 
        end
    end
end

local applyDelay = false

local function setupOptimizedListeners()
    local function onAnyPropertyChange()
        activeDirty = true
        if not applyDelay then
            applyDelay = true
            delayFunc(0.1, function()
                applyDelay = false
                if activeDirty then pcall(applySoftLighting) end
            end)
        end
    end

    for _, key in ipairs(SOFT_CONFIG_KEYS) do
        local sig = Lighting:GetPropertyChangedSignal(key)
        if sig then safeConnectWeak(sig, onAnyPropertyChange) end
    end

    safeConnectWeak(Lighting.ChildAdded, function(child)
        if EFFECTS[child.Name] then 
            effectInstances[child.Name] = child; 
            activeDirty = true 
        end
    end)
    
    safeConnectWeak(Lighting.ChildRemoved, function(child)
        if effectInstances[child.Name] == child then 
            effectInstances[child.Name] = nil; 
            activeDirty = true 
        end
    end)
end

local function delayedInitialize()
    for i = 1, 30 do
        if Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame then break end
        TASK_WAIT(0.1)
    end

    SPAWN(function()
        pcall(function() getEffectInstance("Bloom") end)
        TASK_WAIT(0.1)
        pcall(function() getEffectInstance("ColorCorrection") end)
        TASK_WAIT(0.1)
        setupOptimizedListeners()
        TASK_WAIT(0.1)
        pcall(applySoftLighting)
    end)
end

SPAWN(delayedInitialize)

local mainConn = nil
local ok, err = pcall(function() 
    mainConn = RunService.Stepped:Connect(function(time, dt) 
        createOptimizedLoop()(time, dt) 
    end) 
end)

if not ok or not mainConn then
    mainConn = RunService.Heartbeat:Connect(function(dt) 
        createOptimizedLoop()(TICK(), dt) 
    end)
end

if mainConn then weakConnections[mainConn] = true end

SPAWN(function()
    while true do
        TASK_WAIT(45)
        if not activeDirty then activeDirty = true end
    end
end)

local function cleanup()
    for conn in pairs(weakConnections) do 
        if conn then pcall(function() conn:Disconnect() end) end 
    end
    for i = #strongConnections,1,-1 do 
        local c = strongConnections[i]; 
        if c then pcall(function() c:Disconnect() end) end 
    end

    local childrenToRemove = {}
    for name, inst in pairs(effectInstances) do 
        if inst and inst.Parent == Lighting then 
            table.insert(childrenToRemove, inst) 
        end 
    end
    for _, inst in ipairs(childrenToRemove) do 
        pcall(function() inst.Parent = nil end) 
    end

    weakConnections = setmetatable({}, { __mode = "k" })
    strongConnections = {}
    effectInstances = {}
    lastAppliedValues = {}
    cachedSampleResult = nil
    lastSampleTime = 0
    lastCameraPosition = Vector3.new()
    rayResults = { nil, nil }
    performanceMonitor:reset()
end

if script then 
    safeConnect(script.AncestryChanged, function() 
        if not script:IsDescendantOf(game) then cleanup() end 
    end) 
end

if game.BindToClose then 
    pcall(function() game:BindToClose(cleanup) end) 
end

if DEBUG then
    safeConnect(RunService.Heartbeat, function(dt)
        print(string.format("FPS: %.1f, PerfLevel: %d, Adaptive: %.3f", 
              smoothFPS, performanceLevel, adaptiveState))
    end)
end

return applySoftLighting