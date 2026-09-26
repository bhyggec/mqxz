--玩家esp V1.3
--基于好友esp显示V1.3改进
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

local CONFIG = {
    UPDATE_RATE = 0.08,
    BATCH_SIZE = 5,
    BILLBOARD_SIZE = UDim2.new(0,160,0,36),
    NAME_TEXT_SIZE = 16,
    FALLBACK_COLOR = Color3.fromRGB(255, 255, 255),
    OUTLINE_DARKEN_FACTOR = 0.30,
    FILL_TINT_AMOUNT = 0.70,
    FILL_TRANSPARENCY = 0.55,
    HEAD_WAIT_TIMEOUT = 3,
    HEALTH_CACHE_CLEAN_INTERVAL = 60,
    FORCE_REFRESH_INTERVAL = 30,
}

local espTable = {}
local playersList = {}
local playerIndex = {}

local colorCache = setmetatable({}, { __mode = "k" })
local healthCache = setmetatable({}, { __mode = "v" })

local forceRefreshQueue = {}
local isForceRefreshing = false
local lastForceRefreshTime = 0

local function safeDestroy(obj)
    if obj and obj.Parent then
        pcall(function() obj:Destroy() end)
    end
end

local function safeDisconnect(conn)
    if conn then
        if type(conn) == "function" then
            pcall(conn)
        elseif type(conn.Disconnect) == "function" then
            pcall(conn.Disconnect, conn)
        end
    end
end

local function clamp(v, a, b)
    return math.max(a, math.min(b, v))
end

local function parseHexColor(s)
    if type(s) ~= "string" then return nil end
    local m = s:match("^#?([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])$")
    if not m then return nil end
    local r = tonumber(m:sub(1,2),16) or 0
    local g = tonumber(m:sub(3,4),16) or 0
    local b = tonumber(m:sub(5,6),16) or 0
    return Color3.fromRGB(r,g,b)
end

local function hashColorFromString(str)
    if type(str) ~= "string" or #str == 0 then return CONFIG.FALLBACK_COLOR end
    local h = 0
    for i = 1, #str do
        h = (h * 31 + str:byte(i)) % 16777216
    end
    local r = math.floor(h / 65536) % 256
    local g = math.floor(h / 256) % 256
    local b = h % 256
    return Color3.fromRGB(r,g,b)
end

local function darkenColor(c)
    return Color3.new(
        clamp(c.R * CONFIG.OUTLINE_DARKEN_FACTOR, 0, 1),
        clamp(c.G * CONFIG.OUTLINE_DARKEN_FACTOR, 0, 1),
        clamp(c.B * CONFIG.OUTLINE_DARKEN_FACTOR, 0, 1)
    )
end

local function tintToWhite(c)
    return Color3.new(
        clamp(c.R + (1 - c.R) * CONFIG.FILL_TINT_AMOUNT, 0, 1),
        clamp(c.G + (1 - c.G) * CONFIG.FILL_TINT_AMOUNT, 0, 1),
        clamp(c.B + (1 - c.B) * CONFIG.FILL_TINT_AMOUNT, 0, 1)
    )
end

local function updateHighlightColors(highlight, baseColor)
    if not highlight or not baseColor then return end
    highlight.OutlineColor = darkenColor(baseColor)
    highlight.FillColor = tintToWhite(baseColor)
    highlight.FillTransparency = CONFIG.FILL_TRANSPARENCY
    highlight.OutlineTransparency = 0
end

