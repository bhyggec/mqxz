-- 超高性能 Soft Lighting & Screen Effect Cleaner（已移除 F5 快捷键）
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

-- 本地玩家引用（可能一开始为 nil）
local localPlayer = Players.LocalPlayer

-- 本地化常用函数和常量（性能）
local string_lower = string.lower
local string_find = string.find
local table_insert = table.insert
local table_remove = table.remove
local table_clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end
local tonumber = tonumber
local pcall = pcall
local tick = tick
local task_delay = task.delay
local task_spawn = task.spawn
local task_wait = task.wait
local math_min = math.min
local math_max = math.max

-- 运行参数
local FRAME_BUDGET_MS = 4  -- 每帧最大处理时间 (ms)
local WATCHDOG_INTERVAL = 15 -- 看门狗间隔（秒）

-- 预编译类/关键词集合（O(1)查找）
local SCREEN_EFFECTS_CLASSES = {
    ColorCorrectionEffect = true,
    BloomEffect = true,
    BlurEffect = true,
    SunRaysEffect = true,
    DepthOfFieldEffect = true,
}

local INFECTION_SCREEN_GUI_NAMES = {
    infectioneffect = true,
    infectionscreen = true,
    viruseffect = true,
    bloodeffect = true,
    redfilter = true,
    damageeffect = true,
    poisoneffect = true,
    screenfilter = true,
    infection = true,
    virus = true,
    blood = true,
    filter = true,
    effect = true,
    poison = true,
    damage = true,
    red = true
}

local KEYWORD_CHECKS = {
    infection = true,
    virus = true,
    blood = true,
    filter = true,
    effect = true,
    poison = true,
    damage = true,
    red = true
}

local RED_COLOR_THRESHOLD = {
    R_MIN = 0.9,
    G_MAX = 0.2,
    B_MAX = 0.2
}

-- 任务队列与调度
local pendingTasks = {}
local isProcessing = false

local function scheduleTask(fn, priority)
    if priority then
        table_insert(pendingTasks, 1, fn)
    else
        table_insert(pendingTasks, fn)
    end

    if not isProcessing then
        isProcessing = true
        task_spawn(function()
            -- 持续在帧间迭代处理，直到任务队列清空
            while #pendingTasks > 0 do
                local startTime = tick()
                -- 在单次循环中消费尽量多的任务但受帧预算限制
                while #pendingTasks > 0 and (tick() - startTime) * 1000 < FRAME_BUDGET_MS do
                    local taskFn = table_remove(pendingTasks, 1)
                    if taskFn then
                        local ok, err = pcall(taskFn)
                        if not ok then
                            warn("任务执行失败:", err)
                        end
                    end
                end
                -- 若仍有任务，短暂让出，下一循环继续（防止阻塞）
                if #pendingTasks > 0 then
                    task_wait() -- 等待下一个调度周期（下一帧）
                end
            end
            isProcessing = false
        end)
    end
end

-- 简化安全 pcall
local function safeCall(fn, ...)
    return pcall(fn, ...)
end

-- 名称/关键词快速判断
local function isInfectionNamed(name)
    if not name then return false end
    local nl = string_lower(name)
    if INFECTION_SCREEN_GUI_NAMES[nl] then
        return true
    end
    for kw in pairs(KEYWORD_CHECKS) do
        if string_find(nl, kw, 1, true) then
            return true
        end
    end
    return false
end

-- 快速全屏红色滤镜判断（优先使用 Scale）
local function isLikelyFullScreenRed(frame)
    if not frame or frame.ClassName ~= "Frame" then return false end

    local s = frame.Size
    if s then
        local xScale = (s.X and s.X.Scale) or 0
        local yScale = (s.Y and s.Y.Scale) or 0
        if xScale >= 0.95 and yScale >= 0.95 then
            local bg = frame.BackgroundColor3
            if bg and bg.R > RED_COLOR_THRESHOLD.R_MIN and bg.G < RED_COLOR_THRESHOLD.G_MAX and bg.B < RED_COLOR_THRESHOLD.B_MAX then
                return true
            end
        end
    end

    -- 作为回退：如果 AbsoluteSize 明显很大且颜色满足阈值
    local absSize = frame.AbsoluteSize
    if absSize and (absSize.X > 400 or absSize.Y > 300) then
        local bg = frame.BackgroundColor3
        if bg and bg.R > RED_COLOR_THRESHOLD.R_MIN and bg.G < RED_COLOR_THRESHOLD.G_MAX and bg.B < RED_COLOR_THRESHOLD.B_MAX then
            return true
        end
    end

    return false
end

-- Lighting 清理（批量、安全）
local function clearLightingEffects()
    scheduleTask(function()
        local children = Lighting:GetChildren()
        for i = 1, #children do
            local child = children[i]
            if child and SCREEN_EFFECTS_CLASSES[child.ClassName] then
                safeCall(function() child:Destroy() end)
            end
        end
    end, true)
end

