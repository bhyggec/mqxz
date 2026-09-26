-- 玩家esp V1.0
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local CONFIG = {
    UPDATE_RATE = 0.06,
    BILLBOARD_SIZE = UDim2.new(0,160,0,36),
    NAME_TEXT_SIZE = 18,           -- 名字与血量相同大小
    -- HEALTH_TEXT_SIZE 不再单独使用
    FALLBACK_COLOR = Color3.fromRGB(0,0,0),
    OUTLINE_DARKEN_FACTOR = 0.30,
    FILL_TINT_AMOUNT = 0.70,
    FILL_TRANSPARENCY = 0.55,
    HEAD_WAIT_TIMEOUT = 3,
}

local espTable = {} -- [player] = { gui, name, health, highlight, charChildConn, charRemovingConn }

-- helpers
local function colorFromString(str)
    if not str or #str == 0 then return CONFIG.FALLBACK_COLOR end
    local h = 0
    for i = 1, #str do h = (h * 31 + str:byte(i)) % 16777216 end
    local r = math.floor(h / 65536) % 256
    local g = math.floor(h / 256) % 256
    local b = h % 256
    return Color3.fromRGB(r, g, b)
end

local function getFactionKey(player)
    local attr = player:GetAttribute("Faction")
    if attr and tostring(attr) ~= "" then return tostring(attr) end
    if player.Team and player.Team.Name and tostring(player.Team.Name) ~= "" then return tostring(player.Team.Name) end
    if player.TeamColor and tostring(player.TeamColor) ~= "" then return tostring(player.TeamColor.Name) end
    return nil
end

local function factionBaseColor(player)
    local attr = player:GetAttribute("Faction")
    if attr and type(attr) == "string" and #attr > 0 then
        local ok, b = pcall(function() return BrickColor.new(attr) end)
        if ok and b then return b.Color end
        if tostring(attr):match("^#%x%x%x%x%x%x$") then
            local hex = tostring(attr):gsub("#","")
            local r = tonumber(hex:sub(1,2),16)
            local g = tonumber(hex:sub(3,4),16)
            local bval = tonumber(hex:sub(5,6),16)
            if r and g and bval then return Color3.fromRGB(r,g,bval) end
        end
    end
    if player.TeamColor and tostring(player.TeamColor) ~= "" then
        local ok, bc = pcall(function() return player.TeamColor end)
        if ok and bc then return bc.Color end
    end
    if player.Team and player.Team.Name and #player.Team.Name > 0 then
        local ok, b2 = pcall(function() return BrickColor.new(player.Team.Name) end)
        if ok and b2 then return b2.Color end
    end
    local key = getFactionKey(player)
    if not key then return CONFIG.FALLBACK_COLOR end
    return colorFromString(key)
end

local function darkenColor(c, factor)
    return Color3.new(math.clamp(c.R * factor,0,1), math.clamp(c.G * factor,0,1), math.clamp(c.B * factor,0,1))
end
local function tintToWhite(c, t)
    return Color3.new(
        math.clamp(c.R + (1 - c.R) * t,0,1),
        math.clamp(c.G + (1 - c.G) * t,0,1),
        math.clamp(c.B + (1 - c.B) * t,0,1)
    )
end

