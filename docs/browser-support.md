# Browser support and accessibility evidence

Campfire accepts Safari 17.2, Chrome 120, Firefox 121, Opera 104, and newer
versions. Individual platform features remain conditional: Web Share buttons are
shown only when the browser exposes both `navigator.share` and
`navigator.canShare`, and Web Push still depends on the browser, operating
system, permission, and installed-PWA rules.

## System test drivers

`SYSTEM_TEST_BROWSER` selects one deterministic Selenium configuration. An
unknown value fails while loading the system test case instead of silently
falling back to another browser.

| Value | Browser contract | Deterministic test settings |
| --- | --- | --- |
| `headless_chrome` (default) | Desktop Chrome | Headless, 1400 x 1400 CSS pixel window |
| `headless_firefox` | Desktop Firefox | Headless, 1400 x 1400 window, WebDriver BiDi enabled for preload scripts |
| `safari` | Desktop Safari | Visible Safari controlled by SafariDriver, 1400 x 1400 window |
| `headless_chrome_mobile` | Chrome Android emulation | Headless, 390 x 844 viewport, DPR 3, touch and coarse pointer, fixed Pixel 7/Android 14 user agent |

Cap local and CI concurrency with `PARALLEL_WORKERS`; CI uses two workers for
desktop suites and one for focused Safari and mobile suites.

```sh
PARALLEL_WORKERS=2 SYSTEM_TEST_BROWSER=headless_chrome bin/rails test:system
PARALLEL_WORKERS=2 SYSTEM_TEST_BROWSER=headless_firefox bin/rails test:system
PARALLEL_WORKERS=1 SYSTEM_TEST_BROWSER=headless_chrome_mobile \
  bin/rails test test/system/browser_contracts_test.rb test/system/accessibility_audit_test.rb
safaridriver --enable
PARALLEL_WORKERS=1 SYSTEM_TEST_BROWSER=safari \
  bin/rails test test/system/browser_contracts_test.rb
```

## Automated matrix

The CI browser version is printed in each job log. "Full" means every file in
`test/system`; "focused" means only the files named below. Browser emulation is
not physical-device evidence.

| Automated evidence | Headless Chrome desktop | Headless Firefox desktop | Safari on macOS | Chrome mobile emulation |
| --- | --- | --- | --- | --- |
| Full Rails system suite | Yes | Yes | No | No |
| Focused `browser_contracts_test.rb` | Included in full | Included in full | Yes, SafariDriver | Yes |
| Focused `accessibility_audit_test.rb` | Included in full | Included in full | No | Yes |
| Keyboard operation and visible focus | Yes | Yes | Sign-in contract | Sign-in contract |
| Reduced-motion CSS and behavior | Yes, Chrome media emulation | No deterministic automation | No deterministic automation | No focused run |
| Forced-colors focus visibility | Yes, Chrome media emulation | No deterministic automation | No deterministic automation | Yes, Chrome media emulation |
| 390 px viewport, coarse pointer, touch points, 24 px targets | No | No | No | Yes |
| Manifest fetch and real service-worker registration | Yes | Yes | Yes | Yes |
| Mocked Web Share and Push failure contracts | Yes | Yes | No | No |

The Safari job is deliberately focused because Safari has no supported headless
mode or deterministic media-feature emulation. It uses the Safari bundled with
the pinned macOS runner image and the system `safaridriver`; it is not iOS or
installed-PWA evidence.

### WCAG audit pages

`accessibility_audit_test.rb` injects the unmodified `axe-core` 4.12.1 artifact
from `test/support/axe`. The helper verifies SHA-256
`66a8aaa95a8b044a7fd74a5435873bf04ff65a1ca75567c921b7509742085a14`
before each audit. No Gemfile or package dependency is used. Audits run WCAG
2.0, 2.1, and 2.2 A/AA rule tags and fail on `serious` or `critical` violations.

| Critical state audited with axe | Chrome desktop | Firefox desktop | Safari | Chrome mobile emulation |
| --- | --- | --- | --- | --- |
| Local sign-in | Yes | Yes | No | Yes |
| Room and message list | Yes | Yes | No | Yes |
| Composer with a draft | Yes | Yes | No | Yes |
| Authentication failure and alert | Yes | Yes | No | Yes |
| Message submission failure and recovery actions | Yes | Yes | No | Yes |
| Profile form | Yes | Yes | No | Yes |

Automated rules detect only a subset of WCAG failures. A passing axe run is not
a WCAG conformance claim and does not establish accessible names, reading order,
announcements, speech output, gesture behavior, cognitive usability, zoom
usability, or physical-device behavior beyond the assertions made by the tests.

## Manual matrix

These checks require a human tester and real platform accessibility software.
They are not performed by WebDriver or axe.

| Manual release evidence | Platform | Required coverage |
| --- | --- | --- |
| VoiceOver with Safari | Current supported macOS hardware | Sign-in/error, room navigation, composer/failure recovery, profile, dialogs and focus, PWA smoke where available |
| VoiceOver with Safari | Physical iPhone or iPad | Touch exploration and gestures, virtual keyboard, narrow viewport, rotation, browser and installed-PWA smoke |
| TalkBack with Chrome | Physical supported Android device | Touch exploration and gestures, virtual keyboard, narrow viewport, browser and installed-PWA install/relaunch smoke |
| Keyboard-only | Safari, Chrome, and Firefox desktop | Logical order, no traps, visible focus, skip navigation, dialogs, disclosures, message actions, and failure recovery |
| Zoom and reflow | Desktop at 200% and 400%; mobile text scaling | No lost content or controls, horizontal reflow, composer and error usability |
| OS contrast and motion settings | Windows forced colors plus macOS/iOS/Android settings | Legibility, focus visibility, non-color cues, reduced animation, dark/light appearance |

Use the versioned template at
`docs/accessibility/manual-at-validation-v1.md`; duplicate it into the release
evidence location and retain the commit SHA, exact hardware/software versions,
results, defects, and sign-offs. CI on release branches validates that the v1
template still contains the required VoiceOver and TalkBack record fields. That
structural check neither performs assistive-technology testing nor verifies that
a human-entered result is true.

## Local recovery

Campfire keeps the current rich-text draft and unconfirmed text submissions
separately in `sessionStorage`. Each unconfirmed submission retains its original
client message ID, body, and retry action. A newer editor draft does not replace
an older pending submission, and retrying uses the original ID so a response
lost after commit does not create a second message. These values survive reloads
and reauthentication in the same tab, but browser session storage can be
unavailable or can be cleared when the tab is closed.

Selected file objects cannot be persisted in browser session storage. They stay
in memory after an upload error on the current page, but must be sent before a
reload or authentication transition or selected again afterward.

Message attachment bytes are served through the current authenticated room and
message route. Historical `/rails/active_storage/...` URLs are intentionally no
longer available and should not be treated as durable share links.
