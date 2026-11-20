require "test_helper"

class RoomsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "index redirects to the user's last room" do
    get rooms_url
    assert_redirected_to room_url(users(:david).rooms.last)
  end

  test "show" do
    get room_url(users(:david).rooms.last)
    assert_response :success
  end

  test "show carries the message menu once and each message only its button" do
    room = rooms(:watercooler)
    message = room.messages.ordered.last
    get room_url(room)

    assert_response :success
    assert_select ".message .message__options-btn", count: room.messages.count
    assert_select ".message .message__actions-menu", count: 0

    menu = message_menu_for(message)
    assert_equal 1, menu.css(".message__actions-menu[data-popup-target='menu']").size
    assert_not_includes menu.to_html, "$messageId$"

    new_boost = menu.at_css("a.message__boost-btn")
    assert_equal new_message_boost_path(message), new_boost["href"]
    assert_equal dom_id(message, :new_boost), new_boost["data-turbo-frame"]

    edit = menu.at_css("a.message__edit-btn")
    assert_equal edit_room_message_path(room, message), edit["href"]
    assert_equal dom_id(message, :edit), edit["data-turbo-frame"]

    assert menu.at_css("button[title='Reply'][data-action='reply#reply']")
    assert_nil menu.at_css("[title='Download']")
    assert_nil menu.at_css("[title='Share']")
  end

  test "show renders notification help for each platform" do
    {
      "Firefox on Android" => "Mozilla/5.0 (Android 14; Mobile; rv:131.0) Gecko/131.0 Firefox/131.0",
      "Chrome on Android" => "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36",
      "Firefox on desktop" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:131.0) Gecko/20100101 Firefox/131.0",
      "Chrome on desktop" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
      "Safari on macOS" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }.each do |platform, user_agent|
      get room_url(users(:david).rooms.last), headers: { "User-Agent" => user_agent }

      assert_response :success, platform
      assert_select ".notifications-help ol", { minimum: 1 }, platform
    end
  end

  test "shows records the last room visited in a cookie" do
    get room_url(users(:david).rooms.last)
    assert response.cookies[:last_room] = users(:david).rooms.last.id
  end

  test "show renders a link preview written by hand without its off-scheme image and link" do
    room = rooms(:watercooler)
    post room_messages_url(room, format: :turbo_stream), params: { message: {
      body: link_preview_body(href: "javascript:alert(1)", url: "data:image/svg+xml;base64,PHN2Zy8+"),
      client_message_id: "hand-written-preview" } }
    assert_response :success

    get room_url(room)

    assert_response :success
    assert_no_match /javascript:alert/, response.body
    assert_no_match /data:image\/svg/, response.body
    assert_match "Free cookies", response.body
  end

  test "show renders a link preview written by hand without its image pointed at this Campfire" do
    room = rooms(:watercooler)
    own_url = room_url(room, host: "www.example.com")
    post room_messages_url(room, format: :turbo_stream), params: { message: {
      body: link_preview_body(href: own_url, url: own_url),
      client_message_id: "same-host-preview" } }
    assert_response :success

    get room_url(room)

    assert_response :success
    assert_no_match %r{<img src="#{Regexp.escape(own_url)}"}, response.body
    assert_no_match %r{<a rel="noreferrer" target="_blank" href="#{Regexp.escape(own_url)}"}, response.body
    assert_match "Free cookies", response.body
  end

  test "show renders an unfurled link preview" do
    room = rooms(:watercooler)
    post room_messages_url(room, format: :turbo_stream), params: { message: {
      body: link_preview_body(href: "https://example.com/page", url: "https://example.com/image.png"),
      client_message_id: "unfurled-preview" } }
    assert_response :success

    get room_url(room)

    assert_response :success
    assert_match %r{<img src="https://example\.com/image\.png"}, response.body
    assert_match %r{href="https://example\.com/page"}, response.body
  end

  test "destroy" do
    assert_turbo_stream_broadcasts :rooms, count: 1 do
      assert_difference -> { Room.count }, -1 do
        perform_enqueued_jobs { delete room_url(rooms(:designers)) }
      end
    end
  end

  test "destroy takes the room away from its members at once and leaves its messages to a job" do
    room = rooms(:designers)
    member_ids = room.memberships.pluck(:user_id)

    assert_enqueued_with(job: Room::DestroyJob, args: [ room, member_ids ]) do
      assert_no_difference -> { Message.count } do
        delete room_url(room)
        assert_redirected_to root_url
      end
    end
    assert_empty room.memberships.reload
  end

  test "destroy only allowed for creators or those who can administer" do
    sign_in :jz

    assert_no_difference -> { Room.count } do
      delete room_url(rooms(:designers))
      assert_response :forbidden
    end

    rooms(:designers).update! creator: users(:jz)

    assert_difference -> { Room.count }, -1 do
      perform_enqueued_jobs { delete room_url(rooms(:designers)) }
    end
  end

  private
    def link_preview_body(href:, url:)
      %(<div><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" ) +
        %(href="#{href}" url="#{url}" filename="Free cookies" caption="Cookies here"></action-text-attachment></div>)
    end
end
