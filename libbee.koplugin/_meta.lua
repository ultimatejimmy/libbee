local ok_loc, Localization = pcall(require, "localization_libbee")
if ok_loc and Localization then
    Localization:init()
end
local _ = function(key, ...)
    if ok_loc and Localization then
        return Localization:t(key, ...)
    end
    return key
end

return {
    name        = "libbee",
    fullname    = _("menu_libbee"),
    description = _("menu_libbee_desc"),
    version = "26.8.23-beta2",
    author      = "ultimatejimmy",
}

