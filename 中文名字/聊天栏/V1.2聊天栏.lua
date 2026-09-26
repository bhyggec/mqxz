--聊天栏 V1.2
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ==================== 模块定义 ====================
local ChatSystem = {}
local isEnabled = true          -- 模块启用标志
local isInitialized = false
local connections = {}
local messageFrameCache = {}
local activeMessageFrames = {}
local ChatHistory = {}
local MainGui, ChatButton, ChatWindow, CloseButton, ChatScroller

-- 缓存一些实例引用
local Player
local PlayerGui

-- ==================== 配置常量 ====================
local MAX_HISTORY = 25
local CHAT_BUTTON_SIZE = 44
local DOUBLE_CLICK_THRESHOLD = 0.3
local SAFE_WAIT_TIME = 2

-- ==================== 辅助函数 ====================
local function safeDisconnect(conn)
    if conn then
        pcall(function() conn:Disconnect() end)
    end
end

local function cleanupConnections()
    for _, conn in ipairs(connections) do
        safeDisconnect(conn)
    end
    connections = {}
end

-- 消息存储模块（本地表，全量存储）
local MessageStorage = nil
local function setupMessageStorage()
    if MessageStorage then return end
    MessageStorage = {
        messages = {},
        AddMessage = function(self, player, message, time)
            table.insert(self.messages, {player = player, message = message, time = time})
        end,
        GetAllMessages = function(self)
            local copy = {}
            for i, msg in ipairs(self.messages) do
                copy[i] = {player = msg.player, message = msg.message, time = msg.time}
            end
            return copy
        end,
        ClearMessages = function(self)
            self.messages = {}
        end
    }
end

-- ==================== UI 创建 ====================
local function createUI()
    MainGui = Instance.new("ScreenGui")
    MainGui.Name = "CustomChatSystem"
    MainGui.ResetOnSpawn = false
    MainGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    MainGui.Enabled = isEnabled    -- 根据启用状态设置

    ChatButton = Instance.new("ImageButton")
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

    ChatWindow = Instance.new("Frame")
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

    CloseButton = Instance.new("TextButton")
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

    ChatScroller = Instance.new("ScrollingFrame")
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
    -- 关键修改：VerticalAlignment 改为 Top，使消息从上到下排列，滚动条正常工作
    ChatLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    ChatLayout.Parent = ChatScroller

    TitleBar.Parent = ChatWindow
    ChatScroller.Parent = ChatWindow
    ChatWindow.Parent = MainGui
    ChatButton.Parent = MainGui
end

-- ==================== 消息框架缓存与显示 ====================
local function createMessageFrame(entry)
    local messageFrame
    if #messageFrameCache > 0 then
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

