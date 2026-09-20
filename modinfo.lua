---@diagnostic disable: lowercase-global
-- 名称
name = "【萌萌的新】模组补丁"

-- 描述
description = "众所周知，【萌萌的新】有很多非常优秀的MOD，但这些MOD总有美中不足的地方，本模组用于解决那些不足之处\n模组功能见创意工坊简介，这里写不下\n\n使用这个模组需开启【冰冰羊的模组运行库】模组，否则无效"

-- 作者
author = "冰冰羊"

-- 版本
version = "2026-09-20"

-- klei官方论坛地址，为空则默认是工坊的地址
-- forumthread = ""

-- 模组加载优先级
priority = -100010

-- modicon
icon_atlas = "images/modicon.xml"
icon = "modicon.tex"

-- dst兼容
dst_compatible = true
-- 是否是客户端mod
client_only_mod = true
-- 是否是所有客户端都需要安装
all_clients_require_mod = false
-- 饥荒api版本，固定填10
api_version = 10

---@param label string|nil 标题
---@return table
local function SkipSpace(label)
	return { name = "",label = label, hover = "", options = { { description = "", data = false }, }, default = false}
end

-- mod的配置项
configuration_options =
{
    SkipSpace("记忆力模组"),
    {
        name = "refreshhighlight_range",
        label = "搜索范围",
        hover = "选中一个物品后，搜索多少范围内的箱子是否有此物品",
        options =
        {
            {description = "20", data = 20},
            {description = "25", data = 25},
            {description = "30", data = 30},
            {description = "35", data = 35},
            {description = "40", data = 40},
            {description = "45", data = 45},
            {description = "50", data = 50},
            {description = "55", data = 55},
            {description = "60", data = 60},
            {description = "65", data = 65, hover = "默认值"},
            {description = "70", data = 70},
        },
        default = 65,
    },
    SkipSpace("如果你想要其它模组设置，请留言让我添加")
}