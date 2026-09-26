--V1.2高亮+清除整合
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer
local playerGui = nil
local playerGuiReady = false

-- 局部化常用函数（性能微优化）
local pcall = pcall
local task_wait = task.wait
local task_spawn = task.spawn
local task_defer = task.defer
local warn = warn
local Color3 = Color3
local Instance = Instance

-- 批量设置属性（直接比对当前值，最高效）
local function batchSetProperties(obj, props)
	if not obj then return end
	for key, val in pairs(props) do
		local current = obj[key]
		if current ~= val then
			pcall(function() obj[key] = val end)
		end
	end
end

-- 效果实例缓存
local softEffectInstances = {}

-- 获取或创建光照效果对象（安全访问Parent，防止已销毁对象报错）
local function getOrCreate(name, classType, defaultProps)
	local cached = softEffectInstances[name]
	if cached then
		-- 安全获取Parent，避免因对象已销毁而抛出错误
		local success, parent = pcall(function() return cached.Parent end)
		if success and parent then
			return cached
		else
			-- 对象已无效（已销毁或成为孤儿），从缓存移除并清理孤儿
			if success and not parent then
				pcall(function() cached:Destroy() end)
			end
			softEffectInstances[name] = nil
		end
	end

	local ok, inst = pcall(function()
		local o = Instance.new(classType)
		o.Name = name
		if defaultProps then
			for k, v in pairs(defaultProps) do
				o[k] = v
			end
		end
		o:SetAttribute("IsSoftLightingEffect", true)
		o.Parent = Lighting
		return o
	end)

	if ok and inst then
		softEffectInstances[name] = inst
		return inst
	end
	return nil
end

-- 软光照配置（Threshold 已修正为有效值 0.8）
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
		Threshold = 0.8
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

-- 应用主光照配置
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

-- 应用软效果
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

-- 需要清除的感染类GUI名称
local NOISE_GUIS = {
	SoftNoiseGUI = true, SoftHazeGUI = true,
	InfectionEffect = true, InfectionScreen = true,
	VirusEffect = true, BloodEffect = true,
	RedFilter = true, DamageEffect = true,
	PoisonEffect = true, ScreenFilter = true
}

-- 确保 PlayerGui 就绪
local function ensurePlayerGui()
	if playerGuiReady then return true end
	if not localPlayer then return false end
	local success, gui = pcall(function()
		return localPlayer:WaitForChild("PlayerGui", 2)
	end)
	if success and gui then
		playerGui = gui
		playerGuiReady = true
		return true
	end
	return false
end

-- 清除感染类GUI
local function clearInfectionGUI()
	if not ensurePlayerGui() then return end
	task_spawn(function()
		for _, gui in ipairs(playerGui:GetChildren()) do
			local ok, name = pcall(function() return gui.Name end)
			if ok and NOISE_GUIS[name] then
				pcall(function() gui:Destroy() end)
			end
		end
	end)
end

-- 需要清除的非软光照效果类型
local REMOVE_TYPES = {
	BlurEffect = true,
	DepthOfFieldEffect = true,
	ColorCorrectionEffect = true,
	SunRaysEffect = true,
}

-- 清除 Lighting 下非本脚本创建的光照效果
local function clearInfectionLightingOnce()
	for _, obj in ipairs(Lighting:GetChildren()) do
		local ok, class = pcall(function() return obj.ClassName end)
		if ok and REMOVE_TYPES[class] then
			local success, isSoft = pcall(function() return obj:GetAttribute("IsSoftLightingEffect") end)
			if not success or not isSoft then
				pcall(function() obj:Destroy() end)
			end
		end
	end
end

-- 全量刷新
local function fullRefresh()
	applyLightingConfig()
	applySoftEffects()
	clearInfectionLightingOnce()
	clearInfectionGUI()
end

-- 初始化 + 心跳循环（30秒间隔）
local function initialize()
	if not localPlayer then
		localPlayer = Players.LocalPlayer
		if not localPlayer then
			warn("[SoftLighting] 无法获取 LocalPlayer")
			return false
		end
	end

	fullRefresh()

	task_spawn(function()
		while true do
			task_wait(30)
			local ok, err = pcall(fullRefresh)
			if not ok then
				warn("[SoftLighting] 心跳刷新失败: ", err)
			end
		end
	end)

	return true
end

-- 启动脚本
task_defer(function()
	local ok, err = pcall(initialize)
	if not ok then
		warn("[SoftLighting] 初始化失败: ", err)
		pcall(function()
			Lighting.Brightness = SOFT_CONFIG.Brightness
		end)
	end
end)