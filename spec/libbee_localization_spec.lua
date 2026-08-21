-- Unit and Integration tests for Libbee Localization System

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../libbee.koplugin/?.lua;" .. script_dir .. "?.lua;" .. package.path

require("spec_helper")

describe("Libbee Localization System", function()
    local Localization = require("localization_libbee")

    it("initializes and discovers 18 languages", function()
        local path = script_dir .. "../libbee.koplugin"
        Localization:init(path)

        assert.is_true(#Localization.available_languages >= 18)
        assert.is_true(Localization:languageExists("en"))
        assert.is_true(Localization:languageExists("de"))
        assert.is_true(Localization:languageExists("es"))
        assert.is_true(Localization:languageExists("fr"))
        assert.is_true(Localization:languageExists("zh_CN"))
        assert.is_true(Localization:languageExists("pt_br"))
        assert.is_true(Localization:languageExists("ja"))
        assert.is_true(Localization:languageExists("ko"))
    end)

    it("detects and normalizes KOReader system language settings", function()
        _G.G_reader_settings = {
            readSetting = function(self, key)
                if key == "language" then return "es_ES" end
                return nil
            end
        }
        local detected_es = Localization:detectSystemLanguage()
        assert.equals("es", detected_es)

        _G.G_reader_settings = {
            readSetting = function(self, key)
                if key == "language" then return "de" end
                return nil
            end
        }
        local detected_de = Localization:detectSystemLanguage()
        assert.equals("de", detected_de)

        _G.G_reader_settings = {
            readSetting = function(self, key)
                if key == "language" then return "zh_CN" end
                return nil
            end
        }
        local detected_zh = Localization:detectSystemLanguage()
        assert.equals("zh_CN", detected_zh)

        _G.G_reader_settings = {
            readSetting = function(self, key)
                if key == "language" then return "pt_BR" end
                return nil
            end
        }
        local detected_pt = Localization:detectSystemLanguage()
        assert.equals("pt_br", detected_pt)

        _G.G_reader_settings = {
            readSetting = function(self, key)
                if key == "language" then return "unknown_xyz" end
                return nil
            end
        }
        local detected_unk = Localization:detectSystemLanguage()
        assert.equals("en", detected_unk)

        _G.G_reader_settings = nil
    end)

    it("translates strings with variable formatting", function()
        Localization.current_language = "en"
        Localization:loadTranslations()

        local title = Localization:t("menu_libbee")
        assert.equals("Libbee", title)

        local loans_str = Localization:t("%d loans", 5)
        assert.equals("5 loans", loans_str)

        local days_str = Localization:t("%d days left", 3)
        assert.equals("3 days left", days_str)
    end)

    it("correctly parses PO strings with CRLF and escape sequences", function()
        local tmp_po_path = script_dir .. "test_crlf_sample.po"
        local f_tmp = io.open(tmp_po_path, "w")
        if f_tmp then
            f_tmp:write("msgid \"crlf_key\"\r\nmsgstr \"crlf_val\"\r\n\r\nmsgid \"space_key\"   \r\nmsgstr \"space_val\"   \r\n")
            f_tmp:close()

            local parsed = Localization:parsePO(tmp_po_path)
            os.remove(tmp_po_path)

            assert.is_not_nil(parsed)
            assert.equals("crlf_val", parsed["crlf_key"])
            assert.equals("space_val", parsed["space_key"])
        end
    end)

    it("falls back to default key or fallback table when missing", function()
        Localization.current_language = "en"
        Localization:loadTranslations()

        local fallback_val = Localization:t("non_existent_random_key")
        assert.equals("non_existent_random_key", fallback_val)
    end)
end)
