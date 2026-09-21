GLOBAL.setmetatable(env, {
    __index = function(t, k)
        return GLOBAL.rawget(GLOBAL, k)
    end
})
_G = GLOBAL

-- 加载我的工具
if not rawget(GLOBAL, "BBGOAT_utils") then
    if TUNING.suggest_to_subscribe_bbgoat_basementmod then
        return
    end
    TUNING.suggest_to_subscribe_bbgoat_basementmod = true

	local function should_show_dig()
		if TheNet:GetIsServer() and TheNet:GetServerIsDedicated() then
			return false
		end
		if not TheFrontEnd then
			return false
		end
		if IsMigrating() then
			return false
		end
		return not InGamePlay()
	end

	local _languages = {
		zh = true, --Chinese for Steam
		zhr = true, --Chinese for WeGame
		ch = true, --Chinese mod
		chs = true, --Chinese mod
		sc = true, --simple Chinese
		chinese = true, --Chinese mod
		zht = true, --traditional Chinese for Steam
		tc = true, --traditional Chinese
		cht = true, --Chinese mod
	}
	local lang = _G.LanguageTranslator and _G.LanguageTranslator.defaultlang
	local isCH = lang and _languages[lang]

	if not TheNet:IsDedicated() then
		AddGamePostInit(function()
			TheGlobalInstance:DoTaskInTime(0.1, function()
				if not should_show_dig() then return end
				local PopupDialogScreen = require "screens/redux/popupdialog"
				TheFrontEnd:PushScreen(PopupDialogScreen(
					modinfo.name,
					isCH and "模组基础运行库缺失！\n你缺少了模组基础运行库，你必须去订阅才能继续使用本模组" or
							"Mod Runtime Library Missing!\nYou are missing the required runtime library for this mod. Please subscribe to it before continuing to use this mod.",
					{
						{
							text = isCH and "订阅/启用运行库模组" or "Subscribe/Enable mod",
							cb = function()
								local modname = "workshop-3750536829"
								if table.contains(TheSim:GetModDirectoryNames(), modname) then
									KnownModIndex:Enable(modname)
									KnownModIndex:Save()
									TheGlobalInstance:DoTaskInTime(0.5, function()
										TheNet:Disconnect(true)
										TheSim:ResetError()
										StartNextInstance()
									end)
								else
									VisitURL("https://steamcommunity.com/sharedfiles/filedetails/?id=3750536829")
									TheSim:SubscribeToMod("workshop-3750536829")
									TheFrontEnd:PopScreen()
									TheFrontEnd:PushScreen(PopupDialogScreen(
										isCH and "已订阅" or "Subscribed",
										isCH and "请前往模组列表启用【冰冰羊的模组运行库】模组" or "Please go to the mod list to enable the runtime library mod named\n\"BBGOAT Utils\"",
										{
											{
												text = isCH and "好的" or "OK",
												cb = function()
													TheFrontEnd:PopScreen()
												end
											}
										}
									))
								end
							end
						},
						{
							text = isCH and "订阅运行库模组" or "Subscribe Mod Base",
							cb = function()
								VisitURL("https://steamcommunity.com/sharedfiles/filedetails/?id=3750536829")
								TheSim:SubscribeToMod("workshop-3750536829")
								TheFrontEnd:PopScreen()
							end
						},
						{
							text = isCH and "返回" or "Back",
							cb = function()
								TheFrontEnd:PopScreen()
							end
						},
					}
				))
			end)
		end)
	end
    return
end

Upvaluehelper = _G.BBGOAT_utils.Upvaluehelper
MOD_util = _G.BBGOAT_utils.MOD_util
BBGOAT_util = _G.BBGOAT_utils.BBGOAT_util

modimport("ban_print.lua") -- 关掉萌萌的新print的垃圾消息(你是话血吗)
modimport("hook_getupvalue") -- 将萌萌的新模组里的getupvalue替换为我的版本
modimport("hook_mmdx.lua") -- HOOK 萌萌的新的模组

modimport("hook_lazy_controls.lua") -- HOOK lazy_controls 模组(兼容萌萌的新的模组)