-- 处理单个 PlayerGui 子项（延迟调度以减少主线程消耗）
local function processPlayerGuiChild(child)
    scheduleTask(function()
        if not child or not child.Parent then return end
        if not child:IsA("ScreenGui") then return end

        if isInfectionNamed(child.Name) then
            safeCall(function() child:Destroy() end)
            return
        end

        -- 仅检查第一层子对象，避免深递归
        local children = child:GetChildren()
        local limit = math_min(#children, 20)
        for i = 1, limit do
            local sub = children[i]
            if sub and sub:IsA("Frame") and isLikelyFullScreenRed(sub) then
                safeCall(function() child:Destroy() end)
                return
            end
        end
    end)
end

-- 处理 workspace 的单个 GUI（SurfaceGui / BillboardGui）
local function processWorkspaceGui(inst)
    if not inst or not inst.Parent then return end
    local className = inst.ClassName
    if className ~= "SurfaceGui" and className ~= "BillboardGui" then return end

    if isInfectionNamed(inst.Name) then
        scheduleTask(function()
            if inst and inst.Parent then
                safeCall(function() inst:Destroy() end)
            end
        end)
    end
end

-- 分帧初始扫描 workspace（避免短时间卡顿）
local function initialWorkspaceScan()
    scheduleTask(function()
        local all = Workspace:GetDescendants()
        local total = #all
        if total == 0 then return end

        local batchSize = 50
        local i = 1
        while i <= total do
            local endIdx = math_min(i + batchSize - 1, total)
            for j = i, endIdx do
                local obj = all[j]
                if obj then
                    local cls = obj.ClassName
                    if cls == "SurfaceGui" or cls == "BillboardGui" then
                        if isInfectionNamed(obj.Name) then
                            safeCall(function() obj:Destroy() end)
                        end
                    end
                end
            end
            i = endIdx + 1
            -- 让出帧以控制负载
            task_wait()
        end
    end)
end

-- PlayerGui 初次扫描（只检查顶层 ScreenGui）
local function scanPlayerGuiOnce()
    scheduleTask(function()
        local pg = localPlayer and localPlayer:FindFirstChild("PlayerGui")
        if not pg then return end
        local children = pg:GetChildren()
        for i = 1, #children do
            processPlayerGuiChild(children[i])
        end
    end)
end

-- 对新增 workspace descendant 的响应
local function onWorkspaceDescendantAdded(desc)
    scheduleTask(function() processWorkspaceGui(desc) end)
end

-- 对 PlayerGui ChildAdded 的响应（短延迟以保证属性可读）
local function onPlayerGuiChildAdded(child)
    task_delay(0.03, function() processPlayerGuiChild(child) end)
end

-- 对 Lighting ChildAdded 的响应（立刻销毁可疑后处理）
local function onLightingChildAdded(child)
    scheduleTask(function()
        if child and SCREEN_EFFECTS_CLASSES[child.ClassName] then
            safeCall(function() child:Destroy() end)
        end
    end, true)
end

-- 对外接口清理方法（保留原 API）
local function clearScreenGuiEffects()
    scheduleTask(function()
        local pg = localPlayer and localPlayer:FindFirstChild("PlayerGui")
        if not pg then return end
        local children = pg:GetChildren()
        for i = 1, #children do
            local child = children[i]
            if child and child:IsA("ScreenGui") and isInfectionNamed(child.Name) then
                safeCall(function() child:Destroy() end)
            end
        end
    end)
end

local function clearSurfaceGuiEffects()
    initialWorkspaceScan()
end

local function clearAllScreenEffects()
    -- print("开始高性能屏幕效果清理（无快捷键）...")
    -- 串行调度以减少并发竞争
    scheduleTask(clearLightingEffects, true)
    scheduleTask(clearScreenGuiEffects)
    scheduleTask(clearSurfaceGuiEffects)
    -- print("屏幕效果清理调度已提交。")
    return true
end

-- 初始化（连接事件，执行初始分帧扫描）
local function initialize()
    -- 等待 LocalPlayer 可用
    local start = tick()
    while not localPlayer do
        localPlayer = Players.LocalPlayer
        if localPlayer then break end
        -- 如果卡在这里过久，也不会阻塞主线程
        if tick() - start > 10 then
            -- 仍然尝试继续初始化（防止无限等待）
            break
        end
        task_wait(0.1)
    end

    -- 若可获取 PlayerGui，连接监听并做初次扫描
    local pg = localPlayer and localPlayer:FindFirstChild("PlayerGui")
    if pg then
        pg.ChildAdded:Connect(onPlayerGuiChildAdded)
        -- 初始扫描 PlayerGui 顶层
        scanPlayerGuiOnce()
    else
        -- 若一时没得到 PG，安排后续重试
        task_delay(3, function()
            local pg2 = localPlayer and localPlayer:FindFirstChild("PlayerGui")
            if pg2 then
                pg2.ChildAdded:Connect(onPlayerGuiChildAdded)
                scanPlayerGuiOnce()
            end
        end)
    end

    -- 连接 Workspace 与 Lighting 事件
    Workspace.DescendantAdded:Connect(onWorkspaceDescendantAdded)
    Lighting.ChildAdded:Connect(onLightingChildAdded)

    -- 提交初始清理任务（分帧）
    scheduleTask(clearLightingEffects, true)
    scheduleTask(initialWorkspaceScan)

    -- 轻量看门狗（仅保持低频 Lighting 清理）
    task_spawn(function()
        local last = 0
        while true do
            task_wait(WATCHDOG_INTERVAL)
            local now = tick()
            if now - last >= WATCHDOG_INTERVAL then
                scheduleTask(clearLightingEffects)
                last = now
            end
        end
    end)

    -- print("高性能屏幕效果清理器已激活（F5 已移除）。")
end

-- 启动并回退策略
local ok, err = pcall(initialize)
if not ok then
    warn("初始化失败，启用最小化回退:", err)
    scheduleTask(clearLightingEffects)
end

-- 导出接口
return {
    ClearAll = clearAllScreenEffects,
    ClearLightingEffects = clearLightingEffects,
    ClearScreenGuiEffects = clearScreenGuiEffects,
    ClearSurfaceGuiEffects = clearSurfaceGuiEffects
}