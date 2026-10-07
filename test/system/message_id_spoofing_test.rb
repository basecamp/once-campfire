require "application_system_test_case"

# Visual proof for GHSA-3v99-4vxh-xg84 under the server-id fix.
#
# Before the fix a message rendered with the DOM id "message_<client_message_id>",
# where the client_message_id is chosen by the browser. create/update/destroy Turbo
# Stream broadcasts targeted that DOM id and a browser resolves it to the FIRST
# matching element, so an attacker (a non-admin room member) who reused the victim's
# client_message_id could displace the victim's message in every connected browser.
#
# This fix derives every message DOM id from the record's primary key instead, so two
# distinct records can never share a DOM id no matter what client_message_id they carry.
# The attacker's colliding create still succeeds (there is no uniqueness constraint and
# none is needed) but lands as its own element with its own PK-based id; editing it
# broadcasts to the attacker's own presentation id and cannot touch the victim.
#
# The test drives two real headless-Chromium sessions (victim + attacker) against one
# server and screenshots the outcome to tmp/screenshots/.
class MessageIdSpoofingTest < ApplicationSystemTestCase
  SCREENSHOT_DIR = Rails.root.join("tmp/screenshots")

  setup do
    FileUtils.mkdir_p(SCREENSHOT_DIR)
  end

  test "a reused client_message_id cannot hijack the victim message" do
    room = rooms(:designers)

    # Victim (jz) posts a real message through the composer and keeps the room open.
    sign_in "jz@37signals.com"
    join_room room
    send_message "Victim's real message"
    assert_selector ".message[data-message-id]", text: "Victim's real message"

    # The browser chose the client_message_id; read it (and the record id) back
    # from the persisted message the victim just posted.
    victim_message = room.messages.where(creator: users(:jz)).order(:created_at).last
    victim_client_id = victim_message.client_message_id
    victim_db_id = victim_message.id

    save_screenshot(SCREENSHOT_DIR.join("spoof-before.png"))

    # Attacker (kevin), a different non-admin member of the same room, posts a message
    # reusing the victim's client_message_id, then edits their own message.
    attacker_status = nil
    using_session("attacker") do
      sign_in "kevin@37signals.com"
      join_room room
      attacker_status = post_message_via_browser(room, "HIJACKED BY ATTACKER", victim_client_id)
      assert (200..299).include?(attacker_status), "the colliding create should still succeed (got #{attacker_status})"

      attacker_db_id = find(".message[data-message-id]", text: "HIJACKED BY ATTACKER")["data-message-id"]
      edit_message_via_browser(room, attacker_db_id, "EDITED BY ATTACKER")
    end

    attacker_message = room.messages.where(creator: users(:kevin)).order(:created_at).last
    attacker_db_id = attacker_message.id

    # Both messages carry the SAME client_message_id...
    assert_equal victim_client_id, attacker_message.client_message_id
    assert_not_equal victim_db_id, attacker_db_id

    # ...but in the victim's browser they render as two DISTINCT elements. Elements
    # are located by record id (data-message-id), not by DOM id, so this fails on
    # the vulnerable code for the real reason: the victim's element is gone. Wait
    # for the attacker's edit to arrive in the victim's browser, then confirm the
    # victim's own message is untouched and still under the victim's name.
    assert_selector message_selector(attacker_db_id), text: "EDITED BY ATTACKER"
    assert_selector "#{message_selector(victim_db_id)} .message__body", text: "Victim's real message"
    assert_selector "#{message_selector(victim_db_id)} .message__author", text: "JZ"
    assert_selector ".message[data-message-id]", count: room.messages.count

    # The victim's element never took on the attacker's text.
    assert_no_selector "#{message_selector(victim_db_id)} .message__body", text: /ATTACKER/

    # And the victim's record is untouched on the server.
    assert_equal "Victim's real message", victim_message.reload.body.to_plain_text.strip

    save_screenshot(SCREENSHOT_DIR.join("spoof-after-fixed.png"))
  end

  test "a distinct client_message_id never alters the victim message" do
    room = rooms(:designers)

    sign_in "jz@37signals.com"
    join_room room
    send_message "Victim's untouched message"
    assert_selector ".message[data-message-id]", text: "Victim's untouched message"

    victim_db_id = room.messages.where(creator: users(:jz)).order(:created_at).last.id
    attacker_db_id = nil

    using_session("attacker") do
      sign_in "kevin@37signals.com"
      join_room room
      status = post_message_via_browser(room, "Attacker's own message", "a-distinct-id")
      assert (200..299).include?(status), "a non-colliding create should succeed (got #{status})"

      attacker_db_id = find(".message[data-message-id]", text: "Attacker's own message")["data-message-id"]
      edit_message_via_browser(room, attacker_db_id, "EDITED BY ATTACKER")
    end

    # The attacker's edit lands only on the attacker's own message. The victim's
    # message is untouched.
    assert_selector message_selector(attacker_db_id), text: "EDITED BY ATTACKER"
    assert_selector "#{message_selector(victim_db_id)} .message__body", text: "Victim's untouched message"
    assert_no_selector "#{message_selector(victim_db_id)} .message__body", text: "EDITED BY ATTACKER"
  end

  private
    def message_selector(message_id)
      ".message[data-message-id='#{message_id}']"
    end

    # POST a message through the attacker's live authenticated browser session,
    # forcing a chosen client_message_id. Synchronous XHR so we get the real HTTP
    # status back. Returns the status code.
    def post_message_via_browser(room, body, client_message_id)
      page.evaluate_script(<<~JS)
        (function() {
          var xhr = new XMLHttpRequest();
          xhr.open('POST', '/rooms/#{room.id}/messages', false);
          var token = document.querySelector('meta[name="csrf-token"]');
          if (token) { xhr.setRequestHeader('X-CSRF-Token', token.content); }
          xhr.setRequestHeader('Accept', 'text/vnd.turbo-stream.html');
          var fd = new FormData();
          fd.append('message[body]', #{body.to_json});
          fd.append('message[client_message_id]', #{client_message_id.to_json});
          xhr.send(fd);
          return xhr.status;
        })()
      JS
    end

    # PATCH the attacker's own message through their live browser session. Fired
    # async (the caller then waits on the resulting DOM broadcast); the update's
    # replace broadcast targets the attacker's own presentation DOM id.
    def edit_message_via_browser(room, message_id, body)
      page.execute_script(<<~JS)
        (function() {
          var fd = new FormData();
          fd.append('message[body]', #{body.to_json});
          var headers = { 'Accept': 'text/html' };
          var token = document.querySelector('meta[name="csrf-token"]');
          if (token) { headers['X-CSRF-Token'] = token.content; }
          fetch('/rooms/#{room.id}/messages/#{message_id}', { method: 'PATCH', headers: headers, body: fd });
        })()
      JS
    end
end
