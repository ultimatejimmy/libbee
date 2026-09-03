#!/usr/bin/env python3
import os
import re
import sys
import json
import urllib.request
import time
import hashlib

# Configuration
if sys.version_info >= (3, 7):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

LANGUAGES_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', 'libbee.koplugin', 'languages'))
SOURCE_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', 'libbee.koplugin'))
MASTER_LANG = 'en'

# Narrow allowlist of keys that legitimately don't need translations (symbols, paths, brand names, etc.)
ALLOWLIST = {
    'path',                    # "plugins/libbee.koplugin"
    'current_language',        # "en" (or specific code)
    'menu_libbee',             # "Libbee" (brand name)
}

def get_md5(text):
    return hashlib.md5(text.encode('utf-8')).hexdigest()

def decode_po_string(s):
    if not s: return ""
    return s.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\')

def encode_po_string(s):
    if not s: return ""
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

def format_specifiers(s):
    if not s: return []
    return re.findall(r'%[0-9]*\$?[a-zA-Z]', s)

def extract_keys_from_lua(source_dir=None):
    src = source_dir or SOURCE_DIR
    used_keys = {} # key -> default_string
    fallback_map = {}
    for root, _, files in os.walk(src):
        if 'languages' in root or 'tools' in root or 'spec' in root:
            continue
        for file in files:
            if file.endswith('.lua'):
                with open(os.path.join(root, file), 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                    # Double quoted _("...") or loc:t("...")
                    for m in re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*"((?:[^"\\]|\\.)*)"\s*[\),]', content):
                        s = m.group(1).replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
                        if s and s != '%s' and s != '%d':
                            used_keys[s] = used_keys.get(s, "")

                    # Single quoted _('...')
                    for m in re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*\'((?:[^\'\\]|\\.)*)\'\s*[\),]', content):
                        s = m.group(1).replace("\\'", "'").replace('\\n', '\n').replace('\\\\', '\\')
                        if s and s != '%s' and s != '%d':
                            used_keys[s] = used_keys.get(s, "")

                    # Block quoted _([[...]])
                    for m in re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*\[\[(.*?)\]\]\s*[\),]', content, re.DOTALL):
                        s = m.group(1)
                        if s and s != '%s' and s != '%d':
                            used_keys[s] = used_keys.get(s, "")

                    if 'libbee_localization.lua' in file or 'localization_libbee.lua' in file:
                        m_fb = re.search(r'local FALLBACKS = \{(.*?)\}', content, re.DOTALL)
                        if m_fb:
                            for line in m_fb.group(1).splitlines():
                                m_kv = re.match(r'^\s*([a-zA-Z0-9_]+)\s*=\s*"(.*)"\s*,?\s*$', line)
                                if m_kv:
                                    k, v = m_kv.group(1), m_kv.group(2).replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
                                    used_keys[k] = v
                                    fallback_map[k] = v

                                m_kv2 = re.match(r'^\s*\["(.*)"\]\s*=\s*"(.*)"\s*,?\s*$', line)
                                if m_kv2:
                                    k, v = m_kv2.group(1).replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\'), m_kv2.group(2).replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
                                    used_keys[k] = v
                                    fallback_map[k] = v

    used_keys.pop("", None)
    return set(used_keys.keys()), fallback_map, used_keys