local function createBillboard(player, head)
    if not head or not head.Parent then return nil end
    local success, gui = pcall(function()
        local gui = Instance.new("BillboardGui")
        gui.Name = "ESP_" .. player.UserId
        gui.Adornee = head
        gui.Size = CONFIG.BILLBOARD_SIZE
        gui.StudsOffset = Vector3.new(0, 1.6, 0)
        gui.AlwaysOnTop = true
        gui.Parent = PlayerGui

        local healthLabel = Instance.new("TextLabel")
        healthLabel.Name = "Health"
        healthLabel.Size = UDim2.new(1,0,0.45,0)
        healthLabel.Position = UDim2.new(0,0,0,0)
        healthLabel.BackgroundTransparency = 1
        healthLabel.TextScaled = false
        healthLabel.Font = Enum.Font.SourceSansBold
        healthLabel.TextSize = CONFIG.NAME_TEXT_SIZE
        healthLabel.TextStrokeTransparency = 0.5
        healthLabel.TextStrokeColor3 = Color3.new(0,0,0)
        healthLabel.Parent = gui

        local nameLabel = Instance.new("TextLabel")
        nameLabel.Name = "Name"
        nameLabel.Size = UDim2.new(1,0,0.55,0)
        nameLabel.Position = UDim2.new(0,0,0.45,0)
        nameLabel.BackgroundTransparency = 1
        nameLabel.TextScaled = false
        nameLabel.Font = Enum.Font.SourceSansBold
        nameLabel.TextSize = CONFIG.NAME_TEXT_SIZE
        nameLabel.TextStrokeTransparency = 0.5
        nameLabel.TextStrokeColor3 = Color3.new(0,0,0)
        nameLabel.Parent = gui

        return gui
    end)
    if success then
        return gui
    else
        return nil
    end
end

local function createHighlight(character, baseColor)
    if not character or not character.Parent then return nil end
    local success, highlight = pcall(function()
        local highlight = Instance.new("Highlight")
        highlight.Name = "Highlight_" .. tostring(character)
        highlight.Adornee = character
        highlight.OutlineTransparency = 0
        highlight.FillTransparency = CONFIG.FILL_TRANSPARENCY
        updateHighlightColors(highlight, baseColor)
        highlight.Parent = Workspace
        return highlight
    end)
    if success then
        return highlight
    else
        return nil
    end
end

local function factionBaseColor(player)
    if not player then return CONFIG.FALLBACK_COLOR end

    if colorCache[player] then
        return colorCache[player]
    end

    local baseColor = CONFIG.FALLBACK_COLOR

    local attr = player:GetAttribute("Faction")
    if type(attr) == "string" and #attr > 0 then
        local hex = parseHexColor(attr)
        if hex then
            baseColor = hex
        end
    end

    if baseColor == CONFIG.FALLBACK_COLOR then
        if player.Team then
            local success, color = pcall(function() return player.Team.TeamColor.Color end)
            if success then
                baseColor = color
            end
        end
    end

    if baseColor == CONFIG.FALLBACK_COLOR then
        local key = player.Team and player.Team.Name or player.Name
        if key then
            baseColor = hashColorFromString(key)
        end
    end

    colorCache[player] = baseColor
    return baseColor
end

local function formatHealthString(cur, max)
    cur = math.floor(cur + 0.5)
    max = math.floor(max + 0.5)

    local cacheKey = cur * 100000 + max
    local cached = healthCache[cacheKey]

    if cached then
        return cached
    end

    local result
    if cur <= 0 then
        result = string.format("Dead %d/%d", cur, max)
    else
        result = string.format("%d/%d", cur, max)
    end

    healthCache[cacheKey] = result
    return result
end

task.spawn(function()
    while true do
        task.wait(CONFIG.HEALTH_CACHE_CLEAN_INTERVAL)
        healthCache = setmetatable({}, {__mode = "v"})
        collectgarbage("collect")
    end
end)

local function cleanupPlayer(player)
    if not player then return end

    local data = espTable[player]
    if not data then return end

    if data.gui then
        safeDestroy(data.gui)
    end

    if data.highlight then
        safeDestroy(data.highlight)
    end

    safeDisconnect(data.healthConn)
    safeDisconnect(data.charChildConn)
    safeDisconnect(data.charRemovingConn)

    local idx = playerIndex[player]
    if idx then
        local lastIdx = #playersList
        if idx < lastIdx then
            local lastPlayer = playersList[lastIdx]
            playersList[idx] = lastPlayer
            playerIndex[lastPlayer] = idx
        end
        playersList[lastIdx] = nil
    end

    playerIndex[player] = nil
    colorCache[player] = nil
    espTable[player] = nil

    for i = #forceRefreshQueue, 1, -1 do
        if forceRefreshQueue[i] == player then
            table.remove(forceRefreshQueue, i)
        end
    end
