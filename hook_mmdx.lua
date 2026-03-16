-- hook “萌萌的新”的模组

-- 记忆力模组修改
AddGamePostInit(function()
    if not rawget(_G, "GetContainer_mmdxdata") then return end

    local Memory = Upvaluehelper.GetUpvalue(_G.GetContainer_mmdxdata, "Memory")
    local bancontainers = Upvaluehelper.GetUpvalue(Memory.GetContainer_mmdxdata, "bancontainers")
    if not Memory then MOD_util:Warning("记忆力模组的Memory获取失败") return end

    --------------------------------------------------- 更新禁止记录信息的容器 ---------------------------------------------------

    bancontainers.cookpot = true -- 烹饪锅
    bancontainers.dragonflyfurnace = true -- 龙鳞火炉

    local old_CheckShowmeAndInsight = Memory.CheckShowmeAndInsight
    Memory.CheckShowmeAndInsight = function(self, inst, prefab, ...)
        if not bancontainers[inst.prefab] then
            return old_CheckShowmeAndInsight(self, inst, prefab, ...)
        end
    end
    ---------------------------------------------------------------------------------------------------------------------------------------------------------

    -- 检测是否开启Show Me 或 Insight
    local enabled_showme_or_insight = _G.KnownModIndex:IsModEnabledAny("workshop-2189004162") or _G.KnownModIndex:IsModEnabledAny("workshop-2287303119") or _G.KnownModIndex:IsModEnabledAny("workshop-666155465")

    --------------------------------------------------- 高亮显示功能防冲突 ---------------------------------------------------

    if enabled_showme_or_insight and Memory.HighlightBox then
        Memory.HighlightBox = function() end
    end

    --------------------------------------------------- 删除模组快捷键，后面换成我的版本 ---------------------------------------------------

    local event = TheInput.onkeyup.events[KEY_R] -- R键开关命名功能
    for k in pairs(event) do
        local data = debug.getinfo(k.fn, "S")
        if string.match(data.source, "mods/workshop%-3144028272/modmain.lua") then
            Upvaluehelper.SetUpvalue(k.fn, true, "open") -- 启用命名功能
            k.processor:RemoveHandler(k) -- 删除R键开关命名功能
        end
    end

    -- 将Alt+左键命名物品功能 改为 Ctrl+Alt+左键 才能命名
    local mouse_events = TheInput.onmousebutton.events["onmousebutton"] -- 获取所有鼠标事件
    local funct -- 原按下快捷键执行的函数
    for k in pairs(mouse_events) do
        local data = debug.getinfo(k.fn, "S")
        if string.match(data.source, "mods/workshop%-3144028272/modmain.lua") then
            local _funct = Upvaluehelper.GetUpvalue(k.fn, "funct")
            if _funct then -- 通过判断是否有这个上值来区分是否为命名物品功能
                funct = _funct
                k.processor:RemoveHandler(k) -- 删除Alt键+左键命名物品功能
            else -- 还有另一个是中键收纳功能
                local fn_linedefined = debug.getinfo(k.fn).linedefined
                if fn_linedefined > 970 and fn_linedefined < 1000 then -- 中键收纳当前定义在第985行
                    k.processor:RemoveHandler(k) -- 也是先删除后面自己加新的
                end
            end
        end
    end

    --------------------------------------------------- 添加我制作的新的快捷键 ---------------------------------------------------

    -- Ctrl+Alt+左键命名物品
    local keys = {KEY_LALT, KEY_LCTRL}
    TheInput:AddMouseButtonHandler(function(button, down, x, y)
        if not down then return end

        for _, v in pairs(keys) do
            if not TheInput:IsKeyDown(v) then
                return
            end
        end

        if button == MOUSEBUTTON_LEFT then
            funct()
        end
    end)

    -- 可靠的中键收纳
    TheInput:AddMouseButtonHandler(function(button, down, x, y)
        if not down then return false end
        if button == MOUSEBUTTON_MIDDLE and not TheInput:IsKeyDown(KEY_LALT) and not TheInput:IsKeyDown(KEY_LCTRL) and not TheInput:IsKeyDown(KEY_LSHIFT) then
            local target = TheInput:GetHUDEntityUnderMouse()
            local item = target and target.widget ~= nil and target.widget.parent ~= nil and target.widget.parent.item
            if item then
                local aimbox = FindEntity(ThePlayer, 30, function(inst)
                    if not inst:HasTag('_container') and not Memory.specialcon[inst.prefab] then return false end

                    if not Memory:CanPutin(inst, item) then return end -- 检查是否可以放入

                    local data = Memory:GetContainer_mmdxdata(inst)
                    data = data and data.containerdata
                    if data then
                        -- 原始写法，不会遍历箱子的每个格子导致中键有时不好用
                        -- local itemdata = Memory:Findindata(data, item.prefab)
                        -- if itemdata then --选择有这个物品的箱子
                        --     if not data.full then
                        --         return true
                        --     elseif data.full then
                        --         if itemdata.isfull ~= true then
                        --             return true
                        --         end
                        --     end
                        -- end
                        for k,v in pairs(data) do
                            if type(v) == 'table' and v.prefab == item.prefab then
                                if not data.full then
                                    return true
                                elseif data.full then
                                    if v.isfull ~= true then
                                        return true
                                    end
                                end
                            end
                        end
                    else
                        return Memory:CheckShowmeAndInsight(inst, item.prefab) -- 兼容Show Me 和 Insight
                    end
                end)

                if aimbox then
                    local buffaction = BufferedAction(ThePlayer, aimbox, ACTIONS.STORE)
                    ThePlayer.components.playercontroller:RemoteControllerUseItemOnSceneFromInvTile(buffaction, item) -- 作为服务器时这个函数无效
                elseif MOD_RPC["FINDER_REDUX"] and MOD_RPC["FINDER_REDUX"]["FIND"] then -- 兼容高亮查找 - Finder
                    SendModRPCToServer(MOD_RPC["FINDER_REDUX"]["FIND"], item.prefab)
                    ThePlayer:DoTaskInTime(0.1, function()
                        local FINDER_REDUX_HIGHLIGHT_id = table.typecheckedgetfield(CLIENT_MOD_RPC, "number", "FINDER_REDUX", "HIGHLIGHT", "id")
                        if FINDER_REDUX_HIGHLIGHT_id then
                            local HIGHLITED_ENTS = Upvaluehelper.GetUpvalue(CLIENT_MOD_RPC_HANDLERS["FINDER_REDUX"][FINDER_REDUX_HIGHLIGHT_id], "HIGHLITED_ENTS")
                            local aimbox = HIGHLITED_ENTS and HIGHLITED_ENTS[1]
                            if aimbox then
                                local buffaction = BufferedAction(ThePlayer, aimbox, ACTIONS.STORE)
                                ThePlayer.components.playercontroller:RemoteControllerUseItemOnSceneFromInvTile(buffaction, item) -- 作为服务器时这个函数无效
                            end
                        end
                    end)
                end
            end
        end
    end)

    --------------------------------------------------- 禁用打包带信息记录 ---------------------------------------------------

    -- 获取模组信息内的PrefabPostInit
    local PrefabPostInit_bundle_container = Upvaluehelper.Getmoddata("workshop-3144028272", "PrefabPostInit", "bundle_container")
    local PrefabPostInit_gift = Upvaluehelper.Getmoddata("workshop-3144028272", "PrefabPostInit", "gift")
    local PrefabPostInit_bundle = Upvaluehelper.Getmoddata("workshop-3144028272", "PrefabPostInit", "bundle")

    -- 删全局环境的PrefabPostInit
    local modprefabinitfns = Upvaluehelper.GetUpvalue(SpawnPrefabFromSim,"modprefabinitfns")
    local function Remove_PrefabPostInit(name, fns)
        if not fns then return end

        local postinit = modprefabinitfns[name]
        if not postinit then return end

        for i,v in pairs(postinit) do
            local origin_fn = Upvaluehelper.GetUpvalue(v, "fn")
            if origin_fn == fns[1] then
                modprefabinitfns[name][i] = nil
            end
        end
    end

    Remove_PrefabPostInit("bundle_container", PrefabPostInit_bundle_container)
    Remove_PrefabPostInit("gift", PrefabPostInit_gift)
    Remove_PrefabPostInit("bundle", PrefabPostInit_bundle)
end)


