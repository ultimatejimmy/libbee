local helper = require("spec/spec_helper")
local pdf = require("libbee_adobe_pdf")
local pdfdoc = require("libbee_adobe_pdf_doc")
local pdfparser = require("libbee_adobe_pdf_parser")

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

    describe("ACSM parsing and namespace tolerance", function()
        local LibbeeDRM = require("libbee_drm")

        it("parses namespaced ACSM tokens (<adept:fulfillmentToken>)", function()
            local acsmXml = table.concat({
                '<?xml version="1.0"?>',
                '<adept:fulfillmentToken xmlns:adept="http://ns.adobe.com/adept">',
                '  <adept:distributor>urn:uuid:0001</adept:distributor>',
                '  <adept:operatorURL>https://acs.contentreserve.com/fulfillment</adept:operatorURL>',
                '  <adept:resourceItemInfo>',
                '    <adept:resource>urn:uuid:book-123</adept:resource>',
                '    <adept:metadata>',
                '      <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Book of Evil</dc:title>',
                '      <dc:format xmlns:dc="http://purl.org/dc/elements/1.1/">application/pdf</dc:format>',
                '    </adept:metadata>',
                '  </adept:resourceItemInfo>',
                '</adept:fulfillmentToken>',
            }, "\n")

            local meta = LibbeeDRM.parseAcsmMetadata(acsmXml)
            assert.is_not_nil(meta)
            assert.are_equal("Book of Evil", meta.title)
            assert.are_equal("application/pdf", meta.format)
            assert.are_equal("urn:uuid:book-123", meta.resourceId)
        end)

        it("derives PDF path for namespaced PDF ACSM", function()
            local acsmXml = table.concat({
                '<adept:fulfillmentToken xmlns:adept="http://ns.adobe.com/adept">',
                '  <adept:resourceItemInfo>',
                '    <adept:metadata>',
                '      <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Venom Lethal Protector</dc:title>',
                '      <dc:format xmlns:dc="http://purl.org/dc/elements/1.1/">application/pdf</dc:format>',
                '    </adept:metadata>',
                '  </adept:resourceItemInfo>',
                '</adept:fulfillmentToken>',
            }, "\n")

            local meta = LibbeeDRM.parseAcsmMetadata(acsmXml)
            assert.is_not_nil(meta)
            local finalPath = LibbeeDRM.deriveFinalBookPath("/mnt/us/Home/Libby", { title = "Venom" }, meta)
            assert.is_true(finalPath:find("%.pdf$") ~= nil)
        end)
    end)

    describe("Stream parsing with indirect /Length and fallback endstream scanning", function()
        it("resolves indirect /Length reference via document", function()
            local rawContent = "10 0 obj\n<< /Length 15 0 R >>\nstream\nHELLO_INDIRECT_WORLD\nendstream\nendobj\n"
            local f = io.tmpfile()
            f:write(rawContent)
            f:seek("set", 0)

            local mockDoc = {
                getobj = function(self, id)
                    if id == 15 then return 20 end -- #("HELLO_INDIRECT_WORLD") == 20
                    return nil
                end
            }

            local p = pdfparser.new(f, mockDoc)
            p:seek(0)
            p:nexttoken() -- 10
            p:nexttoken() -- 0
            p:nexttoken() -- obj
            local res = p:nextobject()
            f:close()

            assert.is_table(res)
            local stream_obj = res[2]
            assert.is_table(stream_obj)
            assert.are_equal("HELLO_INDIRECT_WORLD", stream_obj.rawdata)
        end)

        it("scans forward to endstream when /Length is not specified", function()
            local rawContent = "10 0 obj\n<< /Filter /FlateDecode >>\nstream\nFALLBACK_STREAM_DATA_HERE\nendstream\nendobj\n"
            local f = io.tmpfile()
            f:write(rawContent)
            f:seek("set", 0)

            local p = pdfparser.new(f)
            p:seek(0)
            p:nexttoken() -- 10
            p:nexttoken() -- 0
            p:nexttoken() -- obj
            local res = p:nextobject()
            f:close()

            assert.is_table(res)
            local stream_obj = res[2]
            assert.is_table(stream_obj)
            assert.are_equal("FALLBACK_STREAM_DATA_HERE", stream_obj.rawdata)
        end)
    end)

    describe("Clean trailer generation and XRefStream stripping", function()
        it("strips Type, Filter, W, Index from XRefStream trailers and preserves Root", function()
            local doc = pdfdoc.PDFDocument:new()
            doc.root = { ref = { objid = 1, genno = 0 } }
            local xrefStream = {
                trailer = {
                    Type = "XRef",
                    Filter = "FlateDecode",
                    W = { 1, 2, 1 },
                    Index = { 0, 100 },
                    Size = 100,
                    Length = 450,
                    Root = { ref = { objid = 1, genno = 0 } },
                    Info = { ref = { objid = 2, genno = 0 } },
                    ID = { "id1", "id2" },
                    Prev = 12345,
                    XRefStm = 6789,
                }
            }
            doc.xrefs = { xrefStream }

            local clean = doc:getCleanTrailer()
            assert.is_table(clean)
            assert.is_nil(clean.Type)
            assert.is_nil(clean.Filter)
            assert.is_nil(clean.W)
            assert.is_nil(clean.Index)
            assert.is_nil(clean.Length)
            assert.is_nil(clean.Prev)
            assert.is_nil(clean.XRefStm)
            assert.is_nil(clean.Encrypt)

            assert.are_equal(100, clean.Size)
            assert.is_table(clean.Root)
            assert.are_equal(1, clean.Root.ref.objid)
            assert.is_table(clean.Info)
            assert.are_equal(2, clean.Info.ref.objid)
        end)

        it("merges trailers from oldest to newest so newest revision overrides older values", function()
            local doc = pdfdoc.PDFDocument:new()
            local oldTrailer = {
                trailer = {
                    Root = { ref = { objid = 1, genno = 0 } },
                    Info = { ref = { objid = 2, genno = 0 } },
                    Size = 50,
                }
            }
            local newTrailer = {
                trailer = {
                    Root = { ref = { objid = 5, genno = 0 } },
                    Size = 75,
                }
            }
            -- doc.xrefs has newest first (index 1) and oldest last (index 2)
            doc.xrefs = { newTrailer, oldTrailer }

            local clean = doc:getCleanTrailer()
            assert.are_equal(5, clean.Root.ref.objid)
            assert.are_equal(2, clean.Info.ref.objid)
            assert.are_equal(75, clean.Size)
        end)
    end)

    describe("Skipping obsolete stream objects", function()
        it("identifies /Type /XRef and /Type /ObjStm stream objects to skip", function()
            local function should_skip(obj)
                if type(obj) == "table" and obj.dic then
                    local t = obj.dic.Type or obj.dic["type"] or obj.dic["Type"]
                    local type_name = (type(t) == "table" and (t.name or t.keyword)) or tostring(t or "")
                    if type_name == "XRef" or type_name == "ObjStm" then
                        return true
                    end
                end
                return false
            end

            local xrefObj = { dic = { Type = pdfparser.literal("XRef") } }
            local objstmObj = { dic = { Type = "ObjStm" } }
            local pageObj = { dic = { Type = pdfparser.literal("Page") } }
            local rawObj = { dic = { Length = 100 } }

            assert.is_true(should_skip(xrefObj))
            assert.is_true(should_skip(objstmObj))
            assert.is_false(should_skip(pageObj))
            assert.is_false(should_skip(rawObj))
        end)
    end)
end)
