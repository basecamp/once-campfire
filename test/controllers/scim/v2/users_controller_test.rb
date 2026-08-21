require "test_helper"

class Scim::V2::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    configure_oidc
    configure_scim
    host! Oidc.configuration.redirect_host
    https!
    @identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "scim-subject")
  end

  test "disabled and unauthenticated requests fail closed with SCIM errors" do
    get scim_v2_user_path(@identity.scim_id)

    assert_response :unauthorized
    assert_equal "Bearer realm=\"SCIM\"", response.headers.fetch("WWW-Authenticate")
    assert_scim_error "401"

    Scim.configuration = Scim::Configuration.new({}, oidc_configuration: Oidc.configuration)
    get scim_v2_user_path(@identity.scim_id), headers: scim_headers

    assert_response :not_found
    assert_scim_error "404"
  end

  test "gets a user only by its issuer-bound stable SCIM id" do
    get scim_v2_user_path(@identity.scim_id), headers: scim_headers

    assert_response :success
    assert_equal Scim::MEDIA_TYPE, response.media_type
    assert_equal [ Scim::USER_SCHEMA ], scim_body.fetch("schemas")
    assert_equal @identity.scim_id, scim_body.fetch("id")
    assert_equal @identity.subject, scim_body.fetch("externalId")
    assert_equal @identity.subject, scim_body.fetch("userName")
    assert_equal true, scim_body.fetch("active")
    assert_equal scim_v2_user_url(@identity.scim_id), scim_body.dig("meta", "location")

    other_issuer = Identity.create!(
      user: users(:david), issuer: "https://other-idp.example.com", subject: "other-scim-subject",
      provider_fingerprint: Digest::SHA256.hexdigest("other-provider")
    )
    get scim_v2_user_path(other_issuer.scim_id), headers: scim_headers

    assert_response :not_found
    assert_scim_error "404"
  end

  test "filters only by stable id or exact immutable subject values" do
    [
      [ "externalId", @identity.subject ],
      [ "userName", @identity.subject ],
      [ "id", @identity.scim_id ]
    ].each do |attribute, value|
      get scim_v2_users_path,
        params: { filter: %(#{attribute} eq "#{value}"), startIndex: "1", count: "100" },
        headers: scim_headers

      assert_response :success
      assert_equal 1, scim_body.fetch("totalResults")
      assert_equal @identity.scim_id, scim_body.fetch("Resources").sole.fetch("id")
    end

    get scim_v2_users_path,
      params: { filter: %(userName eq "#{users(:jz).email_address}") }, headers: scim_headers
    assert_response :success
    assert_equal 0, scim_body.fetch("totalResults")

    get scim_v2_users_path, headers: scim_headers
    assert_response :bad_request
    assert_equal "invalidFilter", scim_body.fetch("scimType")
  end

  test "PATCH active false atomically deactivates and removes every session and push capability" do
    federated_session = users(:jz).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity: @identity,
      oidc_session_id: "scim-provider-session", oidc_issued_at: Time.current.to_i
    )
    push_subscriptions(:jz_chrome).update!(session: federated_session)
    channel = ApplicationCable::Connection.user_internal_channel(users(:jz))

    assert_difference -> { ActionCable.server.pubsub.broadcasts(channel).size }, 1 do
      patch_scim_user @identity, {
        schemas: [ Scim::PATCH_OPERATION_SCHEMA ],
        Operations: [ { op: "Replace", path: "active", value: false } ]
      }
    end

    assert_response :success
    assert_equal false, scim_body.fetch("active")
    assert users(:jz).reload.deactivated?
    assert_empty users(:jz).sessions
    assert_empty users(:jz).push_subscriptions
    assert_revocation_broadcast channel
  end

  test "PATCH cannot deactivate the last active administrator" do
    User.active.where(role: :administrator).update_all(role: :member)
    users(:jz).update!(role: :administrator)

    patch_scim_user @identity, {
      schemas: [ Scim::PATCH_OPERATION_SCHEMA ],
      Operations: [ { op: "Replace", path: "active", value: false } ]
    }

    assert_response :success
    assert_equal false, scim_body.fetch("active")
    assert users(:jz).reload.active?
    assert users(:jz).administrator?
    assert_predicate @identity.reload, :provider_revoked_at?
    assert Identity::Deprovisioning.blocked?(issuer: @identity.issuer, subject: @identity.subject)
  end

  test "PATCH supports an active false value object and is idempotent" do
    payload = {
      schemas: [ Scim::PATCH_OPERATION_SCHEMA ],
      Operations: [ { op: "replace", value: { active: false } } ]
    }

    patch_scim_user @identity, payload
    assert_response :success

    assert_no_changes -> { [ User.count, Session.count, Push::Subscription.count ] } do
      patch_scim_user @identity, payload
    end
    assert_response :success
    assert_equal false, scim_body.fetch("active")
  end

  test "PATCH durably records deprovisioning for an already-banned user" do
    users(:jz).ban_by! actor: users(:david)
    users(:jz).searches.create!(query: "remove-after-ban")

    patch_scim_user @identity, {
      schemas: [ Scim::PATCH_OPERATION_SCHEMA ],
      Operations: [ { op: "replace", path: "active", value: false } ]
    }

    assert_response :success
    assert users(:jz).reload.banned?
    assert_predicate @identity.reload, :provider_revoked_at?
    assert_empty users(:jz).searches

    users(:jz).unban_by! actor: users(:david)
    assert users(:jz).reload.deactivated?
    assert_match(/-deactivated-/, users(:jz).email_address)
    error = assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(subject: @identity.subject))
    end
    assert_equal "identity_revoked", error.message
  end

  test "an idempotent PATCH scrubs residual capabilities from an already inactive user" do
    users(:jz).update!(status: :deactivated)
    assert users(:jz).sessions.exists?
    assert users(:jz).push_subscriptions.exists?

    patch_scim_user @identity, {
      schemas: [ Scim::PATCH_OPERATION_SCHEMA ],
      Operations: [ { op: "replace", path: "active", value: false } ]
    }

    assert_response :success
    assert_empty users(:jz).sessions
    assert_empty users(:jz).push_subscriptions
  end

  test "PATCH rejects reactivation mutable identifiers and non-boolean false" do
    invalid_operations = [
      { op: "replace", path: "active", value: true },
      { op: "replace", path: "active", value: "false" },
      { op: "replace", path: "userName", value: "attacker@example.com" },
      { op: "replace", value: { active: false, userName: "attacker@example.com" } }
    ]

    invalid_operations.each do |operation|
      assert_no_changes -> { users(:jz).reload.status } do
        patch_scim_user @identity, {
          schemas: [ Scim::PATCH_OPERATION_SCHEMA ], Operations: [ operation ]
        }
      end
      assert_response :bad_request
      assert_equal "mutability", scim_body.fetch("scimType")
    end
  end

  test "PATCH returns SCIM errors for malformed JSON and unsupported media types" do
    patch scim_v2_user_path(@identity.scim_id), params: "{", headers: scim_headers

    assert_response :bad_request
    assert_equal "invalidSyntax", scim_body.fetch("scimType")

    patch scim_v2_user_path(@identity.scim_id),
      params: {
        schemas: [ Scim::PATCH_OPERATION_SCHEMA ],
        Operations: [ { op: "replace", path: "active", value: false } ]
      }.to_json,
      headers: scim_headers.merge("Content-Type" => "text/plain")

    assert_response :bad_request
    assert_equal "invalidSyntax", scim_body.fetch("scimType")
    assert users(:jz).reload.active?
  end

  test "DELETE deactivates idempotently without permitting create or replace" do
    delete scim_v2_user_path(@identity.scim_id), headers: scim_headers

    assert_response :no_content
    assert users(:jz).reload.deactivated?

    delete scim_v2_user_path(@identity.scim_id), headers: scim_headers
    assert_response :no_content

    assert_raises(ActionController::RoutingError) do
      post scim_v2_users_path, params: {}.to_json, headers: scim_headers
    end
    assert_raises(ActionController::RoutingError) do
      put scim_v2_user_path(@identity.scim_id), params: {}.to_json, headers: scim_headers
    end
  end

  test "blind subject DELETE tombstones known and unknown subjects without an existence signal" do
    known_url = subject_deprovisioning_url(@identity.subject)
    delete known_url, headers: scim_headers

    assert_response :no_content
    assert_empty response.body
    assert users(:jz).reload.deactivated?
    assert Identity::Deprovisioning.blocked?(issuer: Oidc.issuer, subject: @identity.subject)

    unknown_subject = "not-yet-linked-scim-subject"
    unknown_url = subject_deprovisioning_url(unknown_subject)
    assert_no_changes -> { [ User.count, Identity.count ] } do
      delete unknown_url, headers: scim_headers
    end

    assert_response :no_content
    assert_empty response.body
    assert Identity::Deprovisioning.blocked?(issuer: Oidc.issuer, subject: unknown_subject)
  end

  test "filesystem fence failures return a generic SCIM service-unavailable error" do
    User::MutationFence.stubs(:ready?).returns(true)
    User::MutationFence.stubs(:with_identity_subject)
      .raises(User::MutationFence::Unavailable, "private filesystem failure")

    delete subject_deprovisioning_url("filesystem-failure-subject"), headers: scim_headers

    assert_response :service_unavailable
    assert_scim_error "503"
    assert_not_includes response.body, "filesystem"
  end

  test "blind subject DELETE does not report success when deprovisioning is rejected" do
    invalid_user = users(:jz)
    invalid_user.errors.add :base, "deprovisioning was rejected"
    Identity::Deprovisioning.stubs(:deprovision!)
      .raises(ActiveRecord::RecordInvalid.new(invalid_user))

    delete subject_deprovisioning_url(@identity.subject), headers: scim_headers

    assert_response :conflict
    assert_scim_error "409"
    assert_equal "mutability", scim_body.fetch("scimType")
  end

  test "DELETE durably records deprovisioning for an already-banned user" do
    users(:jz).ban_by! actor: users(:david)

    delete scim_v2_user_path(@identity.scim_id), headers: scim_headers

    assert_response :no_content
    assert users(:jz).reload.banned?
    assert_predicate @identity.reload, :provider_revoked_at?
  end

  test "revokes recovery provider access while preserving local break-glass access" do
    configure_oidc(
      "OIDC_MODE" => "required",
      "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address
    )
    configure_scim
    recovery_identity = Identity.create!(
      user: users(:jason), issuer: Oidc.issuer, subject: "recovery-scim-subject"
    )
    accounts(:signal).update!(
      oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
      oidc_required_at: Time.current,
      oidc_break_glass_user: users(:jason)
    )
    local_session = users(:jason).sessions.start!(
      user_agent: "Recovery browser", ip_address: "192.0.2.1"
    )
    provider_session = users(:jason).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity: recovery_identity,
      oidc_session_id: "recovery-provider-session", oidc_issued_at: Time.current.to_i
    )
    local_subscription = push_subscriptions(:jason_chrome)
    local_subscription.update!(session: local_session)
    provider_subscription = local_subscription.dup
    provider_subscription.endpoint = "https://fcm.googleapis.com/fcm/send/recovery-provider"
    provider_subscription.session = provider_session
    provider_subscription.save!
    provider_channel = ActionCable.server.remote_connections.where(
      current_user: users(:jason), current_session_id: provider_session.id
    ).send(:internal_channel)
    user_channel = ApplicationCable::Connection.user_internal_channel(users(:jason))
    original_email = users(:jason).email_address

    assert_difference -> { Session.count }, -1 do
      assert_difference -> { Push::Subscription.count }, -1 do
        delete subject_deprovisioning_url(recovery_identity.subject), headers: scim_headers
      end
    end
    assert_response :no_content
    assert_empty response.body
    assert users(:jason).reload.active?
    assert users(:jason).administrator?
    assert_equal original_email, users(:jason).email_address
    assert_predicate recovery_identity.reload, :provider_revoked_at?
    assert Identity::Deprovisioning.blocked?(issuer: Oidc.issuer, subject: recovery_identity.subject)
    assert_not Session.exists?(provider_session.id)
    assert_not Push::Subscription.exists?(provider_subscription.id)
    assert Session.exists?(local_session.id)
    assert Push::Subscription.exists?(local_subscription.id)
    assert local_session.reload.valid_for_authentication?
    error = assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(subject: recovery_identity.subject))
    end
    assert_equal "identity_revoked", error.message
    assert_revocation_broadcast provider_channel
    assert_empty ActionCable.server.pubsub.broadcasts(user_channel)

    assert_no_changes -> { [ Session.count, Push::Subscription.count ] } do
      patch_scim_user recovery_identity, {
        schemas: [ Scim::PATCH_OPERATION_SCHEMA ],
        Operations: [ { op: "replace", path: "active", value: false } ]
      }
    end
    assert_response :success
    assert_equal false, scim_body.fetch("active")
  end

  test "rate limits before identity lookup and fails closed when the store is unavailable" do
    Identity.expects(:where).never
    Rails.cache.stubs(:increment).returns(SecurityEndpointRequestGuard::SCIM_REQUEST_LIMIT + 1)

    get scim_v2_user_path(@identity.scim_id), headers: scim_headers
    assert_response :too_many_requests
    assert_scim_error "429"

    Rails.cache.stubs(:increment).returns(nil)
    get scim_v2_user_path(@identity.scim_id), headers: scim_headers
    assert_response :service_unavailable
    assert_scim_error "503"
  end

  test "rejects an oversized PATCH before parsing or identity lookup" do
    Identity.expects(:where).never

    patch scim_v2_user_path(@identity.scim_id),
      params: "x" * (SecurityEndpointRequestGuard::SCIM_BODY_BYTES + 1), headers: scim_headers

    assert_response :content_too_large
    assert_scim_error "413"
  end

  private
    def patch_scim_user(identity, payload)
      patch scim_v2_user_path(identity.scim_id), params: payload.to_json, headers: scim_headers
    end

    def subject_deprovisioning_url(subject)
      filter = URI.encode_www_form(filter: %(externalId eq "#{subject}"))
      "#{scim_v2_user_path(Scim::V2::UsersController::SUBJECT_DEPROVISIONING_ID)}?#{filter}"
    end

    def assert_scim_error(status)
      assert_equal Scim::MEDIA_TYPE, response.media_type
      assert_equal [ Scim::ERROR_SCHEMA ], scim_body.fetch("schemas")
      assert_equal status, scim_body.fetch("status")
      assert_not_includes response.body, Oidc.issuer
    end

    def assert_revocation_broadcast(channel)
      assert_equal({
        "type" => "disconnect", "reason" => Session::REVOKED_REASON, "reconnect" => false
      }, ActiveSupport::JSON.decode(ActionCable.server.pubsub.broadcasts(channel).last))
    end

    def scim_body
      JSON.parse(response.body)
    end
end