-- 禁用调试参数打印
AddGamePostInit(function()
    local key_list = {}
    table.insert(key_list, TheInput.onkeydown.events[KEY_LEFT])
    table.insert(key_list, TheInput.onkeydown.events[KEY_RIGHT])
    for _,v in pairs (key_list) do
        for k in pairs (v) do
            local data = debug.getinfo(k.fn, "S")
            if string.match(data.source, "scripts/utils/utils.lua") or string.match(data.source, "m_utils/m_utils.lua") then
                k.processor:RemoveHandler(k)
            end
        end
    end
end)

-- 修改“点击切装备”模组，按住Ctrl、Alt时禁用其功能，对准部分物品时也禁用其功能
AddGamePostInit(function()
    local env = ModManager:GetMod("workshop-3135978089") and ModManager:GetMod("workshop-3135978089").env
    if not env then return end

    local ComponentPostInits = env.postinitfns.ComponentPostInit
    local fn = (ComponentPostInits.playeractionpicker[1])
    if not fn then return end

    local selectwork = Upvaluehelper.GetUpvalue(fn, "selectwork")
    if not selectwork then return end

    local black_prefab = {
        ["treasurechest"] = true, -- 箱子
        ["dragonflychest"] = true, -- 龙鳞宝箱
        ["phonograph"] = true, -- 留声机
        ["firesuppressor"] = true, -- 雪球机
        ["winona_catapult"] = true, -- 投石机
    }
    local old_selectwork = selectwork
    selectwork = function(ent, ...)
        local EntityUnderMouse = TheInput:GetWorldEntityUnderMouse()
        if EntityUnderMouse and EntityUnderMouse.prefab and black_prefab[EntityUnderMouse.prefab] then return end
        if --[[TheInput:IsKeyDown(KEY_LSHIFT) or]] TheInput:IsKeyDown(KEY_CTRL) or TheInput:IsKeyDown(KEY_ALT) then return end
        return old_selectwork(ent, ...)
    end
    Upvaluehelper.SetUpvalue(fn, selectwork, "selectwork")
end)

