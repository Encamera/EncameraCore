# App Store Localization Script

This script helps translate and update App Store Connect metadata using Claude (Anthropic API) and the App Store Connect API. It provides a single source of truth for all your App Store listing content, handling both base language updates and translations in one workflow.

## Features

- 🌍 Translates App Store listing content using Claude
- 🏠 Updates base language content directly (no translation needed)
- 🔄 Updates App Store Connect metadata via API for ALL languages
- 🔍 Performs preflight checks to verify API connectivity
- 💾 Secure keychain storage for API keys
- 📊 Interactive preview of all content (base + translations) before upload
- 🚨 Robust error handling and automatic recovery
- 🔧 Smart conflict resolution for existing localizations
- 🔍 Flexible locale matching (handles format differences)

## Setup

### 1. Create Virtual Environment

```bash
# Create virtual environment (one time only)
python3 -m venv venv

# Activate virtual environment (every time you use the script)
source venv/bin/activate
```

### 2. Install Dependencies

```bash
# Make sure virtual environment is activated first!
pip install -r requirements.txt
```

**Important**: The script requires the `cryptography` package for JWT signing with the ES256 algorithm. This is included in `requirements.txt`.

### 3. Configure Credentials

Create a `credentials.yml` file with your API credentials:

```yaml
# App Store Connect API Configuration
app_store_connect:
  key_id: "YOUR_KEY_ID"                    # Your API Key ID (10 characters)
  issuer_id: "YOUR_ISSUER_ID"              # Your Issuer ID (UUID format)
  private_key_file: "AuthKey_KEY_ID.p8"    # Path to your .p8 private key file

# Anthropic Configuration (optional; these are the defaults)
# The API key is read from ANTHROPIC_API_KEY, then the keychain, then a prompt.
anthropic:
  api_key_keychain_service: "encamera_translation_anthropic_key" # Service name for keychain storage
  api_key_keychain_account: "encamera_translation_anthropic_key" # Account name for keychain
  model: "claude-opus-5-5"
  effort: "medium"                         # low | medium | high | xhigh | max

# App Configuration
app:
  bundle_id: "com.yourcompany.yourapp"     # Your app's bundle identifier
```

### 4. Configure Content

Create an `app_store.yml` file with your content to translate:

```yaml
# Base language (will be translated FROM this language)
base_language: "en-US"

# Target languages (matching your .lproj structure)
target_languages:
  - "ja"     # Japanese
  - "de"     # German
  - "es"     # Spanish

# App Store listing content (in base language)
listing:
  description: |
    Your comprehensive app description here.
    
    This can be multiple paragraphs describing features, benefits, and use cases.

  promotional_text: |
    Limited time offer! Get premium features free for the first month.

  whats_new: |
    Version 2.1.0 - New Features & Improvements
    
    • Added dark mode support
    • Improved performance and stability

# Translation settings
translation:
  preserve_formatting: true
  preserve_placeholders: true
  context_note: "This is an iOS app store listing for a camera/photo app"
```

## Usage

### Basic Usage

```bash
# Auto-detect config files in current directory
python localize.py

# Specify config files explicitly
python localize.py --config ./app_store.yml --credentials ./credentials.yml
```

### Advanced Options

```bash
# Preview translations without uploading to App Store
python localize.py --dry-run

# Skip preflight API connectivity check
python localize.py --skip-preflight

# Show help
python localize.py --help
```

### Example Output

The script now processes both base language and translations:

```
🌍 All languages to process: en, ja, ro, de-DE
📋 Fields to process: description, promotional_text

🔄 Processing 'description'...
  → en (base): ✅ Using original content
  → ja... ✅
  → ro... ✅
  → de-DE... ✅

📋 Content Preview (Base Language + Translations)
┌─────────────────┬────────────────────────────────────┐
│ Language        │ Content                            │
├─────────────────┼────────────────────────────────────┤
│ en (BASE)       │ Encamera is the ultimate privacy... │
│ ja (TRANSLATED) │ Encameraは究極のプライバシー重視の... │
│ ro (TRANSLATED) │ Encamera este aplicația foto...    │
│ de-DE (TRANSLATED)│ Encamera ist die ultimative...   │
└─────────────────┴────────────────────────────────────┘

📝 Processing en (en-US) - BASE LANGUAGE...
  ✅ Updated base language localization for en-US

📝 Processing ja (ja-JP) - TRANSLATED...  
  ✅ Updated translated localization for ja-JP

🎉 Completed! Updated: 4, Created: 0 localizations
```

