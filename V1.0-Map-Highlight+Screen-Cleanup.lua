-- 整合版：Soft Lighting with Enhanced Visual Management
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

-- 本地玩家
local localPlayer = Players.LocalPlayer
local playerGui = nil

-- 防抖配置
local DEBOUNCE_TIME = 0.5
local lastUpdateTime = 0
local updatePending = false

-- 软光照配置
local SOFT_CONFIG = {
    Brightness = 0.9,
    GlobalShadows = true,
    Ambient = Color3.fromRGB(140, 140, 140),
    ColorShift_Top = Color3.fromRGB(235, 225, 215),
    ClockTime = 15,
    FogEnd = 900,
    FogColor = Color3.fromRGB(200, 200, 200),
}

-- 软光照效果配置（添加标记属性便于识别）
local SOFT_EFFECTS = {
    ColorCorrection = {
        enabled = true,
        className = "ColorCorrectionEffect",
        settings = { 
            Brightness = -0.02, 
            Contrast = 0.04, 
            Saturation = 0.05,
            Name = "SoftLighting_ColorCorrection"  -- 添加唯一名称
        }
    },
    SunRays = {
        enabled = true,
        className = "SunRaysEffect",
        settings = { 
            Intensity = 0.01,
            Name = "SoftLighting_SunRays"
        }
    },
    Atmosphere = {
        enabled = true,
        className = "Atmosphere",
        settings = { 
            Density = 0.25, 
            Offset = 0.6, 
            Color = Color3.fromRGB(220, 220, 220),
            Name = "SoftLighting_Atmosphere"
        }
    },
    Bloom = {
        enabled = true,
        className = "BloomEffect",
        settings = { 
            Intensity = 0.1, 
            Threshold = 0.75, 
            Size = 18,
            Name = "SoftLighting_Bloom"
        }
    }
}

-- 需要清除的感染效果配置（不会清除软光照效果）
local INFECTION_EFFECTS = {
    ScreenGuiNames = {
        "InfectionEffect",
        "InfectionScreen",
        "VirusEffect",
        "BloodEffect",
        "RedFilter",
        "DamageEffect",
        "PoisonEffect",
        "ScreenFilter"
    },
    LightingEffectClasses = {
        "BlurEffect",
        "DepthOfFieldEffect"
    }
}

-- 缓存已创建的软光照效果实例
local softEffectInstances = {}

-- 安全执行函数
local function safeCall(func, ...)
    local success, result = pcall(func, ...)
    if not success then
        warn("安全调用失败:", result)
    end
    return success, result
end

-- 检查属性是否存在
local function propertyExists(object, property)
    return pcall(function() 
        local _ = object[property]
        return true 
    end)
end

-- 安全设置属性
local function safeSetProperty(object, property, value)
    if object and propertyExists(object, property) then
        local current = object[property]
        if typeof(current) == typeof(value) and current ~= value then
            pcall(function()
                object[property] = value
            end)
        end
    end
end

-- 批量应用配置
local function applyConfigToObject(object, config)
    for prop, value in pairs(config) do
        safeSetProperty(object, prop, value)
    end
end

-- 创建或获取软光照效果实例
local function getOrCreateSoftEffect(name, className, settings)
    -- 首先检查缓存
    if softEffectInstances[name] and softEffectInstances[name].Parent then
        return softEffectInstances[name]
    end
    
    -- 检查是否已存在
    local effectName = settings.Name or name
    local existing = Lighting:FindFirstChild(effectName)
    
    if existing and existing:IsA(className) then
        softEffectInstances[name] = existing
        return existing
    end
    
    -- 移除冲突的旧效果
    if existing then
        existing:Destroy()
    end
    
    -- 创建新效果
    local effect = Instance.new(className)
    effect.Name = effectName
    effect.Parent = Lighting
    
    -- 应用设置
    applyConfigToObject(effect, settings)
    
    -- 标记为软光照效果（使用Attribute）
    pcall(function()
        effect:SetAttribute("IsSoftLightingEffect", true)
    end)
    
    softEffectInstances[name] = effect
    return effect
end

-- 应用软光照设置
local function applySoftLighting()
    local now = tick()
    
    -- 防抖检查
    if now - lastUpdateTime < DEBOUNCE_TIME then
        if not updatePending then
            updatePending = true
            task.delay(DEBOUNCE_TIME, function()
                updatePending = false
                applySoftLighting()
            end)
        end
        return
    end
    
    lastUpdateTime = now
    updatePending = false
    
    -- 应用基础光照设置
    applyConfigToObject(Lighting, SOFT_CONFIG)
    
    -- 应用软光照效果
    for name, data in pairs(SOFT_EFFECTS) do
        if data.enabled then
            local effect = getOrCreateSoftEffect(name, data.className, data.settings)
            applyConfigToObject(effect, data.settings)
        end
    end
    
    -- 确保雾设置
    safeSetProperty(Lighting, "FogEnd", 900)
    safeSetProperty(Lighting, "FogStart", 0)