local function appendNewMessage(entry)
    if not ChatScroller then return end
    local frame = createMessageFrame(entry)
    frame.Parent = ChatScroller

    local frames = {}
    for _, child in ipairs(ChatScroller:GetChildren()) do
        if child:IsA("Frame") and child.Name == "MessageFrame" then
            table.insert(frames, child)
        end
    end
    if #frames > MAX_HISTORY then
        table.sort(frames, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
        local toRemove = frames[1]
        toRemove.Parent = nil
        table.insert(messageFrameCache, toRemove)
        activeMessageFrames[toRemove] = nil
    end

    task.defer(function()
        if ChatScroller and ChatScroller.CanvasSize.Y.Offset > ChatScroller.AbsoluteWindowSize.Y then
            ChatScroller.CanvasPosition = Vector2.new(0, ChatScroller.CanvasSize.Y.Offset - ChatScroller.AbsoluteWindowSize.Y)
        end
    end)
end

local function updateChatDisplay()
    if not ChatScroller then return end
    pcall(function()
        for _, child in ipairs(ChatScroller:GetChildren()) do
            if child:IsA("Frame") and child.Name == "MessageFrame" then
                child.Parent = nil
                table.insert(messageFrameCache, child)
                activeMessageFrames[child] = nil
            end
        end

        for _, entry in ipairs(ChatHistory) do
            local frame = createMessageFrame(entry)
            frame.Parent = ChatScroller
        end

        task.defer(function()
            if ChatScroller and ChatScroller.CanvasSize.Y.Offset > ChatScroller.AbsoluteWindowSize.Y then
                ChatScroller.CanvasPosition = Vector2.new(0, ChatScroller.CanvasSize.Y.Offset - ChatScroller.AbsoluteWindowSize.Y)
            end
        end)
    end)
end

-- ==================== 消息处理 ====================
local function addMessageToHistory(playerName, message)
    if not playerName or not message then return end
    if typeof(playerName) == "Instance" then
        playerName = playerName.Name
    end

    local entry = {
        player = tostring(playerName),
        message = tostring(message),
        time = os.time()
    }

    if MessageStorage then
        pcall(function()
            MessageStorage:AddMessage(entry.player, entry.message, entry.time)
        end)
    end

    pcall(function()
        table.insert(ChatHistory, entry)
        if #ChatHistory > MAX_HISTORY then
            table.remove(ChatHistory, 1)
        end

        if ChatWindow and ChatWindow.Visible then
            appendNewMessage(entry)
        end
    end)
end

-- ==================== 事件监听 ====================
local function handleChatMessage(message)
    -- 禁用模式下也继续记录消息，但 UI 已隐藏，所以直接存储即可
    if message and message.TextSource then
        local success, player = pcall(function()
            return Players:GetPlayerByUserId(message.TextSource.UserId)
        end)
        if success and player then
            addMessageToHistory(player.Name, message.Text)
        end
    end
end

local function setupTextChannels()
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
    local success, chatWindow = pcall(function()
        return TextChatService:WaitForChild("ChatWindow", SAFE_WAIT_TIME)
    end)
    if success and chatWindow then
        local success2, chatBar = pcall(function()
            return chatWindow:WaitForChild("ChatBar", SAFE_WAIT_TIME)
        end)
        if success2 and chatBar then
            local success3, textbox = pcall(function()
                return chatBar:WaitForChild("Textbox", SAFE_WAIT_TIME)
            end)
            if success3 and textbox then
                local conn = textbox.FocusLost:Connect(function(enterPressed)
                    -- 禁用模式下也记录自己发送的消息
                    if enterPressed and textbox.Text ~= "" then
                        addMessageToHistory(Player.Name, textbox.Text)
                    end
                end)
                table.insert(connections, conn)
            end
        end
    end
end

local function setupJoinedChannelsListener()
    pcall(setupTextChannels)
    pcall(setupGlobalListener)
    pcall(setupSelfMessageListener)
end

-- ==================== UI 交互 ====================
local lastClickTime = 0
local function handleDoubleClick()
    if not isEnabled then return end          -- 禁用时忽略点击，不打开窗口
    local currentTime = tick()
    if currentTime - lastClickTime <= DOUBLE_CLICK_THRESHOLD then
        ChatWindow.Visible = not ChatWindow.Visible
        if ChatWindow.Visible then
            updateChatDisplay()
        end
    end
    lastClickTime = currentTime
end

local function setupEventListeners()
    if ChatButton then
        local clickConn = ChatButton.MouseButton1Click:Connect(handleDoubleClick)
        table.insert(connections, clickConn)
    end
    if CloseButton then
        local closeConn = CloseButton.MouseButton1Click:Connect(function()
            if not isEnabled then return end
            ChatWindow.Visible = false
        end)
        table.insert(connections, closeConn)
    end
end

-- ==================== 模块初始化和清理 ====================
local function initialize()
    if isInitialized then return true end

    -- 获取本地玩家
    local success, plr = pcall(function()
        return Players.LocalPlayer
    end)
    if not success or not plr then
        warn("无法获取本地玩家")
        return false
    end
    Player = plr

    -- 获取PlayerGui
    local success2, gui = pcall(function()
        return Player:WaitForChild("PlayerGui", 5)
    end)
    if not success2 or not gui then
        warn("无法获取PlayerGui")
        return false
    end
    PlayerGui = gui

    setupMessageStorage()
    createUI()

    local success3 = pcall(function()
        MainGui.Parent = PlayerGui
    end)
    if not success3 then
        warn("无法将聊天UI添加到PlayerGui")
        return false
    end

    setupJoinedChannelsListener()
    setupEventListeners()

    isInitialized = true
    return true
end

local function cleanup()
    if not isInitialized then return end

    cleanupConnections()

    for _, frame in ipairs(messageFrameCache) do
        pcall(function() frame:Destroy() end)
    end
    messageFrameCache = {}
    for frame in pairs(activeMessageFrames) do
        pcall(function() frame:Destroy() end)
    end
    activeMessageFrames = {}
    ChatHistory = {}

    if MainGui then
        pcall(function() MainGui:Destroy() end)
        MainGui = nil
    end

    isInitialized = false
    isEnabled = false
end

-- ==================== 公共API ====================
function ChatSystem:SetEnabled(enabled)
    enabled = enabled == true
    if enabled == isEnabled then return end

    if enabled then
        -- 启用：重新创建UI（如果之前清理了）或者显示GUI
        if not isInitialized then
            local ok = initialize()
            if not ok then
                warn("重新初始化聊天系统失败")
                return
            end
        else
            if MainGui then
                MainGui.Enabled = true
            end
        end
        isEnabled = true
    else
        -- 禁用：关闭窗口，隐藏GUI，禁止交互（但后台继续记录消息）
        if ChatWindow and ChatWindow.Visible then
            ChatWindow.Visible = false
        end
        if MainGui then
            MainGui.Enabled = false
        end
        isEnabled = false
    end
end

function ChatSystem:IsEnabled()
    return isEnabled
end

-- 获取全部历史消息（从本地表存储）
function ChatSystem:GetFullHistory()
    if not MessageStorage then
        warn("消息存储模块未就绪")
        return {}
    end
    local messages = MessageStorage:GetAllMessages()
    return messages or {}
end

-- 清空全部历史消息（清空存储和显示用历史记录）
function ChatSystem:ClearHistory()
    if MessageStorage then
        pcall(function()
            MessageStorage:ClearMessages()
        end)
    end
    ChatHistory = {}
    -- 如果窗口可见，刷新显示
    if ChatWindow and ChatWindow.Visible then
        updateChatDisplay()
    end
end

-- 自动初始化（默认启用）
local initSuccess = initialize()
if not initSuccess then
    warn("聊天系统初始化失败，后续调用 SetEnabled(true) 将重试")
end

return ChatSystem