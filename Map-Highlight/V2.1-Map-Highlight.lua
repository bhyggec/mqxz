--地图高亮 v2.1
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = workspace

local BASE_DEBOUNCE = 0.35
local MAX_DEBOUNCE_SCALE = 4
local TARGET_FPS = 60
local ADAPTIVE_CALL_MIN = 0.9
local ADAPTIVE_CALL_MAX = 6

local RAY_SAMPLE_DIRECTIONS = 3
local RAY_DISTANCE = 50
local SAMPLE_INTERVAL_MIN = 2.0
local SAMPLE_INTERVAL_MAX = 6.0
local lastSampleTime = 0
local cachedSampleResult = nil

local STEPPED_PROCESS_FPS_LIMIT = 30

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

local ADAPT_RATE = 0.20
local MAX_BLOOM_SCALE = 1.2
local MIN_BLOOM_SCALE = 0.35
local MAX_BRIGHT_CORR = -0.01
local MIN_BRIGHT_CORR = -0.09

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

local PERFORMANCE_THRESHOLD = 30
local performanceLevel = 1

local rayParams = RaycastParams.new()
rayParams.FilterDescendantsInstances = {}
rayParams.FilterType = Enum.RaycastFilterType.Blacklist
rayParams.IgnoreWater = false

local function safeConnect(signal, handler)
    local conn = signal:Connect(function(...)
        local ok, err = pcall(handler, ...)
        if not ok and DEBUG then warn("[SoftLighting] connection handler error:", err) end
    end)
    table.insert(activeConnections, conn)
    return conn
end

for _, data in ipairs(EFFECTS_DATA) do
    local keys = {}
    for k,_ in pairs(data.settings) do keys[#keys+1] = k end
    data._settings_keys = keys
end

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

local function preCreateEffects()
    for _, d in ipairs(EFFECTS_DATA) do
        if d.enabled then
            pcall(function() getOrCreateEffect(d.name, d.class) end)
        end
    end
end

local function luminanceFromColor3(col)
    return 0.2126 * col.R + 0.7152 * col.G + 0.0722 * col.B
end

local function sampleSceneBrightnessOnce()
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local origin = cam.CFrame.Position

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

local function sampleSceneBrightness()
    local now = tick()
    local sampleInterval = math.clamp(SAMPLE_INTERVAL_MIN, SAMPLE_INTERVAL_MIN, SAMPLE_INTERVAL_MAX)
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

local function simpleAmbEstimate()
    local amb = Lighting.Ambient
    return ((amb.R + amb.G + amb.B) / 3) / 255
end

local function advancedEstimateBrightness()
    local baseAmb = simpleAmbEstimate()
    local samp = sampleSceneBrightness()
    if samp == nil then return math.clamp(baseAmb, 0, 1) end
    local weightSample = 0.7
    local combined = samp * weightSample + baseAmb * (1 - weightSample)
    return math.clamp(combined, 0, 1)
end

local function applyAdaptiveBrightnessAdvanced()
    local cc = Lighting:FindFirstChild("ColorCorrection")
    local bloom = Lighting:FindFirstChild("Bloom")
    if not cc or not bloom then return end

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
        if performanceLevel == 1 then
            bloom.Intensity = (EFFECTS_DATA[4] and EFFECTS_DATA[4].settings.Intensity or 0.07) * bloomScale
            cc.Brightness = ccBrightness
            cc.Saturation = ccSaturation
        elseif performanceLevel == 2 then
            bloom.Intensity = math.max(0.02, (EFFECTS_DATA[4] and EFFECTS_DATA[4].settings.Intensity or 0.07) * (bloomScale * 0.7))
            cc.Brightness = ccBrightness * 0.7
            cc.Saturation = ccSaturation * 0.7
        else
            bloom.Intensity = 0.02
            cc.Brightness = ccBrightness * 0.4
            cc.Saturation = math.max(0, ccSaturation * 0.4)
        end

        if env > 0.78 then
            Lighting.ExposureCompensation = (Lighting.ExposureCompensation or 0) - 0.02
        end
    end)
end

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

local function adjustPerformanceLevel()
    if smoothFPS < PERFORMANCE_THRESHOLD then
        if performanceLevel < 3 then
            performanceLevel = performanceLevel + 1
            local bloom = Lighting:FindFirstChild("Bloom")
            if bloom then pcall(function() bloom.Intensity = 0.02 end) end
            local sun = Lighting:FindFirstChild("SunRays")
            if sun then pcall(function() sun.Enabled = false end) end
            RAY_SAMPLE_DIRECTIONS = math.max(1, RAY_SAMPLE_DIRECTIONS - 1)
            SAMPLE_INTERVAL_MIN = math.min(6.0, SAMPLE_INTERVAL_MIN * 1.5)
        end
    else
        if performanceLevel > 1 and smoothFPS > (PERFORMANCE_THRESHOLD + 10) then
            performanceLevel = performanceLevel - 1
            RAY_SAMPLE_DIRECTIONS = math.max(1, RAY_SAMPLE_DIRECTIONS + 1)
            SAMPLE_INTERVAL_MIN = math.max(1.5, SAMPLE_INTERVAL_MIN / 1.5)
            local sun = Lighting:FindFirstChild("SunRays")
            if sun then pcall(function() sun.Enabled = true end) end
            local bloom = Lighting:FindFirstChild("Bloom")
            if bloom then pcall(function() bloom.Intensity = 0.05 end) end
        end
    end
end

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

local steppedConn = RunService.Stepped:Connect(function(_, dt)
    local now = tick()
    if (now - lastSteppedTime) < steppedMinDt then return end
    lastSteppedTime = now

    if dt and dt > 0 then
        local instantFPS = 1 / dt
        smoothFPS = smoothFPS + (instantFPS - smoothFPS) * FPS_ALPHA
    end

    local fpsRatio = math.clamp(TARGET_FPS / math.max(smoothFPS, 1), 1, MAX_DEBOUNCE_SCALE)
    local dynamicDebounce = BASE_DEBOUNCE * fpsRatio

    if dirtyFlag and (now - lastApplyTime) >= dynamicDebounce then
        pcall(applySoftLightingInternal)
    end

    local adaptiveInterval = math.clamp(dynamicDebounce * 1.5, ADAPTIVE_CALL_MIN, ADAPTIVE_CALL_MAX)
    if (now - lastAdaptiveTime) >= adaptiveInterval then
        lastAdaptiveTime = now
        pcall(function()
            if performanceLevel >= 3 then
                adaptiveState = adaptiveState + (simpleAmbEstimate() - adaptiveState) * ADAPT_RATE
            else
                applyAdaptiveBrightnessAdvanced()
            end
        end)
    end

    adjustPerformanceLevel()
end)
table.insert(activeConnections, steppedConn)

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

task.spawn(function()
    while task.wait(60) do requestApply() end
end)

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