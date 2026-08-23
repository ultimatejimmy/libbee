-- libbee_zlib_spec.lua
require("spec.spec_helper")

describe("adobe.util.zlib FFI safety", function()
    it("loads cleanly even when ffi.cdef is invoked multiple times or types are pre-declared", function()
        -- Simulate FFI cdef throwing redefinition error for pre-declared types
        local ffi = require("ffi")
        local orig_cdef = ffi.cdef
        local cdef_calls = {}
        ffi.cdef = function(s)
            table.insert(cdef_calls, s)
            if s:find("z_stream_s", 1, true) then
                error("attempt to redefine 'z_stream_s' at line 9")
            end
        end

        package.loaded["adobe/util/zlib"] = nil
        package.loaded["adobe.util.zlib"] = nil

        local ok, zlib = pcall(require, "adobe.util.zlib")
        ffi.cdef = orig_cdef

        assert.is_truthy(ok)
        assert.is_not_nil(zlib)
        assert.is_function(zlib.inflateRaw)
        assert.is_function(zlib.rawInflater)
        assert.is_function(zlib.inflater)
    end)
end)
