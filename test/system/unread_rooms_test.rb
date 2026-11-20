require "application_system_test_case"

class UnreadRoomsTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
  end

  test "sending messages between two users" do
    designers_room = rooms(:designers)
    hq_room = rooms(:hq)

    join_room hq_room
    assert_room_read hq_room

    using_session("Kevin") do
      sign_in "kevin@37signals.com"
      join_room designers_room

      perform_enqueued_jobs only: Message::BroadcastUnreadRoomJob do
        send_message("Hello!!")
        send_message("Talking to myself?")
      end
    end

    assert_room_unread designers_room

    join_room designers_room
    assert_room_read designers_room
  end

  test "a notice about a message from before the room was read in another tab doesn't mark it unread again" do
    using_session("Kevin in HQ") do
      sign_in "kevin@37signals.com"
      join_room_after_sidebar_reload rooms(:hq)
      broadcast_unread_notice rooms(:designers), to: users(:kevin), at: Time.current
      assert_room_unread rooms(:designers)
    end

    sent_before_reading = Time.current
    using_session("Kevin in Designers") do
      sign_in "kevin@37signals.com"
      join_room_after_sidebar_reload rooms(:designers)
    end

    using_session("Kevin in HQ") do
      assert_room_read rooms(:designers)

      broadcast_unread_notice rooms(:designers), to: users(:kevin), at: sent_before_reading
      broadcast_unread_notice rooms(:bender_and_kevin), to: users(:kevin), at: Time.current
      assert_selector "#" + dom_id(rooms(:bender_and_kevin), :list) + ".unread"
      assert_room_read rooms(:designers)

      broadcast_unread_notice rooms(:designers), to: users(:kevin), at: Time.current
      assert_room_unread rooms(:designers)
    end
  end

  test "a message after a read in the same second marks the room unread" do
    room = rooms(:designers)
    user = users(:jz)
    join_room_after_sidebar_reload rooms(:hq)
    read_at = Time.current.change(usec: 100_000)

    broadcast_unread_notice room, to: user, at: read_at - 1
    assert_room_unread room
    ActionCable.server.broadcast "user_#{user.id}_reads", { room_id: room.id, at: read_at.to_f }
    assert_room_read room

    broadcast_unread_notice room, to: user, at: read_at + 0.2
    assert_room_unread room
  end

  test "joining waits for the sidebar refresh before unread notices" do
    script = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
      document.addEventListener("turbo:frame-load", function holdSidebarReload({ target }) {
        if (target.id !== "user_sidebar") return
        document.removeEventListener("turbo:frame-load", holdSidebarReload)
        target.addEventListener("turbo:before-frame-render", event => {
          event.preventDefault()
          window.resumeSidebarRender = event.detail.resume
          target.setAttribute("data-system-test-render-held", "")
        }, { once: true })
      })
    JS

    error = assert_raises(Minitest::Assertion) do
      join_room_after_sidebar_reload rooms(:hq)
    end
    assert_includes error.message, "data-system-test-ready"
    assert_selector "#user_sidebar[data-system-test-render-held]", visible: false

    page.execute_script "window.resumeSidebarRender()"
    assert_selector "#user_sidebar[data-system-test-ready]", visible: false
    broadcast_unread_notice rooms(:designers), to: users(:jz), at: Time.current
    assert_room_unread rooms(:designers)
  ensure
    begin
      page.execute_script "window.resumeSidebarRender?.()" if script
    ensure
      page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: script.fetch("identifier")) if script
    end
  end

  private
    def join_room_after_sidebar_reload(room)
      script = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
        customElements.whenDefined("turbo-frame").then(() => {
          const prototype = customElements.get("turbo-frame").prototype
          const reload = prototype.reload
          prototype.reload = function(...args) {
            const loaded = reload.apply(this, args)
            if (this.id === "user_sidebar") {
              prototype.reload = reload
              loaded.then(() => this.setAttribute("data-system-test-ready", ""))
            }
            return loaded
          }
        })
      JS

      join_room room
      assert_selector "#user_sidebar[data-system-test-ready]", visible: false
    ensure
      page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: script.fetch("identifier")) if script
    end

    def broadcast_unread_notice(room, to:, at:)
      ActionCable.server.broadcast UnreadRoomsChannel.stream_name_for(to.id), { roomId: room.id, at: at.to_f }
    end
end