def parse_po(file_path):
    entries = []
    current_entry = {'msgid': '', 'msgstr': '', 'comments': [], 'en_hash': None}
    current_field = None
    if not os.path.exists(file_path): return []
    with open(file_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                if current_entry['msgid'] or current_entry['msgstr']:
                    entries.append(current_entry)
                    current_entry = {'msgid': '', 'msgstr': '', 'comments': [], 'en_hash': None}
                current_field = None
                continue
            if line.startswith('#'):
                current_entry['comments'].append(line)
                # Parse English content hash comment
                m = re.match(r'^#\s*en-hash:\s*([a-f0-9]+)$', line)
                if m:
                    current_entry['en_hash'] = m.group(1)
            elif line.startswith('msgid '):
                m = re.match(r'^msgid "(.*)"$', line)
                if m:
                    current_entry['msgid'] = decode_po_string(m.group(1))
                current_field = 'msgid'
            elif line.startswith('msgstr '):
                m = re.match(r'^msgstr "(.*)"$', line)
                if m:
                    current_entry['msgstr'] = decode_po_string(m.group(1))
                current_field = 'msgstr'
            elif line.startswith('"'):
                m = re.match(r'^"(.*)"$', line)
                if m:
                    if current_field == 'msgid':
                        current_entry['msgid'] += decode_po_string(m.group(1))
                    elif current_field == 'msgstr':
                        current_entry['msgstr'] += decode_po_string(m.group(1))
        if current_entry['msgid'] or current_entry['msgstr']:
            entries.append(current_entry)
    return entries

def save_po(file_path, lang_name, lang_code, keys, translations, fallback_map, en_final):
    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(f'msgid ""\nmsgstr ""\n"Language-Team: {lang_name}\\n"\n"Language: {lang_code}\\n"\n"Content-Type: text/plain; charset=UTF-8\\n"\n"Content-Transfer-Encoding: 8bit\\n"\n\n')
        for key in sorted(keys):
            if not key: continue
            if lang_code == 'en':
                val = translations.get(key) or fallback_map.get(key) or key
            else:
                val = translations.get(key, "")
            escaped_key = encode_po_string(key)
            escaped_val = encode_po_string(val)
            
            # For non-English languages, write the hash of the English value we translated from
            if lang_code != 'en':
                en_val = en_final.get(key, "")
                if en_val:
                    f.write(f'# en-hash: {get_md5(en_val)}\n')
            f.write(f'msgid "{escaped_key}"\nmsgstr "{escaped_val}"\n\n')

def get_gemini_key():
    return os.environ.get("GEMINI_API_KEY")

def call_gemini(prompt):
    import urllib.error
    key = get_gemini_key()
    if not key: return None
    
    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent?key={key}"
    headers = {"Content-Type": "application/json"}
    data = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"responseMimeType": "application/json"}
    }
    
    req = urllib.request.Request(url, data=json.dumps(data).encode('utf-8'), headers=headers, method='POST')
    
    max_retries = 3
    for attempt in range(max_retries):
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                res_data = json.loads(response.read().decode('utf-8'))
                text = res_data['candidates'][0]['content']['parts'][0]['text']
                text_stripped = text.strip()
                first_brace = text_stripped.find('{')
                last_brace = text_stripped.rfind('}')
                if first_brace != -1 and last_brace != -1:
                    json_str = text_stripped[first_brace:last_brace+1]
                else:
                    json_str = text_stripped

                try:
                    return json.loads(json_str, strict=False)
                except Exception:
                    # Sanitize invalid backslash escapes produced by LLM (e.g. \%, \', \•, invalid \u, etc.)
                    cleaned = re.sub(r'\\(?!([\"\\/bfnrt]|u[0-9a-fA-F]{4}))', r'\\\\', json_str)
                    try:
                        return json.loads(cleaned, strict=False)
                    except Exception:
                        # Fallback: escape raw newlines/tabs if any inside string values
                        cleaned2 = re.sub(r'(?<!\\)\n', r'\\n', cleaned)
                        return json.loads(cleaned2, strict=False)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < max_retries - 1:
                # For 429, respect Retry-After header if present, otherwise use backoff
                if e.code == 429:
                    retry_after = e.headers.get('Retry-After')
                    sleep_time = int(retry_after) if retry_after else 10 * (attempt + 1)
                else:
                    sleep_time = 5 * (attempt + 1)
                print(f"  - HTTP {e.code}, waiting {sleep_time}s before retry {attempt + 1}/{max_retries - 1}...")
                time.sleep(sleep_time)
            else:
                print(f"API Error calling Gemini: {e}")
                return None
        except urllib.error.URLError as e:
            # Covers socket timeouts and connection errors
            print(f"API Connection Error (timeout or network): {e}")
            if attempt < max_retries - 1:
                time.sleep(5)
            else:
                return None
        except Exception as e:
            print(f"API Error: {e}")
            return None
    return None

