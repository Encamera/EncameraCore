#!/usr/bin/env python3
import argparse
import json
import os
import plistlib
import re
import sys
from pathlib import Path
from typing import Literal

import anthropic
from pydantic import BaseModel

try:
    import getpass

    import inquirer
    import keyring
    from tabulate import tabulate
except ImportError:
    print("Missing required packages. Please install with:")
    print("pip install anthropic pydantic inquirer tabulate keyring")
    sys.exit(1)


PLACEHOLDER_CONTENT = """\
/* 
  Localizable.strings
  Encamera

  Placeholder to ensure iOS recognizes this locale for SPM bundle localization.
  
*/
"""


def find_workspace_root(master_dir):
    """Walk up from master_dir to find the workspace root that contains both Encamera/ and EncameraCore/."""
    current = master_dir.resolve()
    for _ in range(10):
        current = current.parent
        if (current / "Encamera").is_dir() and (current / "EncameraCore").is_dir():
            return current
    return None


def get_main_app_lproj_dir(workspace_root):
    """Return the path to the main app's source directory containing .lproj folders."""
    return workspace_root / "Encamera"


def ensure_main_app_locale_placeholders(master_dir, verbose=True):
    """Ensure the main app has a placeholder Localizable.strings for every locale
    that exists in the EncameraCore package Resources directory.

    iOS determines the app's preferred language from the main bundle's .lproj
    directories. Without a Localizable.strings in the main app's .lproj, the
    system won't select that language for SPM sub-bundles either.
    """
    workspace_root = find_workspace_root(master_dir)
    if workspace_root is None:
        print("⚠️  Could not find workspace root (directory containing both Encamera/ and EncameraCore/).")
        return []

    main_app_dir = get_main_app_lproj_dir(workspace_root)
    resources_dir = master_dir.parent  # e.g. .../Resources/

    created = []
    for lproj in sorted(resources_dir.iterdir()):
        if not lproj.is_dir() or not lproj.name.endswith(".lproj"):
            continue
        # We never need to touch en.lproj (the development language)
        main_app_lproj = main_app_dir / lproj.name
        main_app_loc_strings = main_app_lproj / "Localizable.strings"
        if not main_app_loc_strings.exists():
            main_app_lproj.mkdir(parents=True, exist_ok=True)
            main_app_loc_strings.write_text(PLACEHOLDER_CONTENT, encoding="utf-8")
            created.append(main_app_loc_strings)
            if verbose:
                print(f"  ✅ Created placeholder: {main_app_loc_strings.relative_to(workspace_root)}")

    if created and verbose:
        print(f"  📋 Created {len(created)} placeholder file(s) in the main app.")
        print(f"  ⚠️  Run xcodegen to pick up the new files in the Xcode project.")
    elif verbose:
        print("  ✅ All main-app locale placeholders already exist.")

    return created


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

TRANSLATION_MODEL = "claude-opus-5-5"
TRANSLATION_CHUNK_SIZE = 5

# Set in main() once the API key is known.
client = None


class TranslationBatch(BaseModel):
    translations: list[str]


