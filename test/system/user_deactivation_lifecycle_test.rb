require "application_system_test_case"
require "timeout"

class UserDeactivationLifecycleTest < ApplicationSystemTestCase
  test "administrative deactivation scrubs a connected page" do
    user = users(:jz)
    prepare_sensitive_page user

    user.deactivate_by! actor: users(:david)

    assert_session_scrubbed
  end

  test "SCIM provider deactivation scrubs a connected page" do
    user = users(:jz)
    prepare_sensitive_page user
    configure_oidc
    configure_scim
    identity = Identity.create!(user:, issuer: Scim.issuer, subject: "system-scim-deactivation")
    payload = {
      schemas: [ Scim::PATCH_OPERATION_SCHEMA ],
      Operations: [ { op: "replace", path: "active", value: false } ]
    }

    page.execute_script <<~JAVASCRIPT, scim_v2_user_path(identity.scim_id), payload.to_json
      fetch(arguments[0], {
        method: "PATCH",
        headers: {
          "Authorization": #{("Bearer #{ScimTestHelper::SCIM_BEARER_TOKEN}").to_json},
          "Content-Type": #{Scim::MEDIA_TYPE.to_json},
          "Accept": #{Scim::MEDIA_TYPE.to_json}
        },
        body: arguments[1]
      });
    JAVASCRIPT

    assert_session_scrubbed
    assert_predicate user.reload, :deactivated?
  end

  private
    def prepare_sensitive_page(user)
      sign_in user.email_address
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
        sessionStorage.removeItem("turbo-cache-cleared-for-deactivation-test");
        const sensitive = document.createElement("div");
        sensitive.id = "deactivation-sensitive-content";
        sensitive.textContent = "Sensitive room content";
        document.body.append(sensitive);
        const clearCache = Turbo.cache.clear.bind(Turbo.cache);
        Turbo.cache.clear = () => {
          sessionStorage.setItem("turbo-cache-cleared-for-deactivation-test", "true");
          clearCache();
        };
      JAVASCRIPT
    end

    def assert_session_scrubbed
      assert_selector "input[name='email_address']", wait: 10
      assert_current_path new_session_path
      assert_no_selector "#deactivation-sensitive-content", visible: :all
      assert_no_selector "meta[name='current-session-id']", visible: :all
      assert_equal "true", page.evaluate_script(
        'sessionStorage.getItem("turbo-cache-cleared-for-deactivation-test")'
      )
    end
end
