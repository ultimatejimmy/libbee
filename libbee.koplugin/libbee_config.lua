-- Libbee Configuration
-- Edit this file to configure your Libby library access.
-- This file is safe to edit manually while KOReader is not running.

return {
    -- -----------------------------------------------------------------------
    -- LIBRARY SETUP (Required)
    -- -----------------------------------------------------------------------

    -- Your library's OverDrive website subdomain.
    -- Example: if your library is at "seattle.overdrive.com", enter "seattle".
    -- You can find this by visiting your library's Libby/OverDrive website.
    library_id = "",

    -- Your library card number (barcode on the back of your card).
    -- This is pre-filled into the login dialog to save typing on the e-ink keyboard.
    card_number = "",

    -- -----------------------------------------------------------------------
    -- PRIMARY AUTHENTICATION (Recommended: Libby Setup Code)
    -- -----------------------------------------------------------------------
    -- 1. Open the Libby app on your phone or computer.
    -- 2. Tap the menu (☰) → Settings → Copy Library To Another Device.
    -- 3. Tap "Get Code" — note the 8-digit code shown.
    -- 4. Paste that code below, then use "Libbee → Setup → Authenticate with Code"
    --    in KOReader.
    -- The code is single-use. After setup, your chip identity is stored automatically
    -- and this field is no longer needed (you can leave it or clear it).
    setup_code = "",

    -- -----------------------------------------------------------------------
    -- FALLBACK AUTHENTICATION (Manual Bearer Token)
    -- -----------------------------------------------------------------------
    -- If the setup code flow fails, you can paste a Bearer token here directly.
    --
    -- How to get your token:
    -- 1. Open libbyapp.com in a browser and sign in.
    -- 2. Open DevTools (F12) → Network tab.
    -- 3. Reload the page and look for requests to "sentry-read.svc.overdrive.com".
    -- 4. Click any such request → Headers → find "Authorization: Bearer XXXXX..."
    -- 5. Copy everything after "Bearer " and paste it below.
    --
    -- Tokens expire after a few weeks. If you get auth errors, repeat the steps above.
    bearer_token = "",

    -- -----------------------------------------------------------------------
    -- DOWNLOAD SETTINGS
    -- -----------------------------------------------------------------------

    -- Folder where downloaded .acsm files will be saved.
    -- Leave blank to use KOReader's default storage root (recommended).
    -- Example: "/mnt/us/documents/Libby" (Kindle)
    -- Example: "/mnt/onboard/Libby" (Kobo)
    download_dir = "",
}
