--地图高亮 v2.0
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local BASE_DEBOUNCE = 0.35
local MAX_DEBOUNCE_SCALE = 4
local TARGET_FPS = 60
local ADAPTIVE_CALL_MIN = 0.75
local ADAPTIVE_CALL_MAX = 4

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
for i, d in ipairs(EFFECTS_DATA) do EFFECTS_LOOKUP[d.name] = i end

local ADAPT_RATE = 0.28
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

local function safeConnect(signal, handler)
    local conn = signal:Connect(function(...)
        local ok, err = pcall(handler, ...)
        if not ok and DEBUG then
            warn("[SoftLighting] Connection handler error:", err)
        end
    end)
    table.insert(activeConnections, conn)
    return conn
end

for _, data in ipairs(EFFECTS_DATA) do
    local keys = {}
    for k, _ in pairs(data.settings) do keys[#keys+1] = k end
    data._settings_keys = keys
end

local function valuesEqual(a, b)
    if a == b then return true end
    local ta = typeof(a)
    if ta ~= typeof(b) then return false end
    if ta == "Color3" then return a.R == b.R and a.G == b.G and a.B == b.B end
    if ta == "Vector3" then return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
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
    local changed = false
    for i = 1, #keys do
        local key = keys[i]
        local value = config[key]
        if value ~= nil then
            if safeSetProperty(obj, key, value, cache) then
                changed = true
            end
        end
    end
    return changed
end

local function getOrCreateEffect(name, className)
    local cached = effectInstances[name]
    if cached and cached.Parent and cached.ClassName == className then
        return cached
    end

    local existing = Lighting:FindFirstChild(name)
    if existing and existing.ClassName == className then
        effectInstances[name] = existing
        return existing
    end

    if existing then
        pcall(function() existing:Destroy() end)
    end

    local ok, inst = pcall(function()
        local i = Instance.new(className)
        i.Name = name
        i.Parent = Lighting
        return i
    end)
    if ok and inst then
        effectInstances[name] = inst
        return inst
    end
    return nil
end

local function estimateBrightness()
    local amb = Lighting.Ambient
    local ambAvg = (amb.R + amb.G + amb.B) * 0.33333333
    local exposure = Lighting.ExposureCompensation or 0
    local approx = ambAvg - exposure * 0.25
    if approx < 0 then return 0 elseif approx > 1 then return 1 else return approx end
end

local function applyAdaptiveBrightness()
    local cc = Lighting:FindFirstChild("ColorCorrection")
    local bloom = Lighting:FindFirstChild("Bloom")
    if not cc or not bloom then return end

    local env = estimateBrightness()
    adaptiveState = adaptiveState + (env - adaptiveState) * ADAPT_RATE
    local inv = 1 - adaptiveState

    local bloomScale = MIN_BLOOM_SCALE + (MAX_BLOOM_SCALE - MIN_BLOOM_SCALE) * inv
    local ccBrightness = MIN_BRIGHT_CORR + (MAX_BRIGHT_CORR - MIN_BRIGHT_CORR) * inv
    local ccSaturation = 0.03 * (0.6 + 0.4 * inv)

    pcall(function()
        bloom.Intensity = (EFFECTS_DATA[4] and EFFECTS_DATA[4].settings.Intensity or 0.07) * bloomScale
        cc.Brightness = ccBrightness
        cc.Saturation = ccSaturation
    end)
end

local function applySoftLightingInternal()
    local now = tick()
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

    lastApplyTime = now
    dirtyFlag = false
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

local heartbeatConn = RunService.Heartbeat:Connect(function(dt)
    if dt and dt > 0 then
        local instantFPS = 1 / dt
        smoothFPS = smoothFPS + (instantFPS - smoothFPS) * FPS_ALPHA
    end

    local now = tick()
    local fpsRatio = math.clamp(TARGET_FPS / math.max(smoothFPS, 1), 1, MAX_DEBOUNCE_SCALE)
    local dynamicDebounce = BASE_DEBOUNCE * fpsRatio

    if dirtyFlag and (now - lastApplyTime) >= dynamicDebounce then
        local ok, err = pcall(applySoftLightingInternal)
        if not ok and DEBUG then warn("[SoftLighting] apply error:", err) end
    end

    local adaptiveInterval = math.clamp(dynamicDebounce * 1.5, ADAPTIVE_CALL_MIN, ADAPTIVE_CALL_MAX)
    if now - lastAdaptiveTime >= adaptiveInterval then
        lastAdaptiveTime = now
        pcall(applyAdaptiveBrightness)
    end
end)
table.insert(activeConnections, heartbeatConn)

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
    initializeCaches()
    applySoftLightingInternal()
    applyAdaptiveBrightness()
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
    while task.wait(60) do
        requestApply()
    end
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
    safeConnect(script.AncestryChanged, function()
        if not script:IsDescendantOf(game) then cleanup() end
    end)
end

pcall(function() game:BindToClose(cleanup) end)

debugPrint("Soft Lighting (Deep-Optimized) initialized successfully")
return applySoftLightingInternal