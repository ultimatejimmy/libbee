# Libbee
![Platform](https://img.shields.io/badge/platform-KOReader-green.svg)
![License](https://img.shields.io/badge/license-MIT-yellow.svg)
![Status](https://img.shields.io/badge/status-active-brightgreen.svg)
[![liberapay](https://img.shields.io/liberapay/patrons/ultimatejimmy.svg?logo=liberapay)](https://liberapay.com/ultimatejimmy)
[!["Buy Me A Coffee"](https://img.shields.io/badge/-buy_me_a%C2%A0coffee-gray?logo=buy-me-a-coffee)](https://www.buymeacoffee.com/ultimatejimmy)

Libbee is a plugin for KOReader that connects to your Libby / OverDrive account, allowing you to browse your library shelf and download borrowed ebooks directly to your device.

---

## Overview

Libbee brings your public library loans directly into KOReader. With integrated native Adobe ADEPT fulfillment and DRM support, Libbee downloads and decrypts `.acsm` loan tokens on-device into readable EPUB and PDF files without requiring separate companion plugins or a computer.

| Grid View | List View |
| --- | --- |
| ![Shelf in Grid View](https://github.com/ultimatejimmy/libbee/wiki/img/cover_view.png) | ![Shelf in List View](https://github.com/ultimatejimmy/libbee/wiki/img/list_view.png) |

---

## Key Features

- **Direct Shelf Access**: Browse all active ebook loans from your connected Libby shelf directly within KOReader.
- **On-Device ACSM Fulfillment**: Automatically fulfills and decrypts Adobe DRM `.acsm` loans to standard `.epub` and `.pdf` files on the device.
- **Anonymous Device Activation**: Ready to use out of the box with automatic one-time anonymous device activation.
- **Optional ByteBooks Multi-Device Sync**: Sign in with a ByteBooks ID to synchronize and read the same loan across multiple authorized devices.
- **Cover and Metadata Display**: View book titles, authors, cover art, and remaining loan duration.
- **Grid and List Views**: Flexible shelf presentation tailored for e-ink and high-resolution screens.
- **Offline Shelf Cache**: Cached shelf metadata allows offline browsing of currently borrowed titles.
- **Over-The-Air (OTA) Updates**: Automatic and manual update checks via GitHub Releases with preservation of user settings.

---

## Documentation

Comprehensive guides, setup instructions, and feature details are available on the [Libbee Wiki](https://github.com/ultimatejimmy/libbee/wiki):

- [Installation Guide](https://github.com/ultimatejimmy/libbee/wiki/Installation-Guide): Step-by-step setup for e-readers and devices, plus update instructions.
- [Authentication and Setup](https://github.com/ultimatejimmy/libbee/wiki/Authentication-and-Setup): How to link your Libby account using the 8-digit setup code displayed in KOReader.
- [DRM and Fulfillment](https://github.com/ultimatejimmy/libbee/wiki/DRM-and-Fulfillment): Detailed explanation of on-device ACSM fulfillment and ByteBooks multi-device sync.
- [User Interface and Features](https://github.com/ultimatejimmy/libbee/wiki/User-Interface-and-Features): Guide to shelf navigation, view modes, cover caching, and offline reading.
- [Configuration Reference](https://github.com/ultimatejimmy/libbee/wiki/Configuration-Reference): Reference for all configuration options and default download paths.
- [Troubleshooting and FAQ](https://github.com/ultimatejimmy/libbee/wiki/Troubleshooting-and-FAQ): Solutions for common errors, network issues, and general questions.

---

## Legal and Privacy

- Libbee interacts with OverDrive APIs using standard chip identity authentication mechanisms.
- The plugin accesses only active loans associated with your authorized library cards.
- Credentials and authentication tokens are stored locally on your device.
- Use of this plugin is subject to your library system's OverDrive Terms of Service.

---

## Attribution and Credits

- **[acsm.koplugin](https://github.com/kaikozlov/acsm.koplugin)** by [Kai Kozlov](https://github.com/kaikozlov) — Core on-device Adobe ADEPT fulfillment and ACSM decryption logic.
- **[Bee icon](https://www.flaticon.com/free-icons/bee)** created by Magnific — [Flaticon](https://www.flaticon.com/).

---

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
