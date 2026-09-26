--V1.7玩家esp
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer
while not LocalPlayer do
	LocalPlayer = Players.LocalPlayer
	if not LocalPlayer then
		task.wait(0.1)
	end
end

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local BATCH_SIZE = 1
local FRAME_INTERVAL = 2
local BILLBOARD_SIZE = UDim2.new(0, 160, 0, 36)
local NAME_TEXT_SIZE = 16
local FALLBACK_COLOR = Color3.fromRGB(255, 255, 255)
local OUTLINE_DARKEN_FACTOR = 0.30
local FILL_TINT_AMOUNT = 0.70
local FILL_TRANSPARENCY = 0.55
local HEAD_WAIT_TIMEOUT = 3
local FORCE_REFRESH_INTERVAL = 30

local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local table_insert = table.insert
local type = type
local pcall = pcall
local task_wait = task.wait
local task_delay = task.delay
local task_spawn = task.spawn
local task_defer = task.defer
local pairs = pairs
local ipairs = ipairs
local string_format = string.format
local string_byte = string.byte
local string_match = string.match
local string_sub = string.sub

local espTable = {}
local playersList = {}
local playerIndex = {}
local playerConnections = {}

local colorCache = setmetatable({}, { __mode = "k" })

local pendingQueue = {}
local pendingHead = 1
local pendingTail = 0
local pendingSet = {}

local forceRefreshQueue = {}
local forceRefreshHead = 1
local forceRefreshTail = 0
local forceRefreshSet = {}
local isForceRefreshing = false
local lastForceRefreshTime = 0

local frameCounter = 0

local enqueuePendingPlayer
local ensureESPFor
local rebuildESP
local forceRefreshPlayer

local function safeDestroy(obj)
	if not obj then
		return
	end

	pcall(function()
		if typeof(obj) == "Instance" then
			obj:Destroy()
		elseif type(obj) == "table" and obj.Destroy then
			obj:Destroy()
		end
	end)
end

local function safeDisconnect(conn)
	if not conn then
		return
	end

	pcall(function()
		if type(conn) == "function" then
			conn()
		elseif type(conn) == "table" and type(conn.Disconnect) == "function" then
			conn:Disconnect()
		elseif type(conn) == "table" and type(conn.disconnect) == "function" then
			conn:disconnect()
		end
	end)
end

local function clamp(v, a, b)
	return math_max(a, math_min(b, v))
end

local function parseHexColor(s)
	if type(s) ~= "string" then
		return nil
	end

	local m = string_match(s, "^#?([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])$")
	if not m then
		return nil
	end

	local r = tonumber(string_sub(m, 1, 2), 16) or 0
	local g = tonumber(string_sub(m, 3, 4), 16) or 0
	local b = tonumber(string_sub(m, 5, 6), 16) or 0
	return Color3.fromRGB(r, g, b)
end

local function hashColorFromString(str)
	if type(str) ~= "string" or #str == 0 then
		return FALLBACK_COLOR
	end

	local h = 0
	for i = 1, #str do
		h = (h * 31 + string_byte(str, i)) % 16777216
	end

	local r = math_floor(h / 65536) % 256
	local g = math_floor(h / 256) % 256
	local b = h % 256
	return Color3.fromRGB(r, g, b)
end

local function darkenColor(c)
	return Color3.new(
		clamp(c.R * OUTLINE_DARKEN_FACTOR, 0, 1),
		clamp(c.G * OUTLINE_DARKEN_FACTOR, 0, 1),
		clamp(c.B * OUTLINE_DARKEN_FACTOR, 0, 1)
	)
end

local function tintToWhite(c)
	return Color3.new(
		clamp(c.R + (1 - c.R) * FILL_TINT_AMOUNT, 0, 1),
		clamp(c.G + (1 - c.G) * FILL_TINT_AMOUNT, 0, 1),
		clamp(c.B + (1 - c.B) * FILL_TINT_AMOUNT, 0, 1)
	)
end

local function updateHighlightColors(highlight, baseColor)
	if not highlight or not baseColor then
		return
	end

	highlight.OutlineColor = darkenColor(baseColor)
	highlight.FillColor = tintToWhite(baseColor)
	highlight.FillTransparency = FILL_TRANSPARENCY
	highlight.OutlineTransparency = 0
end