def get_translations(keys_and_values, from_lang, to_lang):
    items = list(keys_and_values.items())
    chunks = [dict(items[i:i + TRANSLATION_CHUNK_SIZE]) for i in range(0, len(items), TRANSLATION_CHUNK_SIZE)]
    system_message = f"""You translate user-facing strings for an iOS app from {from_lang} to {to_lang}.
You receive a JSON object with a "translations" array. Return the same number of strings, in the same order, each one translated.
Keep format specifiers (%@, %d, %lld, %1$@, ...), escape sequences (\\n, \\"), and markup exactly as they appear.
Write native characters, never Unicode escape sequences."""

    translations = []
    for chunk in chunks:
        values = list(chunk.values())
        try:
            response = client.beta.messages.parse(
                model=TRANSLATION_MODEL,
                max_tokens=16000,
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
                output_config={"effort": "medium"},
                system=system_message,
                messages=[{"role": "user", "content": json.dumps({"translations": values}, ensure_ascii=False)}],
                output_format=TranslationBatch,
            )
        except anthropic.APIStatusError as e:
            print(f"❌ API error ({e.status_code}): {e.message}")
            print("⏭️  Skipping this batch of translations")
            continue
        except anthropic.APIConnectionError as e:
            print(f"❌ Network error: {e}")
            print("⏭️  Skipping this batch of translations")
            continue

        if response.stop_reason == "refusal":
            category = response.stop_details.category if response.stop_details else None
            print(f"❌ Request refused (category: {category})")
            print("⏭️  Skipping this batch of translations")
            continue
        if response.stop_reason == "max_tokens" or response.parsed_output is None:
            print(f"❌ Response was cut off or unparseable (stop_reason: {response.stop_reason})")
            print("⏭️  Skipping this batch of translations")
            continue

        translated = response.parsed_output.translations
        if len(translated) != len(values):
            print(f"❌ Expected {len(values)} translations, got {len(translated)}")
            print("⏭️  Skipping this batch of translations")
            continue

        print(translated)
        translations.extend([f"{key} = \"{translation}\";" for key, translation in zip(chunk.keys(), translated)])
    return translations

# --- Plural strings (Localizable.stringsdict) ---

STRINGSDICT_NAME = "Localizable.stringsdict"
FORMAT_KEY = "NSStringLocalizedFormatKey"
PLURAL_SPEC_KEYS = ("NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey")
PLURAL_CATEGORIES = ("zero", "one", "two", "few", "many", "other")

# Matches %d, %1$d, %@, %2$@, %lld and the like, but not the %#@var@ references.
FORMAT_SPECIFIER = re.compile(r"%(?:\d+\$)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSp]")
VARIABLE_REFERENCE = re.compile(r"%(?:\d+\$)?#@(\w+)@")


class PluralForm(BaseModel):
    category: Literal["zero", "one", "two", "few", "many", "other"]
    text: str


class PluralVariable(BaseModel):
    name: str
    forms: list[PluralForm]


class PluralEntry(BaseModel):
    key: str
    format_key: str
    variables: list[PluralVariable]


class PluralBatch(BaseModel):
    entries: list[PluralEntry]


def load_stringsdict(path):
    if not path.exists():
        return {}
    with open(path, "rb") as file:
        return plistlib.load(file)


def write_stringsdict(path, entries):
    with open(path, "wb") as file:
        plistlib.dump(entries, file, fmt=plistlib.FMT_XML, sort_keys=False)


def plural_variables(entry):
    """Return {variable name: {category: text}} for an English stringsdict entry."""
    return {
        name: {category: value[category] for category in PLURAL_CATEGORIES if category in value}
        for name, value in entry.items()
        if isinstance(value, dict)
    }


def language_name_for(locale_dir):
    """Read the language name from the header string_diff.py writes, else use the folder's locale code."""
    code = locale_dir.name.removesuffix(".lproj")
    strings_path = locale_dir / "Localizable.strings"
    if strings_path.exists():
        with open(strings_path, encoding="utf-8") as file:
            match = re.match(r"/\*\s*(.+?) Localization\s*\*/", file.readline())
        if match:
            return f"{match.group(1)} ({code})"
    return f"the language with Apple locale code '{code}'"


