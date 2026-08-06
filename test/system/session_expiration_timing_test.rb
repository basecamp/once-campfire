require "application_system_test_case"
require "timeout"

class SessionExpirationTimingTest < ApplicationSystemTestCase
  SERVER_TIME = Time.zone.local(2030, 1, 2, 12, 0, 0)
  MONOTONIC_START = 10_000

  test "a clock ahead does not warn early and reconnect preserves elapsed time" do
    install_browser_clock_skew 24.hours
    sign_in users(:jz).email_address
    expires_at = SERVER_TIME + 10.minutes
    Session.order(:id).last.update!(expires_at:)

    travel_to(SERVER_TIME) do
      visit room_url(rooms(:designers))

      assert_server_timing_contract expires_at
      assert_no_text "Your session expires in less than five minutes."
      advance_monotonic_clock 5.minutes
      assert_text "Your session expires in less than five minutes."

      body = find("body", visible: :all)
      deadline = body["data-session-expiration-deadline"]
      clock_offset = body["data-session-expiration-clock-offset"]
      disconnect_session_expiration
      page.execute_script("document.querySelector('[data-session-expiration-warning]')?.remove()")
      advance_monotonic_clock 5.minutes, refresh: false
      reconnect_session_expiration

      assert_text "Your session has expired."
      assert_equal deadline, find("body", visible: :all)["data-session-expiration-deadline"]
      assert_equal clock_offset, find("body", visible: :all)["data-session-expiration-clock-offset"]
    end
  end

  test "a clock behind does not delay warning or expiry" do
    install_browser_clock_skew(-24.hours)
    sign_in users(:jz).email_address
    expires_at = SERVER_TIME + 4.minutes
    Session.order(:id).last.update!(expires_at:)

    travel_to(SERVER_TIME) do
      visit room_url(rooms(:designers))

      assert_server_timing_contract expires_at
      assert_text "Your session expires in less than five minutes."
      advance_monotonic_clock 4.minutes
      assert_text "Your session has expired."
    end
  end

  test "waking after the monotonic clock paused accounts for elapsed server-adjusted wall time" do
    install_browser_clock_skew 24.hours
    sign_in users(:jz).email_address
    expires_at = SERVER_TIME + 6.minutes
    Session.order(:id).last.update!(expires_at:)

    travel_to(SERVER_TIME) do
      visit room_url(rooms(:designers))
      assert_no_text "Your session expires in less than five minutes."

      set_visibility "hidden"
      advance_wall_clock 7.minutes
      set_visibility "visible"

      assert_text "Your session has expired."
    end
  end

  test "editing the wall clock while visible cannot move the monotonic deadline" do
    install_browser_clock_skew(-24.hours)
    sign_in users(:jz).email_address
    expires_at = SERVER_TIME + 10.minutes
    Session.order(:id).last.update!(expires_at:)

    travel_to(SERVER_TIME) do
      visit room_url(rooms(:designers))
      advance_wall_clock 2.days
      page.execute_script("document.dispatchEvent(new Event('visibilitychange'))")

      assert_no_text "Your session expires in less than five minutes."
      advance_monotonic_clock 5.minutes
      assert_text "Your session expires in less than five minutes."
    end
  end

  test "pages without a session expose no timing contract" do
    install_browser_clock_skew 24.hours

    travel_to(SERVER_TIME) do
      visit new_session_url

      assert_no_selector "body[data-session-expiration-expires-at-value]", visible: :all
      assert_no_selector "body[data-session-expiration-server-time-value]", visible: :all
      assert_no_selector "body[data-session-expiration-deadline]", visible: :all
      assert_no_selector "body[data-session-expiration-clock-offset]", visible: :all
      assert_not_includes find("body", visible: :all)["data-controller"], "session-expiration"
      advance_monotonic_clock 1.day
      assert_no_selector "[data-session-expiration-warning]"
    end
  end

  test "a non-expiring local session on a non-room page observes revocation" do
    sign_in users(:jz).email_address
    current_session = users(:jz).sessions.order(:id).last
    assert_nil current_session.expires_at

    visit user_profile_url

    body = find("body", visible: :all)
    assert_includes body["data-controller"].split, "session-expiration"
    assert_nil body["data-session-expiration-expires-at-value"]
    assert_nil body["data-session-expiration-server-time-value"]
    wait_for_non_room_session_monitor

    current_session.destroy!

    assert_selector "input[name='email_address']", wait: 10
    assert_current_path new_session_path
  end

  test "coming online reconciles a revocation missed while the non-room socket was disconnected" do
    sign_in users(:jz).email_address
    current_session = users(:jz).sessions.order(:id).last
    visit user_profile_url
    wait_for_non_room_session_monitor

    page.execute_script <<~JAVASCRIPT
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "session-expiration");
      controller.channel.consumer.disconnect();
    JAVASCRIPT
    Timeout.timeout(5) do
      sleep 0.05 while page.evaluate_script(<<~JAVASCRIPT)
        (() => {
          const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "session-expiration");
          return controller.channel.consumer.connection.isOpen();
        })()
      JAVASCRIPT
    end

    current_session.destroy!
    page.execute_script("window.dispatchEvent(new Event('online'))")

    assert_selector "input[name='email_address']", wait: 10
    assert_current_path new_session_path
  end

  test "only explicit session termination protocol reasons are authoritative" do
    visit new_session_url

    reasons = evaluate_module_script_in_page_realm <<~JAVASCRIPT
      const imports = JSON.parse(document.querySelector("script[type='importmap']").textContent).imports;
      const { observeSessionTermination } = await import(imports["controllers/session_expiration_controller"]);
      const socket = new EventTarget();
      const channel = { consumer: { connection: { webSocket: socket } } };
      const reasons = [];
      const stop = observeSessionTermination(channel, (reason) => reasons.push(reason));
      const disconnect = (reason) => socket.dispatchEvent(new MessageEvent("message", {
        data: JSON.stringify({ type: "disconnect", reason, reconnect: false })
      }));

      disconnect("invalid_request");
      disconnect("remote");
      disconnect("Session revoked");
      stop();
      disconnect("Session expired");
      return reasons;
    JAVASCRIPT

    assert_equal [ "Session revoked" ], reasons
    assert_current_path new_session_path
  end

  test "an authoritative revocation clears Turbo snapshots and sensitive DOM before sign in" do
    sign_in users(:jz).email_address
    join_room rooms(:designers)
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script(<<~JAVASCRIPT)
        (() => {
          const element = document.querySelector('[data-controller~="refresh-room"]');
          const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "refresh-room");
          return Boolean(controller?.channel?.consumer.connection.isOpen());
        })()
      JAVASCRIPT
    end
    page.execute_script <<~JAVASCRIPT
      sessionStorage.removeItem("turbo-cache-cleared-for-revocation-test");
      const sensitive = document.createElement("div");
      sensitive.id = "revocation-sensitive-content";
      sensitive.textContent = "Sensitive room content";
      document.body.append(sensitive);
      const clearCache = Turbo.cache.clear.bind(Turbo.cache);
      Turbo.cache.clear = () => {
        sessionStorage.setItem("turbo-cache-cleared-for-revocation-test", "true");
        clearCache();
      };
    JAVASCRIPT

    Session.order(:id).last.destroy!

    assert_selector "input[name='email_address']", wait: 10
    assert_current_path new_session_path
    assert_no_selector "#revocation-sensitive-content", visible: :all
    assert_no_selector "meta[name='current-session-id']", visible: :all
    assert_equal "true", page.evaluate_script(
      'sessionStorage.getItem("turbo-cache-cleared-for-revocation-test")'
    )
  end

  test "a valid-session consumer shutdown does not scrub the page" do
    sign_in users(:jz).email_address
    join_room rooms(:designers)
    page.execute_script <<~JAVASCRIPT
      const sensitive = document.createElement("div");
      sensitive.id = "valid-session-sensitive-content";
      sensitive.textContent = "Keep this valid page";
      document.body.append(sensitive);
    JAVASCRIPT
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script(<<~JAVASCRIPT)
        (() => {
          const element = document.querySelector('[data-controller~="refresh-room"]');
          const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "refresh-room");
          return Boolean(controller?.channel?.consumer.connection.isOpen());
        })()
      JAVASCRIPT
    end

    page.execute_script <<~JAVASCRIPT
      const element = document.querySelector('[data-controller~="refresh-room"]');
      const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "refresh-room");
      controller.channel.consumer.disconnect();
    JAVASCRIPT
    Timeout.timeout(5) do
      sleep 0.05 while page.evaluate_script(<<~JAVASCRIPT)
        (() => {
          const element = document.querySelector('[data-controller~="refresh-room"]');
          const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "refresh-room");
          return controller.channel.consumer.connection.isOpen();
        })()
      JAVASCRIPT
    end

    assert_current_path room_path(rooms(:designers))
    assert_selector "#valid-session-sensitive-content", text: "Keep this valid page"
    assert_selector "meta[name='current-session-id']", visible: :all
    assert_nil find("html", visible: :all)["data-session-invalidated"]
  end

  private
    def install_browser_clock_skew(skew)
      local_time = (SERVER_TIME + skew).to_fs(:epoch)
      install_new_document_script <<~JAVASCRIPT
        window.sessionExpirationMonotonicNowForTest = #{MONOTONIC_START};
        window.sessionExpirationWallNowForTest = #{local_time};
        Date.now = () => window.sessionExpirationWallNowForTest;
        Object.defineProperty(performance, "now", {
          configurable: true,
          value: () => window.sessionExpirationMonotonicNowForTest
        });
      JAVASCRIPT
    end

    def assert_server_timing_contract(expires_at)
      body = find("body", visible: :all)
      assert_equal expires_at.to_fs(:epoch), body["data-session-expiration-expires-at-value"]
      assert_equal SERVER_TIME.to_fs(:epoch), body["data-session-expiration-server-time-value"]
      assert body["data-session-expiration-deadline"].present?
      assert body["data-session-expiration-clock-offset"].present?
    end

    def advance_monotonic_clock(duration, refresh: true)
      page.execute_script("window.sessionExpirationMonotonicNowForTest += #{duration.in_milliseconds}")
      page.execute_script("document.dispatchEvent(new Event('visibilitychange'))") if refresh
    end

    def advance_wall_clock(duration)
      page.execute_script("window.sessionExpirationWallNowForTest += #{duration.in_milliseconds}")
    end

    def set_visibility(state)
      page.execute_script <<~JAVASCRIPT
        Object.defineProperty(document, "visibilityState", { configurable: true, value: #{state.to_json} });
        document.dispatchEvent(new Event("visibilitychange"));
      JAVASCRIPT
    end

    def disconnect_session_expiration
      page.execute_script <<~JAVASCRIPT
        document.body.dataset.controller = document.body.dataset.controller
          .split(/\s+/).filter((identifier) => identifier !== "session-expiration").join(" ");
      JAVASCRIPT
      Timeout.timeout(5) do
        sleep 0.05 while page.evaluate_script(<<~JAVASCRIPT)
          Boolean(window.Stimulus.getControllerForElementAndIdentifier(document.body, "session-expiration"))
        JAVASCRIPT
      end
    end

    def reconnect_session_expiration
      page.execute_script("document.body.dataset.controller += ' session-expiration'")
      Timeout.timeout(5) do
        sleep 0.05 until page.evaluate_script(<<~JAVASCRIPT)
          Boolean(window.Stimulus.getControllerForElementAndIdentifier(document.body, "session-expiration"))
        JAVASCRIPT
      end
    end

    def wait_for_non_room_session_monitor
      Timeout.timeout(5) do
        sleep 0.05 until page.evaluate_script(<<~JAVASCRIPT)
          (() => {
            const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "session-expiration");
            return Boolean(controller?.channel?.consumer.connection.isOpen());
          })()
        JAVASCRIPT
      end
    end
end