## How It Works

1. **Configuration Validation** - Validates all required config values are present
2. **Preflight Check** - Verifies App Store Connect API connectivity  
3. **Content Processing** - Uses original content for base language, translates for target languages
4. **Preview** - Shows all content (base + translated) in a table format for review
5. **Upload** - Updates or creates localizations for ALL languages (base + translations) in App Store Connect

## Supported Fields

Currently supports processing these fields:
- `description` - App description
- `promotional_text` - Promotional text  
- `whats_new` - What's new/release notes

**For each field:**
- **Base Language**: Uses content directly from `app_store.yml` (no translation)
- **Target Languages**: Translates content using Claude
- **App Store**: Updates localizations for ALL languages

## Language Mapping

The script automatically maps language codes to App Store locales:

| Input Code | App Store Locale |
|------------|------------------|
| `de`       | `de-DE`         |
| `ja`       | `ja-JP`         |
| `ko`       | `ko-KR`         |
| `es`       | `es-ES`         |
| `fr`       | `fr-FR`         |
| `it`       | `it-IT`         |
| `pt`       | `pt-BR`         |
| `ru`       | `ru-RU`         |
| `zh`       | `zh-Hans`       |

## Error Handling

- **API Errors** - Detailed error messages for App Store Connect issues
- **Translation Errors** - Graceful handling of Anthropic API failures  
- **Preflight Checks** - Early detection of authentication problems
- **Individual Language Failures** - Script continues if one language fails

## Security

- API keys stored securely in system keychain
- Private keys loaded from secure files
- JWT tokens automatically refreshed
- No sensitive data in logs

## Troubleshooting

### 🚨 401 Unauthorized Error

If you're getting a 401 error, **see [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)** for detailed steps to fix authentication issues.

The script now provides comprehensive troubleshooting output when authentication fails, including:
- Detailed credential verification steps
- Links to App Store Connect pages
- Common causes and solutions
- How to generate new API keys if needed

### Common Issues

1. **"Missing required configuration values"**
   - Check that all required fields are present in `credentials.yml`
   - Ensure `private_key_file` path is correct and file exists
   - Verify `bundle_id` matches your app's identifier

2. **"Preflight check failed"**
   - Verify your App Store Connect API credentials
   - Check that your private key file exists and is readable
   - Ensure your app exists and you have proper permissions
   - **See TROUBLESHOOTING.md for detailed 401 error help**

3. **"No target languages specified"**
   - Add `target_languages` list to your `app_store.yml` file

4. **"Translation failed"**
   - Verify your Anthropic API key is valid
   - Check your internet connection
   - Try reducing the content length

5. **"400 Client Error" on appStoreVersions**
   - This usually indicates invalid appStoreState filter values
   - The script automatically retries without state filtering if this occurs
   - Check the debug output to see what app version states are actually available
   - Your app might not have versions in the expected states (e.g., only READY_FOR_SALE)

6. **"409 Conflict" when creating localizations**
   - This means the localization already exists but wasn't detected initially
   - The script automatically refreshes the localization list and retries as an update
   - Uses flexible matching to handle locale format differences (e.g., 'ja' vs 'ja-JP')
   - Check debug output to see exactly which locales were found

7. **"ModuleNotFoundError: No module named 'cryptography'"**
   - Make sure you activated the virtual environment: `source venv/bin/activate`
   - Reinstall dependencies: `pip install -r requirements.txt`

### Debug Mode

Run with `--skip-preflight` to bypass connectivity checks if needed.

### Enhanced Logging

The script now provides comprehensive debugging information:
- 📂 Private key loading and validation steps
- 🔐 JWT token generation details (without exposing secrets)
- 🌐 API request details (URL, headers, parameters)
- ❌ Full error responses from Apple with JSON details
- 🔍 Specific troubleshooting steps based on error type
- 📊 Lists all found app versions with their current states
- 🗺️ Displays existing localizations with their IDs and formats
- 🔄 Shows locale matching attempts and available alternatives
- ♻️ Automatically retries failed requests with broader parameters
- 🔧 Handles 409 Conflict errors with automatic refresh and retry

## Requirements

- Python 3.7+
- Valid App Store Connect API access
- Anthropic API key
- Internet connection
