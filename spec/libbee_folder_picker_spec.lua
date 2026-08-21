require("spec/spec_helper")

package.path = "libbee.koplugin/?.lua;" .. package.path

local LibbeeFolderPicker = require("libbee_folder_picker")

describe("LibbeeFolderPicker", function()
    describe("getParentPath", function()
        it("returns nil for root, nil, or empty paths", function()
            assert.is_nil(LibbeeFolderPicker.getParentPath(nil))
            assert.is_nil(LibbeeFolderPicker.getParentPath(""))
            assert.is_nil(LibbeeFolderPicker.getParentPath("/"))
            assert.is_nil(LibbeeFolderPicker.getParentPath("   "))
        end)

        it("correctly finds parent directory for nested unix paths", function()
            assert.are.same("/mnt/onboard", LibbeeFolderPicker.getParentPath("/mnt/onboard/screensavers"))
            assert.are.same("/mnt/onboard", LibbeeFolderPicker.getParentPath("/mnt/onboard/screensavers/"))
            assert.are.same("/mnt", LibbeeFolderPicker.getParentPath("/mnt/onboard"))
            assert.are.same("/", LibbeeFolderPicker.getParentPath("/mnt"))
        end)

        it("handles windows-style drive roots gracefully", function()
            assert.are.same("C:/Users", LibbeeFolderPicker.getParentPath("C:/Users/Screensavers"))
            assert.are.same("C:", LibbeeFolderPicker.getParentPath("C:/Users"))
            assert.is_nil(LibbeeFolderPicker.getParentPath("C:"))
        end)
    end)

    describe("scanDirectory", function()
        it("returns subdirectories and counts books", function()
            local mock_files = {
                ["/test/books"] = { "nature", "abstract", "great_gatsby.epub", "dracula.pdf", "notes.txt" },
            }

            local mock_dirs = {
                ["/test/books"] = true,
                ["/test/books/nature"] = true,
                ["/test/books/abstract"] = true,
            }

            local lfs = {
                dir = function(path)
                    local files = mock_files[path] or {}
                    local i = 0
                    return function()
                        i = i + 1
                        return files[i]
                    end
                end,
                attributes = function(path, mode)
                    if mock_dirs[path] then
                        return { mode = "directory", modification = 1700000000 }
                    else
                        return { mode = "file", size = 1024, modification = 1700000000 }
                    end
                end,
            }
            package.loaded["libs/libkoreader-lfs"] = lfs

            local subdirs, book_count = LibbeeFolderPicker.scanDirectory("/test/books")
            assert.are.same(2, book_count) -- great_gatsby.epub and dracula.pdf
            assert.are.same(2, #subdirs)
            assert.are.same("abstract", subdirs[1].name)
            assert.are.same("nature", subdirs[2].name)
        end)
    end)

    describe("show", function()
        it("instantiates UI and runs refresh without errors", function()
            local UIManager = require("ui/uimanager")
            local shown_widget = nil
            local orig_show = UIManager.show
            UIManager.show = function(self, widget)
                shown_widget = widget
            end

            local confirmed_path = nil
            LibbeeFolderPicker.show{
                title = "Select Download Folder",
                initial_path = "/test/books",
                on_confirm = function(path)
                    confirmed_path = path
                end,
            }

            assert.is_true(shown_widget ~= nil)
            UIManager.show = orig_show
        end)
    end)
end)
