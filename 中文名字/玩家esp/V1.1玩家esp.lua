--玩家esp V1.1
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- 确保LocalPlayer存在
local LocalPlayer
while not LocalPlayer do
    LocalPlayer = Players.LocalPlayer
    if not LocalPlayer then
        wait(0.1)
    end
end

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- ===== CONFIG =====
local CONFIG = {
    UPDATE_RATE = 0.08,
    TARGET_BATCH_MS = 8,
    MIN_BATCH = 1,
    MAX_BATCH = 10,
    BILLBOARD_SIZE = UDim2.new(0,160,0,36),
    NAME_TEXT_SIZE = 16,
    FALLBACK_COLOR = Color3.fromRGB(255, 255, 255), -- 改为白色，更容易看到
    OUTLINE_DARKEN_FACTOR = 0.30,
    FILL_TINT_AMOUNT = 0.70,
    FILL_TRANSPARENCY = 0.55,
    HEAD_WAIT_TIMEOUT = 3,
    HEALTH_CACHE_CLEAN_INTERVAL = 60,
    ADAPT_SMOOTH = 0.18,
    MAX_DISTANCE = 300, -- 添加距离限制
}
-- ==================

-- 状态与缓存
local espTable = {}
local playersList = {}
local playerIndex = {}

-- 弱引用缓存
local colorCache = setmetatable({}, { __mode = "k" })
local healthCache = setmetatable({}, { __mode = "v" })

-- 对象池
local guiPool = {}
local highlightPool = {}

-- ===== 工具函数 =====
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

