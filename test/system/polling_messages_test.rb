require "application_system_test_case"

class PollingMessagesTest < ApplicationSystemTestCase
  setup do
    sign_in "kevin@37signals.com"
    join_room rooms(:designers)
  end

  test "creating and voting on a poll" do
    click_on "Create poll"
    fill_in_rich_text_area "poll_question", with: "What should we ship next?"
    fill_in "poll[options_attributes][0][body]", with: "Mobile"
    fill_in "poll[options_attributes][1][body]", with: "Desktop"
    click_on "Create poll"

    assert_selector ".poll", text: "What should we ship next?"
    click_on "Mobile"
    assert_selector ".poll__results", text: "1 vote", wait: 5
  end
end
