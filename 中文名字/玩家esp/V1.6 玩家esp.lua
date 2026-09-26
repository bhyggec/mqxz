--玩家esp V1.6
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

local BATCH_SIZE = 1  --每次处理几个玩家
local FRAME_INTERVAL = 2  -- 每多少帧处理一次（1 = 每帧，2 = 隔帧）
local BILLBOARD_SIZE = UDim2.new(0,160,0,36)
local NAME_TEXT_SIZE = 16
local FALLBACK_COLOR = Color3.fromRGB(255, 255, 255)
local OUTLINE_DARKEN_FACTOR = 0.30
local FILL_TINT_AMOUNT = 0.70
local FILL_TRANSPARENCY = 0.55
local HEAD_WAIT_TIMEOUT = 3
local HEALTH_CACHE_CLEAN_INTERVAL = 60
local FORCE_REFRESH_INTERVAL = 30

local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local table_insert = table.insert
local table_remove = table.remove
local tick = tick
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
local tostring = tostring

local espTable = {}
local playersList = {}
local playerIndex = {}
local playerConnections = {}

local colorCache = setmetatable({}, { __mode = "k" })
local healthCache = setmetatable({}, { __mode = "v" })

local forceRefreshQueue = {}
local forceRefreshSet = {}
local isForceRefreshing = false
local lastForceRefreshTime = 0

local frameCounter = 0   -- 帧计数器，替代原来的时间累计

-- 稳健的 safeDestroy
local function safeDestroy(obj)
    if not obj then return end
    pcall(function()
        if typeof(obj) == "Instance" and obj.Destroy then
            obj:Destroy()
        elseif type(obj) == "table" and obj.Destroy then
            obj:Destroy()
        end
    end)
end

-- 稳健的 safeDisconnect
local function safeDisconnect(conn)
    if not conn then return end
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
    if type(s) ~= "string" then return nil end
    local m = string_match(s, "^#?([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])$")
    if not m then return nil end
    local r = tonumber(string_sub(m,1,2),16) or 0
    local g = tonumber(string_sub(m,3,4),16) or 0
    local b = tonumber(string_sub(m,5,6),16) or 0
    return Color3.fromRGB(r,g,b)
end

local function hashColorFromString(str)
    if type(str) ~= "string" or #str == 0 then return FALLBACK_COLOR end
    local h = 0
    for i = 1, #str do
        h = (h * 31 + string_byte(str, i)) % 16777216
    end
    local r = math_floor(h / 65536) % 256
    local g = math_floor(h / 256) % 256
    local b = h % 256
    return Color3.fromRGB(r,g,b)
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
    if not highlight or not baseColor then return end
    highlight.OutlineColor = darkenColor(baseColor)
    highlight.FillColor = tintToWhite(baseColor)
    highlight.FillTransparency = FILL_TRANSPARENCY
    highlight.OutlineTransparency = 0
end

local function createBillboard(player, head)
    if not head or not head.Parent then return nil end
    local success, gui = pcall(function()
        local gui = Instance.new("BillboardGui")
        gui.Name = "ESP_" .. player.UserId
        gui.Adornee = head
        gui.Size = BILLBOARD_SIZE
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
        healthLabel.TextSize = NAME_TEXT_SIZE
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
        nameLabel.TextSize = NAME_TEXT_SIZE
        nameLabel.TextStrokeTransparency = 0.5
        nameLabel.TextStrokeColor3 = Color3.new(0,0,0)
        nameLabel.Parent = gui

        return gui
    end)
    return success and gui or nil
end

local function createHighlight(player, character, baseColor)
    if not character or not character.Parent then return nil end
    local success, highlight = pcall(function()
        local highlight = Instance.new("Highlight")
        highlight.Name = "Highlight_" .. player.UserId
        highlight.Adornee = character
        highlight.OutlineTransparency = 0
        highlight.FillTransparency = FILL_TRANSPARENCY
        updateHighlightColors(highlight, baseColor)
        highlight.Parent = Workspace
        return highlight
    end)
    return success and highlight or nil
end

local function factionBaseColor(player)
    if not player then return FALLBACK_COLOR end

    local cached = colorCache[player]
    if cached then return cached end

    local baseColor = FALLBACK_COLOR
    local attr = player:GetAttribute("Faction")
    if type(attr) == "string" and #attr > 0 then
        local hex = parseHexColor(attr)
        if hex then baseColor = hex end
    end

    if baseColor == FALLBACK_COLOR and player.Team then
        local success, color = pcall(function()
            return player.Team.TeamColor.Color
        end)
        if success then baseColor = color end
    end

    if baseColor == FALLBACK_COLOR then
        local key = player.Team and player.Team.Name or player.Name
        if key then baseColor = hashColorFromString(key) end
    end

    colorCache[player] = baseColor
    return baseColor