-- ===== 对象池 =====
local function acquireGui()
    for i = #guiPool, 1, -1 do
        local g = guiPool[i]
        if g and not g.Parent then
            table.remove(guiPool, i)
            g.Enabled = true
            return g
        end
    end
    
    local gui = Instance.new("BillboardGui")
    gui.Size = CONFIG.BILLBOARD_SIZE
    gui.StudsOffset = Vector3.new(0, 1.6, 0)
    gui.AlwaysOnTop = true
    gui.Enabled = true
    
    local healthLabel = Instance.new("TextLabel")
    healthLabel.Name = "Health"
    healthLabel.Size = UDim2.new(1, 0, 0.45, 0)
    healthLabel.Position = UDim2.new(0, 0, 0, 0)
    healthLabel.BackgroundTransparency = 1
    healthLabel.TextScaled = false
    healthLabel.Font = Enum.Font.SourceSansBold
    healthLabel.TextSize = CONFIG.NAME_TEXT_SIZE
    healthLabel.TextStrokeTransparency = 0.5
    healthLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    healthLabel.Parent = gui
    
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "Name"
    nameLabel.Size = UDim2.new(1, 0, 0.55, 0)
    nameLabel.Position = UDim2.new(0, 0, 0.45, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.TextScaled = false
    nameLabel.Font = Enum.Font.SourceSansBold
    nameLabel.TextSize = CONFIG.NAME_TEXT_SIZE
    nameLabel.TextStrokeTransparency = 0.5
    nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    nameLabel.Parent = gui
    
    return gui
end

local function releaseGui(gui)
    if not gui then return end
    gui.Adornee = nil
    gui.Enabled = false
    gui.Parent = nil
    table.insert(guiPool, gui)
end

local function acquireHighlight()
    for i = #highlightPool, 1, -1 do
        local h = highlightPool[i]
        if h and not h.Parent then
            table.remove(highlightPool, i)
            h.Enabled = true
            return h
        end
    end
    
    local h = Instance.new("Highlight")
    h.OutlineTransparency = 0
    h.FillTransparency = CONFIG.FILL_TRANSPARENCY
    h.Enabled = true
    return h
end

local function releaseHighlight(h)
    if not h then return end
    h.Adornee = nil
    h.Enabled = false
    h.Parent = nil
    table.insert(highlightPool, h)
end

-- ===== 颜色判定 =====
local function factionBaseColor(player)
    if not player then return CONFIG.FALLBACK_COLOR end
    
    if colorCache[player] then
        return colorCache[player]
    end
    
    local baseColor = CONFIG.FALLBACK_COLOR
    
    -- 1. 检查Faction属性
    local attr = player:GetAttribute("Faction")
    if type(attr) == "string" and #attr > 0 then
        local hex = parseHexColor(attr)
        if hex then
            baseColor = hex
        end
    end
    
    -- 2. 检查队伍颜色
    if not baseColor or baseColor == CONFIG.FALLBACK_COLOR then
        if player.Team then
            baseColor = player.Team.TeamColor.Color
        end
    end
    
    -- 3. 哈希回退
    if not baseColor or baseColor == CONFIG.FALLBACK_COLOR then
        local key = player.Team and player.Team.Name or player.Name
        if key then
            baseColor = hashColorFromString(key)
        end
    end
    
    colorCache[player] = baseColor
    return baseColor
end

-- ===== 健康值格式化 =====
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

-- 定期清理缓存
task.spawn(function()
    while true do
        wait(CONFIG.HEALTH_CACHE_CLEAN_INTERVAL)
        healthCache = setmetatable({}, {__mode = "v"})
        collectgarbage("collect")
    end
end)

-- ===== 玩家ESP管理 =====
local function cleanupPlayer(player)
    if not player then return end
    
    local data = espTable[player]
    if not data then return end
    
    -- 清理GUI
    if data.gui then
        releaseGui(data.gui)
    end
    
    -- 清理高光
    if data.highlight then
        releaseHighlight(data.highlight)
    end
    
    -- 断开连接
    safeDisconnect(data.healthConn)
    safeDisconnect(data.charChildConn)
    safeDisconnect(data.charRemovingConn)
    
    -- 从列表中移除
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
end

local function ensureESPFor(player)
    if not player or player == LocalPlayer then return end
    
    -- 检查玩家是否已在列表中
    if playerIndex[player] and espTable[player] then
        return -- 已经初始化过了
    end
    
    local char = player.Character
    if not char then return end
    
    local head = char:FindFirstChild("Head")
    if not head then
        -- 如果头部不存在，等待它出现
        local headWaitConnection
        headWaitConnection = char.ChildAdded:Connect(function(child)
            if child.Name == "Head" and child:IsA("BasePart") then
                headWaitConnection:Disconnect()
                ensureESPFor(player)
            end
        end)
        
        -- 设置超时
        task.delay(CONFIG.HEAD_WAIT_TIMEOUT, function()
            if headWaitConnection then
                headWaitConnection:Disconnect()
            end
        end)
        
        return
    end
    
    -- 初始化数据
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
    
    -- 创建GUI
    local gui = acquireGui()
    if gui then
        gui.Name = "ESP_" .. player.UserId
        gui.Adornee = head
        gui.Parent = PlayerGui
        
        data.gui = gui
        data.name = gui:FindFirstChild("Name")
        data.health = gui:FindFirstChild("Health")
        
        if data.name then
            data.name.Text = player.Name
            data.name.TextSize = CONFIG.NAME_TEXT_SIZE
        end
    end
    
    -- 创建高光
    local baseColor = factionBaseColor(player)
    local highlight = acquireHighlight()
    if highlight then
        highlight.Name = "Highlight_" .. player.UserId
        highlight.Adornee = char
        updateHighlightColors(highlight, baseColor)
        highlight.Parent = Workspace
        data.highlight = highlight
    end
    
    -- 更新文本颜色
    local outlineColor = darkenColor(baseColor)
    if data.name then
        data.name.TextColor3 = outlineColor
    end
    if data.health then
        data.health.TextColor3 = outlineColor
    end
    
    -- 连接Humanoid事件
    data.humanoid = char:FindFirstChildOfClass("Humanoid")
    if data.humanoid then
        -- 立即更新一次
        local curHealth = math.floor(data.humanoid.Health + 0.5)
        local maxHealth = math.floor((data.humanoid.MaxHealth or 100) + 0.5)
        
        if data.health then
            data.health.Text = formatHealthString(curHealth, maxHealth)
        end
        
        data.lastHealth = curHealth
        data.lastMax = maxHealth
        
        -- 连接事件
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
    
    -- 角色移除监听
    if char then
        data.charRemovingConn = char:GetPropertyChangedSignal("Parent"):Connect(function()
            if not char.Parent then
                cleanupPlayer(player)
            end
        end)
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
    
    -- 距离检查
    local localChar = LocalPlayer.Character
    local localHead = localChar and localChar:FindFirstChild("Head")
    if localHead then
        local distance = (head.Position - localHead.Position).Magnitude
        if distance > CONFIG.MAX_DISTANCE then
            if data.gui then data.gui.Enabled = false end
            if data.highlight then data.highlight.Enabled = false end
            return
        end
    end
    
    -- 启用显示
    if data.gui then
        data.gui.Adornee = head
        data.gui.Enabled = true
    end
    
    if data.highlight then
        data.highlight.Adornee = char
        data.highlight.Enabled = true
    end
    
    -- 更新颜色
    local baseColor = factionBaseColor(player)
    local outlineColor = darkenColor(baseColor)
    
    if data.name then
        data.name.TextColor3 = outlineColor
    end
    if data.health then
        data.health.TextColor3 = outlineColor
    end
    
    -- 更新高光颜色
    if data.highlight then
        updateHighlightColors(data.highlight, baseColor)
    end
    
    -- 后备健康值检查
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
end

-- ===== 玩家加入/离开处理 =====
local function onPlayerAdded(player)
    if player == LocalPlayer then return end
    
    -- 颜色刷新函数
    local function refreshColor()
        colorCache[player] = nil
        ensureESPFor(player)
    end
    
    -- 连接属性变化事件
    player:GetAttributeChangedSignal("Faction"):Connect(refreshColor)
    player:GetPropertyChangedSignal("Team"):Connect(refreshColor)
    player:GetPropertyChangedSignal("TeamColor"):Connect(refreshColor)
    
    -- 初始设置
    if player.Character then
        task.defer(ensureESPFor, player)
    end
    
    -- 角色添加事件
    player.CharacterAdded:Connect(function()
        task.delay(0.1, function()
            if player.Parent then
                ensureESPFor(player)
            end
        end)
    end)
    
    -- 玩家离开
    player.AncestryChanged:Connect(function()
        if not player.Parent then
            cleanupPlayer(player)
        end
    end)
end

-- 初始化现有玩家
for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(cleanupPlayer)

-- ===== 自适应更新循环 =====
local cursor = 1
local acc = 0
local avgMsPerPlayer = 0.001
local batchTarget = CONFIG.MIN_BATCH

RunService.Heartbeat:Connect(function(dt)
    acc = acc + dt
    if acc < CONFIG.UPDATE_RATE then return end
    acc = 0
    
    local totalPlayers = #playersList
    if totalPlayers == 0 then return end
    
    -- 自适应批量大小
    batchTarget = clamp(batchTarget, CONFIG.MIN_BATCH, CONFIG.MAX_BATCH)
    
    local processed = 0
    local startTime = tick()
    
    while processed < batchTarget and totalPlayers > 0 do
        if cursor > totalPlayers then
            cursor = 1
        end
        
        local player = playersList[cursor]
        if player then
            updateSinglePlayer(player)
        end
        
        cursor = cursor + 1
        processed = processed + 1
        totalPlayers = #playersList
    end
    
    -- 性能统计
    local elapsed = (tick() - startTime) * 1000
    local perPlayer = processed > 0 and (elapsed / processed) or 0.0001
    
    -- 平滑平均
    avgMsPerPlayer = avgMsPerPlayer + (perPlayer - avgMsPerPlayer) * CONFIG.ADAPT_SMOOTH
    
    -- 调整批量目标
    local desired = math.floor((CONFIG.TARGET_BATCH_MS / math.max(avgMsPerPlayer, 0.0001)) + 0.5)
    desired = clamp(desired, CONFIG.MIN_BATCH, CONFIG.MAX_BATCH)
    
    if desired > batchTarget then
        batchTarget = math.min(batchTarget + 1, CONFIG.MAX_BATCH)
    elseif desired < batchTarget then
        batchTarget = math.max(batchTarget - 1, CONFIG.MIN_BATCH)
    end
end)

print("ESP系统已加载 - 本地运行")