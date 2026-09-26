--聊天栏 V1.1
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- [1] pcall: 获取本地玩家
local success, Player = pcall(function()
    return Players.LocalPlayer
end)

if not success or not Player then
    warn("无法获取本地玩家，聊天系统初始化失败")
    return
end

local PlayerGui
-- [2] pcall: 获取PlayerGui
success, PlayerGui = pcall(function()
    return Player:WaitForChild("PlayerGui", 5)
end)

if not success or not PlayerGui then
    warn("无法获取PlayerGui，聊天系统初始化失败")
    return
end

local MAX_HISTORY = 25
local CHAT_BUTTON_SIZE = 44
local DOUBLE_CLICK_THRESHOLD = 0.3
local SAFE_WAIT_TIME = 2

local ChatHistory = {}          -- 仅存储最近25条用于显示
local lastClickTime = 0
local isInitialized = false
local connections = {}

-- 全量消息存储模块（无上限）
local MessageStorage = nil

local function setupMessageStorage()
    local moduleName = "ChatMessageStorage"
    local module = ReplicatedStorage:FindFirstChild(moduleName)
    if not module then
        module = Instance.new("ModuleScript")
        module.Name = moduleName
        module.Source = [[
local module = {}
local messages = {}

function module.AddMessage(player, message, time)
    table.insert(messages, {player = player, message = message, time = time})
end

function module.GetAllMessages()
    local copy = {}
    for i, msg in ipairs(messages) do
        copy[i] = {player = msg.player, message = msg.message, time = msg.time}
    end
    return copy
end

function module.ClearMessages()
    messages = {}
end

return module
]]
        module.Parent = ReplicatedStorage
    end

    -- [3] pcall: 加载模块
    local success, result = pcall(require, module)
    if success then
        MessageStorage = result
        -- [4] pcall: 清空旧数据
        pcall(function() MessageStorage.ClearMessages() end)
    else
        warn("无法加载聊天消息存储模块:", result)
    end
end

setupMessageStorage()

-- ==================== GUI 构建（完全不变）====================
local MainGui = Instance.new("ScreenGui")
MainGui.Name = "CustomChatSystem"
MainGui.ResetOnSpawn = false
MainGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local ChatButton = Instance.new("ImageButton")
ChatButton.Name = "ChatButton"
ChatButton.Size = UDim2.new(0, CHAT_BUTTON_SIZE, 0, CHAT_BUTTON_SIZE)
ChatButton.Position = UDim2.new(0, 20, 0.8, 0)
ChatButton.BackgroundColor3 = Color3.fromRGB(0, 162, 255)
ChatButton.BackgroundTransparency = 0.2
ChatButton.Image = ""
ChatButton.ZIndex = 10

local UICorner = Instance.new("UICorner")
UICorner.CornerRadius = UDim.new(1, 0)
UICorner.Parent = ChatButton

local UIStroke = Instance.new("UIStroke")
UIStroke.Color = Color3.fromRGB(255, 255, 255)
UIStroke.Thickness = 1.5
UIStroke.Transparency = 0.7
UIStroke.Parent = ChatButton

local Icon = Instance.new("ImageLabel")
Icon.Name = "Icon"
Icon.Size = UDim2.new(0.6, 0, 0.6, 0)
Icon.Position = UDim2.new(0.2, 0, 0.2, 0)
Icon.BackgroundTransparency = 1
Icon.Image = "rbxassetid://3926305904"
Icon.ImageRectSize = Vector2.new(36, 36)
Icon.ImageRectOffset = Vector2.new(964, 324)
Icon.ZIndex = 11
Icon.Parent = ChatButton

local ChatWindow = Instance.new("Frame")
ChatWindow.Name = "ChatWindow"
ChatWindow.Size = UDim2.new(0.35, 0, 0.4, 0)
ChatWindow.Position = UDim2.new(0.02, 0, 0.55, 0)
ChatWindow.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
ChatWindow.BackgroundTransparency = 0.15
ChatWindow.BorderSizePixel = 0
ChatWindow.Visible = false
ChatWindow.ZIndex = 5

local UICorner2 = Instance.new("UICorner")
UICorner2.CornerRadius = UDim.new(0, 8)
UICorner2.Parent = ChatWindow

local UIStroke2 = Instance.new("UIStroke")
UIStroke2.Color = Color3.fromRGB(60, 60, 70)
UIStroke2.Thickness = 1
UIStroke2.Parent = ChatWindow

local TitleBar = Instance.new("Frame")
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 30)
TitleBar.Position = UDim2.new(0, 0, 0, 0)
TitleBar.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
TitleBar.BackgroundTransparency = 0.3
TitleBar.BorderSizePixel = 0
TitleBar.ZIndex = 6

local TitleCorner = Instance.new("UICorner")
TitleCorner.CornerRadius = UDim.new(0, 8)
TitleCorner.Parent = TitleBar

