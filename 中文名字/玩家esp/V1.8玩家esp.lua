--V1.8玩家esp
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- 等待本地玩家
local LocalPlayer
while not LocalPlayer do
    LocalPlayer = Players.LocalPlayer
    if not LocalPlayer then task.wait(0.1) end
end

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
-- 创建专用 ScreenGui 容器，避免直接放在 PlayerGui 造成管理混乱
local ESP_CONTAINER_NAME = "ESP_Container"
local espContainer = PlayerGui:FindFirstChild(ESP_CONTAINER_NAME)
if not espContainer then
    espContainer = Instance.new("ScreenGui")
    espContainer.Name = ESP_CONTAINER_NAME
    espContainer.ResetOnSpawn = false
    espContainer.Parent = PlayerGui
end

-- 常量配置
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

-- 常用局部化函数
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local table_insert = table.insert
local table_clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end
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
local tonumber = tonumber
local tick = tick
local Color3_new = Color3.new
local Vector3_new = Vector3.new
local UDim2_new = UDim2.new
local typeof = typeof

-- 预定义常量实例
local STROKE_COLOR = Color3_new(0, 0, 0)
local HEAD_STUDS_OFFSET = Vector3_new(0, 1.6, 0)
local HEALTH_SIZE = UDim2_new(1, 0, 0.45, 0)
local HEALTH_POSITION = UDim2_new(0, 0, 0, 0)
local NAME_SIZE = UDim2_new(1, 0, 0.55, 0)
local NAME_POSITION = UDim2_new(0, 0, 0.45, 0)
local SOURCE_SANS_BOLD = Enum.Font.SourceSansBold

-- 数据结构
local espTable = {}            -- 每个玩家对应的ESP对象和状态
local playerConnections = {}   -- 每个玩家的事件连接，方便断开
-- 弱键缓存队伍颜色/阵营颜色
local colorCache = setmetatable({}, { __mode = "k" })

-- 分批处理队列，防止一帧操作过多
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

local enqueuePendingPlayer, ensureESPFor, rebuildESP, forceRefreshPlayer

-- 安全销毁对象
local function safeDestroy(obj)
    if not obj then return end
    pcall(function()
        if typeof(obj) == "Instance" then
            obj:Destroy()
        elseif type(obj) == "table" and type(obj.Destroy) == "function" then
            obj:Destroy()
        end
    end)
end

-- 安全断开连接（支持 RBXScriptConnection、函数或断开方法）
local function safeDisconnect(conn)
    if not conn then return end
    pcall(function()
        local t = typeof(conn)
        if t == "RBXScriptConnection" then
            conn:Disconnect()
        elseif type(conn) == "table" and type(conn.Disconnect) == "function" then
            conn:Disconnect()
        elseif type(conn) == "table" and type(conn.disconnect) == "function" then
            conn:disconnect()
        elseif type(conn) == "function" then
            conn()
        end
    end)
end

-- 数值范围裁剪
local function clamp(v, a, b)
    return math_max(a, math_min(b, v))
end

-- 解析十六进制颜色字符串
local function parseHexColor(s)
    if type(s) ~= "string" then return nil end
    local m = string_match(s, "^#?([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])$")
    if not m then return nil end
    local r = tonumber(string_sub(m, 1, 2), 16) or 0
    local g = tonumber(string_sub(m, 3, 4), 16) or 0
    local b = tonumber(string_sub(m, 5, 6), 16) or 0
    return Color3.fromRGB(r, g, b)
end

-- 字符串哈希生成颜色（姓名或队伍名）
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

-- 颜色变暗
local function darkenColor(c)
    return Color3_new(
        clamp(c.R * OUTLINE_DARKEN_FACTOR, 0, 1),
        clamp(c.G * OUTLINE_DARKEN_FACTOR, 0, 1),
        clamp(c.B * OUTLINE_DARKEN_FACTOR, 0, 1)
    )
end

-- 向白色偏移填充色
local function tintToWhite(c)
    return Color3_new(
        clamp(c.R + (1 - c.R) * FILL_TINT_AMOUNT, 0, 1),
        clamp(c.G + (1 - c.G) * FILL_TINT_AMOUNT, 0, 1),
        clamp(c.B + (1 - c.B) * FILL_TINT_AMOUNT, 0, 1)
    )
end

