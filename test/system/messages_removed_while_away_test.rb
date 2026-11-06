require "application_system_test_case"

class MessagesRemovedWhileAwayTest < ApplicationSystemTestCase
  setup do
    @room = rooms(:designers)
    @kept = @room.messages.create!(body: "Still here", creator: users(:david))
    @edited = @room.messages.create!(body: "To be edited", creator: users(:david))

    sign_in "jz@37signals.com"
  end

  test "a message deleted while the page is disconnected is gone once it reconnects" do
    deleted = @room.messages.create!(body: "To be deleted", creator: users(:kevin))
    join_room @room
    assert_message_text "To be deleted"

    while_disconnected do
      # What MessagesController#destroy does.
      deleted.destroy
      deleted.broadcast_remove
    end

    assert_no_message_text "To be deleted"
    assert_message_text "Still here"
  end

  test "the messages of someone banned while the page is disconnected are gone once it reconnects" do
    @room.messages.create!(body: "Spam one", creator: users(:kevin))
    @room.messages.create!(body: "Spam two", creator: users(:kevin))
    join_room @room
    assert_message_text "Spam two"

    while_disconnected do
      # What RemoveBannedContentJob does after a ban.
      users(:kevin).remove_banned_content
    end

    assert_no_message_text "Spam one"
    assert_no_message_text "Spam two"
    assert_message_text "Still here"
  end

  private
    # Takes the page's cable connection down and keeps it down, as a sleeping laptop or a dropped network would, then
    # brings it back. A message edited meanwhile comes back with the refresh after reconnecting, so once it shows the
    # refresh has been answered.
    def while_disconnected
      page.driver.browser.execute_cdp("Network.enable")
      page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [ "*/cable*" ])
      ActionCable.server.remote_connections.where(current_user: users(:jz)).disconnect(reconnect: true)
      assert_no_selector "turbo-cable-stream-source[connected]", visible: false, wait: 10

      yield
      @edited.update!(body: "Edited while away")

      page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
      assert_message_text "Edited while away", wait: 60
    ensure
      page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
    end

    def assert_no_message_text(text)
      assert_no_selector ".message__body", text: text
    end
end
