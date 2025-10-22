#!/usr/bin/env python3
import argparse
import json
import os
import re
import sys
from itertools import islice
from pathlib import Path

import openai

try:
    import getpass

    import inquirer
    import keyring
    from tabulate import tabulate
except ImportError:
    print("Missing required packages. Please install with:")
    print("pip install inquirer tabulate keyring")
    sys.exit(1)


def append_translations_to_file(file_path, translations):
    with open(file_path, 'a', encoding='utf-8') as file:
        for translation in translations:
            file.write(f"\n{translation}")
def load_strings_from_file(file_path):
    keys_and_values = {}
    with open(file_path, 'r', encoding='utf-8') as file:
        for line in file:
            if '=' in line:
                key, value = line.split('=', 1)

                keys_and_values[key.strip()] = value.strip().rstrip(';').rstrip('"').lstrip('"')
    return keys_and_values

def get_translations(keys_and_values, from_lang, to_lang):
    chunks = [dict(islice(keys_and_values.items(), i, i + 5)) for i in range(0, len(keys_and_values), 5)]
    translations = []
    for chunk in chunks:
        # convert values to list
        values = list(chunk.values())
        # prompt = " ".join([f"{value}" for value in values])
        system_message = f"""Translate the following {from_lang} text to {to_lang}. 
Return JSON and preserve the order provided. DO NOT change the order of the strings.
IMPORTANT: Use native characters (not Unicode escape sequences) for languages like Chinese, Japanese, Korean, etc.
Example good response: {{"translations": ["你好", "谢谢"]}}
Example bad response: {{"translations": ["\\u4f60\\u597d", "\\u8c22\\u8c22"]}}"""

        messages = [
                {"role": "system", "content": system_message},
                {"role": "user", "content": json.dumps({"translations": values})}
            ]
        # import ipdb; ipdb.set_trace()
        response = openai.chat.completions.create(
            model="gpt-4.1",
            messages=messages,
            response_format={"type": "json_object" },
            temperature=0.5,
            max_tokens=256
        )
        
        # Debug: print raw response content
        raw_content = response.choices[0].message.content
        print(f"Raw API response: {raw_content[:200]}...")  # Show first 200 chars
        
        try:
            translation_text = json.loads(raw_content)['translations']
            print(translation_text)
            translations.extend([f"{key} = \"{translation}\";" for key, translation in zip(chunk.keys(), translation_text)])
        except json.JSONDecodeError as e:
            print(f"❌ JSON parsing error: {e}")
            print(f"❌ Raw response content: {raw_content}")
            print(f"❌ Error at position {e.pos}: '{raw_content[max(0, e.pos-10):e.pos+10]}'")
            
            # Try multiple approaches to fix the issue
            print("🔧 Attempting to fix JSON parsing issue...")
            fixed = False
            
            # Approach 1: Try to fix invalid Unicode escapes by making them literal
            try:
                # Find and fix malformed Unicode escapes
                fixed_content = re.sub(r'\\u([0-9a-fA-F]{0,3}[^0-9a-fA-F])', r'\\\\u\1', raw_content)
                translation_data = json.loads(fixed_content)['translations']
                print(f"✅ Fixed with regex Unicode repair: {translation_data}")
                translations.extend([f"{key} = \"{translation}\";" for key, translation in zip(chunk.keys(), translation_data)])
                fixed = True
            except Exception:
                pass
            
            # Approach 2: Try decoding as raw strings
            if not fixed:
                try:
                    # Parse as JSON with a more lenient approach
                    decoded_content = raw_content.encode().decode('unicode_escape')
                    translation_data = json.loads(decoded_content)['translations']
                    print(f"✅ Fixed with unicode_escape decoding: {translation_data}")
                    translations.extend([f"{key} = \"{translation}\";" for key, translation in zip(chunk.keys(), translation_data)])
                    fixed = True
                except Exception:
                    pass
            
            # Approach 3: Manual parsing fallback
            if not fixed:
                try:
                    # Extract translations array manually using regex
                    match = re.search(r'"translations"\s*:\s*\[(.*?)\]', raw_content, re.DOTALL)
                    if match:
                        translations_str = match.group(1)
                        # Split by comma and clean up
                        manual_translations = []
                        parts = translations_str.split('",')
                        for part in parts:
                            clean_part = part.strip().strip('"').strip("'")
                            if clean_part:
                                manual_translations.append(clean_part)
                        
                        print(f"✅ Fixed with manual parsing: {manual_translations}")
                        translations.extend([f"{key} = \"{translation}\";" for key, translation in zip(chunk.keys(), manual_translations)])
                        fixed = True
                except Exception as manual_error:
                    print(f"❌ Manual parsing also failed: {manual_error}")
            
            if not fixed:
                print("❌ Could not fix JSON parsing issue with any method")
                print("⏭️  Skipping this batch of translations due to encoding error")
                continue
    return translations