def translate_all_gemini(all_untranslated, lang_names, max_pairs=50):
    """
    Translates all untranslated keys across all languages in batches.
    all_untranslated: {lang_code: {key: en_val}}
    lang_names: {lang_code: lang_name}
    """
    # Flatten all translation targets to batch them
    flat_pairs = []
    for lang_code, keys in all_untranslated.items():
        for key, en_val in keys.items():
            flat_pairs.append((lang_code, key, en_val))
            
    if not flat_pairs:
        return {}
        
    all_results = {} # lang_code -> {key: translated_val}
    
    # Process flat_pairs in chunks
    for i in range(0, len(flat_pairs), max_pairs):
        chunk = flat_pairs[i:i+max_pairs]
        
        # Group by language code within this chunk to present clean prompt input
        batch_dict = {}
        for lang_code, key, en_val in chunk:
            if lang_code not in batch_dict:
                batch_dict[lang_code] = []
            batch_dict[lang_code].append({"key": key, "english": en_val})
            
        targets = []
        for lang_code, strings in batch_dict.items():
            name = lang_names.get(lang_code, lang_code.capitalize())
            targets.append({
                "language_code": lang_code,
                "language_name": name,
                "strings": strings
            })
            
        prompt = f"""You are a professional translator and localization expert. Translate the following English key-value pairs for a KOReader e-reader plugin UI into their respective target languages.

For each target language, you will receive its language name, language code, and a list of key-value pairs where the values are in English. Translate the English values into the target language, keeping them short, clear, and natural for e-reader menus.

CRITICAL rules:
1. Retain all format specifiers such as %s, %d, %1$s, %2$d, etc. exactly in the translated output.
2. Retain all literal escaped newlines (\\n) and tabs (\\t) exactly.
3. Keep the translation concise, natural, and suited for a mobile e-reader display.
4. All backslashes in JSON strings must be properly escaped. Do not escape percent signs (use %s or %1$s directly, never \\%s).
5. Return ONLY a valid JSON object matching this exact schema:
{{
  "translations": {{
    "<language_code>": {{
      "key_name": "translated_value"
    }}
  }}
}}
Do not add markdown blocks, explanations, or backticks.

Target languages and strings to translate:
{json.dumps(targets, indent=2)}
"""
        print(f"  - Requesting translations for batch {i // max_pairs + 1} ({len(chunk)} strings)...")
        result = call_gemini(prompt)
        
        if result and "translations" in result:
            translations = result["translations"]
            for lang_code, tr_map in translations.items():
                if lang_code not in all_results:
                    all_results[lang_code] = {}
                for k, v in tr_map.items():
                    if isinstance(v, str):
                        v = re.sub(r'\\(%[0-9]*\$?[a-zA-Z])', r'\1', v)
                    all_results[lang_code][k] = v
        else:
            print(f"  - WARNING: Batch {i // max_pairs + 1} failed or returned invalid response.")
            
        # Short rate-limiting recovery sleep between batches (if multiple exist)
        if i + max_pairs < len(flat_pairs):
            time.sleep(2.0)
            
    return all_results

