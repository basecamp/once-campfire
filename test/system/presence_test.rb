require "application_system_test_case"

class PresenceTest < ApplicationSystemTestCase
  setup do
    @membership = memberships(:jz_designers)

    sign_in "jz@37signals.com"
  end

  test "a hidden page whose connection comes back stops counting as present" do
    join_room rooms(:designers)
    assert_present

    hide_page
    assert_absent

    users(:jz).reset_remote_connections
    assert_present wait: 30 # Subscribing again marks the member present.

    assert_absent
  end

  test "a visible page whose connection comes back still counts as present" do
    join_room rooms(:designers)
    assert_present

    users(:jz).reset_remote_connections
    assert_no_selector "turbo-cable-stream-source[connected]", visible: false
    assert_selector "turbo-cable-stream-source[connected]", count: 3, visible: false, wait: 30
    assert_present

    sleep 6 # Past the moment a hidden page reports itself absent.
    assert_present wait: 0
  end

  test "a page shown again after its connection came back while hidden counts once" do
    join_room rooms(:designers)
    assert_present

    hide_page
    assert_absent

    users(:jz).reset_remote_connections
    assert_present wait: 30
    show_page

    sleep 6 # Past the moment a page shown again reports itself present.
    assert_equal 1, @membership.reload.connections
  end

  test "a page opened hidden doesn't count as present" do
    load_pages_hidden do
      join_room rooms(:designers)
    end

    assert_absent
  end

  private
    def hide_page
      page.execute_script <<~JS
        Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true })
        document.dispatchEvent(new Event("visibilitychange"))
      JS
    end

    def show_page
      page.execute_script <<~JS
        delete document.visibilityState
        document.dispatchEvent(new Event("visibilitychange"))
      JS
    end

    def load_pages_hidden
      script = page.driver.browser.execute_cdp "Page.addScriptToEvaluateOnNewDocument",
        source: %(Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true }))

      yield
    ensure
      page.driver.browser.execute_cdp "Page.removeScriptToEvaluateOnNewDocument", identifier: script["identifier"] if script
    end

    # A page reports itself absent five seconds after it's hidden, so the default wait leaves some margin.
    def assert_present(wait: 7)
      assert_membership_connected true, wait: wait
    end

    def assert_absent(wait: 7)
      assert_membership_connected false, wait: wait
    end

    def assert_membership_connected(connected, wait:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait

      until @membership.reload.connected? == connected
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk "Expected #{@membership.user.name} to be #{connected ? "present" : "absent"} in #{@membership.room.name} within #{wait}s"
        end

        sleep 0.1
      end
    end
end