-- 更新 Highlight 颜色属性，只在变化时写
local function updateHighlightColors(highlight, baseColor)
    if not highlight or not baseColor then return end
    local outline = darkenColor(baseColor)
    local fill = tintToWhite(baseColor)
    if highlight.OutlineColor ~= outline then
        highlight.OutlineColor = outline
    end
    if highlight.FillColor ~= fill then
        highlight.FillColor = fill
    end
    if highlight.FillTransparency ~= FILL_TRANSPARENCY then
        highlight.FillTransparency = FILL_TRANSPARENCY
    end
    if highlight.OutlineTransparency ~= 0 then
        highlight.OutlineTransparency = 0
    end
end

-- 创建 BillboardGui 模板（带“Name”和“Health”文本）
local function createBillboardInternal(player, head)
    local newGui = Instance.new("BillboardGui")
    newGui.Name = "ESP_" .. player.UserId
    newGui.Adornee = head
    newGui.Size = BILLBOARD_SIZE
    newGui.StudsOffset = HEAD_STUDS_OFFSET
    newGui.AlwaysOnTop = true
    newGui.Parent = espContainer

    local healthLabel = Instance.new("TextLabel")
    healthLabel.Name = "Health"
    healthLabel.Size = HEALTH_SIZE
    healthLabel.Position = HEALTH_POSITION
    healthLabel.BackgroundTransparency = 1
    healthLabel.TextScaled = false
    healthLabel.Font = SOURCE_SANS_BOLD
    healthLabel.TextSize = NAME_TEXT_SIZE
    healthLabel.TextStrokeTransparency = 0.5
    healthLabel.TextStrokeColor3 = STROKE_COLOR
    healthLabel.Parent = newGui

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "Name"
    nameLabel.Size = NAME_SIZE
    nameLabel.Position = NAME_POSITION
    nameLabel.BackgroundTransparency = 1
    nameLabel.TextScaled = false
    nameLabel.Font = SOURCE_SANS_BOLD
    nameLabel.TextSize = NAME_TEXT_SIZE
    nameLabel.TextStrokeTransparency = 0.5
    nameLabel.TextStrokeColor3 = STROKE_COLOR
    nameLabel.Parent = newGui

    return newGui
end

-- 封装创建 BillBoard，防止失败崩溃
local function createBillboard(player, head)
    if not head or not head.Parent then
        return nil
    end
    local success, gui = pcall(createBillboardInternal, player, head)
    return success and gui or nil
end

-- 创建 Highlight 实例
local function createHighlightInternal(player, character, baseColor)
    local newHighlight = Instance.new("Highlight")
    newHighlight.Name = "Highlight_" .. player.UserId
    newHighlight.Adornee = character
    newHighlight.OutlineTransparency = 0
    newHighlight.FillTransparency = FILL_TRANSPARENCY
    updateHighlightColors(newHighlight, baseColor)
    -- 父级改为角色，这样角色销毁时自动清理
    newHighlight.Parent = character
    return newHighlight
end

local function createHighlight(player, character, baseColor)
    if not character or not character.Parent then
        return nil
    end
    local success, highlight = pcall(createHighlightInternal, player, character, baseColor)
    return success and highlight or nil
end

-- 获取玩家基础颜色：属性Faction优先，其次TeamColor，再Hash
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
        if hex then baseColor = hex end
    end

    if baseColor == FALLBACK_COLOR then
        local team = player.Team
        if team then
            local success, color = pcall(function()
                return team.TeamColor.Color
            end)
            if success and color then
                baseColor = color
            end
        end
    end

    if baseColor == FALLBACK_COLOR then
        local key = (player.Team and player.Team.Name) or player.Name
        if key then
            baseColor = hashColorFromString(key)
        end
    end

    colorCache[player] = baseColor
    return baseColor
end

-- 格式化血量字符串
local function formatHealthString(cur, max)
    cur = math_floor(cur + 0.5)
    max = math_floor(max + 0.5)
    if cur <= 0 then
        return string_format("Dead %d/%d", cur, max)
    end
    return string_format("%d/%d", cur, max)
end

-- 将玩家加入待创建队列，跳过本地玩家或已在队列的
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

-- 将玩家加入强刷队列
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

-- 断开已绑定的血量事件连接
local function disconnectHealthConnections(data)
    if not data or not data.healthConns then
        return
    end
    for _, conn in ipairs(data.healthConns) do
        safeDisconnect(conn)
    end
    data.healthConns = nil
    data.boundHumanoid = nil
