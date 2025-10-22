# App Store Localization Script - Troubleshooting Guide

## Summary of Changes

### ✅ Fixed Issues
1. **Added robust logging** throughout the authentication and API request process
2. **Fixed relative path resolution** for the private key file (it now resolves relative to credentials.yml)
3. **Added private key validation** to ensure it's compatible with JWT ES256 signing before making API calls
4. **Added comprehensive error messages** with specific troubleshooting steps for 401 errors
5. **Added cryptography package** to requirements.txt (required for ES256 JWT signing)

### 🔍 Current Issue: 401 Unauthorized

The script is now working correctly in terms of:
- ✅ Loading the private key
- ✅ Generating JWT tokens
- ✅ Making properly formatted API requests

**However**, Apple is rejecting the credentials with a 401 "NOT_AUTHORIZED" error.

## Why You're Getting a 401 Error

The authentication process is working, but Apple is rejecting your credentials. This means one of the following:

### 1. ❌ Key ID doesn't match the private key
- **Current Key ID:** `C7MGZKX3NM`
- **Private key file:** `AuthKey_C7MGZKX3NM.p8`
- These appear to match, but verify they're correct

### 2. ❌ Issuer ID is incorrect
- **Current Issuer ID:** `36923f74-9153-4712-b861-35b7df778bca`
- This needs to match your Team ID / Issuer ID from App Store Connect

### 3. ❌ API key has been revoked or expired
- Check if the API key is still active in App Store Connect

### 4. ❌ API key doesn't have proper permissions
- The API key needs **App Manager** or **Admin** role to access the App Store Connect API

## How to Fix This

### Step 1: Verify Your Credentials in App Store Connect

1. Go to: https://appstoreconnect.apple.com/access/integrations/api
2. Log in with your Apple ID
3. Look for your API key with Key ID: **C7MGZKX3NM**
4. Verify:
   - ✅ Status is **Active** (not revoked)
   - ✅ Role is **App Manager** or **Admin**
   - ✅ The Issuer ID at the top of the page matches: `36923f74-9153-4712-b861-35b7df778bca`

### Step 2: If the API Key is Revoked or Missing

If you can't find the key or it's been revoked:

1. Generate a new API key in App Store Connect
2. Download the new `.p8` file
3. Update `credentials.yml` with:
   - New Key ID
   - New private key file path
   - Issuer ID (should remain the same)

### Step 3: Verify the Issuer ID

The Issuer ID is a UUID that's shown at the top of the Integrations page in App Store Connect. Make sure it matches exactly in your `credentials.yml`.

### Step 4: Check API Key Permissions

The API key **must** have one of these roles:
- Admin
- App Manager
- Developer (may not have sufficient permissions)
- Marketing (insufficient permissions)

If your key has insufficient permissions, you'll need to:
1. Revoke the current key
2. Generate a new one with the correct role

## Testing After Fixing

Once you've verified/updated your credentials:

```bash
cd /Users/akfreas/github/EncameraApp/EncameraCore/Sources/EncameraCore/scripts/app_store_localization
source venv/bin/activate
python3 localize.py
```

You should see:
```
✅ Successfully connected! Found app: [Your App Name]
```

## Enhanced Logging Output

The script now shows:
- 📂 Private key loading and validation
- 🔐 JWT token generation details
- 🌐 API request details
- ❌ Detailed error responses from Apple
- 🔍 Specific troubleshooting steps for common errors

## Dependencies

The following packages are now required (added to `requirements.txt`):
- `cryptography>=41.0.0` - Required for ES256 JWT signing
- `tqdm>=4.66.0` - Progress bars for translation batches

## Virtual Environment Setup

The script requires a Python virtual environment:

```bash
# Create virtual environment (one time)
python3 -m venv venv

# Activate virtual environment (every time)
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

## Next Steps

1. **Verify your credentials** in App Store Connect using the steps above
2. **Update credentials.yml** if needed with correct values
3. **Run the script again** to test

If you continue to get 401 errors after verifying everything is correct, you may need to:
- Generate a completely new API key
- Ensure your Apple Developer account has the right access level
- Contact Apple Support if the issue persists

