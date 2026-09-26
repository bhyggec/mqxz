--V3.0.2fps-ping显示
local PerfOverlay = {}

-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")
local CoreGui = nil
-- 尝试获取 CoreGui，若失败则回退到 PlayerGui
pcall(function()
	CoreGui = game:GetService("CoreGui")
end)

-- Localized frequently used globals
local floor, format = math.floor, string.format
local clock = os.clock
local Vector2_new = Vector2.new
local UDim2_new = UDim2.new
local Instance_new = Instance.new

-- Localized Enums
local MouseButton1 = Enum.UserInputType.MouseButton1
local Touch = Enum.UserInputType.Touch
local MouseMovement = Enum.UserInputType.MouseMovement
local TextXAlignmentLeft = Enum.TextXAlignment.Left
local TextYAlignmentTop = Enum.TextYAlignment.Top
local FontSemi = Enum.Font.SourceSansSemibold

-- Constants
local UPDATE_THROTTLE = 0.3
local FPS_SAMPLE_TIME = 1.0
local FPS_SAMPLE_TIME_RECIPROCAL = 1.0 / FPS_SAMPLE_TIME
local TEXT_FULL = "fps: %d\nping: %d ms\nplayer: %d"
local TEXT_SIMPLE = "fps: %d\nping: %d ms"
local DOUBLE_CLICK_THRESHOLD = 0.3
local COLOR_PURPLE = Color3.fromRGB(148, 0, 211)

-- Internal state
local cache = {
	player = nil,
	screenGui = nil,
	frame = nil,
	label = nil,
	dataPingObj = nil,
	statsChecked = false,
	frameCount = 0,
	accTime = 0,
	displayFps = 0,
	cachedFPS = -1,
	cachedPing = -1,
	cachedPlayerCount = -1,
	shouldUpdateUI = false,
	dragging = false,
	dragStart = Vector2_new(),
	startPos = nil,
	mode = 1,
	lastClickTime = 0,
	running = true,
	enabled = true,
}

-- Connection management
local connections = {}
local function addConnection(c)
	if c then connections[#connections + 1] = c end
end
local function disconnectAll()
	for i = #connections, 1, -1 do
		local c = connections[i]
		if c then
			pcall(c.Disconnect, c)
		end
		connections[i] = nil
	end
end

-- Alive tracking
local aliveCount = 0
local lastScanAliveCount = -1
local playerAlive = {}
local playerConns = {}

local function safeDisconnect(conn)
	if conn then
		pcall(conn.Disconnect, conn)
	end
end

local function computeAliveCount()
	local alive = 0
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		if char then
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				alive += 1
			end
		end
	end
	return alive
end

local function scanPlayers()
	local newAlive = computeAliveCount()
	if newAlive ~= lastScanAliveCount then
		aliveCount = newAlive
		lastScanAliveCount = newAlive
		cache.shouldUpdateUI = true
	end
end

local function handleHumanoidDied(plr)
	if playerAlive[plr] then
		playerAlive[plr] = false
		aliveCount = math.max(0, aliveCount - 1)
		lastScanAliveCount = aliveCount
		cache.shouldUpdateUI = true
	end
end

local function setupHumanoidTracking(plr, humanoid)
	if not plr or not humanoid then return end
	if humanoid.Health > 0 and not playerAlive[plr] then
		playerAlive[plr] = true
		aliveCount += 1
		lastScanAliveCount = aliveCount
		cache.shouldUpdateUI = true
	end
	local conns = playerConns[plr]
	if conns and conns.diedConn then
		safeDisconnect(conns.diedConn)
		conns.diedConn = nil
	end
	local diedConn = humanoid.Died:Connect(function()
		handleHumanoidDied(plr)
	end)
	if not playerConns[plr] then
		playerConns[plr] = {}
	end
	playerConns[plr].diedConn = diedConn
end

local function onCharacterAdded(plr, char)
	if playerConns[plr] then
		safeDisconnect(playerConns[plr].diedConn)
		playerConns[plr].diedConn = nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		setupHumanoidTracking(plr, hum)
	else
		task.spawn(function()
			local h = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 2)
			if h and plr.Parent then
				setupHumanoidTracking(plr, h)
			end
		end)
	end
end

