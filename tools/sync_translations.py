#!/usr/bin/env python3
import os
import re
import sys
import json
import urllib.request
import time
import hashlib
import tempfile

if sys.version_info >= (3, 7):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

PLUGIN_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'libbee.koplugin'))
LANGUAGES_DIR = os.path.join(PLUGIN_DIR, 'languages')
SOURCE_DIR = PLUGIN_DIR
MASTER_LANG = 'en'

LANG_NAMES = {
    'ar': 'Arabic',
    'de': 'German',
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'hu': 'Hungarian',
    'id': 'Indonesian',
    'it': 'Italian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'nl': 'Dutch',
    'pl': 'Polish',
    'pt_br': 'Portuguese (Brazil)',
    'ru': 'Russian',
    'sr': 'Serbian',
    'tr': 'Turkish',
    'uk': 'Ukrainian',
    'zh_CN': 'Simplified Chinese',
}

TRANSLATION_MAX_LENGTHS = {
    'Restart Now': 16,
    'Later': 12,
}

REPAIR_TRANSLATION_KEYS = {
    'progress_please_wait',
}

def get_md5(text):
    return hashlib.md5(text.encode('utf-8')).hexdigest()

def is_placeholder_translation(value):
    """Return true for strings corrupted into question-mark placeholders."""
    return isinstance(value, str) and "?" in value

def decode_po_string(value):
    """Decode the PO escapes emitted by encode_po_string."""
    escapes = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}
    return re.sub(r'\\([nt"\\])', lambda m: escapes[m.group(1)], value)

def encode_po_string(value):
    """Encode a PO string symmetrically so repeated syncs are byte-stable."""
    return (value.replace("\\", "\\\\")
                 .replace("\n", "\\n")
                 .replace("\t", "\\t")
                 .replace('"', '\\"'))

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

def render_po(lang_name, lang_code, keys, translations, fallback_map, en_final):
    chunks = [
        'msgid ""\nmsgstr ""\n',
        f'"Language-Team: {lang_name}\\n"\n',
        f'"Language: {lang_code}\\n"\n',
        '"Content-Type: text/plain; charset=UTF-8\\n"\n',
        '"Content-Transfer-Encoding: 8bit\\n"\n\n',
    ]
    for key in sorted(keys):
        if not key:
            continue
        if lang_code == 'en':
            val = translations.get(key)
            if (not val or val == key) and key in fallback_map:
                val = fallback_map[key]
            elif not val:
                val = key
        else:
            val = translations.get(key)
            if not val:
                raise ValueError(f"{lang_code}: refusing to write missing translation for {key!r}")

        if lang_code != 'en':
            en_val = en_final.get(key, "")
            if en_val:
                chunks.append(f'# en-hash: {get_md5(en_val)}\n')
        chunks.append(f'msgid "{encode_po_string(key)}"\n')
        chunks.append(f'msgstr "{encode_po_string(val)}"\n\n')
    return ''.join(chunks)

def save_po(file_path, lang_name, lang_code, keys, translations, fallback_map, en_final):
    contents = render_po(lang_name, lang_code, keys, translations, fallback_map, en_final)
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    fd, temporary_path = tempfile.mkstemp(
        dir=os.path.dirname(file_path), prefix='.sync-', suffix='.po', text=True,
    )
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
            f.write(contents)
        os.replace(temporary_path, file_path)
    except Exception:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass
        raise

def format_specifiers(value):
    return re.findall(r'%(?:\d+\$)?[sd]', value)

def validate_translations(lang_code, requested, translated):
    if not isinstance(translated, dict):
        return [f"{lang_code}: provider did not return a translations object"]

    errors = []
    for key, english in requested.items():
        value = translated.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{lang_code}: missing translation for {key!r}")
        elif "???" in value or (key in REPAIR_TRANSLATION_KEYS and "?" in value):
            errors.append(f"{lang_code}: placeholder/corrupt translation for {key!r}")
        elif value == english and key not in {'1 / 1', '·', '\xc2\xb7', 'Libbee', 'Libby', 'ByteBooks', 'Adobe', 'EPUB', 'PDF', 'ACSM', 'JSON', 'Wi-Fi', 'user@example.com', '?', 'OK', 'v%s', '%d / %d', '‹ Prev', 'Next ›', '‹ Back to Settings'}:
            errors.append(f"{lang_code}: English fallback returned for {key!r}")
        elif format_specifiers(value) != format_specifiers(english):
            errors.append(f"{lang_code}: format specifiers differ for {key!r} (expected {format_specifiers(english)}, got {format_specifiers(value)})")
    return errors

