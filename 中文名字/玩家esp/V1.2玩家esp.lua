--玩家esp V1.2
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- 等待LocalPlayer
local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    wait(0.1)
    LocalPlayer = Players.LocalPlayer
end

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- 配置
local CONFIG = {
    UPDATE_RATE = 0.08,
    BATCH_SIZE = 4,
    BILLBOARD_SIZE = UDim2.new(0, 160, 0, 36),
    NAME_TEXT_SIZE = 16,
    FALLBACK_COLOR = Color3.fromRGB(255, 255, 255),
    OUTLINE_DARKEN = 0.30,
    FILL_TINT = 0.70,
    FILL_TRANSPARENCY = 0.55,
    MAX_DISTANCE = 300,
    BACKUP_CHECK_INTERVAL = 60
}

-- 状态管理
local espTable = {}
local playersList = {}
local playerIndex = {}
local colorCache = setmetatable({}, { __mode = "k" })
local healthCache = setmetatable({}, { __mode = "v" })

-- 颜色处理函数
local function parseHexColor(hex)
    if not hex or type(hex) ~= "string" then return nil end
    local cleanHex = hex:match("^#?(%x%x%x%x%x%x)$")
    if not cleanHex then return nil end
    return Color3.fromRGB(
        tonumber(cleanHex:sub(1, 2), 16) or 0,
        tonumber(cleanHex:sub(3, 4), 16) or 0,
        tonumber(cleanHex:sub(5, 6), 16) or 0
    )
end

local function getBaseColor(player)
    if colorCache[player] then return colorCache[player] end
    
    local base = CONFIG.FALLBACK_COLOR
    
    -- 1. Faction属性
    local faction = player:GetAttribute("Faction")
    if type(faction) == "string" then
        local hexColor = parseHexColor(faction)
        if hexColor then
            base = hexColor
            colorCache[player] = base
            return base
        end
    end
    
    -- 2. 队伍颜色
    if player.Team then
        base = player.Team.TeamColor.Color
        colorCache[player] = base
        return base
    end
    
    -- 3. 回退到名字哈希
    local hash = 0
    for i = 1, #player.Name do
        hash = (hash * 31 + player.Name:byte(i)) % 16777216
    end
    base = Color3.fromRGB(
        math.floor(hash / 65536) % 256,
        math.floor(hash / 256) % 256,
        hash % 256
    )
    
    colorCache[player] = base
    return base
end

-- 工具函数
local function safeDestroy(obj)
    if obj and obj.Parent then
        pcall(obj.Destroy, obj)
    end
end

local function safeDisconnect(conn)
    if conn and type(conn) == "function" then
        conn()
    elseif conn and type(conn.Disconnect) == "function" then
        pcall(conn.Disconnect, conn)
    end
end

local function formatHealth(cur, max)
    cur = math.floor(cur + 0.5)
    max = math.floor(max + 0.5)
    
    local key = cur * 100000 + max
    local cached = healthCache[key]
    if cached then return cached end
    
    local result = cur <= 0 and string.format("Dead %d/%d", cur, max) 
                   or string.format("%d/%d", cur, max)
    healthCache[key] = result
    return result
end

