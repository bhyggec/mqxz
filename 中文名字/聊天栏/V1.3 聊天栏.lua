--聊天栏 V1.3
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")

-- ==================== 模块核心定义 ====================
local ChatSystem = {}
local isEnabled = true
local isInitialized = false
local lastWrittenServerId = nil -- 【优化2】记录上一次写入头的服务器ID，防重复写入
local connections = {}
local messageFrameCache = {}
local activeMessageFrames = {}
local ChatHistory = {}
-- UI实例缓存
local MainGui, ChatButton, ChatWindow, CloseButton, ChatScroller
-- 玩家实例缓存
local Player, PlayerGui

-- ==================== 配置常量（所有可调整参数集中在这里） ====================
local MAX_HISTORY = 25
local CHAT_BUTTON_SIZE = 44
local DOUBLE_CLICK_THRESHOLD = 0.3 -- 【优化6】双击阈值做成可配置常量，移动端0.3s为最优值
local SAFE_WAIT_TIME = 2
local SAVE_FILE_PATH = "永久聊天记录.txt"
local ENABLE_FILE_SAVE = true
local ENABLE_BATCH_WRITE = false -- 【优化1】批量写入开关，默认关闭（实时写入保数据），开启后用缓冲区
local BATCH_WRITE_COUNT = 10 -- 批量写入阈值：满10条写入一次
local BATCH_WRITE_INTERVAL = 5 -- 批量写入阈值：最长5秒写入一次
local messageBuffer = {} -- 批量写入缓冲区，仅ENABLE_BATCH_WRITE=true时生效
local batchWriteLoopRunning = false

-- ==================== 底层安全工具函数 ====================
-- 安全断开事件连接
local function safeDisconnect(conn)
    if not conn then return end
    pcall(function()
        if conn.Connected then
            conn:Disconnect()
        end
    end)
end

-- 批量清理所有事件连接
local function cleanupConnections()
    for _, conn in ipairs(connections) do
        safeDisconnect(conn)
    end
    table.clear(connections)
end

-- 【优化3】轻量严谨的文件API可用性检测，无临时文件、全兼容移动端
local function isFileApiAvailable()
    local success, result = pcall(function()
        -- 校验函数存在性+类型为function，比原逻辑更严谨
        local hasAppend = type(appendfile) == "function"
        local hasWrite = type(writefile) == "function"
        local hasRead = type(readfile) == "function"
        local hasIsFile = type(isfile) == "function"
        return (hasAppend or hasWrite) and hasRead and hasIsFile
    end)
    return success and result
end

-- 【优化1】批量写入核心逻辑，仅开关开启时生效
local function flushBufferToFile()
    if not ENABLE_BATCH_WRITE or #messageBuffer == 0 then return end
    if not isFileApiAvailable() then return end

    pcall(function()
        local content = table.concat(messageBuffer, "\n") .. "\n"
        if appendfile then
            appendfile(SAVE_FILE_PATH, content)
        else
            local existingContent = ""
            local readSuccess, readResult = pcall(function()
                return readfile(SAVE_FILE_PATH)
            end)
            if readSuccess then
                existingContent = readResult
            end
            writefile(SAVE_FILE_PATH, existingContent .. content)
        end
        table.clear(messageBuffer)
    end)
end

-- 【优化1】批量写入循环，仅开关开启时启动
local function startBatchWriteLoop()
    if batchWriteLoopRunning or not ENABLE_BATCH_WRITE then return end
    batchWriteLoopRunning = true
    task.spawn(function()
        while ENABLE_BATCH_WRITE and isInitialized do
            task.wait(BATCH_WRITE_INTERVAL)
            flushBufferToFile()
        end
        batchWriteLoopRunning = false
    end)
end

