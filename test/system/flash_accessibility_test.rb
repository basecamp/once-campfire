require "application_system_test_case"
require "timeout"

class FlashAccessibilityTest < ApplicationSystemTestCase
  test "flash remains dismissible with reduced motion and has readable contrast" do
    emulate_media "prefers-color-scheme" => "dark", "prefers-reduced-motion" => "reduce"
    sign_in users(:jz).email_address
    visit user_profile_url
    fill_in "user_name", with: "JZ Updated"
    click_on "Save changes"

    assert_selector ".flash__inner", wait: 5
    sleep 0.5
    assert_selector ".flash__inner"
    assert_operator flash_contrast_ratio, :>=, 4.5

    click_on "Dismiss notification"
    assert_no_selector ".flash"
  end

  test "error flash remains until it is dismissed" do
    visit new_session_url
    fill_in "email_address", with: users(:jz).email_address
    fill_in "password", with: "incorrect password"
    click_on "log_in"

    assert_selector ".flash--error", text: "Too many requests or unauthorized.", wait: 5
    sleep 4
    assert_selector ".flash--error", text: "Too many requests or unauthorized."

    click_on "Dismiss notification"
    assert_no_selector ".flash"
  end

  test "informational flash pauses while hovered" do
    sign_in users(:jz).email_address
    visit user_profile_url
    fill_in "user_name", with: "JZ Updated"
    click_on "Save changes"

    find(".flash").hover
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script(
        "getComputedStyle(document.querySelector('.flash__inner')).animationPlayState"
      ) == "paused"
    end
    assert_equal "paused", page.evaluate_script("getComputedStyle(document.querySelector('.flash__inner')).animationPlayState")
  end

  test "sign in errors do not shake with reduced motion" do
    emulate_media "prefers-reduced-motion" => "reduce"
    visit new_session_url
    fill_in "email_address", with: users(:jz).email_address
    fill_in "password", with: "incorrect password"
    click_on "log_in"

    assert_selector ".shake"
    assert_equal "none", page.evaluate_script("getComputedStyle(document.querySelector('.shake')).animationName")
  end

  private
    def flash_contrast_ratio
      page.evaluate_script <<~JAVASCRIPT
        (() => {
          const node = document.querySelector(".flash__inner");
          const style = getComputedStyle(node);
          const canvas = document.createElement("canvas");
          canvas.width = canvas.height = 1;
          const context = canvas.getContext("2d");
          const rgb = (color) => {
            context.clearRect(0, 0, 1, 1);
            context.fillStyle = color;
            context.fillRect(0, 0, 1, 1);
            return Array.from(context.getImageData(0, 0, 1, 1).data.slice(0, 3));
          };
          const luminance = (color) => {
            const channels = rgb(color).map((value) => {
              value /= 255;
              return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
            });
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
          };
          const foreground = luminance(style.color);
          const background = luminance(style.backgroundColor);
          return (Math.max(foreground, background) + 0.05) / (Math.min(foreground, background) + 0.05);
        })()
      JAVASCRIPT
    end
end