def get_gemini_key():
    return os.environ.get("GEMINI_API_KEY")

def call_gemini(prompt):
    import urllib.error
    key = get_gemini_key()
    if not key: return None
    
    models = ["gemini-flash-latest", "gemini-pro-latest", "gemini-flash-lite-latest"]
    
    headers = {"Content-Type": "application/json"}
    data = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"responseMimeType": "application/json"}
    }
    encoded_data = json.dumps(data).encode('utf-8')
    
    for model in models:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"
        req = urllib.request.Request(url, data=encoded_data, headers=headers, method='POST')
        
        max_retries = 3
        for attempt in range(max_retries):
            try:
                with urllib.request.urlopen(req, timeout=120) as response:
                    res_data = json.loads(response.read().decode('utf-8'))
                    text = res_data['candidates'][0]['content']['parts'][0]['text']
                    text_stripped = text.strip()
                    first_brace = text_stripped.find('{')
                    last_brace = text_stripped.rfind('}')
                    if first_brace != -1 and last_brace != -1:
                        json_str = text_stripped[first_brace:last_brace+1]
                        return json.loads(json_str)
                    return json.loads(text_stripped)
            except urllib.error.HTTPError as e:
                if e.code in (429, 500, 502, 503, 504) and attempt < max_retries - 1:
                    sleep_time = 5 * (attempt + 1)
                    print(f"  - [{model}] HTTP {e.code}, waiting {sleep_time}s before retry {attempt + 1}/{max_retries - 1}...")
                    time.sleep(sleep_time)
                else:
                    print(f"  - [{model}] API Error: {e}")
                    break
            except Exception as e:
                print(f"  - [{model}] General Error: {e}")
                break
    return None

def translate_language_gemini(lang_code, lang_name, untranslated_keys):
    if not untranslated_keys:
        return {}

    all_items = list(untranslated_keys.items())
    chunk_size = 40
    combined_translations = {}

    for i in range(0, len(all_items), chunk_size):
        chunk = dict(all_items[i:i + chunk_size])
        strings_list = [{"key": k, "english": v} for k, v in chunk.items()]
        
        prompt = f"""You are a professional translator and localization expert. Translate the following English key-value pairs for the KOReader Libbee plugin (a Libby/OverDrive library ebook borrower) UI into {lang_name} ({lang_code}).

CRITICAL rules:
1. Retain all format specifiers such as %s, %d, %1$s, %2$d, etc. exactly in the translated output.
2. Retain all literal escaped newlines (\\n) and tabs (\\t) exactly.
3. Keep translations concise, natural, and suited for a mobile e-reader display.
4. Keep product names "Libbee", "Libby", "ByteBooks", "Adobe" untranslated where appropriate.
5. Respect these maximum character limits for fixed-width UI labels:
{json.dumps(TRANSLATION_MAX_LENGTHS, ensure_ascii=False)}
6. Return ONLY a valid JSON object matching this exact schema:
{{
  "translations": {{
    "key_name": "translated_value"
  }}
}}

Input to translate:
{json.dumps(strings_list, indent=2, ensure_ascii=False)}
"""
        res = call_gemini(prompt)
        if res and isinstance(res, dict) and "translations" in res:
            for k, v in res["translations"].items():
                combined_translations[k] = v
        else:
            print(f"  - [{lang_code}] Chunk {i//chunk_size + 1} failed to translate.")
        time.sleep(1)

    return combined_translations