local function createBillboard(player, head)
	if not head or not head.Parent then
		return nil
	end

	local success, gui = pcall(function()
		local newGui = Instance.new("BillboardGui")
		newGui.Name = "ESP_" .. player.UserId
		newGui.Adornee = head
		newGui.Size = BILLBOARD_SIZE
		newGui.StudsOffset = Vector3.new(0, 1.6, 0)
		newGui.AlwaysOnTop = true
		newGui.Parent = PlayerGui

		local healthLabel = Instance.new("TextLabel")
		healthLabel.Name = "Health"
		healthLabel.Size = UDim2.new(1, 0, 0.45, 0)
		healthLabel.Position = UDim2.new(0, 0, 0, 0)
		healthLabel.BackgroundTransparency = 1
		healthLabel.TextScaled = false
		healthLabel.Font = Enum.Font.SourceSansBold
		healthLabel.TextSize = NAME_TEXT_SIZE
		healthLabel.TextStrokeTransparency = 0.5
		healthLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
		healthLabel.Parent = newGui

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "Name"
		nameLabel.Size = UDim2.new(1, 0, 0.55, 0)
		nameLabel.Position = UDim2.new(0, 0, 0.45, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.TextScaled = false
		nameLabel.Font = Enum.Font.SourceSansBold
		nameLabel.TextSize = NAME_TEXT_SIZE
		nameLabel.TextStrokeTransparency = 0.5
		nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
		nameLabel.Parent = newGui

		return newGui
	end)

	return success and gui or nil
end

local function createHighlight(player, character, baseColor)
	if not character or not character.Parent then
		return nil
	end

	local success, highlight = pcall(function()
		local newHighlight = Instance.new("Highlight")
		newHighlight.Name = "Highlight_" .. player.UserId
		newHighlight.Adornee = character
		newHighlight.OutlineTransparency = 0
		newHighlight.FillTransparency = FILL_TRANSPARENCY
		updateHighlightColors(newHighlight, baseColor)
		newHighlight.Parent = Workspace
		return newHighlight
	end)

	return success and highlight or nil
end

local function factionBaseColor(player)
	if not player then
		return FALLBACK_COLOR
	end

	local cached = colorCache[player]
	if cached then
		return cached
	end

	local baseColor = FALLBACK_COLOR
	local attr = player:GetAttribute("Faction")
	if type(attr) == "string" and #attr > 0 then
		local hex = parseHexColor(attr)
		if hex then
			baseColor = hex
		end
	end

	if baseColor == FALLBACK_COLOR and player.Team then
		local success, color = pcall(function()
			return player.Team.TeamColor.Color
		end)
		if success then
			baseColor = color
		end
	end

	if baseColor == FALLBACK_COLOR then
		local key = player.Team and player.Team.Name or player.Name
		if key then
			baseColor = hashColorFromString(key)
		end
	end

	colorCache[player] = baseColor
	return baseColor
end

local function formatHealthString(cur, max)
	cur = math_floor(cur + 0.5)
	max = math_floor(max + 0.5)

	if cur <= 0 then
		return string_format("Dead %d/%d", cur, max)
	end
	return string_format("%d/%d", cur, max)
end

local function enqueuePendingPlayer(player)
	if not player or player == LocalPlayer or not player.Parent then
		return
	end

	if not pendingSet[player] then
		pendingTail = pendingTail + 1
		pendingQueue[pendingTail] = player
		pendingSet[player] = true
	end
end

local function enqueueForceRefresh(player)
	if not player or not player.Parent then
		return
	end

	if not forceRefreshSet[player] then
		forceRefreshTail = forceRefreshTail + 1
		forceRefreshQueue[forceRefreshTail] = player
		forceRefreshSet[player] = true
	end
end

local function disconnectHealthConnections(data)
	if not data or not data.healthConns then
		return
	end

	for i = 1, #data.healthConns do
		safeDisconnect(data.healthConns[i])
		data.healthConns[i] = nil
	end
end

local function bindHumanoidHealth(data, humanoid)
	disconnectHealthConnections(data)
	data.humanoid = humanoid
	data.lastHealth = -1
	data.lastMax = -1

	if not humanoid then
		if data.health then
			data.health.Text = "N/A"
		end
		return
	end

	local function refreshNow()
		local cur = math_floor((humanoid.Health or 0) + 0.5)
		local max = math_floor((humanoid.MaxHealth or 100) + 0.5)
		if data.health then
			data.health.Text = formatHealthString(cur, max)
		end
		data.lastHealth = cur
		data.lastMax = max
	end

	local hc = humanoid.HealthChanged:Connect(function(newHealth)
		local cur = math_floor(newHealth + 0.5)
		local max = math_floor((humanoid.MaxHealth or 100) + 0.5)
		if data.health then
			data.health.Text = formatHealthString(cur, max)
		end
		data.lastHealth = cur
		data.lastMax = max
	end)

	local mhc = humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		local cur = math_floor((humanoid.Health or 0) + 0.5)
		local max = math_floor((humanoid.MaxHealth or 100) + 0.5)
		if data.health then
			data.health.Text = formatHealthString(cur, max)
		end
		data.lastHealth = cur
		data.lastMax = max
	end)

	data.healthConns[1] = hc
	data.healthConns[2] = mhc

	refreshNow()
