-- Localization Manager for Libbee Plugin (with .po support)

local logger = require("logger")
local ok, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok or type(lfs) ~= "table" then
    ok, lfs = pcall(require, "lfs")
end
if not ok then
    logger.warn("Localization: lfs module not found!")
end

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
if plugin_path ~= "" then
    local path_to_dir = plugin_path:gsub("%.", "/")
    if not package.path:find(path_to_dir) then
        package.path = package.path .. ";" .. path_to_dir .. "?.lua"
    end
end

local Localization = {
    current_language = "en",
    translations = {},
    available_languages = {},
    path = "plugins/libbee.koplugin",
}

-- Simple .po file parser
function Localization:parsePO(filepath)
    local translations = {}
    local file = io.open(filepath, "r")
    
    if not file then
        logger.warn("Localization: Cannot open .po file:", filepath)
        return nil
    end
    
    local msgid = nil
    local msgstr = nil
    local in_msgid = false
    local in_msgstr = false
    
    for line in file:lines() do
        -- Strip trailing carriage returns and whitespace (e.g. CRLF from Windows)
        line = line:gsub("[\r\t ]+$", "")

        -- Skip comments and empty lines
        if not (line:match("^#") or line:match("^%s*$")) then
            -- Start of msgid
            if line:match('^msgid%s+"') then
                -- Save previous translation
                if msgid and msgstr then
                    translations[msgid] = msgstr
                end
                
                msgid = line:match('^msgid%s+"(.*)"$')
                msgstr = nil
                in_msgid = true
                in_msgstr = false
            
            -- Start of msgstr
            elseif line:match('^msgstr%s+"') then
                msgstr = line:match('^msgstr%s+"(.*)"$')
                in_msgid = false
                in_msgstr = true
            
            -- Continuation line
            elseif line:match('^"') then
                local continuation = line:match('^"(.-)"')
                if in_msgid and msgid then
                    msgid = msgid .. continuation
                elseif in_msgstr and msgstr then
                    msgstr = msgstr .. continuation
                end
            end
        end
    end
    
    -- Save last translation
    if msgid and msgstr then
        translations[msgid] = msgstr
    end
    
    file:close()
    
    -- Process escape sequences
    local function unescapePOString(str)
        if not str or type(str) ~= "string" then return str end
        local prev = str
        for _ = 1, 3 do
            local next_str = prev:gsub("\\(.)", function(c)
                if c == "n" then return "\n"
                elseif c == "t" then return "\t"
                elseif c == '"' then return '"'
                elseif c == "\\" then return "\\"
                else return c
                end
            end)
            if next_str == prev then break end
            prev = next_str
        end
        return prev
    end

    for key, value in pairs(translations) do
        local normalized_key = unescapePOString(key)
        local unescaped_val = unescapePOString(value)
        translations[normalized_key] = unescaped_val
        if normalized_key ~= key then
            translations[key] = nil
        end
    end
    
    return translations
end

local function resolveScriptDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    local dir = src:match("^@?(.*[/\\])") or "./"
    if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
        dir = dir:sub(1, -2)
    end
    return dir:gsub("\\", "/")
end