end

-- 等待玩家GUI加载
local function waitForPlayerGui()
    if not localPlayer or not localPlayer:IsDescendantOf(Players) then
        return false
    end
    
    playerGui = safeCall(function()
        return localPlayer:WaitForChild("PlayerGui", 10) or localPlayer:FindFirstChild("PlayerGui")
    end)
    
    return playerGui ~= nil
end

-- 清除感染效果（不触及软光照效果）
local function clearInfectionEffects()
    -- 清除Lighting中的感染效果（跳过软光照效果）
    safeCall(function()
        for _, className in ipairs(INFECTION_EFFECTS.LightingEffectClasses) do
            local effects = Lighting:GetChildren()
            for _, effect in ipairs(effects) do
                if effect:IsA(className) then
                    -- 检查是否是软光照效果
                    local isSoftEffect = pcall(function()
                        return effect:GetAttribute("IsSoftLightingEffect") == true
                    end)
                    
                    if not isSoftEffect then
                        effect:Destroy()
                    end
                end
            end
        end
    end)
    
    -- 清除屏幕GUI中的感染效果
    if waitForPlayerGui() then
        safeCall(function()
            for _, guiName in ipairs(INFECTION_EFFECTS.ScreenGuiNames) do
                local screenGui = playerGui:FindFirstChild(guiName)
                while screenGui do
                    screenGui:Destroy()
                    screenGui = playerGui:FindFirstChild(guiName)
                end
            end
        end)
    end
end

-- 完整的视觉管理系统
local function applyVisualManagement()
    -- 1. 首先应用软光照
    applySoftLighting()
    
    -- 2. 然后清除感染效果
    clearInfectionEffects()
end

-- 初始化函数
local function initialize()
    -- 等待玩家加载
    if not localPlayer then
        localPlayer = Players.LocalPlayer
        if not localPlayer then
            Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
            localPlayer = Players.LocalPlayer
        end
    end
    
    -- 初次应用
    applyVisualManagement()
    
    -- 设置属性变化监听
    local function onLightingChanged()
        local now = tick()
        if now - lastUpdateTime >= DEBOUNCE_TIME then
            applyVisualManagement()
        elseif not updatePending then
            updatePending = true
            task.delay(DEBOUNCE_TIME - (now - lastUpdateTime), function()
                if updatePending then
                    updatePending = false
                    applyVisualManagement()
                end
            end)
        end
    end
    
    -- 监听关键光照属性变化
    local importantProperties = {
        "Brightness", "GlobalShadows", "Ambient", "ColorShift_Top",
        "ClockTime", "FogEnd", "FogColor", "FogStart"
    }
    
    for _, prop in ipairs(importantProperties) do
        if propertyExists(Lighting, prop) then
            Lighting:GetPropertyChangedSignal(prop):Connect(onLightingChanged)
        end
    end
    
    -- 监听Lighting子项变化（更智能的过滤）
    Lighting.ChildAdded:Connect(function(child)
        -- 检查是否是应该清除的感染效果
        for _, className in ipairs(INFECTION_EFFECTS.LightingEffectClasses) do
            if child:IsA(className) then
                local isSoftEffect = pcall(function()
                    return child:GetAttribute("IsSoftLightingEffect") == true
                end)
                
                if not isSoftEffect then
                    task.wait(0.5)
                    child:Destroy()
                end
                break
            end
        end
    end)
    
    -- 监听PlayerGui子项变化
    local function onPlayerGuiChildAdded()
        task.wait(0.5)
        clearInfectionEffects()
    end
    
    if waitForPlayerGui() then
        playerGui.ChildAdded:Connect(onPlayerGuiChildAdded)
    end
    
    -- 定期检查（每15秒一次，避免冲突）
    task.spawn(function()
        while true do
            task.wait(15)
            applyVisualManagement()
        end
    end)
    
    -- 键盘快捷键（F5手动刷新）
    UserInputService.InputBegan:Connect(function(input, processed)
        if not processed and input.KeyCode == Enum.KeyCode.F5 then
            applyVisualManagement()
        end
    end)
    
    -- print("视觉管理系统已初始化！按F5手动刷新。")
end

-- 安全初始化
local success, err = pcall(initialize)
if not success then
    warn("视觉管理系统初始化失败:", err)
    
    -- 备用方案：应用最基本的设置
    task.delay(2, function()
        safeCall(function()
            Lighting.Brightness = 0.9
            Lighting.FogEnd = 900
            Lighting.FogStart = 0
        end)
    end)
end

-- 导出API
return {
    -- 主功能
    ApplyVisualManagement = applyVisualManagement,
    ApplySoftLighting = applySoftLighting,
    ClearInfectionEffects = clearInfectionEffects,
    
    -- 配置获取（可选）
    GetSoftLightingConfig = function() return SOFT_CONFIG end,
    GetSoftEffectsConfig = function() return SOFT_EFFECTS end,
    
    -- 状态检查
    IsInitialized = success
}