-- ==================== 核心：服务器头信息写入（【优化2】防重复写入） ====================
local function writeServerHeader()
    -- 前置校验
    if not ENABLE_FILE_SAVE or not isFileApiAvailable() then
        return
    end

    local writeSuccess, err = pcall(function()
        -- 获取当前服务器唯一ID，本地测试兜底
        local currentServerId = game.JobId or ""
        currentServerId = currentServerId ~= "" and currentServerId or "本地测试服务器"

        -- 【优化2】核心：同一个服务器实例，绝对不重复写入头信息
        if lastWrittenServerId == currentServerId then
            return
        end

        -- 时间格式化兜底
        local formattedTime = "[未知时间]"
        pcall(function()
            formattedTime = os.date("[%Y-%m-%d %H:%M:%S]")
        end)

        -- 游戏ID/名称安全获取
        local placeId = tostring(game.PlaceId or 0)
        local serverName = "未知游戏"
        local getInfoSuccess, productInfo = pcall(function()
            return MarketplaceService:GetProductInfo(game.PlaceId)
        end)
        if getInfoSuccess and productInfo and type(productInfo.Name) == "string" then
            serverName = productInfo.Name
        end

        -- 严格按指定格式拼接
        local headerLine = string.format(
            "%s [游戏id:%s] [服务器id:%s] [服务器名字:%s]",
            formattedTime,
            placeId,
            currentServerId,
            serverName
        )

        -- 安全写入文件，自动加分隔空行
        local contentToWrite = headerLine .. "\n"
        local fileExistSuccess, fileExist = pcall(function()
            return isfile(SAVE_FILE_PATH)
        end)
        if fileExistSuccess and fileExist then
            local readSuccess, existingContent = pcall(function()
                return readfile(SAVE_FILE_PATH)
            end)
            if readSuccess and existingContent and #existingContent > 0 then
                contentToWrite = "\n" .. contentToWrite
            end
        end

        -- 写入文件
        if appendfile then
            appendfile(SAVE_FILE_PATH, contentToWrite)
        else
            local existingContent = ""
            local readSuccess, readResult = pcall(function()
                return readfile(SAVE_FILE_PATH)
            end)
            if readSuccess then
                existingContent = readResult
            end
            writefile(SAVE_FILE_PATH, existingContent .. contentToWrite)
        end

        -- 记录本次写入的服务器ID，防重复
        lastWrittenServerId = currentServerId
    end)

    if not writeSuccess then
        warn(string.format("服务器头信息写入失败: %s", tostring(err)))
    end
end

-- ==================== 核心：聊天消息永久保存（兼容实时/批量双模式） ====================
local function saveMessageToFile(playerName, userId, message)
    if not ENABLE_FILE_SAVE or not isFileApiAvailable() then
        return
    end

    local saveSuccess, err = pcall(function()
        -- 所有参数兜底，避免nil报错
        local formattedTime = "[未知时间]"
        pcall(function()
            formattedTime = os.date("[%Y-%m-%d %H:%M:%S]")
        end)
        local safePlayerName = tostring(playerName or "未知玩家")
        local safeUserId = tostring(userId or 0)
        local safeMessage = tostring(message or "")

        -- 清理消息内的换行/制表符，保证一行一条记录
        safeMessage = string.gsub(string.gsub(safeMessage, "[\n\r]+", " "), "\t", " ")
        -- 严格按指定格式拼接
        local finalLine = string.format(
            "%s [uid:%s] %s:%s",
            formattedTime,
            safeUserId,
            safePlayerName,
            safeMessage
        )

        -- 【优化1】根据开关选择写入模式
        if ENABLE_BATCH_WRITE then
            -- 批量模式：加入缓冲区
            table.insert(messageBuffer, finalLine)
            startBatchWriteLoop()
            -- 达到条数阈值立即刷新
            if #messageBuffer >= BATCH_WRITE_COUNT then
                flushBufferToFile()
            end
        else
            -- 实时模式（默认）：立即写入文件，保证不丢记录
            if appendfile then
                appendfile(SAVE_FILE_PATH, finalLine .. "\n")
            else
                local existingContent = ""
                local readSuccess, readResult = pcall(function()
                    return readfile(SAVE_FILE_PATH)
                end)
                if readSuccess then
                    existingContent = readResult
                end
                writefile(SAVE_FILE_PATH, existingContent .. finalLine .. "\n")
            end
        end
    end)

    if not saveSuccess then
        warn(string.format("聊天消息写入失败: %s", tostring(err)))
    end
end

-- ==================== 消息存储模块（全保护） ====================
local MessageStorage = nil
local function setupMessageStorage()
    if MessageStorage then return end
    MessageStorage = {
        messages = {},
        AddMessage = function(self, player, message, time)
            pcall(function()
                table.insert(self.messages, {
                    player = tostring(player or "未知玩家"),
                    message = tostring(message or ""),
                    time = tonumber(time) or os.time()
                })
            end)
        end,
        GetAllMessages = function(self)
            local copy = {}
            pcall(function()
                for i, msg in ipairs(self.messages) do
                    copy[i] = {
                        player = msg.player,
                        message = msg.message,
                        time = msg.time
                    }
                end
            end)
            return copy
        end,
        ClearMessages = function(self)
            pcall(function()
                table.clear(self.messages)
            end)
        end
    }
