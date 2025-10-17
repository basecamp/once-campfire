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
- `DISABLE_LOCAL_LOGIN` - Set to `true` to disable local email/password authentication (defaults to `false`)
- `DISABLE_SSO` - Set to `true` to disable SSO/OIDC authentication (defaults to `false`)

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
- User names are built from first_name and last_name from WordPress, with fallbacks to display_name, nickname, or email prefix
- Random passwords are generated for OIDC users (since they authenticate via OIDC)

## Role-Based Access Control

The application filters users by WordPress role. Only users with the following roles can log in:
- Administrator
- Paid Member
- Free Trial
- Student

**Note:** Configure your WordPress OIDC provider to include user roles in the response. Until roles are configured, all authenticated users are allowed access.

## Disabling Local Authentication

To enforce SSO-only access, set:
```bash
DISABLE_LOCAL_LOGIN=true
```

When enabled, this will:
- Hide the email/password login form (only OIDC button is shown)
- Block local login attempts
- Prevent new user registration via the join code
- Hide email and password fields from user profile pages
- Prevent password changes through the application

Users will only be able to authenticate through the configured OIDC provider.

## Disabling SSO Authentication

To disable SSO/OIDC authentication and only allow local email/password authentication, set:
```bash
DISABLE_SSO=true
```

When enabled, this will:
- Hide the SSO login button from the login page
- Block OIDC login attempts
- Prevent OmniAuth configuration from being loaded
- Redirect OIDC callback attempts back to the login page
- Focus the email field by default on the login page

Users will only be able to authenticate using email/password authentication.