local TitleText = Instance.new("TextLabel")
TitleText.Name = "TitleText"
TitleText.Size = UDim2.new(1, -10, 1, 0)
TitleText.Position = UDim2.new(0, 10, 0, 0)
TitleText.BackgroundTransparency = 1
TitleText.Text = "聊天记录 (最多25条)"
TitleText.TextColor3 = Color3.fromRGB(220, 220, 220)
TitleText.Font = Enum.Font.GothamSemibold
TitleText.TextSize = 14
TitleText.TextXAlignment = Enum.TextXAlignment.Left
TitleText.ZIndex = 7
TitleText.Parent = TitleBar

local CloseButton = Instance.new("TextButton")
CloseButton.Name = "CloseButton"
CloseButton.Size = UDim2.new(0, 20, 0, 20)
CloseButton.Position = UDim2.new(1, -25, 0.5, -10)
CloseButton.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
CloseButton.BackgroundTransparency = 0.3
CloseButton.Text = "×"
CloseButton.TextColor3 = Color3.fromRGB(220, 220, 220)
CloseButton.Font = Enum.Font.GothamBold
CloseButton.TextSize = 16
CloseButton.ZIndex = 7

local CloseCorner = Instance.new("UICorner")
CloseCorner.CornerRadius = UDim.new(0, 4)
CloseCorner.Parent = CloseButton
CloseButton.Parent = TitleBar

local ChatScroller = Instance.new("ScrollingFrame")
ChatScroller.Name = "ChatScroller"
ChatScroller.Size = UDim2.new(1, -10, 1, -40)
ChatScroller.Position = UDim2.new(0, 5, 0, 35)
ChatScroller.BackgroundTransparency = 1
ChatScroller.BorderSizePixel = 0
ChatScroller.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 120)
ChatScroller.ScrollBarThickness = 4
ChatScroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
ChatScroller.ScrollingDirection = Enum.ScrollingDirection.Y
ChatScroller.CanvasSize = UDim2.new(0, 0, 0, 0)
ChatScroller.ZIndex = 6

local ChatLayout = Instance.new("UIListLayout")
ChatLayout.Name = "ChatLayout"
ChatLayout.Padding = UDim.new(0, 5)
ChatLayout.SortOrder = Enum.SortOrder.LayoutOrder
ChatLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
ChatLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
ChatLayout.Parent = ChatScroller

TitleBar.Parent = ChatWindow
ChatScroller.Parent = ChatWindow
ChatWindow.Parent = MainGui
ChatButton.Parent = MainGui

local function safeAddToPlayerGui()
    -- [5] pcall: 将UI添加到PlayerGui
    local success, result = pcall(function()
        MainGui.Parent = PlayerGui
    end)

    if not success then
        warn("无法将聊天UI添加到PlayerGui:", result)
        return false
    end

    return true
end

if not safeAddToPlayerGui() then
    warn("聊天系统UI初始化失败")
    return
end

local function addConnection(connection)
    table.insert(connections, connection)
    return connection
end

local function cleanupConnections()
    for _, connection in ipairs(connections) do
        if connection then
            if typeof(connection) == "RBXScriptConnection" then
                connection:Disconnect()
            end
        end
    end
    connections = {}
end

-- ==================== 缓存优化 ====================
local messageFrameCache = {}       -- 可复用的消息框架列表
local activeMessageFrames = {}     -- 当前正在使用的消息框架（用于清理）

