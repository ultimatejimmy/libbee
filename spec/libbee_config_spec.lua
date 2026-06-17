-- libbee_config_spec.lua
require("spec.spec_helper")
local config = require("libbee_config")

describe("libbee_config", function()
    it("is a table", function()
        assert.is_table(config)
    end)

    it("defines the expected configuration keys", function()
        assert.is_not_nil(config.library_id)
        assert.is_not_nil(config.card_number)
        assert.is_not_nil(config.setup_code)
        assert.is_not_nil(config.bearer_token)
        assert.is_not_nil(config.download_dir)
    end)
end)
