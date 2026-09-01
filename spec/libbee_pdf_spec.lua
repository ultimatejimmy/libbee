local helper = require("spec/spec_helper")
local pdf = require("adobe.pdf")
local pdfdoc = require("adobe.pdf.pdfdoc")
local pdfparser = require("adobe.pdf.parser")

describe("PDF DRM and Decryption", function()
    local testDir = "spec/tmp_pdf"

    before_each(function()
        os.execute("mkdir -p " .. testDir .. " 2>/dev/null")
    end)

    after_each(function()
        os.execute("rm -rf " .. testDir .. " 2>/dev/null")
    end)

    describe("copyFile helper", function()
        it("copies binary data accurately between files", function()
            local srcPath = testDir .. "/src.bin"
            local dstPath = testDir .. "/dst.bin"

            local f = io.open(srcPath, "wb")
            local testData = "%PDF-1.4\nTest content for binary stream copy\0\1\2\255"
            f:write(testData)
            f:close()

            local ok, err = pdf._copyFile(srcPath, dstPath)
            assert.is_true(ok)

            local inF = io.open(dstPath, "rb")
            local readBack = inF:read("*a")
            inF:close()

            assert.are_equal(testData, readBack)
        end)
    end)

    describe("Unencrypted (DRM-free) PDF handling", function()
        it("passes through unencrypted PDF without failing on missing /Encrypt dict", function()
            local inputPath = testDir .. "/unencrypted.pdf"
            local outputPath = testDir .. "/output.pdf"

            -- Create a minimal valid unencrypted PDF
            local pdfContent = table.concat({
                "%PDF-1.4",
                "1 0 obj",
                "<< /Type /Catalog /Pages 2 0 R >>",
                "endobj",
                "2 0 obj",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "endobj",
                "3 0 obj",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
                "endobj",
                "xref",
                "0 4",
                "0000000000 65535 f ",
                "0000000009 00000 n ",
                "0000000058 00000 n ",
                "0000000115 00000 n ",
                "trailer",
                "<< /Size 4 /Root 1 0 R >>",
                "startxref",
                "187",
                "%%EOF",
            }, "\n")

            local f = io.open(inputPath, "wb")
            f:write(pdfContent)
            f:close()

            local fakeLicenseKey = {
                pkey = {
                    decrypt = function() return "fakekey" end
                }
            }

            local result, err = pdf.decryptAdobePdf(inputPath, outputPath, nil, fakeLicenseKey, "fakeFulfillmentKey")
            assert.is_nil(err)
            assert.is_table(result)
            assert.is_true(result.unencrypted)
            assert.are_equal(0, result.decryptedObjects)
            assert.are_equal(0, result.decryptedStreams)
            assert.are_equal(outputPath, result.outputPath)

            local outF = io.open(outputPath, "rb")
            assert.is_not_nil(outF)
            local readBack = outF:read("*a")
            outF:close()
            assert.are_equal(pdfContent, readBack)
        end)
    end)

    describe("PDFDocument: _find_xref", function()
        it("finds startxref on small PDF files (< 1KB)", function()
            local pdfPath = testDir .. "/small.pdf"
            local content = "%PDF-1.4\n...xref...\nstartxref\n123\n%%EOF\n"
            local f = io.open(pdfPath, "wb")
            f:write(content)
            f:close()

            local doc = pdfdoc.PDFDocument:new()
            doc.file = io.open(pdfPath, "rb")
            local pos, err = doc:_find_xref()
            doc:close()

            assert.is_nil(err)
            assert.are_equal(123, pos)
        end)

        it("picks the last startxref when multiple revisions exist", function()
            local pdfPath = testDir .. "/revisions.pdf"
            local content = "%PDF-1.4\nstartxref\n100\n%%EOF\nstartxref\n500\n%%EOF\n"
            local f = io.open(pdfPath, "wb")
            f:write(content)
            f:close()

            local doc = pdfdoc.PDFDocument:new()
            doc.file = io.open(pdfPath, "rb")
            local pos, err = doc:_find_xref()
            doc:close()

            assert.is_nil(err)
            assert.are_equal(500, pos)
        end)
    end)

    describe("Multi-trailer / Incremental Updates", function()
        it("preserves /Encrypt from previous trailer when newest trailer only contains /Root", function()
            local doc = pdfdoc.PDFDocument:new()
            local encDict = { Filter = pdfparser.literal("EBX_HANDLER"), V = 4 }
            doc._loadRawObject = function(self, objid)
                if objid == 10 then return encDict end
                return nil
            end

            local xref1 = {
                trailer = {
                    Root = { ref = { objid = 1, genno = 0 } },
                    Prev = 100,
                    Size = 15,
                }
            }
            local xref2 = {
                trailer = {
                    Encrypt = { ref = { objid = 10, genno = 0 } },
                    Root = { ref = { objid = 1, genno = 0 } },
                    Size = 12,
                }
            }

            doc.xrefs = { xref1, xref2 }

            for _, xref in ipairs(doc.xrefs) do
                local trailer = xref.trailer
                if trailer then
                    if not doc.trailer then doc.trailer = trailer end
                    if not doc.encryption and (trailer.Encrypt or trailer["Encrypt"]) then
                        local encryptRef = trailer.Encrypt or trailer["Encrypt"]
                        if type(encryptRef) == "table" and encryptRef.ref then
                            doc.encrypt_objid = encryptRef.ref.objid
                        end
                        local encObj = doc:_loadRawObject(encryptRef.ref.objid)
                        doc.encryption = {
                            docid = {},
                            param = encObj or {},
                        }
                    end
                    if not doc.root and (trailer.Root or trailer["Root"]) then
                        doc.root = trailer.Root or trailer["Root"]
                    end
                end
            end

            assert.is_not_nil(doc.root)
            assert.is_not_nil(doc.encryption)
            assert.are_equal(10, doc.encrypt_objid)
            assert.are_equal("EBX_HANDLER", doc:getEncryptionFilter())
        end)
    end)

    describe("Stream-based Encrypt dictionaries", function()
        it("extracts Filter and ADEPT_LICENSE when param is a PDFStream", function()
            local doc = pdfdoc.PDFDocument:new()
            local streamObj = {
                dic = {
                    Filter = pdfparser.literal("EBX_HANDLER"),
                    EBX_BOOKID = "urn:uuid:test-book-123",
                },
                rawdata = "sample-raw-adept-license-data",
            }
            doc.encryption = {
                docid = {},
                param = streamObj,
            }

            assert.are_equal("EBX_HANDLER", doc:getEncryptionFilter())

            local lic, bookid = doc:extractAdeptLicense()
            assert.are_equal("sample-raw-adept-license-data", lic)
            assert.are_equal("urn:uuid:test-book-123", bookid)
        end)
    end)
end)
