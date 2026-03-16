if not _G.KnownModIndex:IsModEnabledAny("workshop-2111412487") or not _G.KnownModIndex:IsModEnabledAny("workshop-3136701076") then return end -- 检查对应模组是否开启

AddComponentPostInit("playercontroller", function(self, inst)
    if inst ~= ThePlayer then return end
    ThePlayer:DoTaskInTime(0, function()
        local ActionQueuer = Upvaluehelper.FindUpvalue(self.OnControl, "ActionQueuer", "/mods/workshop%-3136701076/modmain.lua") -- 尝试获取黑化排队论的ActionQueuer

        if ActionQueuer then
            -- Lazy Controls 自动给瓦格斯塔夫工具兼容黑化排队论
            local wagstaff_tool_giver_key = _G.GetModConfigData("wagstaff_tool_giver", "workshop-2111412487") -- 获取给瓦格斯塔夫工具的快捷键
            wagstaff_tool_giver_key = rawget(_G, wagstaff_tool_giver_key)
            if wagstaff_tool_giver_key then
                local event = TheInput.onkeydown.events[wagstaff_tool_giver_key]
                for k in pairs(event) do
                    local data = debug.getinfo(k.fn, "S")
                    if string.match(data.source, "mods/workshop%-2111412487/main/util.lua") then
                        local func = Upvaluehelper.GetUpvalue(k.fn, "func")
                        if func and string.match(debug.getinfo(func).source or "", "wagstaff_tool_giver.lua") then
                            local function GetHandsEquip() -- 获取手部装备的物品
                                return ThePlayer and
                                ThePlayer.replica.inventory and
                                EQUIPSLOTS.HANDS and
                                ThePlayer.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
                            end

                            local new_func = function()
                                local working_thread = Upvaluehelper.GetUpvalue(func, "working_thread")
                                local WAGSTAFF_RANGE = Upvaluehelper.GetUpvalue(func, "WAGSTAFF_RANGE")
                                local find_wagstaff = Upvaluehelper.GetUpvalue(func, "find_wagstaff")
                                local target_mark = Upvaluehelper.GetUpvalue(func, "target_mark")
                                local GetTool = Upvaluehelper.GetUpvalue(func, "GetTool")
                                local Util = Upvaluehelper.GetUpvalue(func, "Util")
                                local SLEEP_TIME = Upvaluehelper.GetUpvalue(func, "SLEEP_TIME")
                                local Stop = Upvaluehelper.GetUpvalue(func, "Stop")

                                Upvaluehelper.SetUpvalue(GetTool, ActionQueuer, "ActionQueuer")
                                ---------------------------------
                                if working_thread then return end

                                if not ActionQueuer then MOD_util:Warning("Wagstaff Tool Giver needs ActionQueuer to work!") return end

                                local wagstaff = FindEntity(ThePlayer, WAGSTAFF_RANGE, find_wagstaff) -- 找瓦格斯塔夫
                                local moonstorm_static_roamer = FindEntity(ThePlayer, WAGSTAFF_RANGE, function(inst) return inst.prefab == "moonstorm_static_roamer" end) -- 找未约束的静电
                                local moonstorm_static_nowag = FindEntity(ThePlayer, WAGSTAFF_RANGE, function(inst) return inst.prefab == "moonstorm_static_nowag" end) -- 找约束静电
                                if wagstaff then -- 查找瓦格斯塔夫
                                    if not wagstaff.tool_wanted and not wagstaff.AnimState:IsCurrentAnimation("build_loop") then
                                        ActionQueuer:SendAction(BufferedAction(ThePlayer, wagstaff, ACTIONS.WALKTO, nil, wagstaff:GetPosition()))
                                        return
                                    end

                                    target_mark = wagstaff:SpawnChild("reticule")

                                    working_thread = ThePlayer:StartThread(function()
                                        while ThePlayer:IsValid() and wagstaff:IsValid() do
                                            if wagstaff.tool_wanted and not wagstaff.AnimState:IsCurrentAnimation("build_loop") then
                                                local tool = GetTool(wagstaff.tool_wanted, wagstaff)
                                                if tool then
                                                    Util.UseItemOnScene(tool, BufferedAction(ThePlayer, wagstaff, ACTIONS.GIVE, tool))
                                                end
                                            end
                                            Sleep(SLEEP_TIME)
                                        end
                                        Stop()
                                    end)
                                elseif moonstorm_static_nowag then -- 直接做约束静电任务（无瓦格斯塔夫）
                                    target_mark = moonstorm_static_nowag:SpawnChild("reticule") -- 底部生成一个标记说明模组生效

                                    local tools =
                                    {
                                        "wagstaff_tool_1",
                                        "wagstaff_tool_2",
                                        "wagstaff_tool_3",
                                        "wagstaff_tool_4",
                                        "wagstaff_tool_5",
                                    }

                                    working_thread = ThePlayer:StartThread(function()
                                        local need_go = true -- 是否需要靠近约束静电
                                        while ThePlayer:IsValid() and moonstorm_static_nowag:IsValid() do
                                            if moonstorm_static_nowag.AnimState:IsCurrentAnimation("needtool_idle") then
                                                local tool
                                                -- 先从身上找所有可用的工具
                                                for _,v in ipairs(tools) do
                                                    tool = Util.GetItemFromContainers(nil, v, nil, function(inst, prefab) return inst.prefab == prefab end)
                                                    if tool then
                                                        Util.UseItemOnScene(tool, BufferedAction(ThePlayer, moonstorm_static_nowag, ACTIONS.GIVE, tool))
                                                        break
                                                    end
                                                end
                                                -- 身上没有再去地上找
                                                if not tool then
                                                    for _,v in ipairs(tools) do
                                                        tool = GetTool(v, moonstorm_static_nowag)
                                                        if tool then
                                                            Util.UseItemOnScene(tool, BufferedAction(ThePlayer, moonstorm_static_nowag, ACTIONS.GIVE, tool))
                                                            break
                                                        end
                                                    end
                                                end
                                            else -- 约束静电不需要材料时，收集地面物品
                                                -- 有工具捡工具，没工具贴近约束静电
                                                local target
                                                for _,v in ipairs(tools) do
                                                    target = FindEntity(moonstorm_static_nowag, 10, function(inst) return inst.prefab == v end, nil, {"INLIMBO"})
                                                    if target then -- 搜索到地面的目标，开始拾取
                                                        ActionQueuer:SendActionAndWait(BufferedAction(ThePlayer, target, ACTIONS.PICKUP), false, target)
                                                        need_go = true
                                                        break
                                                    end
                                                end
                                                if not target and need_go then
                                                    need_go = false
                                                    ActionQueuer:SendAction(BufferedAction(ThePlayer, moonstorm_static_nowag, ACTIONS.WALKTO, nil, moonstorm_static_nowag:GetPosition()))
                                                end
                                            end
                                            Sleep(SLEEP_TIME)
                                        end
                                        Stop()
                                    end)
                                elseif moonstorm_static_roamer then -- 跟随/捕获未约束的静电
                                    target_mark = moonstorm_static_roamer:SpawnChild("reticule")
                                    working_thread = ThePlayer:StartThread(function()
                                        while ThePlayer:IsValid() and moonstorm_static_roamer:IsValid() do
                                            local tool = GetTool("moonstorm_static_catcher", moonstorm_static_roamer) -- 获取物品栏是否有静电约束仪
                                            local HandsEquip = GetHandsEquip() -- 获取手上装备的物品
                                            if tool and (HandsEquip and HandsEquip.prefab ~= "moonstorm_static_catcher") then
                                                -- 距离较远则可以穿戴加速物品(不根据黑化排队论模组设置决定，不然代码太多了)
                                                local speeditem = ActionQueuer:HasAddSpeedEquipment()
                                                if speeditem and math.sqrt(distsq(moonstorm_static_roamer:GetPosition(), ThePlayer:GetPosition())) > math.max((moonstorm_static_roamer:GetPhysicsRadius(0) or 0.5) + 2, 5) then
                                                    ActionQueuer:EquipItem(speeditem) -- 装备加速道具
                                                    -- 跟随未约束的静电
                                                    ActionQueuer:SendAction(BufferedAction(ThePlayer, moonstorm_static_roamer, ACTIONS.WALKTO, nil, moonstorm_static_roamer:GetPosition()))
                                                else
                                                    ActionQueuer:EquipItem(tool) -- 在静电附近，装备静电约束仪
                                                end
                                            else
                                                if HandsEquip and HandsEquip.prefab == "moonstorm_static_catcher" then -- 如果手上装备了静电约束仪，直接抓捕静电
                                                    SendRPCToServer(RPC.LeftClick, ACTIONS.DIVEGRAB.code, moonstorm_static_roamer:GetPosition().x,
                                                        moonstorm_static_roamer:GetPosition().z,
                                                        moonstorm_static_roamer, nil, nil, ACTIONS.DIVEGRAB.canforce, ACTIONS.DIVEGRAB.mod_name)
                                                else
                                                    local speeditem = ActionQueuer:HasAddSpeedEquipment()
                                                    ActionQueuer:EquipItem(speeditem) -- 装备加速道具
                                                    ActionQueuer:SendAction(BufferedAction(ThePlayer, moonstorm_static_roamer, ACTIONS.WALKTO, nil, moonstorm_static_roamer:GetPosition())) -- 跟随未约束的静电
                                                end
                                            end
                                            Sleep(SLEEP_TIME)
                                        end
                                        Stop()
                                    end)
                                end

                                Upvaluehelper.SetUpvalue(func, target_mark, "target_mark")
                                Upvaluehelper.SetUpvalue(func, working_thread, "working_thread")
                            end

                            Upvaluehelper.SetUpvalue(k.fn, new_func, "func")
                        end
                    end
                end
            end

            -- Lazy Controls兼容黑化排队论 一键选择周围实体
            local select_nearby_ents_key = _G.GetModConfigData("select_nearby_ents_key", "workshop-2111412487") -- 给排队论选择周围所有实体的键
            select_nearby_ents_key = rawget(_G, select_nearby_ents_key)
            if select_nearby_ents_key then
                local function has_component(target, cmp)
                    return target and target:HasActionComponent(cmp)
                end
                local unselectable_tags = { -- 排除的标签
                    "DECOR", "FX", "INLIMBO", "NOCLICK", "player", -- RB3的
                    -- 后面是我自定义的
                    "_container", -- 容器
                    "heavy", -- 重物
                }
                local function IsValidEntity(ent) -- 黑化排队论没有定义这个
                    return ent and ent.Transform and ent:IsValid() and not ent:HasTag("INLIMBO")
                end

                ActionQueuer.SelectEntities = function(self, data, whitelist_mode)
                    local pos            = data.pos            or self.inst:GetPosition()
                    local range          = data.range          or self.double_click_range
                    local musttags       = data.musttags       or nil
                    local canttags       = data.canttags       or unselectable_tags
                    local mustoneoftags  = data.mustoneoftags  or nil
                    local test_fn        = data.test_fn        or nil
                    local action_test_fn = data.action_test_fn or nil
                    local is_right_list  = data.is_right_list  or { false }
                    local is_rightclick  = data.is_rightclick  or function(ent, is_right_list)
                        for _, rightclick in ipairs(is_right_list) do
                            local act, acttab = self:GetAction(ent, nil, rightclick) -- 黑化排队论修改了此处！返回的第二个结果是acttab而不是rightclick
                            if act and (action_test_fn == nil or action_test_fn(ent, act)) then
                                return rightclick, act -- 此处多返回一个act给下面用
                            end
                        end
                    end

                    local whitelist_mode_prefab = { -- 白名单模式，允许的Prefab
                        ["alterguardianhat"] = true, -- 启迪之冠，别想跟我抢！
                        ["lunar_seed"] = true, -- 天体珠宝
                        ["meatrack"] = true, -- 晾肉架（为了放肉进去）
                    }
                    local black_action_id = { -- 排除的动作
                        ["ATTACK"] = true, -- 攻击
                    }
                    local selected = {}
                    if not whitelist_mode then -- 正常模式
                        for _, ent in ipairs(TheSim:FindEntities(pos.x, 0, pos.z, range, musttags, canttags, mustoneoftags)) do
                            if IsValidEntity(ent) and not self:IsSelectedEntity(ent) and (test_fn == nil or test_fn(ent)) then
                                local rightclick, act = is_rightclick(ent, is_right_list)
                                if rightclick ~= nil then
                                    if not black_action_id[act.action.id] then
                                        if act.action.id == "PICKUP" then rightclick = false end
                                        self:SelectEntity(ent, act.action.id, nil, nil, rightclick) -- 黑化排队论改了这个传的参数 原版：(ent, rightclick) 黑化排队论：(ent, actid, item, specialtag, rightclick)
                                        table.insert(selected, { ent = ent, right = rightclick })
                                    end
                                end
                            end
                        end
                    else -- 白名单模式
                        for _, ent in ipairs(TheSim:FindEntities(pos.x, 0, pos.z, range, musttags, nil, mustoneoftags)) do
                            if IsValidEntity(ent) and not self:IsSelectedEntity(ent) and (test_fn == nil or test_fn(ent)) then
                                local rightclick, act = is_rightclick(ent, is_right_list)
                                if rightclick ~= nil then
                                    if not black_action_id[act.action.id] and whitelist_mode_prefab[act.target.prefab] then
                                        if act.action.id == "PICKUP" then rightclick = false end
                                        self:SelectEntity(ent, act.action.id, nil, nil, rightclick) -- 黑化排队论改了这个传的参数 原版：(ent, rightclick) 黑化排队论：(ent, actid, item, specialtag, rightclick)
                                        table.insert(selected, { ent = ent, right = rightclick })
                                    end
                                end
                            end
                        end
                    end
                    return selected
                end

                ActionQueuer.SelectAllNearbyEnts = function(self, whitelist_mode) -- 取消了第二个参数force_endless_repeat，不兼容无尽重复模式。取而代之的是白名单模式
                    local data = {
                        range = self.double_click_range * 0.5,
                        action_test_fn = function(ent, act)
                            return act.action ~= ACTIONS.UNWRAP
                                and not (
                                    (ent.prefab == "firesuppressor" or has_component(ent, "inventoryitem"))
                                    and (act.action == ACTIONS.TURNON or act.action == ACTIONS.TURNOFF)
                                )
                        end,
                        is_right_list = { true, false },
                    }
                    self:SelectEntities(data, whitelist_mode)

                    if next(self.selected_ents) and not self.action_thread then
                        self:ApplyToSelection()
                    end
                end

                local function canactive()
                    if not GLOBAL.TheFrontEnd then return true end
                    if InGamePlay() and not GLOBAL.TheFrontEnd:GetActiveScreen():IsEditing() then
                        return true
                    end
                    return false
                end

                TheInput:AddKeyDownHandler(select_nearby_ents_key, function()
                    if not canactive() then return end
                    ActionQueuer:SelectAllNearbyEnts(TheInput:IsKeyDown(KEY_LSHIFT))
                end)
            end
        end
    end)
end)