def manual_translate_languages(all_untranslated, lang_names, all_existing_tr):
    """
    Prompts the user interactively in the terminal to translate keys.
    """
    print("\n=== Interactive Manual Translation ===")
    print("For each language, you can type translations. Press Enter to skip a key.")
    print("Type 'exit' to stop translating and save all progress so far.")
    
    for lang_code in sorted(all_untranslated.keys()):
        keys = all_untranslated[lang_code]
        lang_name = lang_names.get(lang_code, lang_code.capitalize())
        
        print(f"\n--- {lang_name} ({lang_code}) - {len(keys)} keys need translation ---")
        try:
            choice = input(f"Translate keys for {lang_name}? [Y/n/skip-all]: ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print("\nExiting manual translation mode.")
            break
            
        if choice in ('skip-all', 's'):
            print("Skipping all remaining languages.")
            break
        elif choice == 'n':
            print(f"Skipping {lang_name}.")
            continue
            
        existing_tr = all_existing_tr.get(lang_code, {})
        aborted = False
        
        for idx, (key, en_val) in enumerate(keys.items(), 1):
            print(f"\n[{idx}/{len(keys)}] Key: {key}")
            print(f"      English: {en_val}")
            curr = existing_tr.get(key, "")
            if curr:
                print(f"      Current: {curr}")
            try:
                val = input("      Translation: ").strip()
            except (KeyboardInterrupt, EOFError):
                print("\nExiting manual translation mode.")
                aborted = True
                break
                
            if val.lower() == 'exit':
                print("Exiting manual translation mode.")
                aborted = True
                break
                
            if val:
                existing_tr[key] = val
                print(f"      Saved: {val}")
            else:
                print("      Skipped.")
                
        if aborted:
            break

def sync():
    import argparse
    parser = argparse.ArgumentParser(description="Synchronize and translate KOReader X-Ray plugin localizations.")
    parser.add_argument("-m", "--mode", choices=["auto", "manual", "skip"], help="Translation mode: auto (Gemini), manual (interactive CLI), or skip.")
    args = parser.parse_args()

    print("--- Starting Translation Sync ---")
    
    # 1. Scan Source for Used Keys
    all_keys, fallback_map, used_keys = extract_keys_from_lua()
    print(f"Found {len(used_keys)} keys in source code.")

    # 2. Update English Master
    en_path = os.path.join(LANGUAGES_DIR, f'{MASTER_LANG}.po')
    en_entries = parse_po(en_path)
    en_existing = {e['msgid']: e['msgstr'] for e in en_entries if e['msgid']}
    
    en_final = {}
    for key in used_keys:
        code_fallback = used_keys.get(key, "")
        en_final[key] = (code_fallback if code_fallback else en_existing.get(key)) or key
    
    save_po(en_path, 'English', 'en', en_final.keys(), en_final, used_keys, en_final)
    print(f"Updated {MASTER_LANG}.po")

    # 3. Read and Prepare other languages
    lang_files = [f for f in os.listdir(LANGUAGES_DIR) if f.endswith('.po') and not f.startswith(MASTER_LANG)]
    
    lang_names = {}
    all_existing_tr = {}
    all_existing_hashes = {}
    all_untranslated = {}
    
    for file in lang_files:
        lang_code = file.split('.')[0]
        path = os.path.join(LANGUAGES_DIR, file)
        entries = parse_po(path)
        
        # Extract Language Name from header
        lang_name = lang_code.capitalize()
        for e in entries:
            if e['msgid'] == '':
                m = re.search(r'Language-Team: (.*?)\\n', e['msgstr'])
                if m: lang_name = m.group(1)
        
        lang_names[lang_code] = lang_name
        
        existing_tr = {e['msgid']: e['msgstr'] for e in entries if e['msgid'] and e['msgstr']}
        existing_hashes = {e['msgid']: e['en_hash'] for e in entries if e['msgid']}
        
        all_existing_tr[lang_code] = existing_tr
        all_existing_hashes[lang_code] = existing_hashes
        
        # Find missing or untranslated/stale keys
        untranslated = {}
        for key in en_final:
            if key != 'language_name' and key != "":
                current_val = existing_tr.get(key, "")
                en_val = en_final.get(key, "")
                stored_hash = existing_hashes.get(key)
                current_hash = get_md5(en_val) if en_val else None
                
                is_missing = (current_val == "")
                is_fallback = (current_val == key and key not in ALLOWLIST)
                is_stale = (stored_hash and current_hash and stored_hash != current_hash)
                
                if is_missing or is_fallback or is_stale:
                    untranslated[key] = en_val
                    
        if untranslated:
            all_untranslated[lang_code] = untranslated

    # Intercept and translate known keys locally from libbee_translations.json
    json_path = os.path.join(os.path.dirname(__file__), 'libbee_translations.json')
    local_translations = {}
    if os.path.exists(json_path):
        with open(json_path, 'r', encoding='utf-8') as f:
            local_translations = json.load(f)
    for lang_code, keys in list(all_untranslated.items()):
        if lang_code in local_translations:
            for k in list(keys.keys()):
                if k in local_translations[lang_code]:
                    val = local_translations[lang_code][k]
                    all_existing_tr[lang_code][k] = val
                    del keys[k]
            if not keys:
                del all_untranslated[lang_code]

    # 4. Handle Translations
    mode = args.mode
    has_gemini = get_gemini_key() is not None
    is_interactive = sys.stdin.isatty()
    
    if all_untranslated:
        print("\nMissing or stale translations detected:")
        for lang_code, keys in sorted(all_untranslated.items()):
            name = lang_names.get(lang_code, lang_code.capitalize())
            print(f"  - {name} ({lang_code}): {len(keys)} key(s)")
            
        if not mode:
            if is_interactive:
                print("\nChoose translation method:")
                opt_auto = "[1] Auto-translate with Gemini API" if has_gemini else "[1] (Disabled - GEMINI_API_KEY not set) Auto-translate with Gemini"
                print(f"  {opt_auto}")
                print("  [2] Interactively translate in console")
                print("  [3] Skip translations (leave as fallback/empty)")
                try:
                    choice = input("Enter choice [1/2/3] (default 3): ").strip()
                except (KeyboardInterrupt, EOFError):
                    choice = "3"
                if choice == "1" and has_gemini:
                    mode = "auto"
                elif choice == "2":
                    mode = "manual"
                else:
                    mode = "skip"
            else:
                mode = "auto" if has_gemini else "skip"
                print(f"\nNon-interactive shell. Defaulting to mode: {mode}")
                
        if mode == "auto":
            if not has_gemini:
                print("\nError: GEMINI_API_KEY environment variable is not set. Cannot run auto-translation.")
                if is_interactive:
                    print("Falling back to manual translation mode...")
                    mode = "manual"
                else:
                    print("Skipping translation.")
                    mode = "skip"
                    
        if mode == "auto":
            print(f"\nAuto-translating using Gemini API...")
            translations = translate_all_gemini(all_untranslated, lang_names)
            # Apply translations
            for lang_code, tr_map in translations.items():
                if lang_code in all_existing_tr:
                    for k, v in tr_map.items():
                        all_existing_tr[lang_code][k] = v
                        
        elif mode == "manual":
            manual_translate_languages(all_untranslated, lang_names, all_existing_tr)
            
        elif mode == "skip":
            print("\nSkipping translations. Saving updated keys with fallbacks.")
    else:
        print("\nAll translation files are up to date.")

    # 5. Save all files
    for file in lang_files:
        lang_code = file.split('.')[0]
        path = os.path.join(LANGUAGES_DIR, file)
        lang_name = lang_names[lang_code]
        existing_tr = all_existing_tr[lang_code]
        
        save_po(path, lang_name, lang_code, en_final.keys(), existing_tr, en_final, en_final)
        
        missing_count = len([k for k in en_final if k not in existing_tr or existing_tr[k] == ""])
        print(f"Updated {file} ({missing_count} keys need translation)")

    print("--- Sync Complete ---")

if __name__ == "__main__":
    sync()

