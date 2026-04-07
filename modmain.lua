GLOBAL.setmetatable(env, {
    __index = function(t, k)
        return GLOBAL.rawget(GLOBAL, k)
    end
})
_G = GLOBAL

-- local function Import(modulename)
-- 	local f = GLOBAL.kleiloadlua(modulename)
-- 	if f and type(f) == "function" then
--         GLOBAL.setfenv(f, env.env)
--         return f()
-- 	end
-- end

if not rawget(_G, "Chinese_Pro") then return end -- 必须加载Chinese++ Pro模组才能运行

Upvaluehelper = _G.Chinese_Pro.env.Upvaluehelper
MOD_util = _G.Chinese_Pro.env.MOD_util

modimport("hook_mmdx.lua") -- HOOK 萌萌的新的模组
modimport("hook_lazy_controls.lua") -- HOOK lazy_controls 模组