# Libbee — Libby for KOReader

Browse your **Libby library shelf** and download ebook loans directly to KOReader.

---

## Features

- Browse all active ebook loans from your Libby shelf
- See title, author, cover, and days remaining for each loan
- **Direct on-device fulfillment**: Download and decrypt `.acsm` loans directly into readable `.epub` or `.pdf` files — **no separate plugin or computer required!**
- **Anonymous DRM by default**: Works out of the box with automatic one-time anonymous device activation.
- **Optional ByteBooks Multi-Device Sync**: Sign in with your ByteBooks ID in Settings to read the same loan across multiple devices. Passwords are never saved to storage.
- Works from the KOReader **file manager** and reader
- OTA updates via GitHub Releases

---

## Installation

1. Download the latest `libbee.koplugin.zip` from the [Releases page](https://github.com/PLACEHOLDER_OWNER/libbee/releases).
2. Unzip it into your KOReader `plugins/` directory:
   ```
   koreader/plugins/libbee.koplugin/
   ```
3. Restart KOReader.
4. Open the **Tools** menu → **Libbee** → **Link Libby Account**.

---

## DRM & Multi-Device (ByteBooks)

Libbee includes full native ACSM fulfillment and ADEPT DRM management.

- **Single Device (Default)**: You don't need to configure anything. On your first book download, Libbee automatically activates your device anonymously.
- **Multiple Devices (ByteBooks)**: If you borrow a book on Libby and want to open it across multiple e-readers or apps under the same account:
  1. Open Libbee → Settings icon (⚙) → **DRM & Multi-Device**.
  2. Tap **Sign in with ByteBooks ID**.
  3. Enter your ByteBooks email and password.
  4. Your device is authorized and linked. Your password is used only during the handshake and is **never stored on device**.

---

## Setup: Authenticating with a Libby Code (Recommended)

This is the easiest and most reliable method. It works exactly the same way Kobo eReaders sync with Libby natively.

1. Open the **Libby app** on your phone or computer.
2. Tap the **menu icon (☰)** → **Settings** → **Copy Library To Another Device**.
3. Tap **"Get Code"** — you'll see an 8-digit number.
4. In KOReader: **Tools** → **Libbee** → **Setup / Re-authenticate**.
5. Enter your library's subdomain, your card number, then the 8-digit code.

Your device is now registered. The code is single-use — you won't need it again unless you re-authenticate.

---

## Setup: Manual Bearer Token (Fallback)

If the code method fails (e.g., after an API change), you can manually paste a Bearer token.

### How to get your token:

1. Open [libbyapp.com](https://libbyapp.com) in a **desktop browser** and sign in with your library card.
2. Open **DevTools** (`F12` on Windows/Linux, `⌘⌥I` on Mac).
3. Go to the **Network** tab and reload the page.
4. Filter requests by `sentry-read.svc.overdrive.com`.
5. Click any matching request → **Headers** tab → find:
   ```
   Authorization: Bearer eyJhbGci...
   ```
6. Copy everything **after** `Bearer ` (the long token string).

### Add the token to your config:

1. Navigate to your KOReader plugins folder: `koreader/plugins/libbee.koplugin/`
2. Open `libbee_config.lua` in a text editor.
3. Paste your token into the `bearer_token` field:
   ```lua
   bearer_token = "eyJhbGci...",
   ```
4. Save the file. The token will be used automatically on the next shelf load.

> **Note:** Bearer tokens expire after a few weeks. If you get authentication errors, repeat the steps above to get a fresh token.

---

## Configuration

Edit `libbee.koplugin/libbee_config.lua` on your computer while KOReader is not running:

```lua
return {
    library_id   = "seattle",          -- Your library's OverDrive subdomain
    card_number  = "1234567890",       -- Your library card number
    setup_code   = "",                 -- One-time code from Libby app (cleared after use)
    bearer_token = "",                 -- Manual fallback token
    download_dir = "",                 -- Leave blank for auto-detected default
}
```

### `download_dir` defaults

| Device  | Default path          |
|---------|-----------------------|
| Kindle  | `/mnt/us/documents/Libby` |
| Kobo    | `/mnt/onboard/Libby`  |
| Android | `/sdcard/Books/Libby` |
| Linux   | KOReader data dir `/Libby` |

---

## How It Works

1. **Authentication**: Your Libby account is registered as a "chip identity" — the same mechanism Kobo eReaders use. This is obtained once using a one-time clone code from the Libby app.
2. **Shelf fetch**: The plugin calls Libby's internal API (`sentry-read.svc.overdrive.com`) to retrieve your active loans.
3. **Download & Decrypt**: When you tap a book, the plugin downloads the `.acsm` fulfillment token, automatically performs ADEPT device authorization (anonymous or ByteBooks ID), decrypts the stream, and saves a ready-to-read `.epub` or `.pdf` file.
4. **Open**: The fulfilled book is ready to open immediately in KOReader.

---

## Updating

Libbee checks for updates weekly and notifies you when one is available. You can also check manually:

**Tools** → **Libbee** → **About / Check for Updates** → **Check for Updates**

Updates are downloaded and installed automatically. Your config settings (`library_id`, `card_number`, `bearer_token`, `download_dir`) are preserved across updates.

---

## FAQ

**Q: "Authentication failed" during setup code entry**
A: Make sure you're entering the code quickly — Libby codes expire in a few minutes. Generate a new code and try again. If it still fails, use the manual Bearer Token method.

**Q: "Could not load shelf" / network error**
A: Check that KOReader is connected to Wi-Fi. If the error says `HTTP 401` or `AUTH_EXPIRED`, your session has expired — use **Setup / Re-authenticate** to get a new session.

**Q: Do I need `acsm.koplugin` installed?**
A: No. Libbee now includes embedded ACSM fulfillment and Adobe/ByteBooks DRM support.

**Q: I only see some of my loans, not all of them**
A: Libbee only shows ebook loans (EPUB/PDF). Audiobooks and magazines are not currently supported.

**Q: Does this work offline?**
A: The shelf browser uses a 15-minute cache, so if you've loaded your shelf recently, you can browse it offline. Downloads require a network connection.

---

## Legal & Privacy

- This plugin interacts with Libby's API using the same method Kobo eReaders use natively (chip identity / device cloning).
- Only your own active loans are accessed. No data is shared with third parties.
- This plugin does not circumvent DRM — `.acsm` files are the standard fulfillment mechanism provided by OverDrive.
- Use is subject to your library's OverDrive Terms of Service.

---

## License

MIT