end

local function cleanupPlayer(player, fullCleanup)
	if not player then
		return
	end

	pendingSet[player] = nil
	forceRefreshSet[player] = nil

	local data = espTable[player]
	if data then
		if data.gui then
			safeDestroy(data.gui)
		end
		if data.highlight then
			safeDestroy(data.highlight)
		end

		disconnectHealthConnections(data)
		safeDisconnect(data.charChildConn)

		-- 关键修复：清理时重置 inserted，确保重生后能重新进入渲染列表
		data.inserted = false

		-- 清空残留引用，避免延迟回调误用旧实例
		data.gui = nil
		data.name = nil
		data.health = nil
		data.highlight = nil
		data.humanoid = nil
		data.charChildConn = nil
		data.lastHealth = -1
		data.lastMax = -1

		local idx = playerIndex[player]
		if idx then
			local lastIdx = #playersList
			local lastPlayer = playersList[lastIdx]
			if idx < lastIdx then
				playersList[idx] = lastPlayer
				playerIndex[lastPlayer] = idx
			end
			playersList[lastIdx] = nil
		end

		playerIndex[player] = nil
		espTable[player] = nil
	end

	if fullCleanup then
		local conns = playerConnections[player]
		if conns then
			for _, conn in ipairs(conns) do
				safeDisconnect(conn)
			end
			playerConnections[player] = nil
		end
		colorCache[player] = nil
	end
end

local function processPendingQueue()
	if pendingHead > pendingTail then
		return
	end

	local processed = 0
	while processed < BATCH_SIZE and pendingHead <= pendingTail do
		local player = pendingQueue[pendingHead]
		pendingQueue[pendingHead] = nil
		pendingHead = pendingHead + 1

		pendingSet[player] = nil
		if player and player.Parent then
			ensureESPFor(player)
		end

		processed = processed + 1
	end

	if pendingHead > pendingTail then
		pendingQueue = {}
		pendingHead = 1
		pendingTail = 0
	end
end

local function processForceRefreshQueue()
	if forceRefreshHead > forceRefreshTail then
		isForceRefreshing = false
		return
	end

	local processed = 0
	while processed < BATCH_SIZE and forceRefreshHead <= forceRefreshTail do
		local player = forceRefreshQueue[forceRefreshHead]
		forceRefreshQueue[forceRefreshHead] = nil
		forceRefreshHead = forceRefreshHead + 1

		forceRefreshSet[player] = nil
		if player and player.Parent then
			forceRefreshPlayer(player)
		end

		processed = processed + 1
	end

	if forceRefreshHead > forceRefreshTail then
		forceRefreshQueue = {}
		forceRefreshHead = 1
		forceRefreshTail = 0
		isForceRefreshing = false
	end
end

local function checkForceRefresh()
	local now = tick()
	if now - lastForceRefreshTime >= FORCE_REFRESH_INTERVAL then
		lastForceRefreshTime = now

		for player, data in pairs(espTable) do
			if player and player.Parent and data then
				enqueueForceRefresh(player)
			end
		end

		if forceRefreshHead <= forceRefreshTail then
			isForceRefreshing = true
		end
	end
end

