require "application_system_test_case"

class AccessibilityControlsTest < ApplicationSystemTestCase
  setup do
    sign_in users(:jz).email_address
  end

  test "translation disclosures are keyboard accessible" do
    visit user_profile_url
    summary = find("details:has(> .language-list-menu) > summary", match: :first)

    assert_not_equal "-1", summary[:tabindex]
    summary.send_keys :enter

    assert_selector "details[open] > .language-list-menu", visible: true
  end

  test "ping action has an accessible name" do
    visit user_url(users(:jason))

    assert_selector "button[aria-label='Ping #{users(:jason).name}']"
  end

  test "lightbox image uses the attachment filename as its alternative" do
    message = rooms(:designers).messages.first
    message.attachment.attach(
      io: file_fixture("earth.png").open, filename: "earth.png", content_type: "image/png"
    )
    message.attachment.representation(:thumb).processed
    join_room rooms(:designers)

    find("[data-lightbox-target='image']", match: :first).click

    assert_selector "dialog[open] img[data-lightbox-target='zoomedImage'][alt='earth.png']"
  end

  test "message editor scrolling honors reduced motion" do
    emulate_media "prefers-reduced-motion" => "reduce"
    join_room rooms(:designers)
    page.execute_script <<~JAVASCRIPT
      Element.prototype.scrollIntoView = function(options) {
        window.scrollIntoViewOptionsForTest = options;
      };
    JAVASCRIPT

    within_message messages(:third) do
      reveal_message_actions
      find(".message__edit-btn").click
      assert_selector "trix-editor[aria-label='Edit message']"
    end

    assert_equal "auto", page.evaluate_script("window.scrollIntoViewOptionsForTest.behavior")
  end
end
