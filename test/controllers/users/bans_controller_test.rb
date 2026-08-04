require "test_helper"

class Users::BansControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "create bans user and creates ban records from sessions" do
    user = users(:kevin)
    user.sessions.create!(ip_address: "203.0.113.1", user_agent: "Test")
    user.sessions.create!(ip_address: "203.0.113.2", user_agent: "Test")

    assert_difference -> { Ban.count }, 2 do
      post user_ban_url(user)
    end

    assert_redirected_to user_url(user)
    assert Ban.exists?(ip_address: "203.0.113.1", user: user)
    assert Ban.exists?(ip_address: "203.0.113.2", user: user)
  end

  test "create skips private and invalid session addresses without aborting the account ban" do
    user = users(:kevin)
    user.sessions.create!(ip_address: "10.20.30.40", user_agent: "Private network")
    user.sessions.create!(ip_address: "not-an-address", user_agent: "Malformed legacy session")
    user.sessions.create!(ip_address: "203.0.113.25", user_agent: "Public network")

    post user_ban_url(user)

    assert_redirected_to user_url(user)
    assert user.reload.banned?
    assert_equal [ "203.0.113.25" ], user.bans.pluck(:ip_address)
    assert_empty user.sessions
  end

  test "create destroys user sessions and session-bound push subscriptions" do
    user = users(:kevin)
    user.sessions.create!(ip_address: "203.0.113.1", user_agent: "Test")
    session_count = user.sessions.count
    subscription_count = user.push_subscriptions.count

    assert_difference -> { user.sessions.count }, -session_count do
      assert_difference -> { user.push_subscriptions.count }, -subscription_count do
        post user_ban_url(user)
      end
    end

    assert user.reload.banned?
  end

  test "create enqueues RemoveBannedContentJob" do
    user = users(:kevin)

    post user_ban_url(user)

    job = enqueued_jobs.find { _1[:job] == RemoveBannedContentJob }
    assert_equal user.ban_cleanup_intents.sole.id, job[:args].first
    assert_match(/\A[0-9a-f-]{36}\z/, job[:args].second)
  end

  test "RemoveBannedContentJob deletes messages" do
    user = users(:kevin)
    user.sessions.create!(ip_address: "203.0.113.1", user_agent: "Test")
    user.messages.create!(room: rooms(:hq), body: "Test message", client_message_id: "test-123")

    perform_enqueued_jobs do
      post user_ban_url(user)
    end

    assert_empty user.reload.messages
  end

  test "a failed ban does not enqueue content removal" do
    user = users(:jason)
    configure_oidc "OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => user.email_address
    accounts(:signal).update!(oidc_break_glass_user: user)

    assert_no_enqueued_jobs only: RemoveBannedContentJob do
      assert_raises(ActiveRecord::RecordInvalid) { user.ban_by! actor: users(:david) }
    end

    assert user.reload.active?
  end

  test "content removal waits for the outer transaction to commit" do
    user = users(:kevin)

    assert_no_enqueued_jobs only: RemoveBannedContentJob do
      User.transaction do
        user.ban_by! actor: users(:david)
        raise ActiveRecord::Rollback
      end
    end

    assert user.reload.active?
  end

  test "a stale content removal job does not delete an unbanned user's messages" do
    user = users(:kevin)
    message = user.messages.create!(room: rooms(:hq), body: "Keep me", client_message_id: "test-stale-ban")

    user.ban_by! actor: users(:david)
    user.unban_by! actor: users(:david)
    perform_enqueued_jobs

    assert message.reload
  end

  test "non-admins cannot ban users" do
    sign_in :kevin

    post user_ban_url(users(:jz))

    assert_response :forbidden
  end

  test "destroy removes ban records and sets user to active" do
    user = users(:kevin)
    user.sessions.create!(ip_address: "203.0.113.1", user_agent: "Test")
    user.ban_by! actor: users(:david)

    assert user.reload.banned?
    assert_equal 1, user.bans.count

    assert_difference -> { Ban.count }, -1 do
      delete user_ban_url(user)
    end

    assert_redirected_to user_url(user)
    assert user.reload.active?
  end

  test "destroy cannot reactivate an identity-provider-deprovisioned user" do
    configure_oidc
    use_oidc_origin
    user = users(:kevin)
    identity = Identity.create!(user:, issuer: Oidc.issuer, subject: "banned-scim-subject")
    user.ban_by! actor: users(:david)
    user.deactivate_from_identity_provider!(identity:, issuer: Oidc.issuer)

    delete user_ban_url(user)

    assert_redirected_to user_url(user)
    assert user.reload.deactivated?
    assert_empty user.bans
    assert_predicate identity.reload, :provider_revoked_at?
  end

  test "required mode refuses to unban an unlinked user" do
    user = users(:kevin)
    recovery_user = users(:david)
    user.ban_by! actor: recovery_user
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => recovery_user.email_address)
    User.active.without_bots.where.not(id: recovery_user.id).find_each do |active_user|
      Identity.find_or_create_by!(
        user: active_user, issuer: Oidc.issuer,
        subject: "required-unban-#{active_user.id}", provider_fingerprint: Oidc.provider_fingerprint
      )
    end
    accounts(:signal).update!(
      oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
      oidc_required_at: Time.current,
      oidc_break_glass_user: recovery_user
    )
    Session.find_by!(token: parsed_cookies.signed[:session_token]).update_columns(expires_at: 1.hour.from_now)
    use_oidc_origin
    assert Oidc::Activation.ready?

    delete user_ban_url(user)

    assert_response :forbidden
    assert user.reload.banned?
    assert Oidc::Activation.ready?
  end

  test "non-admins cannot unban users" do
    sign_in :kevin

    user = users(:jz)
    user.banned!

    delete user_ban_url(user)

    assert_response :forbidden
  end

  private
    def use_oidc_origin
      session_token = cookies[:session_token]
      reset!
      host! Oidc.configuration.redirect_host
      https!
      cookies[:session_token] = session_token
    end
end