end

local function ensureESPFor(player)
    if not player or player == LocalPlayer then return end

    if playerIndex[player] and espTable[player] then
        return
    end

    local char = player.Character
    if not char then return end

    local head = char:FindFirstChild("Head")
    if not head then
        local headWaitConnection
        local success, conn = pcall(function()
            return char.ChildAdded:Connect(function(child)
                if child.Name == "Head" and child:IsA("BasePart") then
                    headWaitConnection:Disconnect()
                    ensureESPFor(player)
                end
            end)
        end)
        if success then
            headWaitConnection = conn
        end

        task.delay(CONFIG.HEAD_WAIT_TIMEOUT, function()
            if headWaitConnection then
                headWaitConnection:Disconnect()
            end
        end)

        return
    end

    local data = {
        gui = nil,
        name = nil,
        health = nil,
        highlight = nil,
        humanoid = nil,
        healthConn = nil,
        charChildConn = nil,
        charRemovingConn = nil,
        lastHealth = -1,
        lastMax = -1
    }

    espTable[player] = data
    table.insert(playersList, player)
    playerIndex[player] = #playersList

    local gui = createBillboard(player, head)
    if gui then
        data.gui = gui
        data.name = gui:FindFirstChild("Name")
        data.health = gui:FindFirstChild("Health")

        if data.name then
            data.name.Text = player.Name
            data.name.TextSize = CONFIG.NAME_TEXT_SIZE
        end
    end

    local baseColor = factionBaseColor(player)
    local highlight = createHighlight(char, baseColor)
    if highlight then
        data.highlight = highlight
    end

    local outlineColor = darkenColor(baseColor)
    if data.name then
        data.name.TextColor3 = outlineColor
    end
    if data.health then
        data.health.TextColor3 = outlineColor
    end

    data.humanoid = char:FindFirstChildOfClass("Humanoid")
    if data.humanoid then
        local curHealth = math.floor(data.humanoid.Health + 0.5)
        local maxHealth = math.floor((data.humanoid.MaxHealth or 100) + 0.5)

        if data.health then
            data.health.Text = formatHealthString(curHealth, maxHealth)
        end

        data.lastHealth = curHealth
        data.lastMax = maxHealth

        local healthChangedConn = data.humanoid.HealthChanged:Connect(function(newHealth)
            local cur = math.floor(newHealth + 0.5)
            local max = math.floor((data.humanoid.MaxHealth or 100) + 0.5)

            if data.health then
                data.health.Text = formatHealthString(cur, max)
            end

            data.lastHealth = cur
            data.lastMax = max
        end)

        local maxHealthChangedConn = data.humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
            local cur = math.floor((data.humanoid.Health or 0) + 0.5)
            local max = math.floor((data.humanoid.MaxHealth or 100) + 0.5)

            if data.health then
                data.health.Text = formatHealthString(cur, max)
            end

            data.lastHealth = cur
            data.lastMax = max
        end)

        data.healthConn = function()
            healthChangedConn:Disconnect()
            maxHealthChangedConn:Disconnect()
        end
    elseif data.health then
        data.health.Text = "N/A"
    end

    if char then
        local success, conn = pcall(function()
            return char:GetPropertyChangedSignal("Parent"):Connect(function()
                if not char.Parent then
                    cleanupPlayer(player)
                end
            end)
        end)
        if success then
            data.charRemovingConn = conn
        end
    end
end

