-- libbee_nativecrypto_spec.lua
require("spec.spec_helper")

describe("libbee_adobe_nativecrypto soname resolution & safety", function()
    local ffi = require("ffi")
    local orig_loadlib = ffi.loadlib
    local orig_load = ffi.load

    after_each(function()
        ffi.loadlib = orig_loadlib
        ffi.load = orig_load
        package.loaded["libbee_adobe_nativecrypto"] = nil
        package.preload["libbee_adobe_nativecrypto"] = nil
    end)

    it("loads cleanly when KOReader only provides libcrypto.so.55 (v2025.04 behavior)", function()
        local requested_versions = {}
        local mock_lib = {
            RAND_bytes = function(buf, n) return 1 end,
        }

        ffi.loadlib = function(...)
            local args = { ... }
            for i = 1, #args, 2 do
                local name = args[i]
                local ver = args[i + 1]
                table.insert(requested_versions, ver)
                -- Simulate KOReader having libcrypto.so.55 but not 57
                if ver == "55" then
                    return mock_lib
                end
            end
            error("No library found")
        end

        package.loaded["libbee_adobe_nativecrypto"] = nil
        package.preload["libbee_adobe_nativecrypto"] = nil

        local ok, nativecrypto = pcall(require, "libbee_adobe_nativecrypto")
        assert.is_truthy(ok)
        assert.is_not_nil(nativecrypto)
        assert.is_truthy(nativecrypto.is_available())
        -- Ensure version 55 was among the probed versions
        local found_55 = false
        for _, v in ipairs(requested_versions) do
            if v == "55" then found_55 = true end
        end
        assert.is_truthy(found_55)
    end)

    it("does not crash when no compatible libcrypto is available and reports unavailable", function()
        ffi.loadlib = function()
            error("cannot find library")
        end
        ffi.load = function(name)
            error("cannot load " .. tostring(name))
        end

        package.loaded["libbee_adobe_nativecrypto"] = nil
        package.preload["libbee_adobe_nativecrypto"] = nil

        local ok, nativecrypto = pcall(require, "libbee_adobe_nativecrypto")
        assert.is_truthy(ok)
        assert.is_not_nil(nativecrypto)
        assert.is_falsy(nativecrypto.is_available())

        local res, err = nativecrypto.rand_bytes(16)
        assert.is_nil(res)
        assert.are.equal("libcrypto library is not available", err)
    end)
end)
