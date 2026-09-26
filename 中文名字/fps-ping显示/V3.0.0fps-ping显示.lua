--fps/ping显示 v3.0 基于v2.1
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

local cache = {
    player = nil,
    screenGui = nil,
    frame = nil,
    label = nil,
    dataPingObj = nil,
    statsInitialized = false,
    frameCount = 0,
    accTime = 0,
    displayFps = 0,
    updateAccum = 0,
    cachedFPS = 0,
    cachedPing = 0,
    cachedPlayerCount = 0,
    shouldUpdateUI = false,
    dragging = false,
    dragStart = Vector2.new(0, 0),
    startPos = nil,
    mode = 1,
    lastClickTime = 0
}

local connectionManager = {
    _connections = {},
    add = function(self, connection)
        if connection then
            table.insert(self._connections, connection)
        end
    end,
    disconnectAll = function(self)
        for i = #self._connections, 1, -1 do
            local conn = table.remove(self._connections, i)
            if conn then
                pcall(function() 
                    conn:Disconnect() 
                end)
            end
        end
    end
}

local floor = math.floor
local format = string.format
local tinsert = table.insert
local tremove = table.remove

local COLOR_PURPLE = Color3.fromRGB(148, 0, 211)
local ZERO_UDIM2 = UDim2.new(0, 0, 0, 0)

local lastText = ""

local function initialize()
    cache.player = Players.LocalPlayer
    if not cache.player then
        cache.player = Players:WaitForChild("LocalPlayer")
    end
    if not cache.player then
        return false
    end

    local playerGui
    local success = pcall(function()
        playerGui = cache.player:FindFirstChild("PlayerGui") or cache.player:WaitForChild("PlayerGui", 2)
    end)
    
    if not success or not playerGui then
        return false
    end

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
        cache.label.Text = "fps: \nping: \nplayer: "
        cache.label.TextXAlignment = Enum.TextXAlignment.Left
        cache.label.TextYAlignment = Enum.TextYAlignment.Top
        cache.label.Font = Enum.Font.SourceSansSemibold
        cache.label.TextSize = 14
        cache.label.TextColor3 = COLOR_PURPLE
        cache.label.Parent = cache.frame
    end
    
    return true
end

local function updateUIMode()
    if cache.mode == 1 then
        cache.frame.Size = UDim2.new(0, 63, 0, 45)
    else
        cache.frame.Size = UDim2.new(0, 63, 0, 30)
    end
    cache.shouldUpdateUI = true
end

local function initStats()
    if cache.statsInitialized then
        return true
    end
    
    local success = pcall(function()
        local network = Stats.Network
        if network then
            local serverStats = network.ServerStatsItem
            if serverStats then
                cache.dataPingObj = serverStats["Data Ping"]
            end
        end
    end)
    
    cache.statsInitialized = success and cache.dataPingObj ~= nil
    return cache.statsInitialized
end

local function getPingMs()
    if not cache.statsInitialized and not initStats() then
        return 0
    end
    
    if not cache.dataPingObj then
        cache.statsInitialized = false
        return 0
    end
    
    local value
    local success = pcall(function()
        value = cache.dataPingObj:GetValue()
    end)
    
    if success and value then
        return floor(tonumber(value) or 0)
    end
    
    cache.statsInitialized = false
    return 0
end

local function getAlivePlayerCount()
    if cache.mode == 2 then
        return 0
    end
    
    local players = Players:GetPlayers()
    local alive = 0
    local playerCount = #players
    local character, humanoid
    
    for i = 1, playerCount do
        character = players[i].Character
        if character then
            humanoid = character:FindFirstChild("Humanoid")
            if humanoid and humanoid.Health > 0 then
                alive = alive + 1
            end
        end
    end
    
    return alive
end

local function onInputBegan(input)
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
        local now = tick()
        
        if now - cache.lastClickTime < DOUBLE_CLICK_THRESHOLD then
            if cache.mode == 1 then
                cache.mode = 2
            else
                cache.mode = 1
            end
            updateUIMode()
            cache.lastClickTime = 0
            return
        end
        
        cache.lastClickTime = now
        cache.dragging = true
        cache.dragStart = input.Position
        cache.startPos = cache.frame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                cache.dragging = false
            end
        end)
    end
end

local function onInputChanged(input)
    if not cache.dragging then return end
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
        local delta = input.Position - cache.dragStart
        local newX = cache.startPos.X.Offset + delta.X
        local newY = cache.startPos.Y.Offset + delta.Y
        cache.frame.Position = UDim2.new(0, newX, 0, newY)
    end
end

local lastUpdateTime = 0
local function updateDisplay()
    local now = tick()
    if now - lastUpdateTime < UPDATE_THROTTLE then
        return
    end
    lastUpdateTime = now
    
    local currentPing = getPingMs()
    local currentAlive = getAlivePlayerCount()
    
    if not (cache.shouldUpdateUI or 
            currentPing ~= cache.cachedPing or 
            currentAlive ~= cache.cachedPlayerCount) then
        return
    end
    
    cache.cachedFPS = cache.displayFps or 0
    cache.cachedPing = currentPing
    cache.cachedPlayerCount = currentAlive
    
    local newText
    if cache.mode == 1 then
        newText = format(TEXT_TEMPLATE_FULL, cache.cachedFPS, cache.cachedPing, cache.cachedPlayerCount)
    else
        newText = format(TEXT_TEMPLATE_SIMPLE, cache.cachedFPS, cache.cachedPing)
    end
    
    if newText ~= lastText then
        cache.label.Text = newText
        lastText = newText
    end
    
    cache.shouldUpdateUI = false
end

local function onHeartbeat(delta)
    cache.frameCount = cache.frameCount + 1
    cache.accTime = cache.accTime + delta
    
    if cache.accTime >= FPS_SAMPLE_TIME then
        cache.displayFps = floor(cache.frameCount * FPS_SAMPLE_TIME_RECIPROCAL + 0.5)
        cache.frameCount = 0
        cache.accTime = 0
        cache.shouldUpdateUI = true
    end
    
    updateDisplay()
end

local function setupConnections()
    connectionManager:disconnectAll()
    
    connectionManager:add(RunService.Heartbeat:Connect(onHeartbeat))
    
    if cache.frame then
        pcall(function()
            connectionManager:add(cache.frame.InputBegan:Connect(onInputBegan))
        end)
    end
    pcall(function()
        connectionManager:add(UserInputService.InputChanged:Connect(onInputChanged))
    end)
end

local function cleanup()
    connectionManager:disconnectAll()
    
    for key in pairs(cache) do
        cache[key] = nil
    end
end

local function main()
    task.defer(function()
        if not initialize() then
            return
        end
        
        task.spawn(function()
            initStats()
        end)
        
        setupConnections()
        
        updateUIMode()
        
        task.delay(1, updateDisplay)
    end)
end

pcall(main)

Players.PlayerRemoving:Connect(function(leavingPlayer)
    if leavingPlayer == cache.player then
        cleanup()
    end
end)