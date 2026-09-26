--fps/ping显示 v1.0
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
if not player then
    player = Players:WaitForChild("LocalPlayer")
end
if not player then
    return
end

local playerGui = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 5)
if not playerGui then
    return
end

local screenGui = playerGui:FindFirstChild("PerfOverlay")
if not screenGui then
    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "PerfOverlay"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = playerGui
end

local frame = screenGui:FindFirstChild("Holder")
if not frame then
    frame = Instance.new("Frame")
    frame.Name = "Holder"
    frame.Size = UDim2.new(0, 63, 0, 30)
    frame.Position = UDim2.new(0, 12, 0, 60)
    frame.BackgroundTransparency = 1
    frame.BorderSizePixel = 0
    frame.Parent = screenGui
end

local label = frame:FindFirstChild("StatsLabel")
if not label then
    label = Instance.new("TextLabel")
    label.Name = "StatsLabel"
    label.Size = UDim2.new(1, 0, 1, 0)
    label.Position = UDim2.new(0, 0, 0, 0)
    label.BackgroundTransparency = 1
    label.Text = "fps: \nping: "
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.Font = Enum.Font.SourceSansSemibold
    label.TextSize = 14
    label.TextColor3 = Color3.fromRGB(148, 0, 211)
    label.TextTransparency = 0
    label.RichText = false
    label.Parent = frame
end

local dragging = false
local dragStart = Vector2.new()
local startPos = frame.Position

local function onInputBegan(input)
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = frame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end

local function onInputChanged(input)
    if not dragging then return end
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
        local delta = input.Position - dragStart
        local newX = startPos.X.Offset + delta.X
        local newY = startPos.Y.Offset + delta.Y
        frame.Position = UDim2.new(0, newX, 0, newY)
    end
end

pcall(function()
    frame.InputBegan:Connect(onInputBegan)
    UserInputService.InputChanged:Connect(onInputChanged)
end)

local sampleWindow = 0.5
local accTime = 0
local frameCount = 0
local displayFps = 0

local function onRenderStepped(delta)
    frameCount = frameCount + 1
    accTime = accTime + delta
    if accTime >= sampleWindow then
        displayFps = math.floor(frameCount / accTime + 0.5)
        frameCount = 0
        accTime = 0
    end
end

pcall(function()
    RunService.RenderStepped:Connect(onRenderStepped)
end)

local function getPingMs()
    local success, result = pcall(function()
        if not Stats then
            return 0
        end

        local sni
        local ok, v = pcall(function()
            if Stats.Network and Stats.Network.ServerStatsItem then
                sni = Stats.Network.ServerStatsItem
            end
        end)
        if not ok then
            return 0
        end
        if not sni then
            return 0
        end

        local dataPingObj
        ok, v = pcall(function() dataPingObj = sni["Data Ping"] end)
        if not ok then
            return 0
        end
        if not dataPingObj then
            return 0
        end

        ok, v = pcall(function()
            if type(dataPingObj.GetValue) ~= "function" then
                error("Data Ping 对象没有 GetValue 方法")
            end
            local val = dataPingObj:GetValue()
            val = tonumber(val) or 0
            return math.floor(val)
        end)
        if ok and type(v) == "number" then
            return v
        else
            return 0
        end
    end)
    if not success then
        return 0
    end
    return result or 0
end

local UI_UPDATE_INTERVAL = 0.25
local accum = 0
local lastPing = 0

local function onHeartbeat(dt)
    accum = accum + dt
    if accum >= UI_UPDATE_INTERVAL then
        accum = 0
        local okPing, pingVal = pcall(getPingMs)
        if not okPing then
            pingVal = 0
        end
        lastPing = tonumber(pingVal) or 0
        pcall(function()
            label.Text = string.format("fps: %d\nping: %d ms", displayFps or 0, lastPing)
        end)
    end
end

pcall(function()
    RunService.Heartbeat:Connect(onHeartbeat)
end)