def extract_keys_from_lua():
    keys = set()
    fallback_map = {}

    loc_file = os.path.join(SOURCE_DIR, 'localization_libbee.lua')
    if os.path.exists(loc_file):
        with open(loc_file, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
            m_fb = re.search(r'local FALLBACKS = \{(.*?)\}', content, re.DOTALL)
            if m_fb:
                for line in m_fb.group(1).splitlines():
                    m_kv = re.match(r'^\s*([a-zA-Z0-9_]+)\s*=\s*"(.*)"\s*,?\s*$', line)
                    if m_kv:
                        k, v = m_kv.group(1), m_kv.group(2)
                        fallback_map[k] = v
                        keys.add(k)

            m_ka = re.search(r'local KEY_ALIASES = \{(.*?)\}', content, re.DOTALL)
            if m_ka:
                for line in m_ka.group(1).splitlines():
                    m_kv = re.match(r'^\s*\["(.*)"\]\s*=\s*"(.*)"\s*,?\s*$', line)
                    if m_kv:
                        keys.add(m_kv.group(1))
                        keys.add(m_kv.group(2))

    for root, _, files in os.walk(SOURCE_DIR):
        if 'languages' in root or 'tools' in root or 'spec' in root: continue
        for file in files:
            if file.endswith('.lua'):
                file_path = os.path.join(root, file)
                with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()

                    # 1. Double quoted _("...")
                    for m in re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*"((?:[^"\\]|\\.)*)"\s*[\),]', content):
                        s = m.group(1).replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
                        s = s.replace('\\xC2\\xB7', '·').replace('\\xE2\\x86\\x92', '→').replace('\\xE2\\x80\\x94', '—').replace('\\xE2\\x80\\xA2', '•')
                        if s and s != '%s' and s != '%d': keys.add(s)

                    # 2. Single quoted _('...')
                    for m in re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*\'((?:[^\'\\]|\\.)*)\'\s*[\),]', content):
                        s = m.group(1).replace("\\'", "'").replace('\\n', '\n').replace('\\\\', '\\')
                        s = s.replace('\\xC2\\xB7', '·').replace('\\xE2\\x86\\x92', '→').replace('\\xE2\\x80\\x94', '—').replace('\\xE2\\x80\\xA2', '•')
                        if s and s != '%s' and s != '%d': keys.add(s)

                    # 3. Block quoted _([[...]])
                    for m in re.finditer(r'(?:_|_G\._|loc:t|Localization:t)\s*\(\s*\[\[(.*?)\]\]\s*[\),]', content, re.DOTALL):
                        s = m.group(1)
                        if s and s != '%s' and s != '%d': keys.add(s)

    keys.discard("")
    return keys, fallback_map

def sync():
    print("--- Synchronizing Libbee Translation Files ---")
    
    # 1. Scan source code for used keys & fallbacks
    used_keys, fallback_map = extract_keys_from_lua()
    
    # 2. Master Key Union & English Repair
    en_path = os.path.join(LANGUAGES_DIR, f'{MASTER_LANG}.po')
    en_existing = parse_po(en_path)
    en_map = {e['msgid']: e['msgstr'] for e in en_existing if e['msgid']}
    
    all_keys = used_keys | set(en_map.keys())
    print(f"Master key count across source & en.po: {len(all_keys)} keys.")

    for k in all_keys:
        curr = en_map.get(k)
        if not curr or curr == k:
            en_map[k] = fallback_map.get(k, k)
            
    save_po(en_path, 'English', 'en', all_keys, en_map, fallback_map, {})
    print(f"Saved master English file: {en_path}")

    en_final = {e['msgid']: e['msgstr'] for e in parse_po(en_path) if e['msgid']}
    all_keys = set(en_final.keys())

    # 3. Process each target language individually
    gemini_key = get_gemini_key()
    target_languages = [code for code in sorted(LANG_NAMES.keys()) if code != 'en']

    failures = []
    for lang_code in target_languages:
        po_path = os.path.join(LANGUAGES_DIR, f'{lang_code}.po')
        entries = parse_po(po_path)
        tr_map = {e['msgid']: e['msgstr'] for e in entries if e['msgid']}
        hash_map = {e['msgid']: e['en_hash'] for e in entries if e['msgid']}
        
        untranslated = {}
        for k in all_keys:
            en_val = en_final.get(k, k)
            current_val = tr_map.get(k)
            stored_hash = hash_map.get(k)
            current_hash = get_md5(en_val)
            
            needs_targeted_repair = (
                k in REPAIR_TRANSLATION_KEYS
                and (is_placeholder_translation(current_val) or current_val == en_val)
            )
            if (not current_val or needs_targeted_repair
                    or (stored_hash and stored_hash != current_hash)):
                untranslated[k] = en_val
                
        if untranslated:
            lang_name = LANG_NAMES.get(lang_code, lang_code)
            if not gemini_key:
                failures.append(f"{lang_name} ({lang_code}): {len(untranslated)} translations need the Gemini API key")
                continue
            print(f"Translating {len(untranslated)} keys for {lang_name} ({lang_code})...")
            new_translations = translate_language_gemini(lang_code, lang_name, untranslated)
            errors = validate_translations(lang_code, untranslated, new_translations)
            if errors:
                failures.extend(errors)
                print(f"  - Skipping {lang_name}; provider response failed validation.")
                continue
            for k, v in new_translations.items():
                tr_map[k] = str(v)
            time.sleep(2) # Pause between languages
            
        save_po(po_path, LANG_NAMES.get(lang_code, lang_code), lang_code, all_keys, tr_map, fallback_map, en_final)

    if failures:
        print("\nSync failed without overwriting affected locale files:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("\nSync completed successfully.")
    return 0

if __name__ == "__main__":
    sys.exit(sync())
