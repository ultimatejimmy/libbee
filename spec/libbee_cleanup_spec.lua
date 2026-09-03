-- libbee_cleanup_spec.lua
require("spec.spec_helper")

package.path = "libbee.koplugin/?.lua;" .. package.path

local Cleanup = require("libbee_cleanup")

describe("libbee_cleanup", function()
    local orig_lfs
    local orig_os_remove

    before_each(function()
        orig_lfs = package.loaded["libs/libkoreader-lfs"]
        orig_os_remove = os.remove
    end)

    after_each(function()
        package.loaded["libs/libkoreader-lfs"] = orig_lfs
        package.loaded["lfs"] = orig_lfs
        os.remove = orig_os_remove
    end)

    it("cleans up deprecated directories and duplicate files when replacements exist", function()
        local mock_fs = {
            ["/plugin/adobe"] = { is_dir = true, children = { "adobe.lua", "epub.lua", "pdf" } },
            ["/plugin/adobe/pdf"] = { is_dir = true, children = { "parser.lua" } },
            ["/plugin/adobe/pdf/parser.lua"] = { is_dir = false },
            ["/plugin/adobe/adobe.lua"] = { is_dir = false },
            ["/plugin/adobe/epub.lua"] = { is_dir = false },
            ["/plugin/dependencies"] = { is_dir = true, children = { "XmlParser.lua", "xml2lua.lua" } },
            ["/plugin/dependencies/XmlParser.lua"] = { is_dir = false },
            ["/plugin/dependencies/xml2lua.lua"] = { is_dir = false },
            ["/plugin/localization_libbee.lua"] = { is_dir = false },
            ["/plugin/libbee_config.lua"] = { is_dir = false },
            -- Replacement files exist:
            ["/plugin/libbee_adobe_core.lua"] = { is_dir = false },
            ["/plugin/libbee_xml2lua.lua"] = { is_dir = false },
            ["/plugin/libbee_localization.lua"] = { is_dir = false },
            ["/plugin/libbee_state.lua"] = { is_dir = false },
            -- Regular plugin files that must NOT be touched:
            ["/plugin/main.lua"] = { is_dir = false },
            ["/plugin/_meta.lua"] = { is_dir = false },
            ["/plugin/assets"] = { is_dir = true, children = { "bee.png" } },
            ["/plugin/assets/bee.png"] = { is_dir = false },
        }

        local deleted_items = {}

        local mock_lfs = {
            attributes = function(path, req)
                local item = mock_fs[path]
                if not item then return nil end
                local mode = item.is_dir and "directory" or "file"
                if req == "mode" then return mode end
                return { mode = mode }
            end,
            dir = function(path)
                local item = mock_fs[path]
                if not item or not item.is_dir then return function() return nil end end
                local children = item.children or {}
                local i = 0
                return function()
                    i = i + 1
                    return children[i]
                end
            end,
            rmdir = function(path)
                if mock_fs[path] and mock_fs[path].is_dir then
                    mock_fs[path] = nil
                    table.insert(deleted_items, "rmdir:" .. path)
                    return true
                end
                return false
            end
        }
        package.loaded["libs/libkoreader-lfs"] = mock_lfs
        package.loaded["lfs"] = mock_lfs

        os.remove = function(path)
            if mock_fs[path] then
                mock_fs[path] = nil
                table.insert(deleted_items, "remove:" .. path)
                return true
            end
            return false
        end

        local res = Cleanup.cleanDeprecated("/plugin")

        -- Verify results reported deleted folders & files
        assert.is_table(res.deleted_folders)
        assert.is_table(res.deleted_files)

        -- Check that adobe and dependencies were marked deleted
        local found_adobe = false
        local found_deps = false
        for _, f in ipairs(res.deleted_folders) do
            if f == "adobe" then found_adobe = true end
            if f == "dependencies" then found_deps = true end
        end
        assert.is_true(found_adobe)
        assert.is_true(found_deps)

        -- Check that localization_libbee.lua and libbee_config.lua were deleted
        local found_loc = false
        local found_cfg = false
        for _, f in ipairs(res.deleted_files) do
            if f == "localization_libbee.lua" then found_loc = true end
            if f == "libbee_config.lua" then found_cfg = true end
        end
        assert.is_true(found_loc)
        assert.is_true(found_cfg)

        -- Verify non-deprecated files were NOT deleted
        assert.is_not_nil(mock_fs["/plugin/main.lua"])
        assert.is_not_nil(mock_fs["/plugin/_meta.lua"])
        assert.is_not_nil(mock_fs["/plugin/libbee_adobe_core.lua"])
        assert.is_not_nil(mock_fs["/plugin/libbee_xml2lua.lua"])
        assert.is_not_nil(mock_fs["/plugin/libbee_localization.lua"])
        assert.is_not_nil(mock_fs["/plugin/libbee_state.lua"])
        assert.is_not_nil(mock_fs["/plugin/assets"])
        assert.is_not_nil(mock_fs["/plugin/assets/bee.png"])
    end)

    it("does NOT delete deprecated directories or files if replacement is missing", function()
        local mock_fs = {
            ["/plugin/adobe"] = { is_dir = true, children = { "adobe.lua" } },
            ["/plugin/adobe/adobe.lua"] = { is_dir = false },
            ["/plugin/dependencies"] = { is_dir = true, children = { "xml2lua.lua" } },
            ["/plugin/dependencies/xml2lua.lua"] = { is_dir = false },
            ["/plugin/localization_libbee.lua"] = { is_dir = false },
            -- Notice: libbee_adobe_core.lua, libbee_xml2lua.lua, libbee_localization.lua do NOT exist!
        }

        local mock_lfs = {
            attributes = function(path, req)
                local item = mock_fs[path]
                if not item then return nil end
                local mode = item.is_dir and "directory" or "file"
                if req == "mode" then return mode end
                return { mode = mode }
            end,
            dir = function(path)
                local item = mock_fs[path]
                if not item or not item.is_dir then return function() return nil end end
                local children = item.children or {}
                local i = 0
                return function()
                    i = i + 1
                    return children[i]
                end
            end,
        }
        package.loaded["libs/libkoreader-lfs"] = mock_lfs
        package.loaded["lfs"] = mock_lfs

        os.remove = function(path)
            mock_fs[path] = nil
            return true
        end

        local res = Cleanup.cleanDeprecated("/plugin")

        -- Nothing should be deleted because replacements are missing
        assert.are.equal(0, #res.deleted_folders)
        assert.are.equal(0, #res.deleted_files)
        assert.is_not_nil(mock_fs["/plugin/adobe"])
        assert.is_not_nil(mock_fs["/plugin/dependencies"])
        assert.is_not_nil(mock_fs["/plugin/localization_libbee.lua"])
    end)

    it("is idempotent when run on already-cleaned directory", function()
        local mock_fs = {
            ["/plugin/libbee_adobe_core.lua"] = { is_dir = false },
            ["/plugin/libbee_xml2lua.lua"] = { is_dir = false },
            ["/plugin/libbee_localization.lua"] = { is_dir = false },
            ["/plugin/main.lua"] = { is_dir = false },
        }

        local mock_lfs = {
            attributes = function(path, req)
                local item = mock_fs[path]
                if not item then return nil end
                local mode = item.is_dir and "directory" or "file"
                if req == "mode" then return mode end
                return { mode = mode }
            end,
        }
        package.loaded["libs/libkoreader-lfs"] = mock_lfs
        package.loaded["lfs"] = mock_lfs

        local res = Cleanup.cleanDeprecated("/plugin")
        assert.are.equal(0, #res.deleted_folders)
        assert.are.equal(0, #res.deleted_files)
    end)

    it("cleans temporary fulfillment binaries, epub work dirs, and progress files", function()
        local mock_fs = {
            ["/data/cache/acsm.koplugin"] = {
                is_dir = true,
                children = { "fulfillment-12345678-999.bin", "fulfillment-temp.bin", "epub-work-123", "normal.txt" }
            },
            ["/data/cache/acsm.koplugin/fulfillment-12345678-999.bin"] = { is_dir = false },
            ["/data/cache/acsm.koplugin/fulfillment-temp.bin"] = { is_dir = false },
            ["/data/cache/acsm.koplugin/epub-work-123"] = { is_dir = true, children = { "item.xml" } },
            ["/data/cache/acsm.koplugin/epub-work-123/item.xml"] = { is_dir = false },
            ["/data/cache/acsm.koplugin/normal.txt"] = { is_dir = false },
            ["/data/cache"] = {
                is_dir = true,
                children = { ".libbee_prog_111", ".temp_dl_prog_222", "acsm.koplugin", "important_cache.lua" }
            },
            ["/data/cache/.libbee_prog_111"] = { is_dir = false },
            ["/data/cache/.temp_dl_prog_222"] = { is_dir = false },
            ["/data/cache/important_cache.lua"] = { is_dir = false },
            ["/downloads"] = {
                is_dir = true,
                children = { ".temp_123.acsm", "Great_Book.epub", ".libbee_prog_333" }
            },
            ["/downloads/.temp_123.acsm"] = { is_dir = false },
            ["/downloads/Great_Book.epub"] = { is_dir = false },
            ["/downloads/.libbee_prog_333"] = { is_dir = false },
        }

        local deleted_items = {}
        local mock_lfs = {
            attributes = function(path, req)
                local item = mock_fs[path]
                if not item then return nil end
                local mode = item.is_dir and "directory" or "file"
                if req == "mode" then return mode end
                return { mode = mode }
            end,
            dir = function(path)
                local item = mock_fs[path]
                if not item or not item.is_dir then return function() return nil end end
                local children = item.children or {}
                local i = 0
                return function()
                    i = i + 1
                    return children[i]
                end
            end,
            rmdir = function(p)
                mock_fs[p] = nil
                table.insert(deleted_items, p)
                return true
            end
        }
        package.loaded["libs/libkoreader-lfs"] = mock_lfs
        package.loaded["lfs"] = mock_lfs

        os.remove = function(p)
            mock_fs[p] = nil
            table.insert(deleted_items, p)
            return true
        end

        package.loaded["datastorage"] = {
            getDataDir = function() return "/data" end
        }

        local res = Cleanup.cleanTempFiles("/downloads")

        -- Verify temp files and work dirs were deleted
        assert.is_nil(mock_fs["/data/cache/acsm.koplugin/fulfillment-12345678-999.bin"])
        assert.is_nil(mock_fs["/data/cache/acsm.koplugin/fulfillment-temp.bin"])
        assert.is_nil(mock_fs["/data/cache/acsm.koplugin/epub-work-123"])
        assert.is_nil(mock_fs["/data/cache/.libbee_prog_111"])
        assert.is_nil(mock_fs["/data/cache/.temp_dl_prog_222"])
        assert.is_nil(mock_fs["/downloads/.temp_123.acsm"])
        assert.is_nil(mock_fs["/downloads/.libbee_prog_333"])

        -- Verify non-temp user data was NOT touched
        assert.is_not_nil(mock_fs["/data/cache/acsm.koplugin/normal.txt"])
        assert.is_not_nil(mock_fs["/data/cache/important_cache.lua"])
        assert.is_not_nil(mock_fs["/downloads/Great_Book.epub"])

        package.loaded["datastorage"] = nil
    end)
end)
