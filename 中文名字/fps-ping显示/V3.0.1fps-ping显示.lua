--fps/ping显示 v3.0.1
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")

local UPDATE_THROTTLE = 0.3
local FPS_SAMPLE_TIME = 1.0
local FPS_SAMPLE_TIME_RECIPROCAL = 1.0 / FPS_SAMPLE_TIME
local TEXT_TEMPLATE_FULL = "fps: %d\nping: %d ms\nplayer: %d"
local TEXT_TEMPLATE_SIMPLE = "fps: %d\nping: %d ms"
local DOUBLE_CLICK_THRESHOLD = 0.3
local SCAN_INTERVAL_FRAMES = 10

local cache = {
    player = nil,
    screenGui = nil,
    frame = nil,
    label = nil,
    dataPingObj = nil,
    statsChecked = false,
    frameCount = 0,
    scanFrameCounter = 0,
    accTime = 0,
    displayFps = 0,
    cachedFPS = -1,
    cachedPing = -1,
    cachedPlayerCount = -1,
    shouldUpdateUI = false,
    dragging = false,
    dragStart = Vector2.new(),
    startPos = nil,
    mode = 1,
    lastClickTime = 0,
    running = true
}

local connectionManager = {
    _connections = {},
    add = function(self, c)
        if c then self._connections[#self._connections + 1] = c end
    end,
    disconnectAll = function(self)
        for i = #self._connections, 1, -1 do
            local c = self._connections[i]
            if c then
                pcall(function() c:Disconnect() end)
            end
            self._connections[i] = nil
        end
    end
}

local aliveCount = 0
local lastScanAliveCount = -1
local playerAlive = {}
local playerConns = {}

local function safeDisconnect(conn)
    if conn then
        pcall(function() conn:Disconnect() end)
    end
end

local function computeAliveCount()
    local players = Players:GetPlayers()
    local newAlive = 0
    
    for i = 1, #players do
        local player = players[i]
        local character = player.Character
        if character then
            local humanoid = character:FindFirstChildOfClass("Humanoid") or character:FindFirstChild("Humanoid")
            if humanoid and humanoid.Health > 0 then
                newAlive = newAlive + 1
            end
        end
    end
    
    return newAlive
end

local function scanPlayers()
    local newAlive = computeAliveCount()
    
    if newAlive ~= lastScanAliveCount then
        aliveCount = newAlive
        lastScanAliveCount = newAlive
        cache.shouldUpdateUI = true
    end
end

local function handleHumanoidForPlayer(plr, humanoid)
    if not plr or not humanoid then return end
    if humanoid.Health > 0 and not playerAlive[plr] then
        playerAlive[plr] = true
        aliveCount = aliveCount + 1
        lastScanAliveCount = aliveCount
        cache.shouldUpdateUI = true
    end
    local diedConn = humanoid.Died:Connect(function()
        if playerAlive[plr] then
            playerAlive[plr] = false
            aliveCount = math.max(0, aliveCount - 1)
            lastScanAliveCount = aliveCount
            cache.shouldUpdateUI = true
        end
    end)
    playerConns[plr] = playerConns[plr] or {}
    if playerConns[plr].diedConn then
        safeDisconnect(playerConns[plr].diedConn)
    end
    playerConns[plr].diedConn = diedConn
end

local function onCharacterAdded(plr, char)
    if playerConns[plr] and playerConns[plr].diedConn then
        safeDisconnect(playerConns[plr].diedConn)
        playerConns[plr].diedConn = nil
    end
    local hum = char:FindFirstChildOfClass("Humanoid") or char:FindFirstChild("Humanoid")
    if hum then
        handleHumanoidForPlayer(plr, hum)
    else
        task.spawn(function()
            local h = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 2)
            if h and plr.Parent then
                handleHumanoidForPlayer(plr, h)
            end
        end)
    end
end

local function onPlayerAdded(plr)
    playerAlive[plr] = false
    playerConns[plr] = playerConns[plr] or {}
    playerConns[plr].charConn = plr.CharacterAdded:Connect(function(char) onCharacterAdded(plr, char) end)
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
    if playerConns[plr] then
        safeDisconnect(playerConns[plr].charConn)
        safeDisconnect(playerConns[plr].diedConn)
        playerConns[plr] = nil
    end
    playerAlive[plr] = nil
end