end

-- ==================== UI创建模块（【优化5】防内存泄漏） ====================
local function createUI()
    -- 【修复点1】销毁旧UI后立即清空引用，防止残留实例导致挂载失败
    pcall(function()
        if MainGui then
            MainGui:Destroy()
        end
    end)
    MainGui = nil
    ChatButton = nil
    ChatWindow = nil
    CloseButton = nil
    ChatScroller = nil

    table.clear(messageFrameCache)
    table.clear(activeMessageFrames)

    local createSuccess, err = pcall(function()
        -- 主Gui
        MainGui = Instance.new("ScreenGui")
        MainGui.Name = "CustomChatSystem"
        MainGui.ResetOnSpawn = false
        MainGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        MainGui.Enabled = isEnabled

        -- 聊天悬浮按钮
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

        -- 聊天窗口
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

        -- 标题栏
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

        -- 【优化7】动态标题，和MAX_HISTORY常量自动同步
        local TitleText = Instance.new("TextLabel")
        TitleText.Name = "TitleText"
        TitleText.Size = UDim2.new(1, -10, 1, 0)
        TitleText.Position = UDim2.new(0, 10, 0, 0)
        TitleText.BackgroundTransparency = 1
        TitleText.Text = string.format("聊天记录 (最多%d条)", MAX_HISTORY)
        TitleText.TextColor3 = Color3.fromRGB(220, 220, 220)
        TitleText.Font = Enum.Font.GothamSemibold
        TitleText.TextSize = 14
        TitleText.TextXAlignment = Enum.TextXAlignment.Left
        TitleText.ZIndex = 7
        TitleText.Parent = TitleBar

        -- 关闭按钮
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

        -- 聊天滚动容器
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
        ChatLayout.VerticalAlignment = Enum.VerticalAlignment.Top
        ChatLayout.Parent = ChatScroller

        -- 组装UI层级
        TitleBar.Parent = ChatWindow
        ChatScroller.Parent = ChatWindow
        ChatWindow.Parent = MainGui
        ChatButton.Parent = MainGui
    end)

    if not createSuccess then
        -- 【修复点2】UI创建失败时强制清空引用，防止后续挂载到无效实例
        warn(string.format("UI创建失败: %s", tostring(err)))
        MainGui = nil
        ChatButton = nil
        ChatWindow = nil
        CloseButton = nil
        ChatScroller = nil
    end
end

-- ==================== 消息帧缓存与渲染模块（【优化5】防内存泄漏） ====================
local function createMessageFrame(entry)
    local messageFrame = nil
    local createSuccess, err = pcall(function()
        -- 优先复用缓存帧
        if #messageFrameCache > 0 then
            messageFrame = table.remove(messageFrameCache, 1)
            -- 【优化5】校验帧有效性，不缓存已销毁的实例
            if not messageFrame or not messageFrame:IsDescendantOf(game) then
                messageFrame = nil
            else
                -- 复用帧更新内容
                for _, child in ipairs(messageFrame:GetChildren()) do
                    if child.Name == "PlayerName" then
                        child.Text = tostring(entry.player or "未知玩家") .. ":"
                    elseif child.Name == "MessageText" then
                        local msgContent = tostring(entry.message or "")
                        child.Text = msgContent
                        -- 安全计算文本尺寸
                        local textSize = Vector2.new(300, 20)
                        pcall(function()
                            textSize = TextService:GetTextSize(
                                msgContent,
                                14,
                                Enum.Font.Gotham,
                                Vector2.new(300, math.huge)
                            )
                        end)
                        child.Size = UDim2.new(1, -85, 0, textSize.Y)
                        messageFrame.Size = UDim2.new(1, 0, 0, textSize.Y)
                    end
                end
                messageFrame.LayoutOrder = tonumber(entry.time) or os.time()
            end
        end

        -- 无缓存则新建帧
        if not messageFrame then
            messageFrame = Instance.new("Frame")
            messageFrame.Name = "MessageFrame"
            messageFrame.Size = UDim2.new(1, 0, 0, 0)
            messageFrame.BackgroundTransparency = 1
            messageFrame.LayoutOrder = tonumber(entry.time) or os.time()
            messageFrame.ZIndex = 7

            local playerLabel = Instance.new("TextLabel")
            playerLabel.Name = "PlayerName"
            playerLabel.Size = UDim2.new(0, 80, 0, 20)
            playerLabel.Position = UDim2.new(0, 0, 0, 0)
            playerLabel.BackgroundTransparency = 1
            playerLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
            playerLabel.Font = Enum.Font.GothamSemibold
            playerLabel.TextSize = 14
            playerLabel.Text = tostring(entry.player or "未知玩家") .. ":"
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
            local msgContent = tostring(entry.message or "")
            messageLabel.Text = msgContent
            messageLabel.TextXAlignment = Enum.TextXAlignment.Left
            messageLabel.TextYAlignment = Enum.TextYAlignment.Top
            messageLabel.TextWrapped = true
            messageLabel.ZIndex = 8
            messageLabel.Parent = messageFrame

            -- 安全计算文本尺寸
            local textSize = Vector2.new(300, 20)
            pcall(function()
                textSize = TextService:GetTextSize(
                    msgContent,
                    14,
                    Enum.Font.Gotham,
                    Vector2.new(300, math.huge)
                )
            end)
            messageLabel.Size = UDim2.new(1, -85, 0, textSize.Y)
            messageFrame.Size = UDim2.new(1, 0, 0, textSize.Y)
        end

        -- 标记为活跃帧
        activeMessageFrames[messageFrame] = true
    end)

    if not createSuccess then
        warn(string.format("消息帧创建失败: %s", tostring(err)))
        return nil
    end

    return messageFrame
