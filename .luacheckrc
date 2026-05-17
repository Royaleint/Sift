std = "lua51"
max_line_length = false

globals = {
    -- SavedVariables (created by WoW, read/written by addon)
    "BawrSpamDB",
    -- Named UI frames (require global for UISpecialFrames + Blizz close behavior)
    "BawrSpamHistoryFrame",
    "BawrSpamConfigFrame",
    "BawrSpamConfigDialog",
    "BawrSpamConfigOptionsPanel",
    "BawrSpamContextMenu",
    -- Slash registration
    "SlashCmdList",
    "SLASH_BAWRSPAM1",
    -- StaticPopupDialogs is read-only at the table level but addons mutate it
    -- to register their own dialog tables.
    "StaticPopupDialogs",
}

read_globals = {
    -- WoW aliases for stdlib (not in Lua 5.1 std as bare globals)
    "tinsert", "tremove", "wipe", "strsplit", "format",
    "time", "date",

    -- WoW bitlib (LuaJIT/5.2+ bit library exposed via WoW runtime)
    "bit",

    -- WoW frames/UI
    "BackdropTemplateMixin",
    "BackdropTemplate",
    "CreateFrame",
    "DEFAULT_CHAT_FRAME",
    "GameFontNormal", "GameFontHighlight", "GameFontHighlightSmall",
    "GameFontNormalLarge", "GameFontNormalSmall",
    "GameFontDisable", "GameFontDisableSmall",
    "GameTooltip",
    "UIParent",
    "UISpecialFrames",
    "UIPanelButtonTemplate", "UIPanelCloseButton",
    "UIPanelScrollFrameTemplate",
    "CreateScrollBoxListLinearView",
    "ScrollUtil",
    "EasyMenu",
    "StaticPopup_Show",
    "CLOSE",
    "MenuUtil",
    "TooltipDataProcessor",
    "Enum",
    "PlayerLocation",
    "Settings",
    "InterfaceOptions_AddCategory",
    "InterfaceOptionsFrame",
    "InterfaceOptionsFrame_OpenToCategory",
    "HideUIPanel",
    "ChatFontNormal",

    -- WoW API (C_ namespaces)
    "C_BattleNet",
    "C_CVar",
    "C_FriendList",
    "C_LFGList",
    "C_ReportSystem",
    "C_Timer",

    -- WoW API (functions)
    "ChatFrameUtil",
    "ChatFrame_AddMessageEventFilter",
    "GetCVarBool",
    "GetServerTime",
    "GetTime",
    "hooksecurefunc",
    "IsPlayerInGuildFromGUID",
    "issecretvalue",
    "UnitGUID",
    "UnitInParty",
    "UnitInRaid",
    "geterrorhandler",
    "GetScreenWidth", "GetScreenHeight",
    "PLAYER_REPORT_TYPE_SPAM",

    -- Ace3 / Libraries
    "LibStub",
}

-- Exclude vendored libraries (third-party code; not subject to project rules)
-- and the private dev repo (its own rules + dev-only globals live there).
exclude_files = {
    "BawrSpam_Dev/**",
    "Libs/**",
}

ignore = {
    "21[23]",  -- callback/test helper patterns with intentionally unused args
}