-- Detect system language from KOReader settings or environment
function Localization:detectSystemLanguage()
    local lang = nil

    -- 1. Try reading KOReader global settings
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting) == "function" then
        local ok_s, setting = pcall(function()
            return _G.G_reader_settings:readSetting("language") or _G.G_reader_settings:readSetting("lang")
        end)
        if ok_s and setting and type(setting) == "string" and #setting > 0 then
            lang = setting
        end
    end

    -- 2. Try KOReader gettext module
    if not lang then
        local ok_gt, gt = pcall(require, "gettext")
        if ok_gt and type(gt) == "table" then
            if type(gt.lang) == "string" and #gt.lang > 0 then
                lang = gt.lang
            elseif type(gt.language) == "string" and #gt.language > 0 then
                lang = gt.language
            end
        end
    end

    -- 3. Fall back to environment variables
    if not lang then
        local env_lang = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES")
        if env_lang and #env_lang > 0 then
            lang = env_lang:match("^([^%.@]+)") -- strip encoding like .UTF-8
        end
    end

    if not lang then
        return "en"
    end

    -- Normalize language code format (e.g. "zh_cn" -> "zh_CN", "pt-br" -> "pt_br")
    lang = lang:gsub("-", "_")
    
    -- Check exact match in available languages
    if self:languageExists(lang) then
        return lang
    end

    -- Try case normalization (e.g. "zh_cn" -> "zh_CN", "pt_BR" -> "pt_br")
    for _, code in ipairs(self.available_languages) do
        if code:lower() == lang:lower() then
            return code
        end
    end

    -- Try language prefix match (e.g. "es_ES" -> "es", "de_DE" -> "de", "fr_FR" -> "fr")
    local prefix = lang:match("^([a-zA-Z]+)")
    if prefix then
        prefix = prefix:lower()
        if self:languageExists(prefix) then
            return prefix
        end
        for _, code in ipairs(self.available_languages) do
            if code:lower() == prefix then
                return code
            end
        end
    end

    return "en"
end

-- Initialize localization system
function Localization:init(path)
    logger.info("Localization: Initializing Libbee localization...")
    
    if path then
        self.path = path:gsub("\\", "/")
    else
        self.path = resolveScriptDir()
    end
    self.initialized = true
    
    self:discoverLanguages()
    
    -- Detect KOReader system language
    self.current_language = self:detectSystemLanguage()
    
    -- Load translation file
    self:loadTranslations()
    
    logger.info("Localization: Initialized with system language:", self.current_language)
end

function Localization:ensureInit()
    if not self.initialized then
        self:init()
    end
end