def validate_plural_entry(english, translated):
    """Return a reason the translation can't be used, or None if it's sound."""
    english_variables = plural_variables(english)
    translated_variables = {variable.name: variable for variable in translated.variables}

    if set(VARIABLE_REFERENCE.findall(translated.format_key)) != set(VARIABLE_REFERENCE.findall(english[FORMAT_KEY])):
        return "format key references different plural variables"
    if sorted(FORMAT_SPECIFIER.findall(translated.format_key)) != sorted(FORMAT_SPECIFIER.findall(english[FORMAT_KEY])):
        return "format key changes its format specifiers"
    if set(translated_variables) != set(english_variables):
        return f"variables {sorted(translated_variables)} don't match {sorted(english_variables)}"

    for name, variable in translated_variables.items():
        categories = [form.category for form in variable.forms]
        if "other" not in categories:
            return f"variable '{name}' has no 'other' form"
        if len(categories) != len(set(categories)):
            return f"variable '{name}' repeats a plural category"
        allowed = {spec for text in english_variables[name].values() for spec in FORMAT_SPECIFIER.findall(text)}
        for form in variable.forms:
            unexpected = set(FORMAT_SPECIFIER.findall(form.text)) - allowed
            if unexpected:
                return f"variable '{name}' form '{form.category}' adds format specifiers {sorted(unexpected)}"
    return None


def build_plural_entry(english, translated):
    """Rebuild a stringsdict entry from a translation, keeping the English spec and value types."""
    entry = {FORMAT_KEY: translated.format_key}
    for variable in translated.variables:
        forms = {form.category: form.text for form in variable.forms}
        value = {spec_key: english[variable.name][spec_key] for spec_key in PLURAL_SPEC_KEYS if spec_key in english[variable.name]}
        value.update({category: forms[category] for category in PLURAL_CATEGORIES if category in forms})
        entry[variable.name] = value
    return entry


def translate_plural_entries(entries, from_lang, to_lang):
    """Translate stringsdict entries in one request. Returns {key: entry} for the ones that pass validation."""
    request = [
        {"key": key, "format_key": entry[FORMAT_KEY], "variables": plural_variables(entry)}
        for key, entry in entries.items()
    ]
    system_message = f"""You translate plural strings from an iOS app's Localizable.stringsdict from {from_lang} to {to_lang}.
Each entry has a format_key and plural variables. A %#@name@ reference in format_key is replaced by the plural form of variable "name" chosen for the count.

For every entry, return the same key, a translated format_key, and each variable with its forms translated:
- Keep every %#@name@ reference (including any positional prefix such as %1$#@name@) and every other format specifier (%d, %1$d, %@, %2$@, ...) exactly as written. Word order around them may change.
- Give each variable the plural categories {to_lang} uses for cardinal numbers under CLDR rules, always including "other". For example Arabic uses zero, one, two, few, many and other; Russian uses one, few, many and other; Japanese and Chinese use only other.
- Also include a "zero" form whenever the {from_lang} variable has one: iOS uses it for a count of 0 in every language.
- A form may leave out the count specifier when the wording already says the number (for example "one file"), but must not add specifiers the {from_lang} forms don't use.
Write native characters, never Unicode escape sequences."""

    try:
        response = client.beta.messages.parse(
            model=TRANSLATION_MODEL,
            max_tokens=16000,
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
            output_config={"effort": "medium"},
            system=system_message,
            messages=[{"role": "user", "content": json.dumps({"entries": request}, ensure_ascii=False)}],
            output_format=PluralBatch,
        )
    except anthropic.APIStatusError as e:
        print(f"❌ API error ({e.status_code}): {e.message}")
        return {}
    except anthropic.APIConnectionError as e:
        print(f"❌ Network error: {e}")
        return {}

    if response.stop_reason == "refusal":
        category = response.stop_details.category if response.stop_details else None
        print(f"❌ Request refused (category: {category})")
        return {}
    if response.stop_reason == "max_tokens" or response.parsed_output is None:
        print(f"❌ Response was cut off or unparseable (stop_reason: {response.stop_reason})")
        return {}

    translated = {}
    for item in response.parsed_output.entries:
        if item.key not in entries:
            print(f"  ⚠️  Ignoring unexpected key {item.key}")
            continue
        problem = validate_plural_entry(entries[item.key], item)
        if problem:
            print(f"  ❌ {item.key}: {problem}; skipped")
            continue
        translated[item.key] = build_plural_entry(entries[item.key], item)

    for key in entries.keys() - translated.keys():
        if not any(item.key == key for item in response.parsed_output.entries):
            print(f"  ❌ {key}: missing from the response; skipped")
    return translated