-- UI factories (血量在名字上方)
local function createBillboard(player, head)
    if not head or not head.Parent then return nil end
    local gui = Instance.new("BillboardGui")
    gui.Name = "ESP_BB_" .. player.Name
    gui.Adornee = head
    gui.Size = CONFIG.BILLBOARD_SIZE
    gui.StudsOffset = Vector3.new(0, 1.6, 0)
    gui.AlwaysOnTop = true
    gui.Parent = PlayerGui

    local healthLabel = Instance.new("TextLabel") -- 血量在上方
    healthLabel.Size = UDim2.new(1,0,0.45,0)
    healthLabel.Position = UDim2.new(0,0,0,0)
    healthLabel.BackgroundTransparency = 1
    healthLabel.TextScaled = false
    healthLabel.TextSize = CONFIG.NAME_TEXT_SIZE
    healthLabel.Font = Enum.Font.SourceSansBold
    healthLabel.TextStrokeTransparency = 0
    healthLabel.Text = ""
    healthLabel.Parent = gui

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1,0,0.55,0)
    nameLabel.Position = UDim2.new(0,0,0.45,0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.TextScaled = false
    nameLabel.TextSize = CONFIG.NAME_TEXT_SIZE
    nameLabel.Font = Enum.Font.SourceSansBold
    nameLabel.TextStrokeTransparency = 0
    nameLabel.Text = player.Name
    nameLabel.Parent = gui

    return {gui = gui, name = nameLabel, health = healthLabel}
end

local function createHighlightFor(player, character, baseColor)
    if not character or not character.Parent then return nil end
    local outline = darkenColor(baseColor, CONFIG.OUTLINE_DARKEN_FACTOR)
    local fill = tintToWhite(baseColor, CONFIG.FILL_TINT_AMOUNT)
    local ok, hi = pcall(function()
        local h = Instance.new("Highlight")
        h.Name = "ESP_Highlight_" .. player.Name
        h.Adornee = character
        h.OutlineTransparency = 0
        h.FillTransparency = CONFIG.FILL_TRANSPARENCY
        h.OutlineColor = outline
        h.FillColor = fill
        h.Parent = Workspace
        return h
    end)
    if ok then return hi end
    return nil
end

local function updateHighlightColors(highlight, base)
    if not highlight or not base then return end
    local outline = darkenColor(base, CONFIG.OUTLINE_DARKEN_FACTOR)
    local fill = tintToWhite(base, CONFIG.FILL_TINT_AMOUNT)
    if highlight.OutlineColor ~= outline then highlight.OutlineColor = outline end
    if highlight.FillColor ~= fill then highlight.FillColor = fill end
    if highlight.FillTransparency ~= CONFIG.FILL_TRANSPARENCY then highlight.FillTransparency = CONFIG.FILL_TRANSPARENCY end
    if highlight.OutlineTransparency ~= 0 then highlight.OutlineTransparency = 0 end
end

local function cleanupPlayer(player)
    local data = espTable[player]
    if not data then return end
    if data.gui and data.gui.Parent then data.gui:Destroy() end
    if data.highlight and data.highlight.Parent then data.highlight:Destroy() end
    if data.charChildConn and data.charChildConn.Disconnect then pcall(function() data.charChildConn:Disconnect() end) end
    if data.charRemovingConn and data.charRemovingConn.Disconnect then pcall(function() data.charRemovingConn:Disconnect() end) end
    espTable[player] = nil
end

local function formatHealth(humanoid)
    if not humanoid then return "N/A" end
    local maxH = humanoid.MaxHealth and humanoid.MaxHealth > 0 and humanoid.MaxHealth or 100
    local cur = math.max(0, math.floor(humanoid.Health + 0.5))
    local mx = math.floor(maxH + 0.5)
    if cur <= 0 then return string.format("Dead (%d/%d)", cur, mx) end
    return string.format("%d / %d", cur, mx)
end

-- ensure ESP
local function ensureESPFor(player)
    if not player or player == LocalPlayer then return end
    local data = espTable[player]
    local char = player.Character
    local head = char and char:FindFirstChild("Head")
    local base = factionBaseColor(player)

    if not data then
        espTable[player] = { gui = nil, name = nil, health = nil, highlight = nil, charChildConn = nil, charRemovingConn = nil }
        data = espTable[player]
    end

    if char and not head then
        if not data.charChildConn then
            local conn
            conn = char.ChildAdded:Connect(function(child)
                if child.Name == "Head" and child:IsA("BasePart") then
                    task.delay(0, function() ensureESPFor(player) end)
                    if conn then pcall(function() conn:Disconnect() end) end
                    data.charChildConn = nil
                end
            end)
            data.charChildConn = conn
            task.spawn(function()
                local ok, headPart = pcall(function() return char:WaitForChild("Head", CONFIG.HEAD_WAIT_TIMEOUT) end)
                if ok and headPart and headPart.Parent == char then
                    ensureESPFor(player)
                    if data.charChildConn then pcall(function() data.charChildConn:Disconnect() end) data.charChildConn = nil end
                end
            end)
        end
    end

    if char and head then
        if not data.gui or not data.gui.Parent then
            local bb = createBillboard(player, head)
            if bb then
                data.gui = bb.gui
                data.name = bb.name
                data.health = bb.health
            end
        else
            data.gui.Adornee = head
        end

        if not data.highlight or not data.highlight.Parent then
            data.highlight = createHighlightFor(player, char, base)
        else
            updateHighlightColors(data.highlight, base)
        end

        if not data.charRemovingConn then
            data.charRemovingConn = char:GetPropertyChangedSignal("Parent"):Connect(function()
                if not char.Parent then cleanupPlayer(player) end
            end)
        end

        if data.name and data.health then
            local outline = darkenColor(base, CONFIG.OUTLINE_DARKEN_FACTOR)
            data.name.TextColor3 = outline
            data.health.TextColor3 = outline
            data.name.TextSize = CONFIG.NAME_TEXT_SIZE
            data.health.TextSize = CONFIG.NAME_TEXT_SIZE
        end
    end
end

-- player join handling
local function onPlayerJoined(p)
    if p == LocalPlayer then return end
    p:GetAttributeChangedSignal("Faction"):Connect(function() ensureESPFor(p) end)
    p:GetPropertyChangedSignal("Team"):Connect(function() ensureESPFor(p) end)
    p:GetPropertyChangedSignal("TeamColor"):Connect(function() ensureESPFor(p) end)
    if p.Character then ensureESPFor(p) end
    p.CharacterAdded:Connect(function() task.delay(0.05, function() ensureESPFor(p) end) end)
    p.AncestryChanged:Connect(function() if not p.Parent then cleanupPlayer(p) end end)
end

for _, p in ipairs(Players:GetPlayers()) do onPlayerJoined(p) end
Players.PlayerAdded:Connect(onPlayerJoined)
Players.PlayerRemoving:Connect(function(p) cleanupPlayer(p) end)

-- main refresh
local acc = 0
RunService.Heartbeat:Connect(function(dt)
    acc = acc + dt
    if acc < CONFIG.UPDATE_RATE then return end
    acc = 0

    for player, data in pairs(espTable) do
        if not player or not player.Parent then
            cleanupPlayer(player)
        else
            ensureESPFor(player)
            local base = factionBaseColor(player)
            if data and data.health then
                local humanoid = (player.Character and player.Character:FindFirstChildOfClass("Humanoid")) or nil
                data.health.Text = formatHealth(humanoid)
            end
            if data and data.name then
                local outline = darkenColor(base, CONFIG.OUTLINE_DARKEN_FACTOR)
                data.name.TextColor3 = outline
                data.health.TextColor3 = outline
                if data.name.TextSize ~= CONFIG.NAME_TEXT_SIZE then data.name.TextSize = CONFIG.NAME_TEXT_SIZE end
                if data.health.TextSize ~= CONFIG.NAME_TEXT_SIZE then data.health.TextSize = CONFIG.NAME_TEXT_SIZE end
            end
            if data and data.highlight and data.highlight.Parent then
                updateHighlightColors(data.highlight, base)
            end
        end
    end
end)