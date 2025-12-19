--地图高亮 v1.5
local Lighting = game:GetService("Lighting")
local task = task

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
    ColorCorrection = { enabled = true, class = "ColorCorrectionEffect", settings = { Brightness = -0.02, Contrast = 0.04, Saturation = 0.05 } },
    SunRays = { enabled = true, class = "SunRaysEffect", settings = { Intensity = 0.01 } },
    Atmosphere = { enabled = true, class = "Atmosphere", settings = { Density = 0.25, Offset = 0.6, Color = Color3.fromRGB(220, 220, 220) } },
    Bloom = { enabled = true, class = "BloomEffect", settings = { Intensity = 0.1, Threshold = 0.75, Size = 18 } },
}

local pcall_local = pcall
local tick_local = tick
local scriptRef = script

local effectInstances = {}
local effectInstanceCache = setmetatable({}, { __mode = "v" })
local effectClassCache = {}
local lastAppliedLighting = {}
local lastAppliedEffects = {}
local connections = {}
local periodicTasks = {}
local dirty = false
local applyScheduled = false

local importantPropsSet = {
    Brightness = true, GlobalShadows = true, Ambient = true, ColorShift_Top = true,
    ClockTime = true, FogEnd = true, FogColor = true, FogStart = true
}

local function shallowEqual(a, b)
    if a == b then return true end
    if (a == nil) ~= (b == nil) then return false end
    local ta = typeof(a)
    if ta ~= typeof(b) then return false end
    if ta == "Color3" then return a.R == b.R and a.G == b.G and a.B == b.B end
    if ta == "Vector3" then return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
    return a == b
end

local function safeSetProperties(object, propertyTable)
    if not object then return end
    local changed = {}
    for prop, value in pairs(propertyTable) do
        local ok, current = pcall_local(function() return object[prop] end)
        if ok and not shallowEqual(current, value) then changed[prop] = value end
    end
    if next(changed) then
        pcall_local(function()
            for prop, value in pairs(changed) do object[prop] = value end
        end)
    end
end

local function applyConfigToObjectWithCache(object, config, cache)
    local changedConfig = {}
    for prop, value in pairs(config) do
        if cache[prop] == nil or not shallowEqual(cache[prop], value) then
            changedConfig[prop] = value
            cache[prop] = value
        end
    end
    if next(changedConfig) then safeSetProperties(object, changedConfig) end
end

local function shouldUpdateConfig(config, cache)
    for prop, value in pairs(config) do
        if cache[prop] == nil or not shallowEqual(cache[prop], value) then return true end
    end
    return false
end