def compare_and_translate(master_keys_and_values, directory, master_dir, from_lang, to_lang, silent=False):
    loc_path = Path(directory) / "Localizable.strings"
    if loc_path.exists():
        local_keys_and_values = load_strings_from_file(loc_path)
        local_keys = set(local_keys_and_values.keys())
        master_keys = set(master_keys_and_values.keys())
        missing_keys = master_keys - local_keys
        if missing_keys:
            print(f"Missing translations in {directory.name}:")
            for key in sorted(missing_keys):
                print(f"  {key}")
            if silent or input("Do you want to translate these missing keys? (y/n) ").lower() == "y":
                missing_keys_and_values = {key: master_keys_and_values[key] for key in missing_keys}
                translations = get_translations(missing_keys_and_values, from_lang, to_lang)
                append_translations_to_file(loc_path, translations)

def get_localization_status(master_keys_and_values, master_dir):
    """Get comprehensive status of all strings across all localizations."""
    language_map = {"de.lproj": "German", "es.lproj": "Spanish", "ru.lproj": "Russian", "ko.lproj": "Korean"}
    
    # Find all localization directories
    localizations = {}
    for directory in master_dir.parent.iterdir():
        if directory.is_dir() and directory != master_dir and directory.name.endswith('.lproj'):
            loc_path = directory / "Localizable.strings"
            if loc_path.exists():
                local_keys_and_values = load_strings_from_file(loc_path)
                lang_code = directory.name.replace('.lproj', '').upper()
                lang_name = language_map.get(directory.name, lang_code)
                localizations[lang_code] = {
                    'directory': directory,
                    'language': lang_name,
                    'keys': set(local_keys_and_values.keys()),
                    'keys_and_values': local_keys_and_values
                }
    
    # Create status overview
    master_keys = set(master_keys_and_values.keys())
    status_data = []
    missing_by_lang = {}
    
    for key in sorted(master_keys):
        row = {
            'key': key,
            'english_text': master_keys_and_values[key]
        }
        
        for lang_code, lang_info in localizations.items():
            has_translation = key in lang_info['keys']
            row[lang_code] = has_translation
            
            # Track missing keys per language
            if not has_translation:
                if lang_code not in missing_by_lang:
                    missing_by_lang[lang_code] = {
                        'info': lang_info,
                        'missing_keys': set()
                    }
                missing_by_lang[lang_code]['missing_keys'].add(key)
        
        status_data.append(row)
    
    return status_data, localizations, missing_by_lang

def create_new_localization(master_keys_and_values, master_dir, lang_code, lang_name, from_lang="English"):
    """Create a new localization directory and translate all strings."""
    new_dir = master_dir.parent / f"{lang_code}.lproj"
    
    if new_dir.exists():
        print(f"Localization directory {new_dir.name} already exists!")
        return False
    
    # Create directory
    new_dir.mkdir()
    loc_path = new_dir / "Localizable.strings"
    
    print(f"Creating new localization: {lang_name} ({lang_code})")
    print(f"Translating {len(master_keys_and_values)} strings...")
    
    # Translate all strings
    translations = get_translations(master_keys_and_values, from_lang, lang_name)
    
    # Write to new file
    with open(loc_path, 'w', encoding='utf-8') as file:
        file.write(f"/* {lang_name} Localization */\n\n")
        for translation in translations:
            file.write(f"{translation}\n")
    
    print(f"✅ Created {loc_path}")
    return True

