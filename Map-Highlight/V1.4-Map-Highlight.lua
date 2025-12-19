--地图高亮 v1.4
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local task = task

local DEBOUNCE_TIME = 0.5
local CHILD_EVENT_DEBOUNCE = 0.25
local PERIODIC_APPLY_INTERVAL = 60
local DEBUG = false

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

local effectInstances = {}
local lastAppliedLighting = {}
local lastAppliedEffects = {}
local connections = {}
local dirty = false
local lastUpdateTick = 0
local lastChildEventTime = 0

local importantPropsSet = {
    Brightness = true, GlobalShadows = true, Ambient = true, ColorShift_Top = true,
    ClockTime = true, FogEnd = true, FogColor = true, FogStart = true
}

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
    return false
end

local function safeRead(obj, prop)
    if not obj then return nil, false end
    local ok, val = pcall_local(function() return obj[prop] end)
    if ok then return val, true end
    return nil, false
end

local function safeWriteIfDiff(obj, prop, value, cacheTable)
    if not obj then return false end
    local cached = cacheTable[prop]
    if cached ~= nil and shallowEqual(cached, value) then
        return false
    end

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

local function getOrCreateEffect(name, className)
    local inst = effectInstances[name]
    if inst and inst.Parent then return inst end

    local existing, ok = nil, false
    ok, existing = pcall_local(function() return Lighting:FindFirstChild(name) end)
    if ok and existing and existing:IsA(className) then
        effectInstances[name] = existing
        return existing
    end

    if existing then
        pcall_local(function() existing:Destroy() end)
    end

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

local function applySoftLightingInternal()
    if not Lighting then return false end
    local changed = false

    if applyConfigToObjectWithCache(Lighting, SOFT_CONFIG, lastAppliedLighting) then
        changed = true
    end

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
            local inst = effectInstances[name]
            if inst then
                pcall_local(function() inst:Destroy() end)
                effectInstances[name] = nil
                lastAppliedEffects[name] = nil
                changed = true
            else
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

local function requestApply()
    dirty = true
end

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
    effectInstances = {}
    lastAppliedEffects = {}
    lastAppliedLighting = {}
end

local function onLightingChildEvent(child)
    local now = tick_local()
    if now - lastChildEventTime < CHILD_EVENT_DEBOUNCE then
        lastChildEventTime = now
        return
    end
    lastChildEventTime = now
    task.spawn(function()
        task.wait(CHILD_EVENT_DEBOUNCE)
        requestApply()
    end)
end

local function onLightingChanged(prop)
    if type(prop) ~= "string" then return end
    if importantPropsSet[prop] then
        requestApply()
    end
end

local heartbeatConn
heartbeatConn = RunService.Heartbeat:Connect(function()
    if not dirty then return end
    local now = tick_local()
    if now - lastUpdateTick >= DEBOUNCE_TIME then
        lastUpdateTick = now
        dirty = false

        pcall_local(function()
            applySoftLightingInternal()
        end)
    end
end)
addConnection(heartbeatConn)

local function initializeCaches()
    for prop, _ in pairs(SOFT_CONFIG) do
        local ok, val = safeRead(Lighting, prop)
        if ok then
            lastAppliedLighting[prop] = val
        else
            lastAppliedLighting[prop] = nil
        end
    end

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

local function safeInitialize()
    local ok, err = pcall_local(function()
        initializeCaches()

        addConnection(Lighting.ChildAdded:Connect(onLightingChildEvent))
        addConnection(Lighting.ChildRemoved:Connect(onLightingChildEvent))
        addConnection(Lighting.Changed:Connect(onLightingChanged))

        task.delay(1, function()
            while script and script.Parent and script:IsDescendantOf(game) do
                task.wait(PERIODIC_APPLY_INTERVAL)
                requestApply()
            end
        end)

        applySoftLightingInternal()
    end)
    if not ok then
        pcall_local(function()
            Lighting.Brightness = SOFT_CONFIG.Brightness or 0.9
            Lighting.FogEnd = SOFT_CONFIG.FogEnd or 900
            Lighting.FogStart = SOFT_CONFIG.FogStart or 0
        end)
        warn("Soft Lighting init failed (fallback applied):", err)
    end
end

local function cleanup()
    dprint("SoftLighting: cleanup start")
    disconnectAll()
    dprint("SoftLighting: cleanup done")
end

if script then
    addConnection(script.AncestryChanged:Connect(function()
        if not script:IsDescendantOf(game) then
            cleanup()
        end
    end))
end

safeInitialize()

return cleanup