end

-- 追加单条新消息到窗口
local function appendNewMessage(entry)
    if not ChatScroller or not entry then return end
    pcall(function()
        local frame = createMessageFrame(entry)
        if not frame then return end
        frame.Parent = ChatScroller

        -- 超出上限回收旧帧
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

        -- 自动滚动到底部
        task.defer(function()
            pcall(function()
                if ChatScroller and ChatScroller.CanvasSize.Y.Offset > ChatScroller.AbsoluteWindowSize.Y then
                    ChatScroller.CanvasPosition = Vector2.new(0, ChatScroller.CanvasSize.Y.Offset - ChatScroller.AbsoluteWindowSize.Y)
                end
            end)
        end)
    end)
end

-- 全量刷新聊天窗口显示
local function updateChatDisplay()
    if not ChatScroller then return end
    pcall(function()
        -- 回收所有活跃帧
        for _, child in ipairs(ChatScroller:GetChildren()) do
            if child:IsA("Frame") and child.Name == "MessageFrame" then
                child.Parent = nil
                table.insert(messageFrameCache, child)
                activeMessageFrames[child] = nil
            end
        end
        -- 重新渲染所有历史消息
        for _, entry in ipairs(ChatHistory) do
            local frame = createMessageFrame(entry)
            if frame then
                frame.Parent = ChatScroller
            end
        end
        -- 自动滚动到底部
        task.defer(function()
            pcall(function()
                if ChatScroller and ChatScroller.CanvasSize.Y.Offset > ChatScroller.AbsoluteWindowSize.Y then
                    ChatScroller.CanvasPosition = Vector2.new(0, ChatScroller.CanvasSize.Y.Offset - ChatScroller.AbsoluteWindowSize.Y)
                end
            end)
        end)
    end)
end

-- ==================== 消息处理核心模块（全保护） ====================
local function addMessageToHistory(playerName, message, userId)
    if not playerName or not message then return end
    pcall(function()
        -- 玩家实例转名称
        if typeof(playerName) == "Instance" and playerName:IsA("Player") then
            playerName = playerName.Name
        end
        -- 构造消息条目
        local entry = {
            player = tostring(playerName),
            message = tostring(message),
            time = os.time()
        }
        -- 写入内存存储
        if MessageStorage then
            MessageStorage:AddMessage(entry.player, entry.message, entry.time)
        end
        -- 更新显示用历史
        table.insert(ChatHistory, entry)
        if #ChatHistory > MAX_HISTORY then
            table.remove(ChatHistory, 1)
        end
        -- 窗口可见时追加渲染
        if ChatWindow and ChatWindow.Visible then
            appendNewMessage(entry)
        end
        -- 写入本地文件
        saveMessageToFile(playerName, userId, message)
    end)
end

