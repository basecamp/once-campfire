# Manual assistive technology validation record (v1)

This is a template for human-performed release evidence. Duplicate it for a
release; do not record results in this template. Automation verifies the
template structure only. It does not launch, operate, or validate VoiceOver or
TalkBack.

## Record metadata

- Record format: `campfire-manual-at-v1`
- Release or ref: `<required>`
- Commit SHA: `<required>`
- Test date (UTC): `<YYYY-MM-DD>`
- Tester: `<required>`
- Build or deployment URL: `<required>`

Use `pass`, `fail`, or `blocked` for every result. A failed or blocked required
scenario prevents sign-off unless the release owner records an explicit
exception in the defects section.

## VoiceOver

- Status: `<pass|fail|blocked>`
- Hardware: `<required>`
- OS and version: `<required>`
- Safari version: `<required>`
- VoiceOver configuration or non-default settings: `<required-or-none>`
- Input method: `<keyboard|touch-gestures|both>`

| ID | Manual scenario | Result | Notes or defect link |
| --- | --- | --- | --- |
| VO-01 | Sign in, hear field names, error feedback, and recovery instructions | `<pass|fail|blocked>` | `<required>` |
| VO-02 | Enter a room; navigate room, message list, and unread state by landmark and control | `<pass|fail|blocked>` | `<required>` |
| VO-03 | Compose, format, attach, send, and recover a failed message without pointer input | `<pass|fail|blocked>` | `<required>` |
| VO-04 | Edit profile fields and confirm validation and saved-state announcements | `<pass|fail|blocked>` | `<required>` |
| VO-05 | Validate focus after dialogs, message actions, errors, and Turbo navigation | `<pass|fail|blocked>` | `<required>` |
| VO-06 | Install or open the PWA where supported and repeat sign-in and message smoke paths | `<pass|fail|blocked>` | `<required>` |

## TalkBack

- Status: `<pass|fail|blocked>`
- Physical device: `<required>`
- Android and device version: `<required>`
- Chrome version: `<required>`
- TalkBack version and configuration: `<required>`
- Installation mode: `<browser|installed-pwa|both>`

| ID | Manual scenario | Result | Notes or defect link |
| --- | --- | --- | --- |
| TB-01 | Sign in, hear field names, error feedback, and recovery instructions | `<pass|fail|blocked>` | `<required>` |
| TB-02 | Enter a room; navigate room, message list, and unread state by swipe and control | `<pass|fail|blocked>` | `<required>` |
| TB-03 | Compose, format, attach, send, and recover a failed message with touch exploration | `<pass|fail|blocked>` | `<required>` |
| TB-04 | Edit profile fields and confirm validation and saved-state announcements | `<pass|fail|blocked>` | `<required>` |
| TB-05 | Validate focus after dialogs, message actions, errors, and Turbo navigation | `<pass|fail|blocked>` | `<required>` |
| TB-06 | Install the PWA and repeat sign-in, relaunch, offline-shell, and message smoke paths | `<pass|fail|blocked>` | `<required>` |

## Defects and exceptions

| Defect or exception | Severity | Owner | Release decision |
| --- | --- | --- | --- |
| `<required-or-none>` | `<required-or-none>` | `<required-or-none>` | `<required-or-none>` |

## Sign-off

- Overall result: `<pass|fail|blocked>`
- Tester sign-off and date: `<required>`
- Release owner sign-off and date: `<required>`
- Evidence attachments or recording location: `<required>`