def show_comprehensive_status_table(status_data, localizations):
    """Display comprehensive status table showing only keys with missing translations."""
    if not localizations:
        print("🎉 No localizations found!")
        return
    
    # Prepare headers
    lang_codes = sorted(localizations.keys())
    headers = ["Key", "English Text"] + lang_codes
    
    # Filter to only show rows with missing translations
    missing_rows = []
    for row in status_data:
        # Check if any language is missing this translation
        has_missing = any(not row.get(lang_code, False) for lang_code in lang_codes)
        if has_missing:
            missing_rows.append(row)
    
    if not missing_rows:
        print("🎉 All localizations are complete! No missing translations found.")
        return lang_codes
    
    # Prepare table data for missing translations only
    table_data = []
    for row in missing_rows:
        # Truncate English text for display
        english_text = row['english_text']
        if len(english_text) > 50:
            english_text = english_text[:47] + "..."
        
        table_row = [row['key'], english_text]
        
        # Add status for each language
        for lang_code in lang_codes:
            status = "✅" if row.get(lang_code, False) else "❌"
            table_row.append(status)
        
        table_data.append(table_row)
    
    print(f"\n🌍 Missing Translations Overview ({len(missing_rows)} keys)")
    print("=" * 80)
    print(tabulate(table_data, headers=headers, tablefmt="grid"))
    
    # Show summary
    total_keys = len(status_data)  # All keys in master
    print(f"\n📊 Summary:")
    for lang_code in lang_codes:
        lang_name = localizations[lang_code]['language']
        translated_count = sum(1 for row in status_data if row.get(lang_code, False))
        missing_count = total_keys - translated_count
        completion = (translated_count / total_keys) * 100 if total_keys > 0 else 0
        print(f"  {lang_name} ({lang_code}): {translated_count}/{total_keys} ({completion:.1f}%) - {missing_count} missing")
    
    return lang_codes

def interactive_menu():
    """Show the main interactive menu."""
    questions = [
        inquirer.List('action',
                     message="What would you like to do?",
                     choices=[
                         'Translate missing strings for existing localizations',
                         'Add new localization and translate',
                         'Exit'
                     ],
        ),
    ]
    return inquirer.prompt(questions)['action']

def interactive_translate_missing(master_keys_and_values, master_dir, from_lang="English"):
    """Interactive workflow for translating missing strings."""
    status_data, localizations, missing_by_lang = get_localization_status(master_keys_and_values, master_dir)
    
    if not localizations:
        print("🎉 No localizations found!")
        return
    
    if not missing_by_lang:
        print("🎉 All localizations are up to date! No missing strings found.")
        return
    
    # Show comprehensive status table
    show_comprehensive_status_table(status_data, localizations)
    
    # Ask if user wants to translate missing strings
    total_missing = sum(len(info['missing_keys']) for info in missing_by_lang.values())
    languages_with_missing = len(missing_by_lang)
    
    questions = [
        inquirer.Confirm('translate_all',
                       message=f"Translate {total_missing} missing strings across {languages_with_missing} language(s)?",
                       default=True),
    ]
    
    if inquirer.prompt(questions)['translate_all']:
        # Translate for each language with missing strings
        for lang_code, missing_info in missing_by_lang.items():
            lang_name = missing_info['info']['language']
            missing_keys = missing_info['missing_keys']
            
            print(f"\n🔄 Translating {len(missing_keys)} missing strings for {lang_name}...")
            
            missing_keys_and_values = {key: master_keys_and_values[key] for key in missing_keys}
            translations = get_translations(missing_keys_and_values, from_lang, lang_name)
            
            loc_path = missing_info['info']['directory'] / "Localizable.strings"
            append_translations_to_file(loc_path, translations)
            print(f"✅ Added {len(translations)} translations to {loc_path}")
        
        print(f"\n🎉 Successfully translated missing strings for all languages!")
    else:
        print("⏭️  Translation cancelled")

def interactive_add_localization(master_keys_and_values, master_dir, from_lang="English"):
    """Interactive workflow for adding a new localization."""
    # Get language code
    questions = [
        inquirer.Text('lang_code',
                     message="Enter language code (e.g., 'ko', 'jp', 'ro')"),
    ]
    lang_code = inquirer.prompt(questions)['lang_code'].strip().lower()
    
    if not lang_code:
        print("❌ Invalid language code")
        return
    
    # Get language name
    questions = [
        inquirer.Text('lang_name',
                     message="Enter full language name (e.g., 'Korean', 'Japanese', 'Romanian')"),
    ]
    lang_name = inquirer.prompt(questions)['lang_name'].strip()
    
    if not lang_name:
        print("❌ Invalid language name")
        return
    
    # Confirm
    questions = [
        inquirer.Confirm('confirm',
                        message=f"Create localization for {lang_name} ({lang_code}.lproj) with {len(master_keys_and_values)} strings?",
                        default=True),
    ]
    
    if inquirer.prompt(questions)['confirm']:
        success = create_new_localization(master_keys_and_values, master_dir, lang_code, lang_name, from_lang)
        if success:
            print(f"🎉 Successfully created {lang_name} localization!")
    else:
        print("❌ Cancelled")