end

-- 绑定 Humanoid 的血量到文本标签
local function bindHumanoidHealth(data, humanoid)
    if not data then
        return
    end
    data.humanoid = humanoid

    if not humanoid then
        -- 没有人形时显示 N/A
        disconnectHealthConnections(data)
        if data.health then
            data.health.Text = "N/A"
        end
        return
    end

    -- 若连续使用同一个 Humanoid，则只更新文字，无需重新连接
    if data.boundHumanoid == humanoid and data.healthConns then
        local cur = math_floor((humanoid.Health or 0) + 0.5)
        local max = math_floor((humanoid.MaxHealth or 100) + 0.5)
        if data.health then
            data.health.Text = formatHealthString(cur, max)
        end
        return
    end

    disconnectHealthConnections(data)
    data.boundHumanoid = humanoid

    local function updateHealthText()
        local cur = math_floor((humanoid.Health or 0) + 0.5)
        local max = math_floor((humanoid.MaxHealth or 100) + 0.5)
        if data.health then
            data.health.Text = formatHealthString(cur, max)
        end
    end

    local hc = humanoid.HealthChanged:Connect(function(newHealth)
        local cur = math_floor(newHealth + 0.5)
        local max = math_floor((humanoid.MaxHealth or 100) + 0.5)
        if data.health then
            data.health.Text = formatHealthString(cur, max)
        end
    end)
    local mhc = humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
        updateHealthText()
    end)

    data.healthConns = { hc, mhc }
    updateHealthText()
end

-- 清理并断开指定玩家的所有ESP资源
-- 若 fullCleanup 为 true，则移除事件监听和缓存
local function cleanupPlayer(player, fullCleanup)
    if not player then return end

    pendingSet[player] = nil
    forceRefreshSet[player] = nil

    local data = espTable[player]
    if data then
        -- 数据版本+1，阻止延迟回调使用旧数据
        data.generation = (data.generation or 0) + 1

        if data.gui then safeDestroy(data.gui) end
        if data.highlight then safeDestroy(data.highlight) end

        disconnectHealthConnections(data)
        safeDisconnect(data.charChildConn)

        -- 清空引用
        data.gui = nil
        data.name = nil
        data.health = nil
        data.highlight = nil
        data.humanoid = nil
        data.boundHumanoid = nil
        data.charChildConn = nil
        data.lastBaseColor = nil
        data.lastCharacter = nil
        data.lastHead = nil

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

-- 批量处理待创建队列
local function processPendingQueue()
    if pendingHead > pendingTail then return end
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
        table_clear(pendingQueue)
        pendingHead = 1
        pendingTail = 0
    end
end

-- 批量处理强刷队列
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
        table_clear(forceRefreshQueue)
        forceRefreshHead = 1
        forceRefreshTail = 0
        isForceRefreshing = false
    end
end

-- 检查是否到强刷间隔，若到则将所有活动玩家加入队列
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

