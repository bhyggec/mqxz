--// Soft Lighting with Auto-Restore (Client Safe)

local Lighting = game:GetService("Lighting")

local SOFT_CONFIG = {
    Brightness = 0.9,
    GlobalShadows = true,
    Ambient = Color3.fromRGB(140, 140, 140),
    ColorShift_Top = Color3.fromRGB(235, 225, 215),
    ClockTime = 15,
    FogEnd = 900,
    FogColor = Color3.fromRGB(200, 200, 200),
}

local EFFECTS = {
    ColorCorrection = {
        class = "ColorCorrectionEffect",
        settings = { Brightness = -0.02, Contrast = 0.04, Saturation = 0.05 }
    },
    SunRays = {
        class = "SunRaysEffect",
        settings = { Intensity = 0.01 }
    },
    Atmosphere = {
        class = "Atmosphere",
        settings = { Density = 0.25, Offset = 0.6, Color = Color3.fromRGB(220, 220, 220) }
    },
    Bloom = {
        class = "BloomEffect",
        settings = { Intensity = 0.1, Threshold = 0.75, Size = 18 }
    }
}

local function getOrCreate(className, parent, name)
    return parent:FindFirstChild(name) or Instance.new(className, parent)
end

local function applySettings(object, settings)
    for prop, value in pairs(settings) do
        pcall(function()
            object[prop] = value
        end)
    end
end

local function applySoftLighting()
    applySettings(Lighting, SOFT_CONFIG)

    for name, data in pairs(EFFECTS) do
        local obj = getOrCreate(data.class, Lighting, name)
        obj.Name = name
        applySettings(obj, data.settings)
    end
end

-- 初次应用
applySoftLighting()

-- 自动恢复（核心）-----------------------------------------

-- 监听 Lighting 属性变化
Lighting.Changed:Connect(function()
    applySoftLighting()
end)

-- 监听 Lighting 子项被修改或新增
Lighting.ChildAdded:Connect(function()
    task.wait()
    applySoftLighting()
end)

Lighting.ChildRemoved:Connect(function()
    task.wait()
    applySoftLighting()
end)

return applySoftLighting