local function createMessageFrame(entry)
    local messageFrame
    if #messageFrameCache > 0 then
        -- 从缓存中取出并重置内容
        messageFrame = table.remove(messageFrameCache)
        for _, child in ipairs(messageFrame:GetChildren()) do
            if child.Name == "PlayerName" then
                child.Text = entry.player .. ":"
            elseif child.Name == "MessageText" then
                child.Text = entry.message
                local textSize = TextService:GetTextSize(
                    entry.message,
                    14,
                    Enum.Font.Gotham,
                    Vector2.new(300, math.huge)
                )
                child.Size = UDim2.new(1, -85, 0, textSize.Y)
                messageFrame.Size = UDim2.new(1, 0, 0, textSize.Y)
            end
        end
        messageFrame.LayoutOrder = entry.time
    else
        -- 新建框架
        messageFrame = Instance.new("Frame")
        messageFrame.Name = "MessageFrame"
        messageFrame.Size = UDim2.new(1, 0, 0, 0)
        messageFrame.BackgroundTransparency = 1
        messageFrame.LayoutOrder = entry.time
        messageFrame.ZIndex = 7

        local playerLabel = Instance.new("TextLabel")
        playerLabel.Name = "PlayerName"
        playerLabel.Size = UDim2.new(0, 80, 0, 20)
        playerLabel.Position = UDim2.new(0, 0, 0, 0)
        playerLabel.BackgroundTransparency = 1
        playerLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
        playerLabel.Font = Enum.Font.GothamSemibold
        playerLabel.TextSize = 14
        playerLabel.Text = entry.player .. ":"
        playerLabel.TextXAlignment = Enum.TextXAlignment.Left
        playerLabel.TextYAlignment = Enum.TextYAlignment.Top
        playerLabel.TextTruncate = Enum.TextTruncate.AtEnd
        playerLabel.ZIndex = 8
        playerLabel.Parent = messageFrame

        local messageLabel = Instance.new("TextLabel")
        messageLabel.Name = "MessageText"
        messageLabel.Size = UDim2.new(1, -85, 0, 0)
        messageLabel.Position = UDim2.new(0, 85, 0, 0)
        messageLabel.BackgroundTransparency = 1
        messageLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
        messageLabel.Font = Enum.Font.Gotham
        messageLabel.TextSize = 14
        messageLabel.Text = entry.message
        messageLabel.TextXAlignment = Enum.TextXAlignment.Left
        messageLabel.TextYAlignment = Enum.TextYAlignment.Top
        messageLabel.TextWrapped = true
        messageLabel.ZIndex = 8
        messageLabel.Parent = messageFrame

        local textSize = TextService:GetTextSize(
            entry.message,
            14,
            Enum.Font.Gotham,
            Vector2.new(300, math.huge)
        )

        messageLabel.Size = UDim2.new(1, -85, 0, textSize.Y)
        messageFrame.Size = UDim2.new(1, 0, 0, textSize.Y)
    end

    activeMessageFrames[messageFrame] = true
    return messageFrame
end