-- Discover available .po files
function Localization:discoverLanguages()
    local lang_dir = self.path .. "/languages"
    self.available_languages = {}
    
    if not lfs then
        logger.warn("Localization: lfs not available, using fallback language discovery")
        self.available_languages = { "ar", "de", "en", "es", "fr", "hu", "id", "it", "ja", "ko", "nl", "pl", "pt_br", "ru", "sr", "tr", "uk", "zh_CN" }
        return
    end

    local attr = lfs.attributes(lang_dir)
    if not attr or attr.mode ~= "directory" then
        logger.warn("Localization: Languages directory not found at:", lang_dir)
        self.available_languages = { "ar", "de", "en", "es", "fr", "hu", "id", "it", "ja", "ko", "nl", "pl", "pt_br", "ru", "sr", "tr", "uk", "zh_CN" }
        return
    end
    
    for file in lfs.dir(lang_dir) do
        if file:match("%.po$") then
            local lang_code = file:match("^(.+)%.po$")
            if lang_code then
                table.insert(self.available_languages, lang_code)
            end
        end
    end
    
    table.sort(self.available_languages)
    logger.info("Localization: Discovered", #self.available_languages, "languages")
end

-- Load translations from .po file
function Localization:loadTranslations()
    local po_file = self.path .. "/languages/" .. self.current_language .. ".po"
    logger.info("Localization: Loading translations from:", po_file)
    
    local translations = self:parsePO(po_file)
    
    if translations then
        self.translations = translations
        logger.info("Localization: Loaded", self:tableSize(translations), "translations")
    else
        logger.warn("Localization: Failed to load .po file:", po_file)
        if self.current_language ~= "en" then
            logger.info("Localization: Falling back to English master")
            self.current_language = "en"
            po_file = self.path .. "/languages/en.po"
            translations = self:parsePO(po_file)
            self.translations = translations or {}
        else
            self.translations = {}
        end
    end
end

-- Helper: count table size
function Localization:tableSize(t)
    local count = 0
    if t then
        for _ in pairs(t) do count = count + 1 end
    end
    return count
end

function Localization:setLanguage(lang)
    if not lang then return end
    self.current_language = lang
    self:loadTranslations()
end

function Localization:languageExists(lang_code)
    for _, code in ipairs(self.available_languages) do
        if code == lang_code then return true end
    end
    return false
end

-- Fallback English map for strings in case .po file is missing or incomplete
local FALLBACKS = {
    -- Menu & Plugin Info
    menu_libbee = "Libbee",
    menu_libbee_desc = "Browse your Libby shelf and download ebook loans directly to KOReader.",
    menu_sync = "Sync Shelf",
    menu_settings = "Libbee Settings",
    menu_about = "About Libbee",
    
    -- Actions & Buttons
    btn_close = "Close",
    btn_cancel = "Cancel",
    btn_ok = "OK",
    btn_save = "Save",
    btn_download = "Download",
    btn_read = "Read",
    btn_renew = "Renew",
    btn_return = "Return",
    btn_refresh = "Refresh",
    btn_setup = "Setup Passkey",
    btn_unlink = "Unlink Account",
    btn_retry = "Retry",
    btn_restart = "Restart KOReader",
    btn_check_updates = "Check for Updates",
    btn_install_update = "Install Update",

    -- Views & Filters
    tab_loans = "Loans",
    tab_holds = "Holds",
    tab_tags = "Tags",
    filter_all = "All",
    filter_ready = "Ready to Read",
    filter_downloaded = "Downloaded",
    view_list = "List View",
    view_grid = "Cover Grid",

    -- Status & Messages
    status_downloading = "Downloading...",
    status_fulfilling = "Fulfilling DRM...",
    status_ready = "Ready",
    status_expired = "Expired",
    msg_syncing = "Syncing with Libby...",
    msg_sync_complete = "Shelf synced successfully.",
    msg_download_complete = "Download complete.",
    msg_return_confirm = "Return \"%s\" early to your library?",
    msg_unlink_confirm = "Unlink your Libby account from this device?",
    msg_restart_prompt = "Update installed. Restart KOReader now?",
    msg_no_loans = "No loans currently on your shelf.",
    msg_no_holds = "No holds currently placed.",
    progress_please_wait = "Please wait...",
}

local KEY_ALIASES = {
    ["Close"] = "btn_close",
    ["Cancel"] = "btn_cancel",
    ["OK"] = "btn_ok",
    ["Save"] = "btn_save",
    ["Download"] = "btn_download",
    ["Read"] = "btn_read",
    ["Renew"] = "btn_renew",
    ["Return"] = "btn_return",
    ["Refresh"] = "btn_refresh",
    ["Loans"] = "tab_loans",
    ["Holds"] = "tab_holds",
    ["Tags"] = "tab_tags",
    ["All"] = "filter_all",
    ["Settings"] = "menu_settings",
    ["About"] = "menu_about",
}

-- Translate string key with formatting support
function Localization:t(key, ...)
    self:ensureInit()
    local translation = self.translations[key]
    if (not translation or translation == "") and KEY_ALIASES[key] then
        translation = self.translations[KEY_ALIASES[key]]
    end
    
    if not translation or translation == "" then
        translation = FALLBACKS[key] or (KEY_ALIASES[key] and FALLBACKS[KEY_ALIASES[key]]) or key
    end
    
    local arg_count = select('#', ...)
    if arg_count > 0 then
        local args = {}
        for i = 1, arg_count do
            local arg = select(i, ...)
            args[i] = (arg == nil) and "???" or arg
        end
        
        -- Check if it contains positional arguments like %1$s or %2$d
        if translation:find("%%%d+%$") then
            local success, result = pcall(function()
                return string.gsub(translation, "%%(%d+)%$([-+ #0]?%d*%.?%d*[cdeEfgGiouuxXsqp%%])", function(index, spec)
                    local idx = tonumber(index)
                    local val = args[idx]
                    if val == nil then val = "???" end
                    if spec == "%" then return "%" end
                    return string.format("%" .. spec, val)
                end)
            end)
            if success then
                return result
            else
                logger.warn("Localization: Positional format error for key:", key)
                return translation
            end
        else
            local success, result = pcall(string.format, translation, (unpack or table.unpack)(args))
            if success then
                return result
            else
                logger.warn("Localization: Format error for key:", key)
                return translation
            end
        end
    end
    
    return translation
end

-- Global helper alias `_` (matching gettext pattern)
function Localization:getHelper()
    return function(key, ...)
        return self:t(key, ...)
    end
end

return Localization