-- ESP对象创建
local function createESP(player, char, head)
    local baseColor = getBaseColor(player)
    local outlineColor = Color3.new(
        baseColor.R * CONFIG.OUTLINE_DARKEN,
        baseColor.G * CONFIG.OUTLINE_DARKEN,
        baseColor.B * CONFIG.OUTLINE_DARKEN
    )
    local fillColor = Color3.new(
        baseColor.R + (1 - baseColor.R) * CONFIG.FILL_TINT,
        baseColor.G + (1 - baseColor.G) * CONFIG.FILL_TINT,
        baseColor.B + (1 - baseColor.B) * CONFIG.FILL_TINT
    )
    
    -- Billboard GUI
    local gui = Instance.new("BillboardGui")
    gui.Name = "ESP_" .. player.UserId
    gui.Size = CONFIG.BILLBOARD_SIZE
    gui.StudsOffset = Vector3.new(0, 1.6, 0)
    gui.AlwaysOnTop = true
    gui.MaxDistance = CONFIG.MAX_DISTANCE
    gui.Adornee = head
    gui.Parent = PlayerGui
    
    local healthLabel = Instance.new("TextLabel")
    healthLabel.Name = "Health"
    healthLabel.Size = UDim2.new(1, 0, 0.45, 0)
    healthLabel.Position = UDim2.new(0, 0, 0, 0)
    healthLabel.BackgroundTransparency = 1
    healthLabel.Font = Enum.Font.SourceSansBold
    healthLabel.TextSize = CONFIG.NAME_TEXT_SIZE
    healthLabel.TextStrokeTransparency = 0.5
    healthLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    healthLabel.TextColor3 = outlineColor
    healthLabel.Parent = gui
    
    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "Name"
    nameLabel.Size = UDim2.new(1, 0, 0.55, 0)
    nameLabel.Position = UDim2.new(0, 0, 0.45, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Font = Enum.Font.SourceSansBold
    nameLabel.TextSize = CONFIG.NAME_TEXT_SIZE
    nameLabel.TextStrokeTransparency = 0.5
    nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
    nameLabel.TextColor3 = outlineColor
    nameLabel.Text = player.Name
    nameLabel.Parent = gui
    
    -- Highlight
    local highlight = Instance.new("Highlight")
    highlight.Name = "Highlight_" .. player.UserId
    highlight.Adornee = char
    highlight.OutlineTransparency = 0
    highlight.FillTransparency = CONFIG.FILL_TRANSPARENCY
    highlight.OutlineColor = outlineColor
    highlight.FillColor = fillColor
    highlight.Parent = Workspace
    
    return gui, nameLabel, healthLabel, highlight
end

-- 玩家ESP管理
local function cleanupPlayer(player)
    local data = espTable[player]
    if not data then return end
    
    safeDestroy(data.gui)
    safeDestroy(data.highlight)
    safeDisconnect(data.healthConn)
    safeDisconnect(data.charRemovingConn)
    
    -- 从列表中移除
    local idx = playerIndex[player]
    if idx then
        local last = #playersList
        if idx < last then
            local lastPlayer = playersList[last]
            playersList[idx] = lastPlayer
            playerIndex[lastPlayer] = idx
        end
        playersList[last] = nil
    end
    
    playerIndex[player] = nil
    colorCache[player] = nil
    espTable[player] = nil
end

local function ensureESP(player)
    if player == LocalPlayer then return end
    if not player.Parent then return end
    
    local char = player.Character
    if not char then return end
    
    local head = char:FindFirstChild("Head")
    if not head then
        -- 等待头部出现
        local headWait
        headWait = char.ChildAdded:Connect(function(child)
            if child.Name == "Head" then
                headWait:Disconnect()
                task.delay(0.1, function() ensureESP(player) end)
            end
        end)
        task.delay(3, function() if headWait then headWait:Disconnect() end end)
        return
    end
    
    local data = espTable[player]
    if not data then
        data = {}
        espTable[player] = data
        playersList[#playersList + 1] = player
        playerIndex[player] = #playersList
    end
    
    -- 创建或更新ESP
    if not data.gui or not data.gui.Parent then
        data.gui, data.name, data.health, data.highlight = createESP(player, char, head)
        
        -- 连接Humanoid事件
        local humanoid = char:FindFirstChildOfClass("Humanoid")
        if humanoid then
            local function updateHealth()
                local cur = math.floor(humanoid.Health + 0.5)
                local max = math.floor((humanoid.MaxHealth or 100) + 0.5)
                if data.health then
                    data.health.Text = formatHealth(cur, max)
                end
                data.lastHealth = cur
                data.lastMax = max
            end
            
            updateHealth()
            
            local healthConn = humanoid.HealthChanged:Connect(updateHealth)
            local maxConn = humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(updateHealth)
            
            data.healthConn = function()
                healthConn:Disconnect()
                maxConn:Disconnect()
            end
            data.humanoid = humanoid
        elseif data.health then
            data.health.Text = "N/A"
        end
        
        -- 角色移除监听
        if not data.charRemovingConn then
            data.charRemovingConn = char:GetPropertyChangedSignal("Parent"):Connect(function()
                if not char.Parent then cleanupPlayer(player) end
            end)
        end
    else
        -- 更新现有ESP
        data.gui.Adornee = head
        data.highlight.Adornee = char
    end
end

local function updatePlayerESP(player)
    if not player or not player.Parent then
        cleanupPlayer(player)
        return
    end
    
    local data = espTable[player]
    if not data then
        ensureESP(player)
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
    local baseColor = getBaseColor(player)
    local outlineColor = Color3.new(
        baseColor.R * CONFIG.OUTLINE_DARKEN,
        baseColor.G * CONFIG.OUTLINE_DARKEN,
        baseColor.B * CONFIG.OUTLINE_DARKEN
    )
    
    if data.name then data.name.TextColor3 = outlineColor end
    if data.health then data.health.TextColor3 = outlineColor end
    
    if data.highlight then
        data.highlight.OutlineColor = outlineColor
        data.highlight.FillColor = Color3.new(
            baseColor.R + (1 - baseColor.R) * CONFIG.FILL_TINT,
            baseColor.G + (1 - baseColor.G) * CONFIG.FILL_TINT,
            baseColor.B + (1 - baseColor.B) * CONFIG.FILL_TINT
        )
    end
    
    -- 后备健康检查
    if data.humanoid and data.humanoid.Parent == char then
        local cur = math.floor(data.humanoid.Health + 0.5)
        local max = math.floor((data.humanoid.MaxHealth or 100) + 0.5)
        if cur ~= data.lastHealth or max ~= data.lastMax then
            if data.health then
                data.health.Text = formatHealth(cur, max)
            end
            data.lastHealth = cur
            data.lastMax = max
        end
    end
end

-- 保底检查
local lastBackupCheck = 0
local function backupCheck()
    local now = tick()
    if now - lastBackupCheck < CONFIG.BACKUP_CHECK_INTERVAL then return end
    lastBackupCheck = now
    
    local allPlayers = Players:GetPlayers()
    for _, player in ipairs(allPlayers) do
        if player ~= LocalPlayer and player.Parent then
            local data = espTable[player]
            local char = player.Character
            local head = char and char:FindFirstChild("Head")
            
            if char and head then
                if not data or not data.gui or not data.gui.Parent then
                    cleanupPlayer(player)
                    ensureESP(player)
                end
            end
        end
    end
end

-- 玩家管理
local function onPlayerAdded(player)
    if player == LocalPlayer then return end
    
    -- 属性变化监听
    local function refreshESP()
        colorCache[player] = nil
        ensureESP(player)
    end
    
    player:GetAttributeChangedSignal("Faction"):Connect(refreshESP)
    player:GetPropertyChangedSignal("Team"):Connect(refreshESP)
    
    -- 角色监听
    if player.Character then
        task.defer(ensureESP, player)
    end
    
    player.CharacterAdded:Connect(function()
        task.delay(0.1, function()
            if player.Parent then
                ensureESP(player)
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

-- 初始化
for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(cleanupPlayer)

-- 主循环
local updateAcc = 0
local cursor = 1

RunService.Heartbeat:Connect(function(dt)
    updateAcc = updateAcc + dt
    if updateAcc < CONFIG.UPDATE_RATE then return end
    updateAcc = 0
    
    -- 保底检查
    backupCheck()
    
    local totalPlayers = #playersList
    if totalPlayers == 0 then return end
    
    local processed = 0
    while processed < CONFIG.BATCH_SIZE and totalPlayers > 0 do
        if cursor > totalPlayers then cursor = 1 end
        
        local player = playersList[cursor]
        if player then
            updatePlayerESP(player)
        end
        
        cursor = cursor + 1
        processed = processed + 1
        totalPlayers = #playersList
    end
    
    -- 定期清理缓存
    healthCache = setmetatable({}, { __mode = "v" })
end)

print("ESP系统已加载")