-- ==================== 聊天事件监听模块（全保护） ====================
-- 处理收到的聊天消息
local function handleChatMessage(message)
    if not message or not message.TextSource then return end
    pcall(function()
        local getPlayerSuccess, player = pcall(function()
            return Players:GetPlayerByUserId(message.TextSource.UserId)
        end)
        if getPlayerSuccess and player then
            addMessageToHistory(player.Name, message.Text, player.UserId)
        end
    end)
end

-- 监听所有文本频道
local function setupTextChannels()
    pcall(function()
        local getChannelsSuccess, textChannels = pcall(function()
            return TextChatService:WaitForChild("TextChannels", SAFE_WAIT_TIME)
        end)
        if not getChannelsSuccess or not textChannels then return end

        -- 监听已有频道
        for _, channel in ipairs(textChannels:GetChildren()) do
            if channel:IsA("TextChannel") then
                local conn = channel.OnIncomingMessage:Connect(handleChatMessage)
                table.insert(connections, conn)
            end
        end

        -- 监听新增频道
        local childAddConn = textChannels.ChildAdded:Connect(function(channel)
            if channel:IsA("TextChannel") then
                local childConn = channel.OnIncomingMessage:Connect(handleChatMessage)
                table.insert(connections, childConn)
            end
        end)
        table.insert(connections, childAddConn)
    end)
end

-- 全局消息监听兜底
local function setupGlobalListener()
    pcall(function()
        local globalConnSuccess, conn = pcall(function()
            return TextChatService.MessageReceived:Connect(function(message)
                if message.TextChannel then
                    handleChatMessage(message)
                end
            end)
        end)
        if globalConnSuccess and conn then
            table.insert(connections, conn)
        end
    end)
end

-- 监听自己发送的消息
local function setupSelfMessageListener()
    task.wait(1)
    pcall(function()
        local getChatWindowSuccess, chatWindow = pcall(function()
            return TextChatService:WaitForChild("ChatWindow", SAFE_WAIT_TIME)
        end)
        if not getChatWindowSuccess or not chatWindow then return end

        local getChatBarSuccess, chatBar = pcall(function()
            return chatWindow:WaitForChild("ChatBar", SAFE_WAIT_TIME)
        end)
        if not getChatBarSuccess or not chatBar then return end

        local getTextboxSuccess, textbox = pcall(function()
            return chatBar:WaitForChild("Textbox", SAFE_WAIT_TIME)
        end)
        if not getTextboxSuccess or not textbox then return end

        local selfMsgConn = textbox.FocusLost:Connect(function(enterPressed)
            if enterPressed and textbox.Text ~= "" and Player then
                addMessageToHistory(Player.Name, textbox.Text, Player.UserId)
            end
        end)
        table.insert(connections, selfMsgConn)
    end)
end

-- 批量初始化所有监听
local function setupJoinedChannelsListener()
    setupTextChannels()
    setupGlobalListener()
    setupSelfMessageListener()
end

-- ==================== UI交互事件模块 ====================
local lastClickTime = 0
-- 双击打开/关闭聊天窗（移动端最优逻辑，无改动）
local function handleDoubleClick()
    if not isEnabled then return end
    pcall(function()
        local currentTime = tick()
        if currentTime - lastClickTime <= DOUBLE_CLICK_THRESHOLD then
            if ChatWindow then
                ChatWindow.Visible = not ChatWindow.Visible
                if ChatWindow.Visible then
                    updateChatDisplay()
                end
            end
        end
        lastClickTime = currentTime
    end)
end

-- 初始化UI交互监听
local function setupEventListeners()
    pcall(function()
        if ChatButton then
            local clickConn = ChatButton.MouseButton1Click:Connect(handleDoubleClick)
            table.insert(connections, clickConn)
        end
        if CloseButton then
            local closeConn = CloseButton.MouseButton1Click:Connect(function()
                if not isEnabled or not ChatWindow then return end
                ChatWindow.Visible = false
            end)
            table.insert(connections, closeConn)
        end
    end)
end

