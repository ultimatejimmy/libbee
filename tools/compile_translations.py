#!/usr/bin/env python3
import os
import sys
import json
import hashlib
import re

if sys.version_info >= (3, 7):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

PLUGIN_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'libbee.koplugin'))
LANGUAGES_DIR = os.path.join(PLUGIN_DIR, 'languages')
SF_LANG_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', 'storefront', 'storefront.koplugin', 'storefront.koplugin', 'languages'))

sys.path.insert(0, os.path.dirname(__file__))
import sync_translations

LANG_NAMES = sync_translations.LANG_NAMES

def get_md5(text):
    return hashlib.md5(text.encode('utf-8')).hexdigest()

def main():
    print("--- Compiling Libbee 18-Language PO Files ---")
    
    # 1. Scan Lua files for all keys
    lua_keys, fallback_map = sync_translations.extract_keys_from_lua()
    en_path = os.path.join(LANGUAGES_DIR, 'en.po')
    en_entries = sync_translations.parse_po(en_path)
    en_map = {e['msgid']: e['msgstr'] for e in en_entries if e['msgid']}
    
    all_keys = sorted(lua_keys | set(en_map.keys()))
    for k in all_keys:
        if k not in en_map or not en_map[k]:
            en_map[k] = fallback_map.get(k, k)

    print(f"Master keys count across Lua source & en.po: {len(all_keys)}")
    sync_translations.save_po(en_path, 'English', 'en', all_keys, en_map, fallback_map, {})

    # 2. Load Storefront translations for shared keys
    sf_data = {}
    for code in LANG_NAMES:
        sf_file = os.path.join(SF_LANG_DIR, f"{code}.po")
        if os.path.exists(sf_file):
            entries = sync_translations.parse_po(sf_file)
            sf_data[code] = {e['msgid']: e['msgstr'] for e in entries if e['msgid'] and e['msgstr']}
        else:
            sf_data[code] = {}

    # 3. Read multilingual translations dictionary from json
    json_path = os.path.join(os.path.dirname(__file__), 'libbee_translations.json')
    if os.path.exists(json_path):
        with open(json_path, 'r', encoding='utf-8') as f:
            libbee_dict = json.load(f)
    else:
        libbee_dict = {}

    # 4. Generate PO file for each of the 18 languages
    for lang_code, lang_name in sorted(LANG_NAMES.items()):
        po_path = os.path.join(LANGUAGES_DIR, f"{lang_code}.po")
        existing_entries = sync_translations.parse_po(po_path)
        existing_map = {e['msgid']: e['msgstr'] for e in existing_entries if e['msgid']}

        target_map = {}
        missing = []

        for key in all_keys:
            en_val = en_map[key]
            if lang_code == 'en':
                target_map[key] = en_val
            else:
                val = None
                # Priority 1: libbee_translations.json
                if lang_code in libbee_dict and key in libbee_dict[lang_code]:
                    val = libbee_dict[lang_code][key]
                # Priority 2: Storefront dictionary
                elif key in sf_data.get(lang_code, {}):
                    val = sf_data[lang_code][key]
                # Priority 3: Existing PO file
                elif key in existing_map and existing_map[key] and not sync_translations.is_placeholder_translation(existing_map[key]):
                    val = existing_map[key]
                # Priority 4: Direct fallback for identical names / symbols
                elif key in {'1 / 1', '·', '\xc2\xb7', 'Libbee', 'Libby', 'ByteBooks', 'Adobe', 'EPUB', 'PDF', 'ACSM', 'JSON', 'Wi-Fi', 'user@example.com', '?', 'OK', 'v%s', '%d / %d', '‹ Prev', 'Next ›', '‹ Back to Settings'}:
                    val = key

                if val and val.strip():
                    target_map[key] = val
                else:
                    missing.append(key)

        if missing and lang_code != 'en':
            print(f"[{lang_code}] {len(missing)} keys missing in dataset.")
        else:
            print(f"[{lang_code}] 100% complete ({len(target_map)}/{len(all_keys)} keys).")

        sync_translations.save_po(po_path, lang_name, lang_code, all_keys, target_map, {}, en_map)

    print("\nCompilation completed.")

if __name__ == "__main__":
    main()