def sync_locale_stringsdict(master_dir, locale_dir, from_lang="English"):
    """Bring one locale's stringsdict in line with the master: translate missing keys, drop removed ones.

    Returns (translated keys, removed keys, keys still missing).
    """
    master = load_stringsdict(master_dir / STRINGSDICT_NAME)
    path = locale_dir / STRINGSDICT_NAME
    existing = load_stringsdict(path)

    removed = [key for key in existing if key not in master]
    missing = {key: entry for key, entry in master.items() if key not in existing}
    if not missing and not removed:
        return [], [], []

    translated = {}
    if missing:
        to_lang = language_name_for(locale_dir)
        print(f"🔄 Translating {len(missing)} plural string(s) to {to_lang}...")
        translated = translate_plural_entries(missing, from_lang, to_lang)

    merged = {key: existing.get(key) or translated.get(key) for key in master}
    merged = {key: entry for key, entry in merged.items() if entry is not None}
    write_stringsdict(path, merged)
    return sorted(translated), sorted(removed), sorted(missing.keys() - translated.keys())


def interactive_translate_plurals(master_dir, from_lang="English"):
    """Translate missing stringsdict entries for every existing localization."""
    if not (master_dir / STRINGSDICT_NAME).exists():
        print(f"❌ No {STRINGSDICT_NAME} in {master_dir}")
        return

    master_keys = set(load_stringsdict(master_dir / STRINGSDICT_NAME))
    locale_dirs = sorted(
        d for d in master_dir.parent.iterdir()
        if d.is_dir() and d != master_dir and d.name.endswith(".lproj")
    )

    rows = []
    pending = []
    for locale_dir in locale_dirs:
        existing = set(load_stringsdict(locale_dir / STRINGSDICT_NAME))
        missing, removed = master_keys - existing, existing - master_keys
        rows.append([locale_dir.name, len(master_keys & existing), len(missing), len(removed)])
        if missing or removed:
            pending.append(locale_dir)

    print(f"\n🌍 Plural strings ({len(master_keys)} keys in {master_dir.name}/{STRINGSDICT_NAME})")
    print(tabulate(rows, headers=["Locale", "Translated", "Missing", "Removed from master"], tablefmt="grid"))

    if not pending:
        print("🎉 Every localization has all plural strings.")
        return

    confirmed = inquirer.prompt([
        inquirer.Confirm('confirm',
                         message=f"Translate missing and drop removed plural strings in {len(pending)} localization(s)?",
                         default=True),
    ])['confirm']
    if not confirmed:
        print("⏭️  Cancelled")
        return

    for locale_dir in pending:
        print(f"\n📁 {locale_dir.name}")
        translated, removed, still_missing = sync_locale_stringsdict(master_dir, locale_dir, from_lang)
        if translated:
            print(f"  ✅ Added {len(translated)}: {', '.join(translated)}")
        if removed:
            print(f"  🗑️  Removed {len(removed)} no longer in master: {', '.join(removed)}")
        if still_missing:
            print(f"  ⚠️  Still missing {len(still_missing)}: {', '.join(still_missing)}")


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

    if (master_dir / STRINGSDICT_NAME).exists():
        translated, _, still_missing = sync_locale_stringsdict(master_dir, new_dir, from_lang)
        print(f"✅ Created {new_dir / STRINGSDICT_NAME} with {len(translated)} plural string(s)")
        if still_missing:
            print(f"⚠️  Plural strings still missing: {', '.join(still_missing)}")

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
                         'Translate missing plural strings (stringsdict)',
                         'Verify main-app locale placeholders',
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
    """Interactive workflow for adding one or more new localizations."""
    answer = inquirer.prompt([
        inquirer.Text('lang_codes',
                      message="Enter language codes, space separated (e.g. 'ko ja ro pt-BR zh-Hans')"),
    ])['lang_codes']

    lang_codes = list(dict.fromkeys(answer.split()))
    if not lang_codes:
        print("❌ No language codes entered")
        return

    existing = [code for code in lang_codes if (master_dir.parent / f"{code}.lproj").exists()]
    for code in existing:
        print(f"⏭️  Skipping {code}: {code}.lproj already exists")
    lang_codes = [code for code in lang_codes if code not in existing]
    if not lang_codes:
        return

    # The name goes into the translation prompt and the file header.
    languages = []
    for code in lang_codes:
        lang_name = inquirer.prompt([
            inquirer.Text('lang_name', message=f"Full language name for '{code}' (e.g. 'Korean', 'Brazilian Portuguese')"),
        ])['lang_name'].strip()
        if not lang_name:
            print(f"⏭️  Skipping {code}: no language name given")
            continue
        languages.append((code, lang_name))

    if not languages:
        return

    summary = ", ".join(f"{name} ({code})" for code, name in languages)
    confirmed = inquirer.prompt([
        inquirer.Confirm('confirm',
                         message=f"Create {len(languages)} localization(s) with {len(master_keys_and_values)} strings each: {summary}?",
                         default=True),
    ])['confirm']
    if not confirmed:
        print("❌ Cancelled")
        return

    created = []
    for index, (code, lang_name) in enumerate(languages, start=1):
        print(f"\n🔄 [{index}/{len(languages)}] {lang_name} ({code})")
        if create_new_localization(master_keys_and_values, master_dir, code, lang_name, from_lang):
            created.append(f"{lang_name} ({code})")

    if created:
        print(f"\n🎉 Created {len(created)} localization(s): {', '.join(created)}")
        print("\n📱 Ensuring main app has locale placeholders...")
        ensure_main_app_locale_placeholders(master_dir, verbose=True)