-- 增量添加单条消息到显示区域（仅窗口可见时调用）
local function appendNewMessage(entry)
    local frame = createMessageFrame(entry)
    frame.Parent = ChatScroller

    -- 检查并限制框架数量不超过MAX_HISTORY
    local frames = {}
    for _, child in ipairs(ChatScroller:GetChildren()) do
        if child:IsA("Frame") and child.Name == "MessageFrame" then
            table.insert(frames, child)
        end
    end
    if #frames > MAX_HISTORY then
        -- 按 LayoutOrder 排序（最早的消息最小）
        table.sort(frames, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
        local toRemove = frames[1]  -- 最早的消息框架
        toRemove.Parent = nil
        table.insert(messageFrameCache, toRemove)
        activeMessageFrames[toRemove] = nil
    end

    -- 自动滚动到底部
    task.defer(function()
        if ChatScroller.CanvasSize.Y.Offset > ChatScroller.AbsoluteWindowSize.Y then
            ChatScroller.CanvasPosition = Vector2.new(0, ChatScroller.CanvasSize.Y.Offset - ChatScroller.AbsoluteWindowSize.Y)
        end
    end)
end

-- 全量刷新显示（窗口打开或需要重建时调用）
local function updateChatDisplay()
    -- [6] pcall: 刷新聊天显示
    pcall(function()
        -- 回收现有消息框架到缓存
        for _, child in ipairs(ChatScroller:GetChildren()) do
            if child:IsA("Frame") and child.Name == "MessageFrame" then
                child.Parent = nil
                table.insert(messageFrameCache, child)
                activeMessageFrames[child] = nil
            end
        end

        -- 用历史记录重建所有框架
        for _, entry in ipairs(ChatHistory) do
            local frame = createMessageFrame(entry)
            frame.Parent = ChatScroller
        end

        task.defer(function()
            if ChatScroller.CanvasSize.Y.Offset > ChatScroller.AbsoluteWindowSize.Y then
                ChatScroller.CanvasPosition = Vector2.new(0, ChatScroller.CanvasSize.Y.Offset - ChatScroller.AbsoluteWindowSize.Y)
            end
        end)
    end)
end

local function addMessageToHistory(playerName, message)
    if not playerName or not message then
        return
    end

    if typeof(playerName) == "Instance" then
        playerName = playerName.Name
    end

    local entry = {
        player = tostring(playerName),
        message = tostring(message),
        time = os.time()
    }

    -- [7] pcall: 存储到全量存储
    if MessageStorage then
        local success, err = pcall(function()
            MessageStorage.AddMessage(entry.player, entry.message, entry.time)
        end)
        if not success then
            warn("添加消息到全量存储失败:", err)
        end
    end

    -- [8] pcall: 更新显示存储并处理增量显示
    pcall(function()
        table.insert(ChatHistory, entry)
        if #ChatHistory > MAX_HISTORY then
            table.remove(ChatHistory, 1)
        end

        -- 如果窗口可见，增量添加该消息（避免全量刷新）
        if ChatWindow.Visible then
            appendNewMessage(entry)
        end
    end)
end

-- ==================== 消息监听（不变）====================
local function setupJoinedChannelsListener()
    local function handleChatMessage(message)
        if message and message.TextSource then
            -- [9] pcall: 根据UserId获取玩家对象
            local success, player = pcall(function()
                return Players:GetPlayerByUserId(message.TextSource.UserId)
            end)

            if success and player then
                addMessageToHistory(player.Name, message.Text)
            end
        end
    end

    local function setupTextChannels()
        -- [10] pcall: 获取TextChannels
        local success, textChannels = pcall(function()
            return TextChatService:WaitForChild("TextChannels", SAFE_WAIT_TIME)
        end)

        if success and textChannels then
            for _, channel in ipairs(textChannels:GetChildren()) do
                if channel:IsA("TextChannel") then
                    local conn = channel.OnIncomingMessage:Connect(handleChatMessage)
                    table.insert(connections, conn)
                end
            end

            local conn = textChannels.ChildAdded:Connect(function(channel)
                if channel:IsA("TextChannel") then
                    local childConn = channel.OnIncomingMessage:Connect(handleChatMessage)
                    table.insert(connections, childConn)
                end
            end)
            table.insert(connections, conn)
        end
    end

    local function setupGlobalListener()
        -- [11] pcall: 监听全局消息
        local success, conn = pcall(function()
            return TextChatService.MessageReceived:Connect(function(message)
                if message.TextChannel then
                    handleChatMessage(message)
                end
            end)
        end)

        if success and conn then
            table.insert(connections, conn)
        end
    end

    local function setupSelfMessageListener()
        task.wait(1)

        -- [12] pcall: 获取ChatWindow
        local success, chatWindow = pcall(function()
            return TextChatService:WaitForChild("ChatWindow", SAFE_WAIT_TIME)
        end)

        if success and chatWindow then
            -- [13] pcall: 获取ChatBar
            local success2, chatBar = pcall(function()
                return chatWindow:WaitForChild("ChatBar", SAFE_WAIT_TIME)
            end)

            if success2 and chatBar then
                -- [14] pcall: 获取Textbox
                local success3, textbox = pcall(function()
                    return chatBar:WaitForChild("Textbox", SAFE_WAIT_TIME)
                end)

                if success3 and textbox then
                    local conn = textbox.FocusLost:Connect(function(enterPressed)
                        if enterPressed and textbox.Text ~= "" then
                            addMessageToHistory(Player.Name, textbox.Text)
                        end
                    end)
                    table.insert(connections, conn)
                end
            end
        end
    end

    -- [15][16][17] pcall: 分别调用三个设置函数
    pcall(setupTextChannels)
    pcall(setupGlobalListener)
    pcall(setupSelfMessageListener)

    print("聊天监听已设置 - 只监听已加入频道的消息")
end

local function handleDoubleClick()
    local currentTime = tick()

    if currentTime - lastClickTime <= DOUBLE_CLICK_THRESHOLD then
        ChatWindow.Visible = not ChatWindow.Visible
        if ChatWindow.Visible then
            updateChatDisplay()    -- 窗口打开时全量刷新
        end
    end

    lastClickTime = currentTime
end

local function setupEventListeners()
    local clickConn = ChatButton.MouseButton1Click:Connect(handleDoubleClick)
    table.insert(connections, clickConn)

    local closeConn = CloseButton.MouseButton1Click:Connect(function()
        ChatWindow.Visible = false
    end)
    table.insert(connections, closeConn)
end

local function initialize()
    if isInitialized then
        warn("聊天系统已经初始化")
        return
    end

    print("开始初始化聊天系统...")

    setupEventListeners()
    setupJoinedChannelsListener()  -- 内部已有pcall

    isInitialized = true
    print("聊天系统初始化完成")
end

local function cleanup()
    if not isInitialized then
        return
    end

    print("清理聊天系统...")

    cleanupConnections()

    -- 销毁缓存中的框架
    for _, frame in ipairs(messageFrameCache) do
        pcall(function() frame:Destroy() end)
    end
    messageFrameCache = {}

    -- 销毁活动框架
    for frame in pairs(activeMessageFrames) do
        pcall(function() frame:Destroy() end)
    end
    activeMessageFrames = {}

    ChatHistory = {}

    -- [18] pcall: 移除GUI
    pcall(function()
        if MainGui and MainGui.Parent then
            MainGui.Parent = nil
        end
    end)

    isInitialized = false
end

-- [19] pcall: 初始化聊天系统
local success, err = pcall(initialize)
if not success then
    warn("聊天系统初始化失败:", err)
    pcall(cleanup)
else
end

local leaveConn = Player.AncestryChanged:Connect(function()
    if not Player.Parent then
        -- [20] pcall: 玩家离开时清理
        pcall(cleanup)
        if leaveConn then
            leaveConn:Disconnect()
        end
    end
end)
table.insert(connections, leaveConn)