-- 修改“点击切装备”模组951行，获取动作的对象，不使用传入的target (BYD这个BUG是因为滚轮切换重叠物品模组)
-- if _G.KnownModIndex:IsModEnabledAny("workshop-3135978089") then
--     AddComponentPostInit("playeractionpicker", function(self, inst)
--         ThePlayer:DoTaskInTime(0, function()
--             local mod_old, up_i, up_fn = Upvaluehelper.FindUpvalue(self.DoGetMouseActions, "old", nil, nil, nil, "workshop%-3135978089/modmain.lua")
--             if mod_old then
--                 local my_old = function(self, position, target, spellbook, ...)
--                     local lmb, rmb = mod_old(self, position, target, spellbook, ...)
--                     Upvaluehelper.SetLocal(2, "target", nil)
--                     return lmb, rmb
--                 end
--                 debug.setupvalue(up_fn, up_i, my_old)
--             end
--         end)
--     end)
-- end

-- 修改“黑化排队论”模组
AddComponentPostInit("playercontroller", function(self, inst)
    if inst ~= ThePlayer then return end
    ThePlayer:DoTaskInTime(0, function()
        local ActionQueuer = Upvaluehelper.FindUpvalue(self.OnControl, "ActionQueuer", "/mods/workshop%-3136701076/modmain.lua") -- 尝试获取黑化排队论的ActionQueuer
        if not ActionQueuer then return end

        local env = ModManager:GetMod("workshop-3136701076").env
        local INV_util = env.INV_util
        local POS_util = env.POS_util
        local MOD_util = env.MOD_util
        local dont_controller_prefab = {
            ["luckysimulator"] = true -- 欧皇模拟器：老虎机
        }
        -- 修改行为学的SendControllerRPCSafely函数
        local old_SendControllerRPCSafely = ActionQueuer.SendControllerRPCSafely
        function ActionQueuer:SendControllerRPCSafely(actioncode, item, target, modname, ...)
            if dont_controller_prefab[target.prefab] then
                if INV_util:GetActiveItem() then
                    SendRPCToServer(RPC.LeftClick, actioncode, target:GetPosition().x,
                        target:GetPosition().z,
                        target, nil, nil, true, modname)
                else
                    POS_util:GoToPoint(target:GetPosition().x,
                        target:GetPosition().z)
                end
            else
                old_SendControllerRPCSafely(self, actioncode, item, target, modname, ...)
            end
        end

        local allowed_actions = Upvaluehelper.GetUpvalue(ActionQueuer.GetAction, "allowed_actions")
        if allowed_actions then
            -- 修改关于晾肉架的操作
            allowed_actions['STORE'].rpc = function(act)
                -- 晾肉架批量塞入优化
                if act.target and act.target.prefab and allowed_actions.RUMMAGE.meatrack_list[act.target.prefab] then
                    -- 一开始时使用STORE驱动走路（唯一能让玩家走过去的RPC）
                    if act.time == 0 then
                        act.self:SendControllerRPCSafely(ACTIONS.STORE.code, act.item, act.target)
                    end

                    local container = act.target.replica and act.target.replica.container
                    if container and container:IsOpenedBy(ThePlayer) then
                        -- 从物品栏塞入
                        for k, v in pairs(ThePlayer.replica.inventory:GetItems() or {}) do
                            if v.prefab == act.item.prefab then
                                SendRPCToServer(RPC.MoveInvItemFromAllOfSlot, k, act.target)
                            end
                        end

                        -- 从背包塞入
                        for con in pairs(ThePlayer.replica.inventory:GetOpenContainers() or {}) do
                            if con and con.replica and con.replica.container and con ~= act.target then
                                for k, v in pairs(con.replica.container:GetItems()) do
                                    if v.prefab == act.item.prefab then
                                        SendRPCToServer(RPC.MoveItemFromAllOfSlot, k, con, act.target)
                                    end
                                end
                            end
                        end
                    end
                else
                    -- 非晾肉架：原逻辑
                    act.self:SendControllerRPCSafely(ACTIONS.STORE.code, act.item, act.target)
                    if not act.self:CanSeeTarget(act.target) then
                        for i = 1, 10 do
                            SendRPCToServer(RPC.MoveItemFromAllOfSlot, i, act.target)
                        end
                    end
                end
            end
            allowed_actions['STORE'].controllertable = {
                needreturnactiveitem = function(act)
                    -- 晒肉时将鼠标上的物品放回物品栏
                    return act.item and act.item:HasTag("dryable") and
                            act.target and act.target.prefab and allowed_actions.RUMMAGE.meatrack_list[act.target.prefab]
                end,
            }
            allowed_actions['STORE'].addtimefn = function(act)
                return act.target and act.target.replica and act.target.replica.container and
                    -- 想要晒肉时直接addtime，确保SendControllerRPCSafely只运行一次
                    (allowed_actions.RUMMAGE.meatrack_list[act.target.prefab] or act.target.replica.container:IsOpenedBy(act.self.inst))
            end

            allowed_actions['RUMMAGE'].reselectfn = function(act)
                if act.target and act.target.prefab and allowed_actions.RUMMAGE.meatrack_list[act.target.prefab] then
                    local num = act.target.replica.container and act.target.replica.container:GetNumSlots() or 3
                    for i = 1, num do
                        SendRPCToServer(RPC.MoveItemFromAllOfSlot, i, act.target)
                    end
                    -- 如果是晾肉巨架且里面有盐晶，这段代码就会生效
                    MOD_util:DoTaskInTime(0.2, function()
                        if act and act.target and act.target.replica and act.target.replica.container and #act.target.replica.container:GetItems() ~= 0 then
                            for i = 1, num do
                                SendRPCToServer(RPC.MoveItemFromAllOfSlot, i, act.target)
                            end
                        end
                    end)
                end
            end
        end
    end)
end)