-- ==================== 模块生命周期管理（已修复 Player.Removing 问题） ====================
local function initialize()
    if isInitialized then return true end

    local initSuccess, err = pcall(function()
        -- 步骤1：获取本地玩家
        local plr = Players.LocalPlayer
        if not plr then
            error("[步骤1] 无法获取本地玩家")
        end
        Player = plr

        -- 步骤2：玩家离开时自动清理（改用 Players.PlayerRemoving，兼容新版引擎）
        local leaveConn = game.Players.PlayerRemoving:Connect(function(player)
            if player == Player then
                pcall(cleanup)
            end
        end)
        table.insert(connections, leaveConn)

        -- 步骤3：等待 PlayerGui（无限等待）
        local gui = Player:WaitForChild("PlayerGui")
        if not gui then
            error("[步骤3] 无法获取PlayerGui")
        end
        PlayerGui = gui

        -- 步骤4：初始化消息存储
        setupMessageStorage()

        -- 步骤5：创建 UI
        createUI()
        if not MainGui then
            error("[步骤5] UI创建失败")
        end

        -- 步骤6：挂载 UI
        MainGui.Parent = PlayerGui

        -- 步骤7：初始化监听器
        setupJoinedChannelsListener()
        setupEventListeners()

        -- 步骤8：文件保存模块
        if ENABLE_FILE_SAVE then
            local apiAvailable = isFileApiAvailable()
            if not apiAvailable then
                warn("当前环境不支持文件写入API，聊天记录永久保存功能未启用")
            else
                print("聊天记录永久保存功能已启用，保存文件：" .. SAVE_FILE_PATH)
                writeServerHeader()
                if ENABLE_BATCH_WRITE then
                    startBatchWriteLoop()
                end
            end
        end

        isInitialized = true
        return true
    end)

    if not initSuccess then
        warn("聊天系统初始化失败: " .. tostring(err))
        return false
    end

    print("聊天系统初始化成功")
    return true
end

-- 模块清理销毁
local function cleanup()
    if not isInitialized then return end
    pcall(function()
        -- 【优化1】销毁前强制刷新缓冲区，避免丢记录
        if ENABLE_BATCH_WRITE then
            flushBufferToFile()
        end
        -- 清理所有事件连接
        cleanupConnections()
        -- 清理UI缓存
        for _, frame in ipairs(messageFrameCache) do
            pcall(function() frame:Destroy() end)
        end
        table.clear(messageFrameCache)
        for frame in pairs(activeMessageFrames) do
            pcall(function() frame:Destroy() end)
        end
        table.clear(activeMessageFrames)
        -- 清理内存数据
        table.clear(ChatHistory)
        table.clear(messageBuffer)
        if MessageStorage then
            MessageStorage:ClearMessages()
        end
        -- 销毁UI
        if MainGui then
            pcall(function() MainGui:Destroy() end)
            MainGui = nil
        end
        -- 重置状态标记
        isInitialized = false
        isEnabled = false
        batchWriteLoopRunning = false
        -- 【优化2】仅完全销毁时重置服务器ID标记，开关UI不重置
        lastWrittenServerId = nil
    end)
end

-- ==================== 公共开放API（全保护，无改动） ====================
-- 设置模块启用/禁用状态
function ChatSystem:SetEnabled(enabled)
    enabled = enabled == true
    if enabled == isEnabled then return end
    pcall(function()
        if enabled then
            -- 启用模块
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
            -- 禁用模块
            if ChatWindow then
                ChatWindow.Visible = false
            end
            if MainGui then
                MainGui.Enabled = false
            end
            -- 【优化1】禁用时强制刷新缓冲区，避免丢记录
            if ENABLE_BATCH_WRITE then
                flushBufferToFile()
            end
            isEnabled = false
        end
    end)
end

-- 获取当前启用状态
function ChatSystem:IsEnabled()
    return isEnabled
end

-- 获取全量历史消息
function ChatSystem:GetFullHistory()
    local history = {}
    pcall(function()
        if not MessageStorage then
            warn("消息存储模块未就绪")
            return
        end
        history = MessageStorage:GetAllMessages()
    end)
    return history
end

-- 清空所有历史消息
function ChatSystem:ClearHistory()
    pcall(function()
        if MessageStorage then
            MessageStorage:ClearMessages()
        end
        table.clear(ChatHistory)
        if ChatWindow and ChatWindow.Visible then
            updateChatDisplay()
        end
    end)
end

-- 销毁整个聊天系统
function ChatSystem:Destroy()
    cleanup()
end

-- ==================== 自动初始化 ====================
local autoInitSuccess = initialize()
if not autoInitSuccess then
    warn("聊天系统自动初始化失败，后续可调用 ChatSystem:SetEnabled(true) 重试初始化")
end

return ChatSystem