end

local function formatHealthString(cur, max)
    cur = math_floor(cur + 0.5)
    max = math_floor(max + 0.5)
    local cacheKey = cur .. "|" .. max
    local cached = healthCache[cacheKey]
    if cached then return cached end
    local result = cur <= 0
        and string_format("Dead %d/%d", cur, max)
        or string_format("%d/%d", cur, max)
    healthCache[cacheKey] = result
    return result
end

task_spawn(function()
    while true do
        task_wait(HEALTH_CACHE_CLEAN_INTERVAL)
        healthCache = setmetatable({}, {__mode = "v"})
        collectgarbage("collect")
    end
end)

local function cleanupPlayer(player, fullCleanup)
    if not player then return end
    local data = espTable[player]
    if data then
        if data.gui then safeDestroy(data.gui) end
        if data.highlight then safeDestroy(data.highlight) end

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
            table_remove(playersList, lastIdx)
        end
        playerIndex[player] = nil
        espTable[player] = nil
    end

    if forceRefreshSet[player] then
        forceRefreshSet[player] = nil
        for i = #forceRefreshQueue, 1, -1 do
            if forceRefreshQueue[i] == player then
                table_remove(forceRefreshQueue, i)
                break
            end
        end
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

local function ensureESPFor(player)
    if not player or player == LocalPlayer then return end

    local data = espTable[player]
    if not data then
        data = {
            gui = nil, name = nil, health = nil, highlight = nil,
            humanoid = nil, healthConn = nil, charChildConn = nil, charRemovingConn = nil,
            lastHealth = -1, lastMax = -1,
            inserted = false
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
                    ensureESPFor(player)
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
    if not data.highlight then
        local highlight = createHighlight(player, char, baseColor)
        if highlight then data.highlight = highlight end
    end

    local outlineColor = darkenColor(baseColor)
    if data.name then data.name.TextColor3 = outlineColor end
    if data.health then data.health.TextColor3 = outlineColor end
    if data.highlight then updateHighlightColors(data.highlight, baseColor) end

    data.humanoid = char:FindFirstChildOfClass("Humanoid")
    if data.humanoid then
        safeDisconnect(data.healthConn)

        local cur = math_floor(data.humanoid.Health + 0.5)
        local max = math_floor((data.humanoid.MaxHealth or 100) + 0.5)
        if data.health then
            data.health.Text = formatHealthString(cur, max)
        end
        data.lastHealth, data.lastMax = cur, max

        local hc = data.humanoid.HealthChanged:Connect(function(newHealth)
            local cur = math_floor(newHealth + 0.5)
            local max = math_floor((data.humanoid.MaxHealth or 100) + 0.5)
            if data.health then data.health.Text = formatHealthString(cur, max) end
            data.lastHealth, data.lastMax = cur, max
        end)

        local mhc = data.humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
            local cur = math_floor((data.humanoid.Health or 0) + 0.5)
            local max = math_floor((data.humanoid.MaxHealth or 100) + 0.5)
            if data.health then data.health.Text = formatHealthString(cur, max) end
            data.lastHealth, data.lastMax = cur, max
        end)

        data.healthConn = function()
            hc:Disconnect()
            mhc:Disconnect()
        end
    elseif data.health then
        data.health.Text = "N/A"
    end

    if not data.charRemovingConn then
        local success, conn = pcall(function()
            return char:GetPropertyChangedSignal("Parent"):Connect(function()
                if not char.Parent then cleanupPlayer(player, false) end
            end)
        end)
        if success then data.charRemovingConn = conn end
    end

    if not data.inserted and data.gui then
        table_insert(playersList, player)
        playerIndex[player] = #playersList
        data.inserted = true
    end
end

local function updateSinglePlayer(player)
    if not player or not player.Parent then
        cleanupPlayer(player, true)
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

        if data.name then data.name.TextColor3 = outlineColor end
        if data.health then data.health.TextColor3 = outlineColor end
        if data.highlight then updateHighlightColors(data.highlight, baseColor) end

        if data.humanoid and data.humanoid.Parent == char then
            local cur = math_floor(data.humanoid.Health + 0.5)
            local max = math_floor((data.humanoid.MaxHealth or 100) + 0.5)
            if cur ~= data.lastHealth or max ~= data.lastMax then
                if data.health then data.health.Text = formatHealthString(cur, max) end
                data.lastHealth, data.lastMax = cur, max
            end
        end
    end)
