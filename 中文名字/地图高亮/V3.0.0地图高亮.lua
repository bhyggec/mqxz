--地图高亮 v3.0.0
--基于v1.5版本的极致性能优化
local Lighting = game:GetService("Lighting")
local task = task

local CONFIG = {
    Brightness = 0.9,
    Ambient = Color3.fromRGB(140, 140, 140),
    ColorShift_Top = Color3.fromRGB(235, 225, 215),
    ClockTime = 15,
    FogEnd = 900,
    FogColor = Color3.fromRGB(200, 200, 200),
    FogStart = 0,
    
    effects = {
        ColorCorrection = {
            class = "ColorCorrectionEffect",
            settings = { Brightness = -0.02, Contrast = 0.04, Saturation = 0.05 }
        },
        Atmosphere = {
            class = "Atmosphere",
            settings = { Density = 0.25, Offset = 0.6, Color = Color3.fromRGB(220, 220, 220) }
        }
    }
}

local effectInstances = {}
local appliedProperties = {}
local isInitialized = false

local function isEqual(a, b)
    if a == b then return true end
    if typeof(a) ~= typeof(b) then return false end
    
    if typeof(a) == "Color3" then
        return a.R == b.R and a.G == b.G and a.B == b.B
    end
    
    return false
end

local function setProperty(object, prop, value)
    if object and object[prop] ~= nil then
        object[prop] = value
    end
end

local function setProperties(object, props)
    for prop, value in pairs(props) do
        if object[prop] ~= nil then
            object[prop] = value
        end
    end
end

local function getEffect(name, className)
    local effect = effectInstances[name]
    if effect and effect.Parent then
        return effect
    end
    
    effect = Lighting:FindFirstChild(name)
    if effect and effect.ClassName == className then
        effectInstances[name] = effect
        return effect
    end
    
    if effect then
        effect:Destroy()
    end
    
    effect = Instance.new(className)
    effect.Name = name
    effect.Parent = Lighting
    effectInstances[name] = effect
    
    return effect
end

local function applyInitialConfig()
    if isInitialized then return end
    
    setProperties(Lighting, {
        Brightness = CONFIG.Brightness,
        FogEnd = CONFIG.FogEnd,
        FogStart = CONFIG.FogStart,
        FogColor = CONFIG.FogColor,
        Ambient = CONFIG.Ambient,
        ClockTime = CONFIG.ClockTime,
        ColorShift_Top = CONFIG.ColorShift_Top
    })
    
    appliedProperties.Brightness = CONFIG.Brightness
    appliedProperties.FogEnd = CONFIG.FogEnd
    appliedProperties.FogStart = CONFIG.FogStart
    appliedProperties.FogColor = CONFIG.FogColor
    appliedProperties.Ambient = CONFIG.Ambient
    appliedProperties.ClockTime = CONFIG.ClockTime
    appliedProperties.ColorShift_Top = CONFIG.ColorShift_Top
    
    task.delay(1, function()
        local colorCorrection = getEffect("ColorCorrection", "ColorCorrectionEffect")
        setProperties(colorCorrection, CONFIG.effects.ColorCorrection.settings)
        
        local atmosphere = getEffect("Atmosphere", "Atmosphere")
        setProperties(atmosphere, CONFIG.effects.Atmosphere.settings)
        
        isInitialized = true
    end)
end

local function restoreLighting()
    for prop, value in pairs(appliedProperties) do
        if Lighting[prop] ~= value then
            setProperty(Lighting, prop, value)
        end
    end
    
    for name, data in pairs(CONFIG.effects) do
        local effect = getEffect(name, data.class)
        if effect then
            setProperties(effect, data.settings)
        end
    end
end

local monitoringProps = {
    "Brightness",
    "FogEnd",
    "FogStart",
    "FogColor"
}

local lastRestoreTime = 0
local RESTORE_COOLDOWN = 10

local function startLightingMonitor()
    local connection = Lighting.Changed:Connect(function(prop)
        local isImportant = false
        for _, importantProp in ipairs(monitoringProps) do
            if prop == importantProp then
                isImportant = true
                break
            end
        end
        
        if isImportant then
            local now = tick()
            if now - lastRestoreTime > RESTORE_COOLDOWN then
                lastRestoreTime = now
                task.delay(0.5, restoreLighting)
            end
        end
    end)
    
    return connection
end

local function cleanupEffects()
    for name, _ in pairs(CONFIG.effects) do
        local effect = Lighting:FindFirstChild(name)
        if effect then
            effect:Destroy()
        end
    end
    
    effectInstances = {}
end

local function smartInitialize()
    setProperty(Lighting, "Brightness", CONFIG.Brightness)
    setProperty(Lighting, "FogEnd", CONFIG.FogEnd)
    
    local startTime = tick()
    task.wait(0.1)
    
    local frameTime = tick() - startTime
    
    if frameTime < 0.02 then
        applyInitialConfig()
    else
        task.delay(2, function()
            setProperties(Lighting, {
                FogStart = CONFIG.FogStart,
                FogColor = CONFIG.FogColor,
                Ambient = CONFIG.Ambient
            })
            
            task.delay(3, function()
                local colorCorrection = getEffect("ColorCorrection", "ColorCorrectionEffect")
                setProperties(colorCorrection, CONFIG.effects.ColorCorrection.settings)
                isInitialized = true
            end)
        end)
    end
end

smartInitialize()

local monitorConnection = startLightingMonitor()

local PublicAPI = {}

function PublicAPI.restore()
    restoreLighting()
end

function PublicAPI.cleanup()
    cleanupEffects()
    if monitorConnection then
        monitorConnection:Disconnect()
    end
end

function PublicAPI.reinitialize()
    cleanupEffects()
    isInitialized = false
    smartInitialize()
end

function PublicAPI.isActive()
    return isInitialized
end

return PublicAPI