local function onPlayerAdded(plr)
	playerAlive[plr] = false
	local conns = playerConns[plr] or {}
	conns.charConn = plr.CharacterAdded:Connect(function(char) onCharacterAdded(plr, char) end)
	playerConns[plr] = conns
	if plr.Character then
		onCharacterAdded(plr, plr.Character)
	end
end

local function onPlayerRemoving(plr)
	if playerAlive[plr] then
		playerAlive[plr] = false
		aliveCount = math.max(0, aliveCount - 1)
		lastScanAliveCount = aliveCount
		cache.shouldUpdateUI = true
	end
	local conns = playerConns[plr]
	if conns then
		safeDisconnect(conns.charConn)
		safeDisconnect(conns.diedConn)
		playerConns[plr] = nil
	end
	playerAlive[plr] = nil
end

-- GUI Initialization
local function initialize()
	cache.player = Players.LocalPlayer or Players.PlayerAdded:Wait()
	if not cache.player then return false end

	-- 确定父级容器：优先 CoreGui，不可用时回退到 PlayerGui
	local targetParent = nil
	if CoreGui then
		targetParent = CoreGui
	else
		warn("PerfOverlay: CoreGui unavailable, falling back to PlayerGui")
		local playerGui = cache.player:FindFirstChild("PlayerGui") or cache.player:WaitForChild("PlayerGui", 2)
		if not playerGui then return false end
		targetParent = playerGui
	end

	-- ScreenGui
	cache.screenGui = targetParent:FindFirstChild("PerfOverlay")
	if not cache.screenGui then
		cache.screenGui = Instance_new("ScreenGui")
		cache.screenGui.Name = "PerfOverlay"
		cache.screenGui.ResetOnSpawn = false
		cache.screenGui.Parent = targetParent
	end
	cache.screenGui.Enabled = cache.enabled

	-- Frame
	cache.frame = cache.screenGui:FindFirstChild("Holder")
	if not cache.frame then
		cache.frame = Instance_new("Frame")
		cache.frame.Name = "Holder"
		cache.frame.Size = UDim2_new(0, 63, 0, 45)
		cache.frame.Position = UDim2_new(0, 12, 0, 60)
		cache.frame.BackgroundTransparency = 1
		cache.frame.BorderSizePixel = 0
		cache.frame.Parent = cache.screenGui
	end

	-- Label
	cache.label = cache.frame:FindFirstChild("StatsLabel")
	if not cache.label then
		cache.label = Instance_new("TextLabel")
		cache.label.Name = "StatsLabel"
		cache.label.Size = UDim2_new(1, 0, 1, 0)
		cache.label.BackgroundTransparency = 1
		cache.label.Text = ""
		cache.label.TextXAlignment = TextXAlignmentLeft
		cache.label.TextYAlignment = TextYAlignmentTop
		cache.label.Font = FontSemi
		cache.label.TextSize = 14
		cache.label.TextColor3 = COLOR_PURPLE
		cache.label.Parent = cache.frame
	end
	return true
end

-- Data Ping (simple one-shot cache)
local function getDataPingObj()
	if cache.dataPingObj then return cache.dataPingObj end
	if cache.statsChecked then return nil end
	cache.statsChecked = true
	local network = Stats.Network
	if network and network.ServerStatsItem then
		local obj = network.ServerStatsItem["Data Ping"]
		if obj then
			cache.dataPingObj = obj
		end
	end
	return cache.dataPingObj
end

local function getPingMs()
	local obj = getDataPingObj()
	if not obj then return 0 end
	local ok, val = pcall(obj.GetValue, obj)
	if ok and val then
		return floor(tonumber(val) or 0)
	end
	return 0
end

-- Heartbeat: FPS + scan once per second
local function onHeartbeat(delta)
	cache.frameCount += 1
	cache.accTime += delta

	if cache.accTime >= FPS_SAMPLE_TIME then
		cache.displayFps = floor(cache.frameCount * FPS_SAMPLE_TIME_RECIPROCAL + 0.5)
		cache.frameCount = 0
		cache.accTime -= FPS_SAMPLE_TIME
		scanPlayers()
		cache.shouldUpdateUI = true
	end
end