ensureESPFor = function(player)
	if not player or player == LocalPlayer then
		return
	end

	local data = espTable[player]
	if not data then
		data = {
			gui = nil,
			name = nil,
			health = nil,
			highlight = nil,
			healthConns = {},
			humanoid = nil,
			charChildConn = nil,
			lastHealth = -1,
			lastMax = -1,
			inserted = false,
		}
		espTable[player] = data
	end

	local char = player.Character
	if not char then
		return
	end

	local head = char:FindFirstChild("Head")
	if not head then
		if data.charChildConn then
			return
		end

		local success, conn = pcall(function()
			return char.ChildAdded:Connect(function(child)
				if child.Name == "Head" and child:IsA("BasePart") then
					if data.charChildConn then
						safeDisconnect(data.charChildConn)
						data.charChildConn = nil
					end
					enqueuePendingPlayer(player)
				end
			end)
		end)

		if success then
			data.charChildConn = conn
		end

		task_delay(HEAD_WAIT_TIMEOUT, function()
			if data and data.charChildConn then
				safeDisconnect(data.charChildConn)
				data.charChildConn = nil
			end
			if player and player.Parent and player.Character == char and not char:FindFirstChild("Head") then
				enqueuePendingPlayer(player)
			end
		end)

		return
	end

	if not data.gui then
		local gui = createBillboard(player, head)
		if gui then
			data.gui = gui
			data.name = gui:FindFirstChild("Name")
			data.health = gui:FindFirstChild("Health")

			if data.name then
				data.name.Text = player.Name
				data.name.TextSize = NAME_TEXT_SIZE
			end
		end
	end

	local baseColor = factionBaseColor(player)
	local outlineColor = darkenColor(baseColor)

	if data.name then
		data.name.TextColor3 = outlineColor
	end
	if data.health then
		data.health.TextColor3 = outlineColor
	end

	if not data.highlight then
		local highlight = createHighlight(player, char, baseColor)
		if highlight then
			data.highlight = highlight
		end
	else
		data.highlight.Adornee = char
		data.highlight.Enabled = true
		updateHighlightColors(data.highlight, baseColor)
	end

	if data.gui then
		data.gui.Adornee = head
		data.gui.Enabled = true
	end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	bindHumanoidHealth(data, humanoid)

	if not data.inserted and data.gui then
		table_insert(playersList, player)
		playerIndex[player] = #playersList
		data.inserted = true
	end
end

rebuildESP = function(player)
	local data = espTable[player]
	if not data then
		ensureESPFor(player)
		return
	end

	local char = player.Character
	if not char then
		cleanupPlayer(player, false)
		return
	end

	local head = char:FindFirstChild("Head")
	if not head then
		cleanupPlayer(player, false)
		return
	end

	local oldGui = data.gui
	local oldHighlight = data.highlight

	local newGui = createBillboard(player, head)
	local baseColor = factionBaseColor(player)
	local newHighlight = createHighlight(player, char, baseColor)

	if newGui then
		data.gui = newGui
		data.name = newGui:FindFirstChild("Name")
		data.health = newGui:FindFirstChild("Health")

		if data.name then
			data.name.Text = player.Name
			data.name.TextSize = NAME_TEXT_SIZE
			data.name.TextColor3 = darkenColor(baseColor)
		end
		if data.health then
			data.health.TextColor3 = darkenColor(baseColor)
		end

		if oldGui then
			safeDestroy(oldGui)
		end
	end

	if newHighlight then
		data.highlight = newHighlight
		updateHighlightColors(newHighlight, baseColor)
		if oldHighlight then
			safeDestroy(oldHighlight)
		end
	end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	bindHumanoidHealth(data, humanoid)
end

forceRefreshPlayer = function(player)
	rebuildESP(player)
end

local function onPlayerAdded(player)
	if player == LocalPlayer then
		return
	end

	local conns = {}
	playerConnections[player] = conns

	local function refreshColor()
		colorCache[player] = nil
		enqueuePendingPlayer(player)
	end

	table_insert(conns, player:GetAttributeChangedSignal("Faction"):Connect(refreshColor))
	table_insert(conns, player:GetPropertyChangedSignal("Team"):Connect(refreshColor))
	table_insert(conns, player:GetPropertyChangedSignal("TeamColor"):Connect(refreshColor))

	table_insert(conns, player.AncestryChanged:Connect(function()
		if not player.Parent then
			cleanupPlayer(player, true)
		end
	end))

	table_insert(conns, player.CharacterAdded:Connect(function(character)
		task_defer(function()
			if player.Parent and player.Character == character then
				cleanupPlayer(player, false)
				enqueuePendingPlayer(player)
			end
		end)
	end))

	if player.Character then
		task_defer(function()
			enqueuePendingPlayer(player)
		end)
	else
		enqueuePendingPlayer(player)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	task_spawn(onPlayerAdded, player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	cleanupPlayer(player, true)
end)

RunService.Heartbeat:Connect(function()
	frameCounter = frameCounter + 1
	if frameCounter % FRAME_INTERVAL ~= 0 then
		return
	end

	checkForceRefresh()

	if isForceRefreshing then
		processForceRefreshQueue()
	else
		processPendingQueue()
	end
end)