-- 确保为指定玩家创建或更新ESP
ensureESPFor = function(player)
    if not player or player == LocalPlayer then return end

    local data = espTable[player]
    if not data then
        data = {
            gui = nil, name = nil, health = nil, highlight = nil,
            healthConns = nil, humanoid = nil, boundHumanoid = nil,
            charChildConn = nil, generation = 0,
            lastBaseColor = nil, lastCharacter = nil, lastHead = nil,
        }
        espTable[player] = data
    end

    local char = player.Character
    if not char then return end

    local head = char:FindFirstChild("Head")
    if not head then
        -- 处理角色还没Head的情况，监听后续新增
        if data.charChildConn then
            return
        end
        local watchGen = data.generation or 0
        local success, conn = pcall(function()
            return char.ChildAdded:Connect(function(child)
                if not data or not player or not player.Parent then return end
                if data.generation ~= watchGen then return end
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
        -- 超时后如果仍无 Head，也尝试创建ESP
        task_delay(HEAD_WAIT_TIMEOUT, function()
            if not data or not player or not player.Parent then return end
            if data.generation ~= watchGen then return end
            if data.charChildConn then
                safeDisconnect(data.charChildConn)
                data.charChildConn = nil
            end
            if player.Character == char and not char:FindFirstChild("Head") then
                enqueuePendingPlayer(player)
            end
        end)
        return
    end

    -- 创建 BillboardGui 和文本
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

    -- 颜色计算和应用
    local baseColor = factionBaseColor(player)
    -- 只在颜色有变时更新文本颜色和Highlight
    if data.lastBaseColor ~= baseColor then
        data.lastBaseColor = baseColor
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
    end

    -- 创建或更新高亮
    if not data.highlight then
        local highlight = createHighlight(player, char, baseColor)
        if highlight then
            data.highlight = highlight
        end
    else
        -- 仅更新附着目标和启用状态，无需重建
        if data.highlight.Adornee ~= char then
            data.highlight.Adornee = char
        end
        if not data.highlight.Enabled then
            data.highlight.Enabled = true
        end
    end

    -- 更新 BillboardGui 的 Adornee
    if data.gui then
        if data.gui.Adornee ~= head then
            data.gui.Adornee = head
        end
        if not data.gui.Enabled then
            data.gui.Enabled = true
        end
    end

    -- 绑定Humanoid血量
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    bindHumanoidHealth(data, humanoid)

    data.lastCharacter = char
    data.lastHead = head
end

-- 重建玩家ESP（用于强刷）
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

    -- 先记录旧对象
    local oldGui = data.gui
    local oldHighlight = data.highlight
    local baseColor = factionBaseColor(player)

    -- 创建新对象
    local newGui = createBillboard(player, head)
    local newHighlight = createHighlight(player, char, baseColor)

    if newGui then
        data.gui = newGui
        data.name = newGui:FindFirstChild("Name")
        data.health = newGui:FindFirstChild("Health")
        if data.name then
            data.name.Text = player.Name
            data.name.TextSize = NAME_TEXT_SIZE
        end
        safeDestroy(oldGui)
    end

    if newHighlight then
        data.highlight = newHighlight
        safeDestroy(oldHighlight)
    end

    -- 应用最新颜色
    if data.highlight then
        updateHighlightColors(data.highlight, baseColor)
    end
    if data.name and data.health then
        local outlineColor = darkenColor(baseColor)
        data.name.TextColor3 = outlineColor
        data.health.TextColor3 = outlineColor
    end

    -- 绑定血量、设置附着
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    bindHumanoidHealth(data, humanoid)
    if data.gui then
        data.gui.Adornee = head
        data.gui.Enabled = true
    end
    if data.highlight then
        data.highlight.Adornee = char
        data.highlight.Enabled = true
    end

    data.lastCharacter = char
    data.lastHead = head
end

forceRefreshPlayer = function(player)
    rebuildESP(player)
end

-- 玩家加入时初始化监听
local function onPlayerAdded(player)
    if player == LocalPlayer then return end

    local conns = {}
    playerConnections[player] = conns

    -- 阵营/队伍变化时刷新颜色
    local function refreshColor()
        colorCache[player] = nil
        local data = espTable[player]
        local newColor = factionBaseColor(player)
        if data then
            data.lastBaseColor = nil
            -- 立即更新已存在的显示对象
            if data.name then
                data.name.TextColor3 = darkenColor(newColor)
            end
            if data.health then
                data.health.TextColor3 = darkenColor(newColor)
            end
            if data.highlight then
                updateHighlightColors(data.highlight, newColor)
            end
            -- 如果GUI/Highlight丢失，也重新排队
            if not data.gui or not data.highlight then
                enqueuePendingPlayer(player)
            end
        else
            enqueuePendingPlayer(player)
        end
    end

    table_insert(conns, player:GetAttributeChangedSignal("Faction"):Connect(refreshColor))
    table_insert(conns, player:GetPropertyChangedSignal("Team"):Connect(refreshColor))
    table_insert(conns, player:GetPropertyChangedSignal("TeamColor"):Connect(refreshColor))
    table_insert(conns, player.AncestryChanged:Connect(function()
        if not player.Parent then
            -- 玩家离开时彻底清理
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

    -- 立即处理已有角色
    if player.Character then
        task_defer(function()
            enqueuePendingPlayer(player)
        end)
    else
        enqueuePendingPlayer(player)
    end
end

-- 已在线玩家
for _, player in ipairs(Players:GetPlayers()) do
    task_spawn(onPlayerAdded, player)
end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
    cleanupPlayer(player, true)
end)

-- 心跳驱动：分帧处理队列，30秒强刷
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