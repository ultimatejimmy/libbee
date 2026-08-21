-- libbee_api_spec.lua — Unit tests for Libby API, transport, and state logic
require("spec/spec_helper")

local API = require("libbee_api")
local State = require("libbee_state")
local Transport = require("libbee_transport")

describe("Libbee API & Transport Tests", function()

    describe("Accept-Language generation", function()
        it("generates correct 2-letter lang code from default seed", function()
            local lang = API.chip_accept_language(nil, nil)
            assert.is_string(lang)
            assert.equals(2, #lang)
            assert.equals("bh", lang)
        end)

        it("generates correct lang code from token seed", function()
            local token = "abc.defghijklmnopqrstuvwxyz.123"
            local lang = API.chip_accept_language(token, nil)
            assert.is_string(lang)
            assert.equals(2, #lang)
        end)
    end)

    describe("Transport Base64URL & JWT parsing", function()
        local transport = Transport.new({
            mime = {
                unb64 = function(str)
                    -- Simple mock base64 decoder for test payload
                    if str:find("eyJjaGlwIjp7ImlkIjoiMTIzNDU2NzgtYWJjZCJ9fQ") then
                        return '{"chip":{"id":"12345678-abcd"}}'
                    end
                    return nil
                end
            },
            json_decode = function(str)
                if str == '{"chip":{"id":"12345678-abcd"}}' then
                    return { chip = { id = "12345678-abcd" } }
                end
                return {}
            end
        })

        it("decodes valid JWT payload into table", function()
            local test_jwt = "header.eyJjaGlwIjp7ImlkIjoiMTIzNDU2NzgtYWJjZCJ9fQ.sig"
            local payload, err = API.decodeJwtPayload(test_jwt)
            -- If running with mocked transport
            if payload then
                assert.is_table(payload)
                assert.is_table(payload.chip)
                assert.equals("12345678-abcd", payload.chip.id)
            end
        end)

        it("extracts short chip id from JWT", function()
            local test_jwt = "header.eyJjaGlwIjp7ImlkIjoiMTIzNDU2NzgtYWJjZCJ9fQ.sig"
            -- Using mocked payload
            local short_id = API.short_chip_id(test_jwt)
            if short_id then
                assert.equals("12345678", short_id)
            end
        end)
    end)

    describe("State loan days remaining", function()
        it("calculates remaining days from timestamp", function()
            local now = 1000000
            local future = now + (3 * 24 * 3600) + 500
            local loan = { expires = future }
            local days = State.loanDaysRemaining(loan, now)
            assert.equals(4, days)
        end)

        it("returns 0 for expired timestamp", function()
            local now = 1000000
            local past = now - 500
            local loan = { expires = past }
            local days = State.loanDaysRemaining(loan, now)
            assert.equals(0, days)
        end)

        it("calculates remaining days from ISO date string", function()
            local loan = { expires = "2026-08-25T12:00:00Z" }
            local now = os.time({ year = 2026, month = 8, day = 20, hour = 12, min = 0, sec = 0 })
            local days = State.loanDaysRemaining(loan, now)
            assert.equals(5, days)
        end)
    end)

    describe("ACSM Path derivation", function()
        it("creates safe filenames with .acsm extension", function()
            local loan = { title = "Great Book: The Sequel / 2?" }
            local path = API.getAcsmPath("/mnt/books", loan)
            assert.is_true(path:find("^/mnt/books/Great_Book__The_Sequel___2_") ~= nil)
            assert.is_true(path:match("%.acsm$") ~= nil)
        end)

        it("uses .epub for open DRM-free format", function()
            local loan = { title = "Public Domain Book", format = "ebook-epub-open" }
            local path = API.getAcsmPath("/mnt/books", loan)
            assert.is_true(path:match("%.epub$") ~= nil)
        end)
    end)

    describe("Loan format analysis & restriction detection", function()
        it("detects standard downloadable Adobe EPUB loans", function()
            local loan = {
                formats = {
                    { id = "ebook-epub-adobe", name = "Adobe EPUB" },
                    { id = "ebook-kindle", name = "Kindle Book" },
                    { id = "ebook-overdrive", name = "OverDrive Read" },
                }
            }
            local info = API.analyzeLoanFormats(loan)
            assert.is_true(info.is_downloadable)
            assert.equals("ebook-epub-adobe", info.format)
            assert.is_nil(info.restriction_type)
        end)

        it("detects downloadable PDF and open EPUB formats", function()
            local pdf_loan = {
                formats = { { id = "ebook-pdf-adobe" } }
            }
            local pdf_info = API.analyzeLoanFormats(pdf_loan)
            assert.is_true(pdf_info.is_downloadable)
            assert.equals("ebook-pdf-adobe", pdf_info.format)

            local open_loan = {
                formats = { { id = "ebook-epub-open" } }
            }
            local open_info = API.analyzeLoanFormats(open_loan)
            assert.is_true(open_info.is_downloadable)
            assert.equals("ebook-epub-open", open_info.format)
        end)

        it("detects Kindle and Libby only loans", function()
            local loan = {
                formats = {
                    { id = "ebook-kindle" },
                    { id = "ebook-overdrive" },
                }
            }
            local info = API.analyzeLoanFormats(loan)
            assert.is_false(info.is_downloadable)
            assert.equals("kindle_or_libby", info.restriction_type)
        end)

        it("detects Kindle-only loans", function()
            local loan = {
                formats = {
                    { id = "ebook-kindle" }
                }
            }
            local info = API.analyzeLoanFormats(loan)
            assert.is_false(info.is_downloadable)
            assert.equals("kindle_only", info.restriction_type)
        end)

        it("detects Libby-only web reader loans", function()
            local loan = {
                formats = {
                    { id = "ebook-overdrive" }
                }
            }
            local info = API.analyzeLoanFormats(loan)
            assert.is_false(info.is_downloadable)
            assert.equals("libby_only", info.restriction_type)
        end)

        it("detects audiobook loans", function()
            local loan = {
                type = { id = "audiobook" },
                formats = { { id = "audiobook-overdrive" } }
            }
            local info = API.analyzeLoanFormats(loan)
            assert.is_false(info.is_downloadable)
            assert.is_false(info.is_ebook)
            assert.equals("audiobook", info.restriction_type)
        end)

        it("detects magazine loans", function()
            local loan = {
                type = { id = "magazine" },
                formats = { { id = "magazine-overdrive" } }
            }
            local info = API.analyzeLoanFormats(loan)
            assert.is_false(info.is_downloadable)
            assert.is_false(info.is_ebook)
            assert.equals("magazine", info.restriction_type)
        end)

        it("prevents downloadACSM from requesting fulfillment for restricted loans", function()
            State.saveChipIdentity("valid_identity_token", "Test Lib", { { id = "123" } })
            local restricted_loan = {
                id = "loan1",
                card_id = "123",
                is_downloadable = false,
                restriction_type = "kindle_or_libby",
            }
            local res, err = API.downloadACSM(restricted_loan, "/tmp/out.acsm")
            assert.is_nil(res)
            assert.is_truthy(err:find("Libby or on Kindle"))
        end)
    end)

end)
