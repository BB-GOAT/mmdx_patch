local CHECK_INTERVAL = 0.5
local FINISH_CHECK_TIME = 1.5
local CHECK_COMMAND = "BBGOAT_FN.Clear_AQ_RPC_Hander(ThePlayer)"
local INSTALL_COMMAND

function CreateRPCQueueGuard(queuer)
    local inst = queuer.inst
    local guard = { finish_until = 0 }

    function guard:Poll()
        local now = GetTimeRealSeconds()
        if not queuer.action_thread and now >= self.finish_until then return end
        if self.last_probe and now - self.last_probe < CHECK_INTERVAL then return end
        self.last_probe = now
        local command = CHECK_COMMAND
        if not self.registered then
            if not INSTALL_COMMAND then
                local file = assert(io.open(MODROOT .. "ActionQueuerPatch/aq_rpc_guard_cmd.lua", "r"), "无法加载文件 aq_rpc_guard_cmd.lua")
                INSTALL_COMMAND = file:read("*a") .. "\n" .. CHECK_COMMAND
                file:close()
            end
            command = INSTALL_COMMAND
        end
        BBGOAT_util:remote(command)
        self.registered = true
    end

    function guard:KeepAlive()
        self.finish_until = GetTimeRealSeconds() + FINISH_CHECK_TIME
        self:Poll()
    end

    guard.Finish = guard.KeepAlive

    guard.task = inst:DoPeriodicTask(CHECK_INTERVAL, function() guard:Poll() end, CHECK_INTERVAL)
    return guard
end