def get_anthropic_api_key():
    """Get Anthropic API key from keychain, prompt user if not found, and save it."""
    service_name = "encamera_translation_anthropic_key"
    key_name = "encamera_translation_anthropic_key"
    
    try:
        # Try to get the key from keychain
        api_key = keyring.get_password(service_name, key_name)
        
        if api_key:
            print("🔑 Found Anthropic API key in keychain")
            return api_key
        else:
            print("🔑 Anthropic API key not found in keychain")
            
    except Exception as e:
        print(f"⚠️  Could not access keychain: {e}")
    
    # Prompt user for API key
    print("Please enter your Anthropic API key:")
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
                print("✅ API key saved to keychain as 'encamera_translation_anthropic_key'")
            except Exception as e:
                print(f"⚠️  Could not save to keychain: {e}")
        
    except Exception as e:
        # Fallback if inquirer fails
        response = input("Save this API key to keychain for future use? (y/n): ").lower()
        if response in ['y', 'yes']:
            try:
                keyring.set_password(service_name, key_name, api_key)
                print("✅ API key saved to keychain as 'encamera_translation_anthropic_key'")
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

    global client
    api_key = os.environ.get("ANTHROPIC_API_KEY") or get_anthropic_api_key()
    if not api_key:
        print("❌ Anthropic API key is required to proceed.")
        return

    client = anthropic.Anthropic(api_key=api_key)

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

    # Verify main-app locale placeholders on every run
    print("\n📱 Checking main-app locale placeholders...")
    ensure_main_app_locale_placeholders(master_dir, verbose=True)

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
            elif action == 'Translate missing plural strings (stringsdict)':
                interactive_translate_plurals(master_dir, from_lang)
            elif action == 'Verify main-app locale placeholders':
                print("\n📱 Verifying main-app locale placeholders...")
                ensure_main_app_locale_placeholders(master_dir, verbose=True)
            
            print("\n" + "=" * 40)
            
        except KeyboardInterrupt:
            print("\n\n👋 Goodbye!")
            break
        except Exception as e:
            print(f"\n❌ Error: {e}")
            break

if __name__ == '__main__':
    main()
