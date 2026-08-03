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
end
