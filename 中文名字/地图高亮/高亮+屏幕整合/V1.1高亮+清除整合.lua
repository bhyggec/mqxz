--地图高亮+屏幕清除 v1.1
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerGui = nil

local function safeCall(fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then
        warn("[SoftLighting] Safe call failed:", res)
    end
    return ok, res
end

local function batchSetProperties(obj, props)
    if not obj then return end
    safeCall(function()
        for key, val in pairs(props) do
            local ok, current = pcall(function() return obj[key] end)
            if ok then
                if current ~= val then
                    obj[key] = val
                end
            else
                pcall(function() obj[key] = val end)
            end
        end
    end)
end

local softEffectInstances = {}

local function getOrCreate(name, classType, defaultProps)
    local cached = softEffectInstances[name]
    if cached and cached.Parent then
        return cached
    end

    local ok, inst = safeCall(function()
        local o = Instance.new(classType)
        o.Name = name
        if defaultProps then
            for k, v in pairs(defaultProps) do
                pcall(function() o[k] = v end)
            end
        end
        pcall(function() o:SetAttribute("IsSoftLightingEffect", true) end)
        o.Parent = Lighting
        return o
    end)

    if ok and inst then
        softEffectInstances[name] = inst
        return inst
    end
    return nil
end

local SOFT_CONFIG = {
    Brightness = 2.0,
    Ambient = Color3.fromRGB(140, 140, 140),
    OutdoorAmbient = Color3.fromRGB(135, 135, 135),
    ClockTime = 14,
    EnvironmentDiffuseScale = 1,
    EnvironmentSpecularScale = 1,

    ColorCorrection = {
        Brightness = 0.02,
        Contrast = 0.1,
        TintColor = Color3.fromRGB(255, 248, 235)
    },

    Bloom = {
        Intensity = 0.4,
        Size = 24,
        Threshold = 2
    },

    SunRays = {
        Intensity = 0.15,
        Spread = 0.5
    },

    Atmosphere = {
        Density = 0.22,
        Haze = 1.5,
        Glare = 0.08,
        Color = Color3.fromRGB(205, 205, 225),
    }
}

local function applyLightingConfig()
    batchSetProperties(Lighting, {
        Brightness = SOFT_CONFIG.Brightness,
        Ambient = SOFT_CONFIG.Ambient,
        OutdoorAmbient = SOFT_CONFIG.OutdoorAmbient,
        ClockTime = SOFT_CONFIG.ClockTime,
        EnvironmentDiffuseScale = SOFT_CONFIG.EnvironmentDiffuseScale,
        EnvironmentSpecularScale = SOFT_CONFIG.EnvironmentSpecularScale,
    })
end

local function applySoftEffects()
    local cc = getOrCreate("Soft_CC", "ColorCorrectionEffect", SOFT_CONFIG.ColorCorrection)
    if cc then batchSetProperties(cc, SOFT_CONFIG.ColorCorrection) end

    local bl = getOrCreate("Soft_Bloom", "BloomEffect", SOFT_CONFIG.Bloom)
    if bl then batchSetProperties(bl, SOFT_CONFIG.Bloom) end

    local sr = getOrCreate("Soft_SunRays", "SunRaysEffect", SOFT_CONFIG.SunRays)
    if sr then batchSetProperties(sr, SOFT_CONFIG.SunRays) end

    local at = getOrCreate("Soft_Atmosphere", "Atmosphere", SOFT_CONFIG.Atmosphere)
    if at then batchSetProperties(at, SOFT_CONFIG.Atmosphere) end
end

local NOISE_GUIS = {
    SoftNoiseGUI = true,
    SoftHazeGUI = true,
    InfectionEffect = true,
    InfectionScreen = true,
    VirusEffect = true,
    BloodEffect = true,
    RedFilter = true,
    DamageEffect = true,
    PoisonEffect = true,
    ScreenFilter = true
}

local function ensurePlayerGui(timeout)
    if playerGui and playerGui.Parent then return true end
    if not localPlayer then return false end
    local success, gui = safeCall(function()
        return localPlayer:WaitForChild("PlayerGui", timeout or 5)
    end)
    if success and gui then
        playerGui = gui
        return true
    end
    return false
end

local function clearInfectionGUI()
    if not ensurePlayerGui(2) then return end
    safeCall(function()
        for _, gui in ipairs(playerGui:GetChildren()) do
            if NOISE_GUIS[gui.Name] then
                pcall(function() gui:Destroy() end)
            end
        end
    end)
end

local REMOVE_TYPES = {
    BlurEffect = true,
    DepthOfFieldEffect = true,
    ColorCorrectionEffect = true,
    SunRaysEffect = true,
}

local function clearInfectionLightingOnce()
    safeCall(function()
        for _, obj in ipairs(Lighting:GetChildren()) do
            if REMOVE_TYPES[obj.ClassName] then
                local ok, isSoft = pcall(function() return obj:GetAttribute("IsSoftLightingEffect") end)
                if not ok or not isSoft then
                    pcall(function() obj:Destroy() end)
                end
            end
        end
    end)
end

local function isMobileDevice()
    return RunService:IsStudio() and false or (tick() % 2 > 1)
end

local updateDirty = false
local lastRenderUpdate = 0
local UPDATE_COOLDOWN = isMobileDevice() and (1 / 20) or (1 / 30)

local function requestVisualUpdate()
    updateDirty = true
end

RunService.RenderStepped:Connect(function()
    if updateDirty then
        local t = tick()
        if t - lastRenderUpdate >= UPDATE_COOLDOWN then
            updateDirty = false
            lastRenderUpdate = t

            applyLightingConfig()
            applySoftEffects()
            clearInfectionLightingOnce()
            clearInfectionGUI()
        end
    end
end)

Lighting.ChildAdded:Connect(function(child)
    if REMOVE_TYPES[child.ClassName] then
        task.delay(0.2, function()
            if child and child.Parent == Lighting then
                local ok, isSoft = pcall(function() return child:GetAttribute("IsSoftLightingEffect") end)
                if not ok or not isSoft then
                    pcall(function() child:Destroy() end)
                    requestVisualUpdate()
                end
            end
        end)
    end
end)

local function addPropertyListener(prop)
    local success = pcall(function()
        Lighting:GetPropertyChangedSignal(prop):Connect(function()
            requestVisualUpdate()
        end)
    end)
    if not success then
        warn("[SoftLighting] 无法监听属性:", prop)
    end
end

addPropertyListener("Brightness")
addPropertyListener("Ambient")
addPropertyListener("ClockTime")

local function initialize()
    if not localPlayer then
        Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
        localPlayer = Players.LocalPlayer
        if not localPlayer then
            warn("[SoftLighting] 无法获取 LocalPlayer")
            return false
        end
    end

    requestVisualUpdate()

    return true
end

task.defer(function()
    local success, err = pcall(initialize)
    if not success then
        warn("[SoftLighting] 初始化失败:", err)
        pcall(function()
            Lighting.Brightness = SOFT_CONFIG.Brightness or 2.0
        end)
    end
end)