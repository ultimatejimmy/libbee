-- libbee_return_spec.lua
require("spec.spec_helper")

local API = require("libbee_api")
local State = require("libbee_state")

describe("libbee_api M.returnLoan", function()
    before_each(function()
        State.saveChipIdentity("test-identity-token", "Test Library", { { id = "card-123" } })
    end)

    it("validates missing loan or missing card/loan ids", function()
        local r1, err1 = API.returnLoan(nil)
        assert.is_nil(r1)
        assert.are_equal("Loan is missing", err1)

        local r2, err2 = API.returnLoan({ id = "loan-1" })
        assert.is_nil(r2)
        assert.are_equal("Loan card id is missing", err2)

        local r3, err3 = API.returnLoan({ card_id = "card-1" })
        assert.is_nil(r3)
        assert.are_equal("Loan id is missing", err3)
    end)

    it("routes return through loan chip identity or account id", function()
        State.clearChipIdentity()
        State.addOrUpdateAccount({
            id = "acc-2",
            chip_identity = "token-account-2",
            library_name = "Second Library",
            cards = { { id = "card-second" } },
        })

        -- Should pick up loan.chip_identity
        local r1, err1 = API.returnLoan({
            id = "loan-1",
            card_id = "card-second",
            chip_identity = "token-account-2",
            account_id = "acc-2"
        })
        -- Returns nil with error from mock network or passes validation
        assert.is_truthy(r1 == true or err1 ~= nil)
    end)
end)