local COLOR_PURPLE = Color3.fromRGB(148, 0, 211)
local TEXT_INITIAL = "fps: \nping: \nplayer: "
local function initialize()
    cache.player = Players.LocalPlayer or Players.PlayerAdded:Wait()
    if not cache.player then return false end
    local playerGui = cache.player:FindFirstChild("PlayerGui") or cache.player:WaitForChild("PlayerGui", 2)
    if not playerGui then return false end
    cache.screenGui = playerGui:FindFirstChild("PerfOverlay")
    if not cache.screenGui then
        cache.screenGui = Instance.new("ScreenGui")
        cache.screenGui.Name = "PerfOverlay"
        cache.screenGui.ResetOnSpawn = false
        cache.screenGui.Parent = playerGui
    end
    cache.frame = cache.screenGui:FindFirstChild("Holder")
    if not cache.frame then
        cache.frame = Instance.new("Frame")
        cache.frame.Name = "Holder"
        cache.frame.Size = UDim2.new(0, 63, 0, 45)
        cache.frame.Position = UDim2.new(0, 12, 0, 60)
        cache.frame.BackgroundTransparency = 1
        cache.frame.BorderSizePixel = 0
        cache.frame.Parent = cache.screenGui
    end
    cache.label = cache.frame:FindFirstChild("StatsLabel")
    if not cache.label then
        cache.label = Instance.new("TextLabel")
        cache.label.Name = "StatsLabel"
        cache.label.Size = UDim2.new(1, 0, 1, 0)
        cache.label.BackgroundTransparency = 1
        cache.label.Text = TEXT_INITIAL
        cache.label.TextXAlignment = Enum.TextXAlignment.Left
        cache.label.TextYAlignment = Enum.TextYAlignment.Top
        cache.label.Font = Enum.Font.SourceSansSemibold
        cache.label.TextSize = 14
        cache.label.TextColor3 = COLOR_PURPLE
        cache.label.Parent = cache.frame
    end
    return true
end

local function getDataPingObj()
    if cache.dataPingObj then return cache.dataPingObj end
    if cache.statsChecked then return nil end
    cache.statsChecked = true
    local network = Stats.Network
    if not network then return nil end
    local serverStats = network.ServerStatsItem
    if not serverStats then return nil end
    local obj = serverStats["Data Ping"]
    if obj then cache.dataPingObj = obj end
    return cache.dataPingObj
end

local floor, format, tick = math.floor, string.format, tick

local function getPingMs()
    local obj = getDataPingObj()
    if not obj then return 0 end
    local ok, val = pcall(function() return obj:GetValue() end)
    if ok and val then return floor(tonumber(val) or 0) end
    return 0
end

local function onHeartbeat(delta)
    cache.frameCount = cache.frameCount + 1
    cache.accTime = cache.accTime + delta
    
    cache.scanFrameCounter = cache.scanFrameCounter + 1
    if cache.scanFrameCounter >= SCAN_INTERVAL_FRAMES then
        cache.scanFrameCounter = 0
        scanPlayers()
    end
    
    if cache.accTime >= FPS_SAMPLE_TIME then
        cache.displayFps = floor(cache.frameCount * FPS_SAMPLE_TIME_RECIPROCAL + 0.5)
        cache.frameCount = 0
        cache.accTime = cache.accTime - FPS_SAMPLE_TIME
        cache.shouldUpdateUI = true
    end
end

local function onInputBegan(input)
    local t = input.UserInputType
    if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
    local now = tick()
    if now - cache.lastClickTime < DOUBLE_CLICK_THRESHOLD then
        cache.mode = cache.mode == 1 and 2 or 1
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
    if not cache.dragging then return end
    local t = input.UserInputType
    if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then return end
    local delta = input.Position - cache.dragStart
    local newX = cache.startPos.X.Offset + delta.X
    local newY = cache.startPos.Y.Offset + delta.Y
    cache.frame.Position = UDim2.new(0, newX, 0, newY)
end

local function onInputEnded(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        cache.dragging = false
    end
end

local lastText = ""
local function performUIUpdate()
    if not cache.shouldUpdateUI then return end
    local fps = cache.displayFps or 0
    local alive = (cache.mode == 1) and aliveCount or 0
    local ping = getPingMs()
    if fps ~= cache.cachedFPS or ping ~= cache.cachedPing or alive ~= cache.cachedPlayerCount then
        cache.cachedFPS = fps
        cache.cachedPing = ping
        cache.cachedPlayerCount = alive
        local newText
        if cache.mode == 1 then
            newText = format(TEXT_TEMPLATE_FULL, fps, ping, alive)
        else
            newText = format(TEXT_TEMPLATE_SIMPLE, fps, ping)
        end
        if newText ~= lastText then
            cache.label.Text = newText
            lastText = newText
        end
    end
    cache.shouldUpdateUI = false
end

local function setupConnections()
    connectionManager:disconnectAll()
    connectionManager:add(RunService.Heartbeat:Connect(onHeartbeat))
    if cache.frame then
        connectionManager:add(cache.frame.InputBegan:Connect(onInputBegan))
    end
    connectionManager:add(UserInputService.InputChanged:Connect(onInputChanged))
    connectionManager:add(UserInputService.InputEnded:Connect(onInputEnded))
    connectionManager:add(Players.PlayerAdded:Connect(onPlayerAdded))
    connectionManager:add(Players.PlayerRemoving:Connect(onPlayerRemoving))
end

local function cleanup()
    cache.running = false
    connectionManager:disconnectAll()
    if cache.screenGui and cache.screenGui.Parent then
        pcall(function() cache.screenGui:Destroy() end)
    end
    for plr, tbl in pairs(playerConns) do
        if tbl then
            safeDisconnect(tbl.charConn)
            safeDisconnect(tbl.diedConn)
            playerConns[plr] = nil
        end
    end
    cache.dataPingObj = nil
    cache.statsChecked = false
end

local function mainLoop()
    while cache.running and cache.player and cache.player.Parent do
        performUIUpdate()
        task.wait(UPDATE_THROTTLE)
    end
    cleanup()
end

local function start()
    if not initialize() then
        return
    end
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

pcall(start)