def get_openai_api_key():
    """Get OpenAI API key from keychain, prompt user if not found, and save it."""
    service_name = "encamera_translation_openai_key"
    key_name = "encamera_translation_openai_key"
    
    try:
        # Try to get the key from keychain
        api_key = keyring.get_password(service_name, key_name)
        
        if api_key:
            print("🔑 Found OpenAI API key in keychain")
            return api_key
        else:
            print("🔑 OpenAI API key not found in keychain")
            
    except Exception as e:
        print(f"⚠️  Could not access keychain: {e}")
    
    # Prompt user for API key
    print("Please enter your OpenAI API key:")
    api_key = getpass.getpass("API Key: ").strip()
    
    if not api_key:
        print("❌ Invalid API key")
        return None
    
    # Ask if user wants to save it to keychain
    try:
        questions = [
            inquirer.Confirm('save_to_keychain',
                           message="Save this API key to keychain for future use?",
                           default=True),
        ]
        
        if inquirer.prompt(questions)['save_to_keychain']:
            try:
                keyring.set_password(service_name, key_name, api_key)
                print("✅ API key saved to keychain as 'encamera_translation_openai_key'")
            except Exception as e:
                print(f"⚠️  Could not save to keychain: {e}")
        
    except Exception as e:
        # Fallback if inquirer fails
        response = input("Save this API key to keychain for future use? (y/n): ").lower()
        if response in ['y', 'yes']:
            try:
                keyring.set_password(service_name, key_name, api_key)
                print("✅ API key saved to keychain as 'encamera_translation_openai_key'")
            except Exception as e:
                print(f"⚠️  Could not save to keychain: {e}")
    
    return api_key

def main():
    parser = argparse.ArgumentParser(
        description='Compare and translate localization files.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Interactive mode (default) - API key will be loaded from keychain
  python string_diff.py --master ./en.lproj
    
    """
    )
    parser.add_argument('--master', type=str, help='Path to the master localization directory.')
    args = parser.parse_args()

    api_key = get_openai_api_key()
    if not api_key:
        print("❌ OpenAI API key is required to proceed.")
        return

    openai.api_key = api_key

    # Auto-detect master directory if not provided
    if not args.master:
        # Look for en.lproj in current directory or parent directories
        current = Path.cwd()
        for path in [current] + list(current.parents):
            en_lproj = path / "en.lproj"
            if en_lproj.exists():
                args.master = str(en_lproj)
                break
        
        if not args.master:
            print("❌ Could not find en.lproj directory. Please specify --master path.")
            return

    master_dir = Path(args.master)
    master_file = master_dir / "Localizable.strings"

    if not master_file.exists():
        print(f"❌ Master file {master_file} does not exist.")
        return

    master_keys_and_values = load_strings_from_file(master_file)
    from_lang = "English"  # Master language assumed to be English

    print(f"📁 Using master localization: {master_file}")
    print(f"📝 Loaded {len(master_keys_and_values)} strings from master file")

    # Interactive mode
    print("\n🌍 Localization Manager")
    print("=" * 40)
    
    while True:
        try:
            action = interactive_menu()
            
            if action == 'Exit':
                print("👋 Goodbye!")
                break
            elif action == 'Translate missing strings for existing localizations':
                interactive_translate_missing(master_keys_and_values, master_dir, from_lang)
            elif action == 'Add new localization and translate':
                interactive_add_localization(master_keys_and_values, master_dir, from_lang)
            
            print("\n" + "=" * 40)
            
        except KeyboardInterrupt:
            print("\n\n👋 Goodbye!")
            break
        except Exception as e:
            print(f"\n❌ Error: {e}")
            break

if __name__ == '__main__':
    main()
