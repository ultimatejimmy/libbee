local ok_loc, Localization = pcall(require, "libbee_localization")
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
    version = "26.9.3-beta3",
    author      = "ultimatejimmy",
}