local function createCancellablePeriodicTask(interval, callback)
    local running = true
    task.spawn(function()
        while running do
            pcall_local(callback)
            if not running then break end
            task.wait(interval)
        end
    end)
    local function cancel() running = false end
    periodicTasks[#periodicTasks + 1] = cancel
    return cancel
end

local function cleanup()
    for _, conn in ipairs(connections) do pcall_local(function() conn:Disconnect() end) end
    connections = {}
    for _, cancelFunc in ipairs(periodicTasks) do pcall_local(cancelFunc) end
    periodicTasks = {}
    effectInstances = {}
    effectInstanceCache = setmetatable({}, { __mode = "v" })
    effectClassCache = {}
    lastAppliedEffects = {}
    lastAppliedLighting = {}
end

local function getOrCreateEffect(name, className)
    local inst = effectInstanceCache[name]
    if inst and inst.Parent and inst:IsA(className) then effectInstances[name] = inst; return inst end
    local strong = effectInstances[name]
    if strong and strong.Parent and strong:IsA(className) then effectInstanceCache[name] = strong; return strong end
    effectClassCache[name] = effectClassCache[name] or className
    local found = Lighting:FindFirstChild(name)
    if found and found:IsA(className) then effectInstances[name] = found; effectInstanceCache[name] = found; return found end
    if found then pcall_local(function() found:Destroy() end) end
    local effect = Instance.new(className)
    effect.Name = name
    effect.Parent = Lighting
    effectInstances[name] = effect
    effectInstanceCache[name] = effect
    return effect
end

local function applySoftLightingInternal()
    if shouldUpdateConfig(SOFT_CONFIG, lastAppliedLighting) then
        applyConfigToObjectWithCache(Lighting, SOFT_CONFIG, lastAppliedLighting)
    end
    for name, data in pairs(EFFECTS) do
        if data.enabled then
            local effect = getOrCreateEffect(name, data.class)
            lastAppliedEffects[name] = lastAppliedEffects[name] or {}
            if shouldUpdateConfig(data.settings, lastAppliedEffects[name]) then
                applyConfigToObjectWithCache(effect, data.settings, lastAppliedEffects[name])
            end
        else
            local existing = Lighting:FindFirstChild(name)
            if existing then pcall_local(function() existing:Destroy() end) end
            effectInstances[name] = nil
            lastAppliedEffects[name] = nil
            effectInstanceCache[name] = nil
        end
    end
end

local function scheduleApply()
    if applyScheduled then return end
    applyScheduled = true
    task.delay(DEBOUNCE_TIME, function()
        applyScheduled = false
        if dirty then dirty = false; pcall_local(applySoftLightingInternal) end
    end)
end

local function requestApply() dirty = true; scheduleApply() end

local function addConnection(conn) if conn and typeof(conn) == "RBXScriptConnection" then connections[#connections + 1] = conn end end

local childChangeQueue = {}
local childChangeDebounce = false
local function processChildChanges()
    childChangeDebounce = false
    if #childChangeQueue == 0 then return end
    local needsUpdate = false
    for i = #childChangeQueue, 1, -1 do
        local child = childChangeQueue[i]
        if child then
            local name = child.Name
            if EFFECTS[name] or (type(name) == "string" and (name:find("Effect") or child:IsA("PostEffect"))) then needsUpdate = true; break end
        end
        table.remove(childChangeQueue, i)
    end
    for i = 1, #childChangeQueue do childChangeQueue[i] = nil end
    if needsUpdate then requestApply() end
end

addConnection(Lighting.ChildAdded:Connect(function(child)
    childChangeQueue[#childChangeQueue + 1] = child
    if not childChangeDebounce then childChangeDebounce = true; task.defer(processChildChanges) end
end))
addConnection(Lighting.ChildRemoved:Connect(function(child)
    childChangeQueue[#childChangeQueue + 1] = child
    if not childChangeDebounce then childChangeDebounce = true; task.defer(processChildChanges) end
end))

local changeDebounce = false
addConnection(Lighting.Changed:Connect(function(prop)
    if type(prop) ~= "string" then return end
    if not importantPropsSet[prop] then return end
    if changeDebounce then return end
    changeDebounce = true
    requestApply()
    task.delay(0.1, function() changeDebounce = false end)
end))

local function initializeCaches()
    for prop, _ in pairs(SOFT_CONFIG) do
        local ok, v = pcall_local(function() return Lighting[prop] end)
        lastAppliedLighting[prop] = ok and v or nil
    end
    for name, data in pairs(EFFECTS) do
        lastAppliedEffects[name] = nil
        if data.enabled then
            local existing = Lighting:FindFirstChild(name)
            if existing and existing:IsA(data.class) then
                effectInstances[name] = existing
                effectInstanceCache[name] = existing
                lastAppliedEffects[name] = {}
                for k, _ in pairs(data.settings) do
                    local ok2, v2 = pcall_local(function() return existing[k] end)
                    if ok2 then lastAppliedEffects[name][k] = v2 end
                end
            end
        end
    end
end

local function waitForGameLoadedAndAdjust()
    local start = tick_local()
    local timeout = 10
    while tick_local() - start < timeout do
        if #Lighting:GetChildren() > 3 then break end
        task.wait(0.25)
    end
    local ok, frameTime = pcall_local(function()
        local before = tick_local()
        RunService.RenderStepped:Wait()
        return tick_local() - before
    end)
    if not ok or not frameTime or frameTime <= 0 then frameTime = 0.016 end
    local fps = frameTime > 0 and (1 / frameTime) or 60
    if fps < 30 then
        DEBOUNCE_TIME = math.max(DEBOUNCE_TIME, 1.0)
        EFFECTS.Bloom.enabled = false
        EFFECTS.SunRays.enabled = false
    elseif fps < 50 then
        DEBOUNCE_TIME = math.max(DEBOUNCE_TIME, 0.8)
    end
end

do
    local lastFrameTime = tick_local()
    local frameTimeHistory = {}
    local maxFrameTime = 0.033
    local conn = RunService.RenderStepped:Connect(function()
        local now = tick_local()
        local ft = now - lastFrameTime
        lastFrameTime = now
        frameTimeHistory[#frameTimeHistory + 1] = ft
        if #frameTimeHistory > 10 then table.remove(frameTimeHistory, 1) end
        if #frameTimeHistory >= 5 then
            local s = 0
            for i = 1, #frameTimeHistory do s = s + frameTimeHistory[i] end
            local avg = s / #frameTimeHistory
            if avg > maxFrameTime and DEBOUNCE_TIME < 2.0 then
                DEBOUNCE_TIME = math.min(DEBOUNCE_TIME * 1.25, 2.0)
            elseif avg < maxFrameTime * 0.7 and DEBOUNCE_TIME > 0.1 then
                DEBOUNCE_TIME = math.max(DEBOUNCE_TIME * 0.95, 0.1)
            end
        end
    end)
    addConnection(conn)
end

createCancellablePeriodicTask(300, function() requestApply() end)

if scriptRef then addConnection(scriptRef.AncestryChanged:Connect(function() if not scriptRef:IsDescendantOf(game) then cleanup() end end)) end

local ok, err = pcall_local(function() waitForGameLoadedAndAdjust(); initializeCaches(); requestApply() end)
if not ok then
    pcall_local(function()
        Lighting.Brightness = SOFT_CONFIG.Brightness or 0.9
        Lighting.FogEnd = SOFT_CONFIG.FogEnd or 900
        Lighting.FogStart = SOFT_CONFIG.FogStart or 0
    end)
end

return applySoftLightingInternal