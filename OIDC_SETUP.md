# OpenID Connect (OIDC) Authentication Setup

This application now supports OpenID Connect authentication alongside the existing email/password authentication.

## Environment Variables

Set the following environment variables to enable OIDC authentication:

### Required Variables
- `OIDC_ISSUER` - The OIDC provider's issuer URL (e.g., https://your-oidc-provider.com)
- `OIDC_CLIENT_ID` - Your OIDC client ID
- `OIDC_CLIENT_SECRET` - Your OIDC client secret

### Optional Variables
- `OIDC_PROVIDER_NAME` - Display name for the provider (defaults to "OpenID Connect")
- `OIDC_REDIRECT_URI` - Callback URL (defaults to `{app_url}/auth/oidc/callback`)

### Optional Endpoint Overrides
If your OIDC provider doesn't support auto-discovery, you can manually specify endpoints:
- `OIDC_AUTHORIZATION_ENDPOINT`
- `OIDC_TOKEN_ENDPOINT`
- `OIDC_USERINFO_ENDPOINT`

## Setup Instructions

1. Install the required gems:
   ```bash
   bundle install
   ```

2. Configure your OIDC provider:
   - Register your application with the OIDC provider
   - Set the redirect URI to: `{your_app_url}/auth/oidc/callback`
   - Obtain the client ID and secret

3. Set the environment variables:
   ```bash
   export OIDC_ISSUER=https://your-oidc-provider.com
   export OIDC_CLIENT_ID=your-client-id
   export OIDC_CLIENT_SECRET=your-client-secret
   export OIDC_PROVIDER_NAME="Your Provider Name"
   ```

4. Restart your Rails application

## How It Works

- When OIDC is configured, users will see both OIDC and traditional login options
- OIDC users are automatically created or matched by email address
- The application maintains backward compatibility with existing email/password authentication
- If no users exist (first run), OIDC login will redirect to the first run setup

## User Creation

- Existing users are matched by email address
- New users are automatically created with information from the OIDC provider
- User names are extracted from the OIDC profile (name, nickname, or email prefix)
- Random passwords are generated for OIDC users (since they authenticate via OIDC)