-- Input events
local function onInputBegan(input)
	if not cache.enabled then return end
	local inputType = input.UserInputType
	if inputType ~= MouseButton1 and inputType ~= Touch then return end

	local now = clock()
	if now - cache.lastClickTime < DOUBLE_CLICK_THRESHOLD then
		cache.mode = cache.mode == 1 and 2 or 1
		-- 强制刷新
		cache.cachedFPS = -1
		cache.cachedPing = -1
		cache.cachedPlayerCount = -1
		cache.shouldUpdateUI = true
		cache.lastClickTime = 0
		return
	end
	cache.lastClickTime = now
	cache.dragging = true
	cache.dragStart = input.Position
	cache.startPos = cache.frame.Position
end

local function onInputChanged(input)
	if not cache.enabled or not cache.dragging then return end
	local inputType = input.UserInputType
	if inputType ~= MouseMovement and inputType ~= Touch then return end

	local delta = input.Position - cache.dragStart
	cache.frame.Position = UDim2_new(
		0,
		cache.startPos.X.Offset + delta.X,
		0,
		cache.startPos.Y.Offset + delta.Y
	)
end

local function onInputEnded(input)
	local inputType = input.UserInputType
	if inputType == MouseButton1 or inputType == Touch then
		cache.dragging = false
	end
end

-- UI update
local lastText = ""
local function performUIUpdate()
	if not cache.shouldUpdateUI then return end
	cache.shouldUpdateUI = false

	if not cache.enabled then return end

	local fps = cache.displayFps
	local ping = getPingMs()
	local alive = (cache.mode == 1) and aliveCount or 0

	if fps == cache.cachedFPS and ping == cache.cachedPing and alive == cache.cachedPlayerCount then
		return
	end

	cache.cachedFPS = fps
	cache.cachedPing = ping
	cache.cachedPlayerCount = alive

	local newText = cache.mode == 1
		and format(TEXT_FULL, fps, ping, alive)
		or format(TEXT_SIMPLE, fps, ping)

	if newText ~= lastText then
		cache.label.Text = newText
		lastText = newText
	end
end

-- Event wiring
local function setupConnections()
	disconnectAll()
	addConnection(RunService.Heartbeat:Connect(onHeartbeat))
	if cache.frame then
		addConnection(cache.frame.InputBegan:Connect(onInputBegan))
	end
	addConnection(UserInputService.InputChanged:Connect(onInputChanged))
	addConnection(UserInputService.InputEnded:Connect(onInputEnded))
	addConnection(Players.PlayerAdded:Connect(onPlayerAdded))
	addConnection(Players.PlayerRemoving:Connect(onPlayerRemoving))
end

-- Cleanup
local function cleanup()
	cache.running = false
	disconnectAll()
	if cache.screenGui and cache.screenGui.Parent then
		pcall(cache.screenGui.Destroy, cache.screenGui)
	end
	for plr, conns in pairs(playerConns) do
		if conns then
			safeDisconnect(conns.charConn)
			safeDisconnect(conns.diedConn)
			playerConns[plr] = nil
		end
	end
	cache.dataPingObj = nil
	cache.statsChecked = false
end

-- Main throttled loop
local function mainLoop()
	while cache.running and cache.player and cache.player.Parent do
		performUIUpdate()
		task.wait(UPDATE_THROTTLE)
	end
	cleanup()
end

-- Start
local function start()
	if not initialize() then return end
	for _, plr in ipairs(Players:GetPlayers()) do
		onPlayerAdded(plr)
	end
	aliveCount = computeAliveCount()
	lastScanAliveCount = aliveCount
	cache.cachedPlayerCount = aliveCount
	cache.shouldUpdateUI = true

	setupConnections()
	task.spawn(getDataPingObj)
	task.spawn(mainLoop)
end

-- Public API
function PerfOverlay:setEnabled(enabled)
	enabled = enabled == true
	if cache.enabled == enabled then return end
	cache.enabled = enabled
	if cache.screenGui then
		cache.screenGui.Enabled = enabled
	end
	if not enabled then
		cache.dragging = false
	else
		cache.shouldUpdateUI = true
	end
end

function PerfOverlay:toggle()
	self:setEnabled(not cache.enabled)
end

function PerfOverlay:isEnabled()
	return cache.enabled
end

-- Auto-start
task.spawn(start)

return PerfOverlay