-- 仅接管南瓜 TOSS；沿用本体在执行期间关闭延迟补偿的约定。
-- 选择集表示拆除许可，覆盖次数表示已确认出手的预算；不等待逐颗爆炸。
local MARGIN = .45
-- 请求投点不是实际爆心：原版飞行按帧积分并在实际落地位置引爆，不能把边缘目标算作必定命中。
local COVER_MARGIN = .45
local CELL = 8
local POLL = FRAMES * 2
local MAX_PREVIEWS = 80
local FLIGHT_TIME = 1.2
-- 原版倒地碰撞半径 1，加上南瓜半径 .2；站立阶段也按倒地尺寸预留，避免在途炸弹遇到扩大的碰撞体。
local ROCK_COLLISION_RADIUS = 1.2
local CANT_TAGS = { "INLIMBO", "notarget", "FX", "DECOR", "CLASSIFIED" }
local PATH_CAPS = { ignorewalls = false, ignorecreep = true, allowocean = false }
local BUILDING_TAGS = { "structure", "wall", "fence", "wall_door", "furnituredecor" }
local GROUPS = {
    rock_trees = {
        "tree_rock1", "tree_rock2", "tree_rock1_short", "tree_rock1_normal",
        "tree_rock2_short", "tree_rock2_normal",
    },
    farm_plants = {},
}
local PLANTS = require("prefabs/farm_plant_defs").PLANT_DEFS
for _, def in pairs(PLANTS) do
    if def.prefab and not def.data_only then
        GROUPS.farm_plants[#GROUPS.farm_plants + 1] = def.prefab
    end
end
local GROUP_BY_PREFAB = {}
for group, prefabs in pairs(GROUPS) do
    for _, prefab in ipairs(prefabs) do GROUP_BY_PREFAB[prefab] = group end
end

local function Valid(ent)
    return ent and ent:IsValid()
end

local function DistanceSq(a, b)
    return (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2
end

local function SegmentDistanceSq(p, a, b)
    local dx, dz = b.x - a.x, b.z - a.z
    local length = dx * dx + dz * dz
    local t = length > 0 and math.clamp(((p.x - a.x) * dx + (p.z - a.z) * dz) / length, 0, 1) or 0
    return (p.x - a.x - t * dx) ^ 2 + (p.z - a.z - t * dz) ^ 2
end

local function Building(ent)
    return ent:HasTag("structure") or ent:HasTag("wall")
        or ent:HasTag("fence") or ent:HasTag("wall_door") or ent.prefab == "w_radio"
end

local function Stage(ent)
    local anim = ent.AnimState
    if anim then
        for _, size in ipairs({ "short", "normal", "tall", "small", "med" }) do
            for _, prefix in ipairs({ "idle_", "sway1_loop_", "sway2_loop_", "chop_", "hit_", "grow_" }) do
                if anim:IsCurrentAnimation(prefix .. size) then
                    return (size == "short" or size == "small") and "SMALL" or size == "tall" and "TALL" or "NORMAL"
                end
            end
        end
    end
    local prefab = ent.prefab or ""
    return prefab:find("_short$") and "SMALL" or prefab:find("_normal$") and "NORMAL" or "TALL"
end

-- 精确组件只在主机存在；客机按原版种类/阶段估算完整工作量，避免伪读 workleft。
local function Required(ent, clear_stumps, damage)
    local workable = ent.components and ent.components.workable
    local work = workable and workable:CanBeWorked() and workable:GetWorkLeft()
    local function Shots(value) return math.ceil((value or 1) / damage) end
    if ent:HasTag("stump") then return clear_stumps and Shots(work) or 0 end
    if GROUP_BY_PREFAB[ent.prefab] == "rock_trees" then
        if ent:HasTag("CHOP_workable") then
            return Shots(work or TUNING.TREE_ROCK.CHOP) + Shots(TUNING.TREE_ROCK.MINE)
        end
        local anim = ent.AnimState
        local reduced = anim and (anim:IsCurrentAnimation("fall_med_normal") or anim:IsCurrentAnimation("burnt_med_normal")
            or anim:IsCurrentAnimation("fall_low_normal") or anim:IsCurrentAnimation("burnt_low_normal"))
        return Shots(work or (reduced and 4 or TUNING.TREE_ROCK.MINE))
    end
    if ent:HasTag("CHOP_workable") then
        local prefab = ent.prefab or ""
        local prefix = prefab:find("deciduous") and "DECIDUOUS" or prefab:find("moon_tree") and "MOON_TREE"
            or prefab:find("palmcone") and "PALMCONETREE" or "EVERGREEN"
        local count = work or TUNING[prefix .. "_CHOPS_" .. Stage(ent)] or 15
        return Shots(count) + (clear_stumps and 1 or 0)
    end
    if ent:HasTag("DIG_workable") then return Shots(work) end
    if ent:HasTag("MINE_workable") then
        local prefab = ent.prefab or ""
        local anim = ent.AnimState
        local reduced = prefab:find("_low$") and TUNING.ROCKS_MINE_LOW
            or prefab:find("_med$") and TUNING.ROCKS_MINE_MED
            or anim and anim:IsCurrentAnimation("low") and TUNING.ROCKS_MINE_LOW
            or anim and anim:IsCurrentAnimation("med") and TUNING.ROCKS_MINE_MED
        return Shots(work or (prefab:find("petrified") and 4) or reduced or TUNING.ROCKS_MINE)
    end
    return Shots(work or 2)
end

return function(queuer)
    if queuer.smart_destruction then return queuer.smart_destruction end
    for _, name in ipairs({ "ApplyToSelection", "SendAction", "ClearActionThread", "SelectEntity", "DeselectEntity", "nullPick" }) do
        if type(queuer[name]) ~= "function" then
            MOD_util:Warning("智能南瓜拆除：排队论接口缺失 " .. name)
            return
        end
    end
    local inst = queuer.inst
    local smart = { revision = 0, markers = {}, pending = {} }
    local old_apply = queuer.ApplyToSelection
    local old_clear = queuer.ClearActionThread
    local old_select = queuer.SelectEntity
    local old_deselect = queuer.DeselectEntity
    local old_nullpick = queuer.nullPick
    local old_same = queuer.RegardAsSame

    local function Inventory() return inst.replica and inst.replica.inventory end
    local function Bomb()
        local inv = Inventory()
        if not inv then return end
        local active = inv:GetActiveItem()
        if active then return active.prefab == "pumpkin_bomb" and active or nil end
        local hands = inv:GetEquippedItem(EQUIPSLOTS.HANDS)
        return Valid(hands) and hands.prefab == "pumpkin_bomb" and hands or nil
    end

    local function CountBombs()
        local inv, count, seen = Inventory(), 0, {}
        local function Add(item)
            if Valid(item) and item.prefab == "pumpkin_bomb" and not seen[item] then
                seen[item] = true
                local stack = item.replica.stackable
                -- 排除 UI 的预扣预览值，确认依据使用已同步的实际数量。
                count = count + (stack and stack._stacksize and stack._stacksizeupper
                    and (stack._stacksizeupper:value() * 64 + stack._stacksize:value() + 1)
                    or stack and stack:StackSize() or 1)
            end
        end
        Add(inv:GetActiveItem())
        Add(inv:GetEquippedItem(EQUIPSLOTS.HANDS))
        for _, item in pairs(inv:GetItems()) do Add(item) end
        local overflow = inv:GetOverflowContainer()
        if overflow then for _, item in pairs(overflow:GetItems()) do Add(item) end end
        return count
    end

    local function IsTask(ent, data)
        return ent ~= queuer.posaction and data and data.id == "TOSS" and Valid(ent) and not ent:HasTag("INLIMBO")
            and (not data.item or data.item.prefab == "pumpkin_bomb")
    end

    local function Changed()
        if not smart.internal then
            smart.revision = smart.revision + 1
            smart.changed_at = GetTime()
        end
    end

    function queuer:SelectEntity(ent, id, ...)
        if not self.selected_ents[ent] then Changed() end
        return old_select(self, ent, id, ...)
    end

    function queuer:DeselectEntity(ent, ...)
        if self.selected_ents[ent] then Changed() end
        return old_deselect(self, ent, ...)
    end

    -- 同类只在本次南瓜双击扩选的调用栈内生效，避免影响存放、交易等其他调用。
    function queuer:RegardAsSame(a, b, ...)
        if smart.selecting then
            local pa, pb = type(a) == "table" and a.prefab or a, type(b) == "table" and b.prefab or b
            if GROUP_BY_PREFAB[pa] and GROUP_BY_PREFAB[pa] == GROUP_BY_PREFAB[pb] then return true end
        end
        if old_same then return old_same(self, a, b, ...) end
    end

    local function AfterSelection(...)
        smart.selecting = false
        return ...
    end

    function queuer:nullPick(x, y, z, rightclick, ...)
        smart.selecting = Bomb() and self.last_click and self.last_click.action == ACTIONS.TOSS and rightclick or false
        return AfterSelection(old_nullpick(self, x, y, z, rightclick, ...))
    end

    local function HideMarkers(remove)
        for _, marker in ipairs(smart.markers) do
            if marker:IsValid() then
                if remove then marker:Remove() else marker:Hide() end
            end
        end
        if remove then smart.markers = {} end
    end

    local function Marker(index, pos, current)
        local marker = smart.markers[index]
        if not marker then
            marker = CreateEntity()
            marker.entity:AddTransform()
            marker.entity:AddAnimState()
            marker.AnimState:SetBank("pumpkin_bomb")
            marker.AnimState:SetBuild("pumpkin_bomb")
            marker.AnimState:PlayAnimation("idle", true)
            marker.AnimState:SetLightOverride(.6)
            marker.persists = false
            marker._aq_preview_entity = true
            for _, tag in ipairs({ "FX", "DECOR", "NOCLICK", "NOBLOCK", "CLASSIFIED" }) do marker:AddTag(tag) end
            smart.markers[index] = marker
        end
        marker.Transform:SetPosition(pos.x, 0, pos.z)
        marker.AnimState:SetMultColour(current and 1 or .4, 1, .3, current and .8 or .4)
        marker:Show()
    end

    local function Paint(session, first)
        HideMarkers()
        local count = 0
        for i = first, #session.plan do
            local node = session.plan[i]
            if not node.skipped then
                count = count + 1
                Marker(count, node.pos, i == first)
                if count >= MAX_PREVIEWS then break end
            end
        end
    end

    function smart:Cancel()
        local session = self.session
        self.session = nil
        self.selecting = false
        if self.pathsearch then
            TheWorld.Pathfinder:KillSearch(self.pathsearch)
            self.pathsearch = nil
        end
        if session then
            -- 调用排队论自己的取消选中路径，恢复其 highlight 组件，而不是强行染成白色。
            self.internal = true
            for ent, data in pairs(queuer.selected_ents) do
                if IsTask(ent, data) then queuer:DeselectEntity(ent) end
            end
            self.internal = false
        end
        HideMarkers(true)
    end

    function queuer:ClearActionThread(...)
        smart:Cancel()
        return old_clear(self, ...)
    end
    inst:ListenForEvent("onremove", function() smart:Cancel() end)

    local function Pause(session, delay)
        Sleep(delay or POLL)
        return smart.session == session and inst:IsValid()
    end

    local function DropSelection(ent)
        smart.internal = true
        queuer:DeselectEntity(ent)
        smart.internal = false
    end

    local function Complete(session, record, skipped)
        record.remaining = 0
        if skipped then
            session.authorized[record.ent] = nil
            session.skipped = session.skipped + 1
            if inst.components.talker then
                inst.components.talker:Say("智能南瓜拆除：已跳过 " .. session.skipped .. " 个没有安全投点或站位的目标")
            end
        else
            session.completed[record.ent] = true
        end
        DropSelection(record.ent)
    end

    local function Remaining(node, session)
        local count = 0
        for _, record in ipairs(node.covered) do
            if record.remaining > 0 and (not Valid(record.ent) or not session.byent[record.ent]
                or record.ent:HasTag("stump") and queuer.autocollect <= 1) then
                Complete(session, record)
            end
            count = math.max(count, record.remaining)
        end
        node.empty = count == 0
        return count
    end

    local function RockFallRadius(ent)
        return (ent:HasTag("tree_rock1") and TUNING.TREE_ROCK.ROCK1_AOE_RADIUS
            or TUNING.TREE_ROCK.ROCK2_AOE_RADIUS) + inst:GetPhysicsRadius(.5) + MARGIN
    end

    local function Passable(pos)
        local map = TheWorld.Map
        return map:IsPassableAtPoint(pos.x, 0, pos.z) and not map:IsOceanAtPoint(pos.x, 0, pos.z)
            and not map:IsGroundTargetBlocked(Vector3(pos.x, 0, pos.z))
    end

    local function NearbyBuildings(session, pos, radius)
        local result = {}
        for _, ent in ipairs(TheSim:FindEntities(pos.x, 0, pos.z, radius, nil, CANT_TAGS, BUILDING_TAGS)) do
            if Building(ent) and not session.authorized[ent] then result[#result + 1] = ent:GetPosition() end
        end
        return result
    end

    local function SafePoint(session, pos, buildings)
        if not Passable(pos) then return false end
        for _, other in ipairs(buildings) do
            if DistanceSq(pos, other) <= session.protect_sq then return false end
        end
        return true
    end

    local function RefreshRocks(session, node, force)
        if not force and node.rocks and GetTime() - node.rock_scan < .5 then return end
        node.rocks, node.rock_entities, node.rock_scan = {}, {}, GetTime()
        -- 只查当前投点的最大投掷走廊；同一快照供所有候选站位复用。
        for _, ent in ipairs(TheSim:FindEntities(node.pos.x, 0, node.pos.z, 7.4 + ROCK_COLLISION_RADIUS,
            { "rock_tree" }, CANT_TAGS)) do
            if Valid(ent) then
                local rock = { ent = ent, pos = ent:GetPosition() }
                node.rock_entities[#node.rock_entities + 1] = rock
                if ent:HasTag("CHOP_workable") then
                    rock.radius_sq = RockFallRadius(ent) ^ 2
                    node.rocks[#node.rocks + 1] = rock
                end
            end
        end
        -- 提前受阻的位置也可能引爆，建筑保护不能只检查请求落点。
        node.shot_buildings = #node.rock_entities > 0
            and NearbyBuildings(session, node.pos, 7.4 + session.radius + MARGIN) or nil
    end

    local function ImpactSafe(session, node, from, first, last)
        if SegmentDistanceSq(from, first, last) <= session.protect_sq then return false end
        for _, building in ipairs(node.shot_buildings or {}) do
            if SegmentDistanceSq(building, first, last) <= session.protect_sq then return false end
        end
        for _, rock in ipairs(node.rocks or {}) do
            if Valid(rock.ent) and DistanceSq(from, rock.pos) <= rock.radius_sq
                and SegmentDistanceSq(rock.pos, first, last) <= session.protect_sq then return false end
        end
        return true
    end

    local function ShotPoints(session, node, from)
        if not ImpactSafe(session, node, from, node.pos, node.pos) then return end
        local points = { node.pos, hazards = { { pos = node.pos, radius_sq = session.protect_sq } } }
        local length = math.sqrt(DistanceSq(from, node.pos))
        local dx, dz = (node.pos.x - from.x) / length, (node.pos.z - from.z) / length
        for _, rock in ipairs(node.rock_entities or {}) do
            if Valid(rock.ent) then
                local rx, rz = rock.pos.x - from.x, rock.pos.z - from.z
                local along = rx * dx + rz * dz
                local across_sq = math.max(0, rx * rx + rz * rz - along * along)
                if across_sq < ROCK_COLLISION_RADIUS ^ 2 then
                    local half = math.sqrt(ROCK_COLLISION_RADIUS ^ 2 - across_sq)
                    local first, last = math.max(.25, along - half), math.min(length, along + half)
                    if first <= last then
                        -- 不伪造精确碰撞高度：保守检查水平走廊内可能提前受阻的区间。
                        -- 距离平方在区间上是凸函数，检查两端与原落点即可覆盖整个区间。
                        local a = { x = from.x + dx * first, z = from.z + dz * first }
                        local b = { x = from.x + dx * last, z = from.z + dz * last }
                        if not ImpactSafe(session, node, from, a, b) then return end
                        points[#points + 1], points[#points + 2] = a, b
                        -- 用包围圆保护整段可能爆心；只标两端会漏掉区间侧面的危险区域。
                        points.hazards[#points.hazards + 1] = {
                            pos = { x = (a.x + b.x) * .5, z = (a.z + b.z) * .5 },
                            radius_sq = (session.radius + MARGIN + (last - first) * .5) ^ 2,
                        }
                    end
                end
            end
        end
        return points
    end

    local function ShotCovers(session, record, points)
        for _, point in ipairs(points) do
            if DistanceSq(point, record.pos) > session.cover_sq then return false end
        end
        return true
    end

    -- 网格只用于局部查询；覆盖关系跨格保留，不把格子边界当作独立任务边界。
    local function NearbyRecords(session, pos, radius)
        local records = {}
        for x = math.floor((pos.x - radius) / CELL), math.floor((pos.x + radius) / CELL) do
            local column = session.grid[x]
            if column then
                for z = math.floor((pos.z - radius) / CELL), math.floor((pos.z + radius) / CELL) do
                    for _, record in ipairs(column[z] or {}) do
                        if DistanceSq(pos, record.pos) <= radius * radius then records[#records + 1] = record end
                    end
                end
            end
        end
        return records
    end

    local function BuildRecords(session)
        local previous = session.byent or {}
        session.records, session.byent, session.grid = {}, {}, {}
        session.authorized = {}
        for ent, data in pairs(queuer.selected_ents) do
            if IsTask(ent, data) then
                local record = previous[ent] or { ent = ent, remaining = Required(ent, queuer.autocollect > 1, session.damage) }
                record.pos = ent:GetPosition()
                session.authorized[ent] = true
                session.byent[ent] = record
                session.records[#session.records + 1] = record
                local x, z = math.floor(record.pos.x / CELL), math.floor(record.pos.z / CELL)
                session.grid[x] = session.grid[x] or {}
                session.grid[x][z] = session.grid[x][z] or {}
                table.insert(session.grid[x][z], record)
            end
        end
        -- 已按预算完成、但还在飞行中的建筑仍属本批许可，不误判成新出现的受保护建筑。
        for ent in pairs(session.completed or {}) do session.authorized[ent] = true end
        -- 布局不依赖玩家站位；转场顺序另行按实际移动成本选择。
        table.sort(session.records, function(a, b)
            return a.pos.x < b.pos.x or a.pos.x == b.pos.x and a.pos.z < b.pos.z
        end)
        session.revision = smart.revision
    end

    local function PlanningPause(session)
        if GetTimeRealSeconds() - (session.work_started or 0) > .003 then
            Sleep(0)
            session.work_started = GetTimeRealSeconds()
        end
        return smart.session == session and session.revision == smart.revision
    end

    local function Candidates(session, anchor)
        local nearby = NearbyRecords(session, anchor.pos, session.cover * 2)
        local buildings = NearbyBuildings(session, anchor.pos, session.radius * 2 + MARGIN)
        local candidates, keys = {}, {}
        local function Add(x, z)
            local key = math.floor(x * 100) .. ":" .. math.floor(z * 100)
            if not keys[key] then
                keys[key] = true
                candidates[#candidates + 1] = { x = x, z = z }
            end
        end
        Add(anchor.pos.x, anchor.pos.z)
        for _, record in ipairs(nearby) do
            if record.virtual > 0 then
                local dx, dz = record.pos.x - anchor.pos.x, record.pos.z - anchor.pos.z
                local dsq = dx * dx + dz * dz
                if dsq <= session.cover_sq then Add(record.pos.x, record.pos.z) end
                if dsq > .001 and dsq < 4 * session.cover_sq then
                    local d = math.sqrt(dsq)
                    local h = math.sqrt(session.cover_sq - dsq * .25) * .995
                    local x, z = (anchor.pos.x + record.pos.x) * .5, (anchor.pos.z + record.pos.z) * .5
                    Add(x - dz / d * h, z + dx / d * h)
                    Add(x + dz / d * h, z - dx / d * h)
                    Add(x, z)
                end
            end
        end
        for _, building in ipairs(buildings) do
            local dx, dz = anchor.pos.x - building.x, anchor.pos.z - building.z
            local d = math.sqrt(dx * dx + dz * dz)
            if d > .001 then Add(anchor.pos.x + dx / d * session.cover, anchor.pos.z + dz / d * session.cover) end
        end
        for i = 0, 23 do
            local angle = i * PI / 12
            for _, fraction in ipairs({ .5, .98 }) do
                Add(anchor.pos.x + math.cos(angle) * session.cover * fraction,
                    anchor.pos.z + math.sin(angle) * session.cover * fraction)
            end
        end
        local best, best_count, best_margin = nil, 0, -1
        for i, pos in ipairs(candidates) do
            if DistanceSq(pos, anchor.pos) <= session.cover_sq + .001 and SafePoint(session, pos, buildings) then
                local covered, count = {}, 0
                for _, record in ipairs(nearby) do
                    if record.virtual > 0 and DistanceSq(pos, record.pos) <= session.cover_sq + .001 then
                        covered[#covered + 1] = record
                        count = count + record.virtual
                    end
                end
                local clearance = math.huge
                for _, building in ipairs(buildings) do clearance = math.min(clearance, DistanceSq(pos, building)) end
                if count > best_count or count == best_count and clearance > best_margin then
                    best, best_count, best_margin = { pos = pos, covered = covered }, count, clearance
                end
            end
            if i % 32 == 0 and not PlanningPause(session) then return end
        end
        return best
    end

    local function GridPlan(session)
        local records = {}
        for _, record in ipairs(session.records) do
            if record.remaining > 0 then records[#records + 1] = record end
        end
        if #records < 4 then return end
        local seed = records[1].pos -- BuildRecords 已按坐标排序，过滤后仍保持顺序。
        local axis, nearest
        for _, record in ipairs(NearbyRecords(session, seed, session.cover * 2)) do
            local distance = DistanceSq(seed, record.pos)
            if distance > .04 and (not nearest or distance < nearest) then axis, nearest = record.pos, distance end
        end
        if not axis then return end
        local ux, uz = (axis.x - seed.x) / math.sqrt(nearest), (axis.z - seed.z) / math.sqrt(nearest)
        local points, us, vs = {}, {}, {}
        for i, record in ipairs(records) do
            local dx, dz = record.pos.x - seed.x, record.pos.z - seed.z
            local u, v = dx * ux + dz * uz, -dx * uz + dz * ux
            points[i], us[i], vs[i] = { record = record, u = u, v = v }, u, v
        end
        local function Spacing(values)
            table.sort(values)
            local step, previous
            for _, value in ipairs(values) do
                if previous and value - previous > .08 then step = math.min(step or math.huge, value - previous) end
                if not previous or value - previous > .08 then previous = value end
            end
            return step, values[1]
        end
        local du, min_u = Spacing(us)
        local dv, min_v = Spacing(vs)
        if not du or not dv or du < .2 or dv < .2 then return end
        for _, point in ipairs(points) do
            point.x, point.z = math.floor((point.u - min_u) / du + .5), math.floor((point.v - min_v) / dv + .5)
            if math.abs(point.u - min_u - point.x * du) > .08
                or math.abs(point.v - min_v - point.z * dv) > .08 then return end
        end
        -- 一次收集本片区域的受保护建筑，再按格查询；分组相位比较不重复调用 FindEntities。
        local min_x, max_x, min_z, max_z = seed.x, seed.x, seed.z, seed.z
        for _, record in ipairs(records) do
            min_x, max_x = math.min(min_x, record.pos.x), math.max(max_x, record.pos.x)
            min_z, max_z = math.min(min_z, record.pos.z), math.max(max_z, record.pos.z)
        end
        local center = { x = (min_x + max_x) * .5, z = (min_z + max_z) * .5 }
        local buildings, safety_cache = { grid = {} }, {}
        for _, pos in ipairs(NearbyBuildings(session, center,
            math.sqrt((max_x - min_x) ^ 2 + (max_z - min_z) ^ 2) * .5 + session.radius + MARGIN)) do
            local x, z = math.floor(pos.x / CELL), math.floor(pos.z / CELL)
            buildings.grid[x] = buildings.grid[x] or {}
            buildings.grid[x][z] = buildings.grid[x][z] or {}
            table.insert(buildings.grid[x][z], { pos = pos })
        end
        local best, best_cost, best_count
        -- 比较行列分组大小及相位，避免从中间开炸把完整树阵切碎；也支持旋转后的矩形树阵。
        for width = 1, math.min(7, math.floor(session.cover * 2 / du) + 1) do
            for height = 1, math.min(7, math.floor(session.cover * 2 / dv) + 1) do
                if ((width - 1) * du * .5) ^ 2 + ((height - 1) * dv * .5) ^ 2 <= session.cover_sq then
                    for ox = 0, width - 1 do for oz = 0, height - 1 do
                        local groups, order = {}, {}
                        for i, point in ipairs(points) do
                            local key = math.floor((point.x - ox) / width) .. ":" .. math.floor((point.z - oz) / height)
                            local group = groups[key]
                            if not group then
                                group = { covered = {}, shots = 0, min_u = point.u, max_u = point.u, min_v = point.v, max_v = point.v }
                                groups[key], order[#order + 1] = group, group
                            end
                            group.covered[#group.covered + 1] = point.record
                            group.shots = math.max(group.shots, point.record.remaining)
                            group.min_u, group.max_u = math.min(group.min_u, point.u), math.max(group.max_u, point.u)
                            group.min_v, group.max_v = math.min(group.min_v, point.v), math.max(group.max_v, point.v)
                            if i % 128 == 0 and not PlanningPause(session) then return end
                        end
                        local cost, safe = 0, true
                        for group_index, group in ipairs(order) do
                            local u, v = (group.min_u + group.max_u) * .5, (group.min_v + group.max_v) * .5
                            group.pos = { x = seed.x + u * ux - v * uz, z = seed.z + u * uz + v * ux }
                            local key = string.format("%.4f:%.4f", group.pos.x, group.pos.z)
                            local safety = safety_cache[key]
                            if not safety then
                                local nearby = {}
                                for _, record in ipairs(NearbyRecords(buildings, group.pos, session.radius + MARGIN)) do
                                    nearby[#nearby + 1] = record.pos
                                end
                                safety = { safe = SafePoint(session, group.pos, nearby) }
                                safety_cache[key] = safety
                            end
                            if not safety.safe then safe = false break end
                            for _, record in ipairs(group.covered) do
                                if DistanceSq(record.pos, group.pos) > session.cover_sq then safe = false break end
                            end
                            cost = cost + group.shots
                            if not safe or best_cost and cost > best_cost then safe = false break end
                            if group_index % 32 == 0 and not PlanningPause(session) then return end
                        end
                        if safe and (not best_cost or cost < best_cost or cost == best_cost and #order < best_count) then
                            best, best_cost, best_count = order, cost, #order
                        end
                        if not PlanningPause(session) then return end
                    end end
                end
            end
        end
        return best, best_cost
    end

    local function Plan(session)
        session.plan = {}
        for _, record in ipairs(session.records) do
            record.virtual = record.remaining
            if record.remaining <= 0 then Complete(session, record) end
        end
        local grid, grid_cost = GridPlan(session)
        if not PlanningPause(session) then return false end
        local cost, skipped = 0, {}
        for index, anchor in ipairs(session.records) do
            if anchor.virtual > 0 then
                local node = Candidates(session, anchor)
                if not PlanningPause(session) then return false end
                if node then
                    local shots = 0
                    for _, record in ipairs(node.covered) do shots = math.max(shots, record.virtual) end
                    node.shots = shots
                    cost = cost + shots
                    session.plan[#session.plan + 1] = node
                    -- shots 是本组预算的最大值，组内所有目标均已完整分配。
                    for _, record in ipairs(node.covered) do record.virtual = 0 end
                else
                    anchor.virtual = 0
                    skipped[#skipped + 1] = anchor
                end
            end
            if index % 8 == 0 and not PlanningPause(session) then return false end
        end
        if grid and (#skipped > 0 or grid_cost < cost or grid_cost == cost and #grid <= #session.plan) then
            session.plan = grid
        else
            for _, record in ipairs(skipped) do Complete(session, record, true) end
        end
        return true
    end

    local function NextNode(session, index)
        local plan, origin = session.plan, inst:GetPosition()
        repeat
            local best, best_cost, best_distance
            -- 原地可投优先；过近要后退、过远要靠近，不能只比较到炸弹落点的距离。
            for i = index, #plan do
                if not plan[i].empty then
                    local distance = math.sqrt(DistanceSq(origin, plan[i].pos))
                    local cost = distance <= session.radius + MARGIN and session.radius + MARGIN + .8 - distance
                        or distance > 7.4 and distance - 6.8 or 0
                    if not best_cost or cost < best_cost or cost == best_cost and distance < best_distance then
                        best, best_cost, best_distance = i, cost, distance
                    end
                end
                if (i - index + 1) % 128 == 0 and not PlanningPause(session) then return end
            end
            if not best then return end
            -- 只验证选中的节点；空节点永久标记，避免每次切换都重查全部目标实体。
            if Remaining(plan[best], session) > 0 then
                plan[index], plan[best] = plan[best], plan[index]
                return plan[index]
            end
        until smart.session ~= session
    end

    local function PrunePending()
        local now = GetTime()
        for i = #smart.pending, 1, -1 do
            if smart.pending[i].until_time <= now then table.remove(smart.pending, i) end
        end
    end

    local function RouteSafe(from, to)
        PrunePending()
        for _, hazard in ipairs(smart.pending) do
            if SegmentDistanceSq(hazard.pos, from, to) <= hazard.radius_sq then return false end
        end
        -- 原地只需检查危险区，不把零长度路径交给原生寻路器判定。
        if DistanceSq(from, to) < .0001 then return true end
        return TheWorld.Pathfinder:IsClear(from.x, 0, from.z, to.x, 0, to.z, PATH_CAPS)
    end

    local function StandSafe(session, node, pos)
        local distance = DistanceSq(pos, node.pos)
        if distance <= session.protect_sq or distance > 7.4 ^ 2 then return false end
        if not node.rock_entities or #node.rock_entities == 0 then return true end
        local points = ShotPoints(session, node, pos)
        if not points then return false end
        for _, record in ipairs(node.covered) do
            if record.remaining > 0 and not ShotCovers(session, record, points) then return false end
        end
        return true
    end

    local function SplitNode(session, node)
        local total, last = 0
        for _, record in ipairs(node.covered) do
            if record.remaining > 0 then total, last = total + 1, record end
        end
        if total == 0 or not node.rock_entities or #node.rock_entities == 0 then return false end
        if total == 1 then
            -- 子组最后只剩一个目标时，旧组中心可能已不合适；只允许归位一次，不追加空子组。
            if DistanceSq(node.pos, last.pos) < .001 then return false end
            node.pos, node.covered = last.pos, { last }
            node.rocks, node.rock_entities, node.shot_buildings = nil, nil, nil
            return true
        end
        local from = inst:GetPosition()
        local facing = math.atan2(from.z - node.pos.z, from.x - node.pos.x)
        local best, best_cost, best_point
        local centers = { node.pos }
        -- 原中心过深时，退到目标外缘再分组，避免为了打内圈而让炸弹在玩家身边受阻。
        for direction = 0, 7 do
            local dx, dz = math.cos(direction * PI / 4), math.sin(direction * PI / 4)
            local support, x, z, count = -math.huge, 0, 0, 0
            for _, record in ipairs(node.covered) do
                if record.remaining > 0 then
                    local dot = record.pos.x * dx + record.pos.z * dz
                    if dot > support + .001 then support, x, z, count = dot, 0, 0, 0 end
                    if math.abs(dot - support) <= .001 then x, z, count = x + record.pos.x, z + record.pos.z, count + 1 end
                end
            end
            centers[#centers + 1] = { x = x / count, z = z / count }
        end
        for center_index, center in ipairs(centers) do
            local probe = { pos = center, rock_entities = node.rock_entities, rocks = node.rocks, shot_buildings = node.shot_buildings }
            if SafePoint(session, center, node.shot_buildings or {}) then
                for _, radius in ipairs({ session.radius + MARGIN + .8, 6.5, 6.8 }) do
                    for i = 0, 23 do
                        local angle = facing + i * PI / 12
                        local pos = { x = center.x + math.cos(angle) * radius, z = center.z + math.sin(angle) * radius }
                        if Passable(pos) then
                            local points = ShotPoints(session, probe, pos)
                            if points then
                                local covered = {}
                                for _, record in ipairs(node.covered) do
                                    if record.remaining > 0 and ShotCovers(session, record, points) then covered[#covered + 1] = record end
                                end
                                -- 存在完整覆盖站位时，应继续处理寻路，不能因走不过去就拆分目标。
                                if #covered == total and center_index == 1 then return false end
                                local cost = DistanceSq(from, pos)
                                if #covered > 0 and #covered < total
                                    and (not best or #covered > #best or #covered == #best and cost < best_cost) then
                                    best, best_cost, best_point = covered, cost, center
                                end
                            end
                        end
                    end
                end
            end
            if not PlanningPause(session) then return false end
        end
        if not best then return false end
        local kept, rest = {}, {}
        for _, record in ipairs(best) do kept[record] = true end
        for _, record in ipairs(node.covered) do
            if record.remaining > 0 and not kept[record] then rest[#rest + 1] = record end
        end
        -- 只拆当前受阻分组，保留已扣预算和其余计划；每次严格减少分组大小，避免反复重分。
        session.plan[#session.plan + 1] = { pos = node.pos, covered = rest }
        node.covered, node.pos = best, best_point
        node.rocks, node.rock_entities, node.shot_buildings = nil, nil, nil
        return true
    end

    local function Detour(from, to)
        local best, best_cost
        for _, hazard in ipairs(smart.pending) do
            local radius = (math.sqrt(hazard.radius_sq) + .7) * 1.8
            for i = 0, 15 do
                local angle = i * PI / 8
                local via = { x = hazard.pos.x + math.cos(angle) * radius, z = hazard.pos.z + math.sin(angle) * radius }
                local cost = math.sqrt(DistanceSq(from, via)) + math.sqrt(DistanceSq(via, to))
                if (not best_cost or cost < best_cost) and Passable(via)
                    and RouteSafe(from, via) and RouteSafe(via, to) then
                    best, best_cost = via, cost
                end
            end
        end
        return best
    end

    local function SearchRoute(session, from, to)
        local finder = TheWorld.Pathfinder
        local handle = finder:SubmitSearch(from.x, 0, from.z, to.x, 0, to.z, PATH_CAPS)
        if not handle then return end
        smart.pathsearch = handle
        local deadline, result = GetTime() + 1.5
        while smart.session == session and session.revision == smart.revision and GetTime() < deadline do
            local status = finder:GetSearchStatus(handle)
            if status ~= 0 then -- 与原版 locomotor 一致：0 计算中，1 找到路径。
                if status == 1 then result = finder:GetSearchResult(handle) end
                break
            end
            if not Pause(session) then break end
        end
        if smart.pathsearch == handle then
            finder:KillSearch(handle)
            smart.pathsearch = nil
        end
        if smart.session ~= session or session.revision ~= smart.revision or not result or not result.steps then return end
        local route, previous = {}, from
        for _, step in ipairs(result.steps) do
            local pos = { x = step.x, z = step.z }
            if DistanceSq(previous, pos) > .0001 then
                -- 原生寻路只处理地形；飞行炸弹与倒塌危险必须对整条折线路径另外检查。
                if not Passable(pos) or not RouteSafe(previous, pos) then return end
                route[#route + 1], previous = pos, pos
            end
        end
        if DistanceSq(previous, to) > .0001 then
            if not RouteSafe(previous, to) then return end
            route[#route + 1] = to
        end
        return #route > 0 and route or nil
    end

    local function MoveToStand(session, node)
        local start = GetTime()
        local route, route_index
        while smart.session == session do
            if session.revision ~= smart.revision then return false end
            if Remaining(node, session) == 0 then return true end
            if inst:GetCurrentPlatform() or GetTime() - start > 15 then return false end
            RefreshRocks(session, node)
            local from = inst:GetPosition()
            local best, best_distance, detouring, blocked = nil, nil, nil, {}
            if StandSafe(session, node, from) and RouteSafe(from, from) then return true end
            local facing = math.atan2(from.z - node.pos.z, from.x - node.pos.x)
            -- 外侧站位也留出走路到达容差，避免寻路提前停下时仍在投掷距离之外。
            for _, radius in ipairs({ session.radius + MARGIN + .8, 6.5, 6.8 }) do
                for i = 0, 23 do
                    local angle = facing + i * PI / 12
                    local pos = { x = node.pos.x + math.cos(angle) * radius, z = node.pos.z + math.sin(angle) * radius }
                    local distance = DistanceSq(from, pos)
                    if StandSafe(session, node, pos) and Passable(pos) then
                        if RouteSafe(from, pos) then
                            if not best_distance or distance < best_distance then best, best_distance = pos, distance end
                        else
                            blocked[#blocked + 1] = { pos = pos, distance = distance }
                        end
                    end
                end
            end
            -- 无完整覆盖站位时直接交给局部拆分，不原地等一个不会消失的静态碰撞体。
            if not best and #blocked == 0 and #node.rock_entities > 0 then return false end
            if best then route = nil end
            if not best and route then
                while route_index <= #route and DistanceSq(from, route[route_index]) < .25 do route_index = route_index + 1 end
                local via = route[route_index]
                if via and RouteSafe(from, via) then
                    best, best_distance, detouring = via, DistanceSq(from, via), true
                else
                    route = nil
                end
            end
            -- 直接转场会穿过飞行炸弹时，优先绕行，不把等待落地作为每个点的固定开销。
            if not best and #smart.pending > 0 then
                local to = { x = node.pos.x + math.cos(facing) * 6.5, z = node.pos.z + math.sin(facing) * 6.5 }
                if StandSafe(session, node, to) and Passable(to) then
                    best = Detour(from, to)
                    best_distance = best and DistanceSq(from, best)
                    detouring = best
                end
            end
            -- 直线受阻并不代表不可达；只在确实需要时搜索少量候选站位，按安全路点逐段移动。
            if not best then
                table.sort(blocked, function(a, b) return a.distance < b.distance end)
                local tried, previous = 0
                for _, candidate in ipairs(blocked) do
                    if not previous or DistanceSq(previous, candidate.pos) > 4 then
                        route = SearchRoute(session, from, candidate.pos)
                        if smart.session ~= session or session.revision ~= smart.revision then return false end
                        if route then
                            route_index = 1
                            best, best_distance, detouring = route[1], DistanceSq(from, route[1]), true
                            break
                        end
                        tried, previous = tried + 1, candidate.pos
                        if tried >= 4 then break end
                    end
                end
            end
            if not best then
                if #smart.pending == 0 or GetTime() - start > 4 then return false end
            else
                if Remaining(node, session) == 0 then return true end
                local last_move, last_distance, stuck, next_check = -math.huge, best_distance, GetTime(), GetTime() + .5
                while smart.session == session do
                    if session.revision ~= smart.revision then return false end
                    if GetTime() >= next_check then
                        if Remaining(node, session) == 0 then return true end
                        next_check = GetTime() + .5
                    end
                    local current = inst:GetPosition()
                    if DistanceSq(current, best) < .25 then
                        -- 接近候选点不代表已进入安全投掷区；范围外仍必须真正移动。
                        if StandSafe(session, node, current) and RouteSafe(current, current) then return true end
                        if detouring then break end
                    end
                    if not RouteSafe(current, best) then break end
                    local distance = DistanceSq(current, best)
                    if distance < last_distance - .1 then last_distance, stuck = distance, GetTime() end
                    if GetTime() - stuck > 2 or GetTime() - start > 15 then return false end
                    if GetTime() - last_move > .8 then
                        POS_util:GoToPoint(best.x, best.z)
                        last_move = GetTime()
                    end
                    if not Pause(session) then return false end
                end
            end
            -- 内层可因到达绕行点或路径失效直接退出，外层每轮必须让出，保证超时也能推进。
            if not Pause(session) then return false end
        end
        return false
    end

    local function Ready(session)
        local combat = inst.replica.combat
        local controller = inst.components.playercontroller
        local deadline = GetTime() + 5
        while smart.session == session do
            if GetTime() > deadline then
                session.failure = "角色尚未恢复可投掷状态，已停止本批投掷"
                return false
            end
            -- idle 由服务端 SG 同步；库存减少发生在第 7 帧，不能代表第 11 帧的续投窗口已到。
            -- 只检查状态标签，不等 throw 动画结束，也不用请求发送时间推算服务端冷却。
            if inst:HasTag("idle") and (not inst.sg or inst.sg:HasStateTag("idle"))
                and not controller:IsDoingOrWorking()
                and not controller:IsBusy()
                and not inst:HasTag("moving") and not (combat and combat:InCooldown()) then return true end
            if not Pause(session, FRAMES) then return false end
        end
        return false
    end

    local function Refill(session)
        local bomb = Bomb()
        if bomb then return bomb end
        local inv = Inventory()
        if inv:GetActiveItem() then return end
        -- 只从随身库存/背包补充，不从附近打开的箱子取物。
        for _, container in ipairs({ inv, inv:GetOverflowContainer() }) do
            for slot, item in pairs(container:GetItems()) do
                if Valid(item) and item.prefab == "pumpkin_bomb" then
                    container:TakeActiveItemFromAllOfSlot(slot)
                    local deadline = GetTime() + 2
                    repeat
                        if not Pause(session) then return end
                        bomb = Bomb()
                        if bomb then
                            if session.equipped then
                                inv:EquipActiveItem()
                                repeat
                                    bomb = Bomb()
                                    if bomb and not inv:GetActiveItem() then return bomb end
                                    if not Pause(session) then return end
                                until GetTime() >= deadline
                                return
                            end
                            return bomb
                        end
                    until GetTime() >= deadline
                    return
                end
            end
        end
    end

    local function Throw(session, node)
        if Remaining(node, session) == 0 then return true end
        local item = Refill(session)
        if not item or not Ready(session) then return false end
        if Remaining(node, session) == 0 then return true end
        if Bomb() ~= item or session.revision ~= smart.revision then return false end
        RefreshRocks(session, node, true)
        if not StandSafe(session, node, inst:GetPosition()) then
            -- 等待就绪期间若新增倒塌危险，重新找安全站位，而不是放弃整个点位。
            if not MoveToStand(session, node) then
                if SplitNode(session, node) then return true, true end
                return false
            end
            if not Ready(session) then return false end
            if Remaining(node, session) == 0 then return true end
            RefreshRocks(session, node, true)
            if not StandSafe(session, node, inst:GetPosition()) then return false end
        end
        local before = CountBombs()
        local controller = inst.components.playercontroller
        for attempt = 1, 3 do
            if attempt > 1 then
                if not Pause(session) or not Ready(session) then return false end
                RefreshRocks(session, node, true)
                if Remaining(node, session) == 0 then return true end
                if not StandSafe(session, node, inst:GetPosition()) then return false end
            end
            -- 首次发送与主机重试共用最后复核；以上等待可能改变物品、选择集或周围建筑。
            if Bomb() ~= item or session.revision ~= smart.revision
                or not SafePoint(session, node.pos, node.shot_buildings or NearbyBuildings(session, node.pos, session.radius + MARGIN)) then return false end
            local started, succeeded, failed = GetTime(), false, false
            local points = ShotPoints(session, node, inst:GetPosition())
            if not points then return false end
            local rocks = node.rocks -- 保存发射前的倒塌风险，确认时树可能已经切换成 MINE 阶段。
            -- 必须 target=nil；否则服务端 TOSS 会忽略规划坐标并重新吸附实体。
            local action = BufferedAction(inst, nil, ACTIONS.TOSS, item, Vector3(node.pos.x, 0, node.pos.z))
            if controller.ismastersim then
                action:AddSuccessAction(function() succeeded = true end)
                action:AddFailAction(function() failed = true end)
            end
            queuer:SendAction(action, true, nil)
            while smart.session == session do
                if succeeded or CountBombs() < before then
                    for _, hazard in ipairs(points.hazards) do
                        smart.pending[#smart.pending + 1] = {
                            pos = hazard.pos, radius_sq = hazard.radius_sq, until_time = GetTime() + FLIGHT_TIME,
                        }
                    end
                    for _, rock in ipairs(rocks) do
                        for _, hazard in ipairs(points.hazards) do
                            if DistanceSq(hazard.pos, rock.pos) <= hazard.radius_sq then
                                smart.pending[#smart.pending + 1] = { pos = rock.pos, radius_sq = rock.radius_sq, until_time = GetTime() + 2 }
                                break
                            end
                        end
                    end
                    for _, record in ipairs(node.covered) do
                        record.remaining = math.max(0, record.remaining - 1)
                        if record.remaining == 0 then Complete(session, record) end
                    end
                    if queuer.rpc_queue_guard then queuer.rpc_queue_guard:KeepAlive() end
                    return true
                end
                -- 主机可确认动作未入队或执行失败；客机请求发出后只等实际消耗，禁止超时重发。
                if controller.ismastersim then
                    local queued = inst:GetBufferedAction() == action
                        or controller.locomotor and controller.locomotor.bufferedaction == action
                    if failed or not queued then
                        if failed then
                            if inst:GetBufferedAction() == action then inst:ClearBufferedAction() end
                            if controller.locomotor and controller.locomotor.bufferedaction == action then controller.locomotor:Clear() end
                        end
                        break
                    end
                end
                if GetTime() - started > 3 then
                    local state = inst.sg and inst.sg.currentstate and inst.sg.currentstate.name or "unknown"
                    print(string.format("[智能南瓜拆除] 投掷确认超时：模式=%s，状态=%s，idle=%s，busy=%s，库存=%d->%d",
                        controller.ismastersim and "主机" or "客机",
                        state, tostring(inst:HasTag("idle")), tostring(controller:IsBusy()), before, CountBombs()))
                    session.failure = "投掷请求已提交但消耗未确认，已停止，避免重复投掷"
                    return false
                end
                if not Pause(session, FRAMES) then return false end
            end
            if smart.session ~= session then return false end
        end
        session.failure = "角色未能接收投掷动作，已停止本批投掷"
        return false
    end

    local function Finish(session)
        HideMarkers(true)
        if session.failure and inst.components.talker then
            inst.components.talker:Say("智能南瓜拆除：" .. session.failure)
        end
        -- 不在当前协程中自杀后再交接；只交还非南瓜任务，禁止失败时回退到原版乱投。
        inst:DoTaskInTime(0, function()
            if smart.session ~= session then return end
            local handoff = not session.failure
            for ent, data in pairs(queuer.selected_ents) do
                if IsTask(ent, data) then handoff = false break end
            end
            queuer:ClearActionThread()
            if handoff and next(queuer.selected_ents) then old_apply(queuer) end
        end)
    end

    function queuer:ApplyToSelection(...)
        local bomb, has_task = Bomb(), false
        for ent, data in pairs(self.selected_ents) do if IsTask(ent, data) then has_task = true break end end
        if not bomb or not has_task then return old_apply(self, ...) end
        if smart.session then return end
        local radius = TUNING.PUMPKIN_BOMB_RANGE
        local session = {
            radius = radius, cover = radius - COVER_MARGIN, cover_sq = (radius - COVER_MARGIN) ^ 2,
            protect_sq = (radius + MARGIN) ^ 2, damage = TUNING.PUMPKIN_BOMB_BUILDING_DAMAGE,
            equipped = not Inventory():GetActiveItem(), skipped = 0, completed = {},
        }
        smart.session = session
        self.action_thread = StartThread(function()
            -- 第一次抬键已启动线程；等第二次点击扩选完成，才允许发送第一颗。
            local began = GetTime()
            repeat
                if not Pause(session) then return end
            until not queuer.clicked and not queuer.selection_thread
                and GetTime() - math.max(began, smart.changed_at or began) >= (queuer.double_click_speed or .3)
            inst:ClearBufferedAction()
            while smart.session == session do
                BuildRecords(session)
                local planned = Plan(session)
                if smart.session ~= session then return end
                if planned then
                    local revision = session.revision
                    local index = 1
                    while index <= #session.plan do
                        if smart.session ~= session then return end
                        if revision ~= smart.revision then break end
                        local node = NextNode(session, index)
                        if not node then break end
                        Paint(session, index)
                        local split = false
                        if MoveToStand(session, node) then
                            while Remaining(node, session) > 0 do
                                if revision ~= smart.revision then break end
                                local thrown, updated = Throw(session, node)
                                if not thrown then
                                    if revision == smart.revision then
                                        session.failure = session.failure or "投点、站位或物品状态改变，已停止本批投掷"
                                    end
                                    break
                                end
                                if updated then Paint(session, index) end
                            end
                        elseif revision == smart.revision and SplitNode(session, node) then
                            -- 动态增加的子分组也走同一调度循环；当前分组尚未完成，不推进游标。
                            split = true
                        elseif revision == smart.revision then
                            node.skipped = true
                            for _, record in ipairs(node.covered) do
                                if record.remaining > 0 then
                                    Complete(session, record, true)
                                end
                            end
                        end
                        if session.failure then break end
                        if not split then index = index + 1 end
                        if not Pause(session, 0) then return end
                    end
                    if session.failure or revision == smart.revision then break end
                end
            end
            if smart.session == session then Finish(session) end
        end, "aq_smart_destruction_thread")
    end

    return smart
end