end

local function rebuildESP(player)
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
    local oldHealthConn = data.healthConn

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
        end
        local outlineColor = darkenColor(baseColor)
        if data.name then data.name.TextColor3 = outlineColor end
        if data.health then data.health.TextColor3 = outlineColor end
        if oldGui then safeDestroy(oldGui) end
    end

    if newHighlight then
        data.highlight = newHighlight
        updateHighlightColors(newHighlight, baseColor)
        if oldHighlight then safeDestroy(oldHighlight) end
    end

    data.humanoid = char:FindFirstChildOfClass("Humanoid")
    safeDisconnect(oldHealthConn)

    if data.humanoid then
        local hc = data.humanoid.HealthChanged:Connect(function(newHealth)
            local cur = math_floor(newHealth + 0.5)
            local max = math_floor((data.humanoid.MaxHealth or 100) + 0.5)
            if data.health then data.health.Text = formatHealthString(cur, max) end
            data.lastHealth, data.lastMax = cur, max
        end)

        local mhc = data.humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
            local cur = math_floor((data.humanoid.Health or 0) + 0.5)
            local max = math_floor((data.humanoid.MaxHealth or 100) + 0.5)
            if data.health then data.health.Text = formatHealthString(cur, max) end
            data.lastHealth, data.lastMax = cur, max
        end)

        data.healthConn = function()
            hc:Disconnect()
            mhc:Disconnect()
        end

        local cur = math_floor(data.humanoid.Health + 0.5)
        local max = math_floor((data.humanoid.MaxHealth or 100) + 0.5)
        if data.health then
            data.health.Text = formatHealthString(cur, max)
        end
        data.lastHealth, data.lastMax = cur, max
    else
        data.healthConn = nil
        if data.health then
            data.health.Text = "N/A"
        end
    end
end

local function forceRefreshPlayer(player)
    rebuildESP(player)
end

local function enqueueForceRefresh(player)
    if not player or not player.Parent then return end
    if not forceRefreshSet[player] then
        table_insert(forceRefreshQueue, player)
        forceRefreshSet[player] = true
    end
end

local function checkForceRefresh()
    local now = tick()
    if now - lastForceRefreshTime >= FORCE_REFRESH_INTERVAL then
        lastForceRefreshTime = now
        for player, _ in pairs(espTable) do
            if player and player.Parent then
                enqueueForceRefresh(player)
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
    while processed < BATCH_SIZE and #forceRefreshQueue > 0 do
        local player = forceRefreshQueue[1]
        table_remove(forceRefreshQueue, 1)
        forceRefreshSet[player] = nil
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

    local conns = {}
    playerConnections[player] = conns

    local function refreshColor()
        colorCache[player] = nil
        ensureESPFor(player)
    end

    table_insert(conns, player:GetAttributeChangedSignal("Faction"):Connect(refreshColor))
    table_insert(conns, player:GetPropertyChangedSignal("Team"):Connect(refreshColor))
    table_insert(conns, player:GetPropertyChangedSignal("TeamColor"):Connect(refreshColor))

    table_insert(conns, player.AncestryChanged:Connect(function()
        if not player.Parent then cleanupPlayer(player, true) end
    end))

    if player.Character then
        task_defer(ensureESPFor, player)
    end

    table_insert(conns, player.CharacterAdded:Connect(function()
        task_delay(0.1, function()
            if player.Parent then
                cleanupPlayer(player, false)
                ensureESPFor(player)
            end
        end)
    end))
end

for _, player in ipairs(Players:GetPlayers()) do
    task_spawn(onPlayerAdded, player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
    cleanupPlayer(player, true)
end)

local cursor = 1

-- 新的 Heartbeat 逻辑：完全基于帧数驱动
RunService.Heartbeat:Connect(function(dt)
    frameCounter = frameCounter + 1

    -- 只有每隔 FRAME_INTERVAL 帧才做实际更新
    if frameCounter % FRAME_INTERVAL ~= 0 then
        return
    end

    -- 检查并启动 30 秒强刷（仅标记，轻量操作）
    checkForceRefresh()

    if isForceRefreshing then
        -- 强刷也遵循相同的帧间隔，每次只处理 BATCH_SIZE 个
        processForceRefreshQueue()
    else
        -- 常规循环更新玩家
        local total = #playersList
        if total == 0 then return end

        for i = 1, BATCH_SIZE do
            if cursor > total then cursor = 1 end
            local player = playersList[cursor]
            if player then
                updateSinglePlayer(player)
            end
            cursor = cursor + 1
            total = #playersList
            if total == 0 then break end
        end
    end
end)