local function updateSinglePlayer(player)
    if not player or not player.Parent then
        cleanupPlayer(player)
        return
    end

    local data = espTable[player]
    if not data then
        ensureESPFor(player)
        return
    end

    local char = player.Character
    if not char then
        if data.gui then data.gui.Enabled = false end
        if data.highlight then data.highlight.Enabled = false end
        return
    end

    local head = char:FindFirstChild("Head")
    if not head then
        if data.gui then data.gui.Enabled = false end
        if data.highlight then data.highlight.Enabled = false end
        return
    end

    pcall(function()
        if data.gui then
            data.gui.Adornee = head
            data.gui.Enabled = true
        end

        if data.highlight then
            data.highlight.Adornee = char
            data.highlight.Enabled = true
        end

        local baseColor = factionBaseColor(player)
        local outlineColor = darkenColor(baseColor)

        if data.name then
            data.name.TextColor3 = outlineColor
        end
        if data.health then
            data.health.TextColor3 = outlineColor
        end

        if data.highlight then
            updateHighlightColors(data.highlight, baseColor)
        end

        if data.humanoid and data.humanoid.Parent == char then
            local cur = math.floor(data.humanoid.Health + 0.5)
            local max = math.floor((data.humanoid.MaxHealth or 100) + 0.5)

            if cur ~= data.lastHealth or max ~= data.lastMax then
                if data.health then
                    data.health.Text = formatHealthString(cur, max)
                end
                data.lastHealth = cur
                data.lastMax = max
            end
        end
    end)
end

local function forceRefreshPlayer(player)
    local data = espTable[player]
    if not data then return end

    if data.highlight then
        safeDestroy(data.highlight)
        data.highlight = nil
    end

    local char = player.Character
    if char and char.Parent then
        local baseColor = factionBaseColor(player)
        local success, newHighlight = pcall(function()
            return createHighlight(char, baseColor)
        end)
        if success and newHighlight then
            data.highlight = newHighlight
        end
    end
end

local function checkForceRefresh()
    local now = tick()
    if now - lastForceRefreshTime >= CONFIG.FORCE_REFRESH_INTERVAL then
        lastForceRefreshTime = now
        for player in pairs(espTable) do
            if player and player.Parent then
                table.insert(forceRefreshQueue, player)
            end
        end
        if #forceRefreshQueue > 0 then
            isForceRefreshing = true
        end
    end
end

local function processForceRefreshQueue()
    if #forceRefreshQueue == 0 then
        isForceRefreshing = false
        return
    end

    local processed = 0
    while processed < CONFIG.BATCH_SIZE and #forceRefreshQueue > 0 do
        local player = forceRefreshQueue[1]
        table.remove(forceRefreshQueue, 1)
        if player and player.Parent then
            forceRefreshPlayer(player)
        end
        processed = processed + 1
    end

    if #forceRefreshQueue == 0 then
        isForceRefreshing = false
    end
end

local function onPlayerAdded(player)
    if player == LocalPlayer then return end

    local function refreshColor()
        colorCache[player] = nil
        ensureESPFor(player)
    end

    player:GetAttributeChangedSignal("Faction"):Connect(refreshColor)
    player:GetPropertyChangedSignal("Team"):Connect(refreshColor)
    player:GetPropertyChangedSignal("TeamColor"):Connect(refreshColor)

    if player.Character then
        task.defer(ensureESPFor, player)
    end

    player.CharacterAdded:Connect(function()
        task.delay(0.1, function()
            if player.Parent then
                cleanupPlayer(player)
                ensureESPFor(player)
            end
        end)
    end)

    player.AncestryChanged:Connect(function()
        if not player.Parent then
            cleanupPlayer(player)
        end
    end)
end

for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(cleanupPlayer)

local cursor = 1
local acc = 0

RunService.Heartbeat:Connect(function(dt)
    acc = acc + dt
    if acc < CONFIG.UPDATE_RATE then return end
    acc = 0

    checkForceRefresh()

    if isForceRefreshing then
        processForceRefreshQueue()
        return
    end

    local totalPlayers = #playersList
    if totalPlayers == 0 then return end

    for i = 1, CONFIG.BATCH_SIZE do
        if cursor > totalPlayers then
            cursor = 1
        end
        local player = playersList[cursor]
        if player then
            updateSinglePlayer(player)
        end
        cursor = cursor + 1
        totalPlayers = #playersList
        if totalPlayers == 0 then break end
    end
end)