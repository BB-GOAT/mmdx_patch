if BBGOAT_FN.Clear_AQ_RPC_Hander then return end
function BBGOAT_FN.Clear_AQ_RPC_Hander(player)
    if not (player and player:IsValid()) then return end

    local state = player._aq_rpc_guard_state or {}
    player._aq_rpc_guard_state = state

    if state.task then return end
    local getval = BBGOAT_FN.getval
    -- 延迟执行并捕获 player；不能在 RPC 遍历期间改队列。
    state.task = player:DoTaskInTime(0, function()
        state.task = nil
        if not player:IsValid() or player._aq_rpc_guard_state ~= state then return end

        local queue = getval(HandleRPCQueue, "RPC_Queue")
        local limiter = getval(HandleRPCQueue, "RPC_Queue_Limiter")
        local warned = getval(HandleRPCQueue, "RPC_Queue_Warned")
        local timeline = getval(HandleRPCQueue, "RPC_Timeline")
        local handlers = getval(HandleRPC, "RPC_HANDLERS")
        if type(queue) ~= "table" or type(limiter) ~= "table"
            or type(warned) ~= "table" or type(timeline) ~= "table"
            or type(handlers) ~= "table" or getval(HandleRPC, "RPC_Queue") ~= queue then
            local now = GetTimeRealSeconds()
            if not state.last_warning or now - state.last_warning >= 30 then
                state.last_warning = now
                print("[AQ RPC guard] RPC functions were changed; queue untouched, will retry.")
            end
            return
        end

        local work_handlers = {}
        for _, name in ipairs({
            "LeftClick", "RightClick", "ActionButton", "ControllerActionButton",
            "ControllerAltActionButton", "ControllerActionButtonDeploy",
            "DropItemFromInvTile",
        }) do
            local fn = handlers[RPC[name]]
            if fn ~= nil then work_handlers[fn] = true end
        end
        local userid = player.userid
        local function IsWork(entry)
            local sender = entry[2]
            return work_handlers[entry[1]] and
                (sender == player or sender == userid or
                    (type(sender) == "table" and sender.userid == userid))
        end

        local pending = 0
        for i = 1, #queue do
            if IsWork(queue[i]) then pending = pending + 1 end
        end
        if pending < 12 then return end

        local now = GetTimeRealSeconds()
        if state.last_clear and now - state.last_clear < 1 then return end

        local total, kept, removed = #queue, 0, 0
        local removed_by_sender = {}
        for i = 1, total do
            local entry = queue[i]
            if removed < pending - 2 and IsWork(entry) then
                local sender = entry[2]
                removed_by_sender[sender] = (removed_by_sender[sender] or 0) + 1
                removed = removed + 1
            else
                kept = kept + 1
                queue[kept] = entry
            end
        end
        for i = kept + 1, total do queue[i] = nil end

        for sender, count in pairs(removed_by_sender) do
            if limiter[sender] ~= nil then
                local remaining = limiter[sender] - count
                limiter[sender] = remaining > 0 and remaining or nil
            end
            if limiter[sender] == nil then warned[sender] = nil end
            timeline[sender] = nil
        end
        state.last_clear = now
        print(string.format("[AQ RPC guard] user=%s, pending=%d, removed=%d, queue_remaining=%d", player.name, pending, removed, kept))
    end)
end