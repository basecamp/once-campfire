require "application_system_test_case"

class AccessibilityAuditTest < ApplicationSystemTestCase
  test "sign-in page has no serious or critical WCAG violations" do
    visit new_session_url

    assert_selector "form input[name='email_address']"
    assert_no_serious_accessibility_violations
  end

  test "room page has no serious or critical WCAG violations" do
    sign_in users(:jz).email_address
    join_room rooms(:designers)

    assert_no_serious_accessibility_violations
  end

  test "composer has no serious or critical WCAG violations" do
    sign_in users(:jz).email_address
    join_room rooms(:designers)
    fill_in_rich_text_area "message_body", with: "Accessibility audit draft"

    assert_no_serious_accessibility_violations context: "#composer"
  end

  test "authentication failure has no serious or critical WCAG violations" do
    visit new_session_url
    fill_in "email_address", with: users(:jz).email_address
    fill_in "password", with: "incorrect password"
    click_on "log_in"

    assert_selector ".flash--error[role='alert'], .flash--error [role='alert']"
    assert_no_serious_accessibility_violations
  end

  test "message submission failure has no serious or critical WCAG violations" do
    sign_in users(:jz).email_address
    join_room rooms(:designers)
    execute_script_in_page_realm <<~JAVASCRIPT
      document.addEventListener("turbo:before-fetch-request", (event) => {
        const { fetchOptions, url } = event.detail;
        if (fetchOptions.method === "POST" && url.pathname.endsWith("/messages")) {
          event.detail.fetchRequest = {
            response: Promise.resolve(new Response("", {
              status: 503,
              headers: { "Content-Type": "text/vnd.turbo-stream.html" }
            }))
          };
        }
      });
    JAVASCRIPT
    fill_in_rich_text_area "message_body", with: "Accessibility failure audit"
    click_on "Send Message"

    assert_selector ".message--failed [role='alert']", text: "Message outcome is unknown."
    assert_no_serious_accessibility_violations
  end

  test "profile page has no serious or critical WCAG violations" do
    sign_in users(:jz).email_address
    visit user_profile_url

    assert_selector "form input[name='user[name]']"
    assert_no_serious_accessibility_violations
  end
end
