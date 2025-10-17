# Zoom Weekly Call Setup

This application includes a weekly zoom call page that displays information about the next Tuesday's meeting.

## Environment Variables

Set the following environment variables to configure the zoom call page:

### Required Variables
- `ZOOM_MEETING_LINK` - The full Zoom meeting URL (e.g., https://us06web.zoom.us/j/82136981968?pwd=0BZaVHCNCaitltOyXflcvwV4qhOzdk.1)
- `ZOOM_MEETING_ID` - The Zoom meeting ID (e.g., 821 3698 1968)
- `ZOOM_PASSCODE` - The Zoom meeting passcode (e.g., 219684)

### Optional Variables
- `ZOOM_MEETING_TIME_GMT` - The meeting time in GMT (24-hour format, e.g., "18:00" for 6:00 PM GMT, defaults to "18:00")
  - EST/EDT and KSA times are automatically calculated from this GMT time

## Setup Instructions

1. Set the environment variables:
   ```bash
   export ZOOM_MEETING_LINK="https://us06web.zoom.us/j/82136981968?pwd=0BZaVHCNCaitltOyXflcvwV4qhOzdk.1"
   export ZOOM_MEETING_ID="821 3698 1968"
   export ZOOM_PASSCODE="219684"
   export ZOOM_MEETING_TIME_GMT="18:00"  # Optional: defaults to 18:00 (6:00 PM GMT)
   ```

2. Restart your Rails application

## How It Works

- The page automatically calculates the next Tuesday from the current date
- The meeting time is based on GMT and can be configured via the `ZOOM_MEETING_TIME_GMT` environment variable
- EST/EDT and KSA times are automatically calculated from the GMT base time
- The meeting information is displayed with the calculated day and date
- Users can access the page via the "Quick Links" section in the sidebar
- The page includes all meeting details and important instructions

## Features

- **Dynamic Date Calculation**: Automatically shows the next Tuesday's date
- **Meeting Details**: Displays meeting link, ID, and passcode from environment variables
- **Sidebar Integration**: Accessible via the "Quick Links" section in the sidebar
- **Responsive Design**: Works on both desktop and mobile devices
- **External Links**: Zoom links open in new tabs for better user experience

## Page Content

The page displays:
- Next Tuesday's day and date
- Meeting times in EST, UK, and KSA timezones
- Clickable Zoom meeting link
- Meeting ID and passcode
- Help link for joining Zoom calls
- Important instructions about cameras and privacy
- Comfort recommendations for the call
