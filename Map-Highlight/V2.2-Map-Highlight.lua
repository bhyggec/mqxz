--地图高亮 v2.2
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace

local BASE_DEBOUNCE = 0.5
local TARGET_FPS = 60
local ADAPTIVE_CALL_MIN = 2.5
local PERFORMANCE_ADJUST_INTERVAL = 5.0

local PROCESS_FPS_LIMIT = 15
local processMinDt = 1 / PROCESS_FPS_LIMIT

local COLOR_135 = Color3.fromRGB(135,135,135)
local COLOR_230_220_210 = Color3.fromRGB(230,220,210)
local COLOR_210 = Color3.fromRGB(210,210,210)
local COLOR_225 = Color3.fromRGB(225,225,225)

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

local SOFT_CONFIG_KEYS = {
    "Brightness", "GlobalShadows", "Ambient", "ColorShift_Top",
    "ClockTime", "FogEnd", "FogColor", "FogStart"
}

local EFFECTS = {
    ColorCorrection = {class = "ColorCorrectionEffect", settings = {Brightness = -0.04, Contrast = 0.03, Saturation = 0.03}},
    SunRays = {class = "SunRaysEffect", settings = {Intensity = 0.01}},
    Atmosphere = {class = "Atmosphere", settings = {Density = 0.23, Offset = 0.55, Color = COLOR_225}},
    Bloom = {class = "BloomEffect", settings = {Intensity = 0.07, Threshold = 0.8, Size = 16}}
}

local ADAPT_RATE = 0.12
local BLOOM_RANGE = 0.9
local BRIGHT_CORR_RANGE = 0.09

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

local rayDirs = {}
local effectKeys = {}

for name, data in pairs(EFFECTS) do
    local keys = {}
    for k in pairs(data.settings) do
        keys[#keys + 1] = k
    end
    effectKeys[name] = keys
end

local function safeConnect(signal, handler)
    if not signal then return nil end
    local ok, conn = pcall(function() return signal:Connect(handler) end)
    if ok then
        activeConnections[#activeConnections + 1] = conn
        return conn
    end
    return nil
end

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

local lastSampleTime = 0
local cachedSampleResult = nil

local function simpleAmbEstimate()
    local amb = Lighting.Ambient
    return (amb.R + amb.G + amb.B) * ONE_THIRD_255
end

local function sampleSceneBrightness()
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

local function applyAdaptiveBrightness()
    if performanceLevel >= 3 then return end
    
    local cc = effectInstances.ColorCorrection or Lighting:FindFirstChild("ColorCorrection")
    local bloom = effectInstances.Bloom or Lighting:FindFirstChild("Bloom")
    if not cc or not bloom then return end
    
    local env = performanceLevel == 1 and sampleSceneBrightness() or simpleAmbEstimate()
    adaptiveState = adaptiveState + (env - adaptiveState) * ADAPT_RATE
    local inv = 1 - adaptiveState
    
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

local function applySoftLighting()
    for i = 1, 8 do
        local key = SOFT_CONFIG_KEYS[i]
        local value = SOFT_CONFIG[key]
        local current = Lighting[key]
        
        if not valuesEqual(current, value) then
            pcall(function() Lighting[key] = value end)
        end
    end
    
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
        
        local sun = effectInstances.SunRays or Lighting:FindFirstChild("SunRays")
        if sun then
            pcall(function()
                sun.Enabled = performanceLevel <= 2
            end)
        end
    end
end

local function requestApply()
    dirtyFlag = true
end

for i = 1, 8 do
    local prop = SOFT_CONFIG_KEYS[i]
    local signal = Lighting:GetPropertyChangedSignal(prop)
    if signal then
        safeConnect(signal, requestApply)
    end
end

local childSignal = Lighting.ChildAdded
if childSignal then
    safeConnect(childSignal, function(child)
        if EFFECTS[child.Name] then
            effectInstances[child.Name] = child
            requestApply()
        end
    end)
end

local lastProcessTime = 0
local frameCounter = 0

local heartbeatConn = RunService.Heartbeat:Connect(function(dt)
    frameCounter = frameCounter + 1
    
    if frameCounter < 4 then return end
    frameCounter = 0
    
    local now = tick()
    
    if (now - lastProcessTime) < processMinDt then return end
    lastProcessTime = now
    
    if dt > 0 then
        local instantFPS = 1 / dt
        smoothFPS = smoothFPS + (instantFPS - smoothFPS) * FPS_ALPHA
    end
    
    local dynamicDebounce = BASE_DEBOUNCE * math.clamp(TARGET_FPS / math.max(smoothFPS, 1), 1, 3)
    
    if dirtyFlag and (now - lastApplyTime) >= dynamicDebounce then
        pcall(applySoftLighting)
    end
    
    if (now - lastAdaptiveTime) >= ADAPTIVE_CALL_MIN then
        lastAdaptiveTime = now
        pcall(applyAdaptiveBrightness)
    end
    
    if (now - lastPerformanceAdjustTime) >= PERFORMANCE_ADJUST_INTERVAL then
        lastPerformanceAdjustTime = now
        pcall(adjustPerformanceLevel)
    end
end)

table.insert(activeConnections, heartbeatConn)

local function initialize()
    pcall(function() getEffectInstance("Bloom") end)
    pcall(function() getEffectInstance("ColorCorrection") end)
    
    task.wait(0.5)
    pcall(applySoftLighting)
end

pcall(initialize)

task.spawn(function()
    while true do
        task.wait(45)
        if not dirtyFlag then
            dirtyFlag = true
        end
    end
end)

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

if script then
    safeConnect(script.AncestryChanged, function()
        if not script:IsDescendantOf(game) then
            cleanup()
        end
    end)
end

if game.BindToClose then
    pcall(function()
        game:BindToClose(function()
            cleanup()
        end)
    end)
end

if DEBUG then
end

return applySoftLighting