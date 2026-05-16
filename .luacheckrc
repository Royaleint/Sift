std = "none"
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
    -- Lua builtins
    "_G", "next",
    "pairs", "ipairs", "type", "select", "unpack",
    "tonumber", "tostring", "print", "format",
    "tinsert", "tremove", "wipe", "strsplit",
    "time", "date", "math", "string", "table",
    "error", "pcall", "xpcall", "rawget", "rawset", "setmetatable", "getmetatable",
    "assert",

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
    "FauxScrollFrameTemplate",
    "FauxScrollFrame_Update",
    "FauxScrollFrame_OnVerticalScroll",
    "FauxScrollFrame_GetOffset",
    "EasyMenu",
    "StaticPopup_Show",
    "CLOSE",
    "MenuUtil",
    "Settings",
    "InterfaceOptions_AddCategory",
    "InterfaceOptionsFrame",
    "InterfaceOptionsFrame_OpenToCategory",
    "HideUIPanel",
    "ChatFontNormal",

    -- WoW API (C_ namespaces)
    "C_BattleNet",
    "C_FriendList",
    "C_Timer",

    -- WoW API (functions)
    "ChatFrameUtil",
    "ChatFrame_AddMessageEventFilter",
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

    -- WoW bitlib (Lua 5.1)
    "bit",

    -- Ace3 / Libraries
    "LibStub",
}

-- Vendored libraries are not subject to project luacheck rules.
exclude_files = {
    "Libs/**/*.lua",
}

ignore = {"21[23]"}  -- callback / Ace3 patterns
