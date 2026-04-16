# URL Unfurling Feature

This application includes an optional URL unfurling feature that automatically creates rich previews for URLs pasted or typed in chat messages.

## Configuration

The unfurling feature is controlled by the `ENABLE_URL_UNFURLING` environment variable:

- **Enabled**: Set `ENABLE_URL_UNFURLING=true`
- **Disabled**: Set `ENABLE_URL_UNFURLING=false` or leave unset (default)

## How to Enable

### Development
```bash
export ENABLE_URL_UNFURLING=true
bin/rails server
```

### Production
Add to your environment configuration:
```bash
ENABLE_URL_UNFURLING=true
```

## How it Works

When enabled, the system will:

1. **Detect URLs** as you type or paste them in chat messages
2. **Fetch OpenGraph metadata** from the target website
3. **Create rich previews** with title, description, and image
4. **Display previews** in the chat interface

## Features

- ✅ **Paste detection** - Immediate unfurling when pasting URLs
- ✅ **Type detection** - Unfurling after 1 second of no typing
- ✅ **Rich previews** - Title, description, image, and clickable links
- ✅ **Beautiful styling** - Similar to The Lounge's implementation
- ✅ **Network resilience** - Retry logic for network issues
- ✅ **Optional feature** - Can be disabled via environment variable

## Supported URLs

The system works with any website that provides OpenGraph metadata, including:
- GitHub repositories
- YouTube videos
- Reddit posts
- News articles
- Social media posts
- And many more!

## Disabling the Feature

To disable URL unfurling:

1. Set `ENABLE_URL_UNFURLING=false` or remove the environment variable
2. Restart the application
3. URLs will no longer be unfurled and will appear as regular links
