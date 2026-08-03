require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "connects with valid user_id cookie" do
    cookies.signed[:session_token] = sessions(:david_safari).token

    connect

    assert_equal users(:david), connection.current_user
    assert_equal sessions(:david_safari), connection.current_session
    assert_equal sessions(:david_safari).id, connection.current_session_id
    assert_equal users(:david).authorization_generation, connection.current_authorization_generation
  end

  test "rejects connection with missing user_id cookie" do
    assert_reject_connection { connect }
  end

  test "rejects connection with invalid user_id cookie" do
    cookies.signed[:session_token] = -1

    assert_reject_connection { connect }
  end

  test "rejects unready required mode without deleting the session" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)
    cookies.signed[:session_token] = sessions(:david_safari).token

    assert_no_difference -> { Session.count } do
      assert_reject_connection { connect }
    end
    assert Session.exists?(sessions(:david_safari).id)
  end

  test "rejects a connection when authentication policy cannot be read" do
    cookies.signed[:session_token] = sessions(:david_safari).token
    Oidc.stubs(:rollback_prepared?).raises(Oidc::PolicyUnavailable, Oidc::POLICY_UNAVAILABLE_MESSAGE)

    assert_reject_connection { connect }
  end

  test "expires a federated connection and its push subscriptions" do
    configure_oidc
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "cable-subject")
    session = users(:jz).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity:,
      oidc_issued_at: Time.current.to_i
    )
    push_subscriptions(:jz_chrome).update!(session:)
    cookies.signed[:session_token] = session.token
    expiration_monitor = stub(cancel: nil)
    Concurrent::ScheduledTask.stubs(:execute).returns(expiration_monitor)

    connect
    connection.expects(:close).with(reason: "Session expired", reconnect: false)

    assert_difference -> { Session.count }, -1 do
      assert_difference -> { Push::Subscription.count }, -1 do
        connection.send :expire_session
      end
    end
  end

  test "closes an expired connection when session cleanup fails" do
    configure_oidc
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "failed-cleanup-subject")
    session = users(:jz).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity:,
      oidc_issued_at: Time.current.to_i
    )
    cookies.signed[:session_token] = session.token
    expiration_monitor = stub(cancel: nil)
    Concurrent::ScheduledTask.stubs(:execute).returns(expiration_monitor)
    connect

    Session.stubs(:find_by).with(id: session.id).returns(session)
    session.stubs(:destroy!).raises(ActiveRecord::StatementInvalid, "database unavailable")
    connection.expects(:close).with(reason: "Session expired", reconnect: false)

    assert_raises(ActiveRecord::StatementInvalid) { connection.send :expire_session }
  end

  test "does not transmit after the database session is revoked" do
    cookies.signed[:session_token] = sessions(:david_safari).token
    connect
    Session.where(id: sessions(:david_safari).id).delete_all
    connection.expects(:close).with(reason: "Session revoked", reconnect: false)

    connection.transmit(type: "private-message")
  end

  test "does not transmit after an OIDC back-channel logout revokes its provider session" do
    configure_oidc
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "cable-logout-subject")
    session = users(:jz).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity:,
      oidc_session_id: "cable-provider-session", oidc_issued_at: Time.current.to_i
    )
    cookies.signed[:session_token] = session.token
    Concurrent::ScheduledTask.stubs(:execute).returns(stub(cancel: nil))
    connect
    claims = {
      "iss" => Oidc.issuer,
      "iat" => Time.current.to_i,
      "exp" => 5.minutes.from_now.to_i,
      "jti" => SecureRandom.uuid,
      "sub" => identity.subject,
      "sid" => session.oidc_session_id
    }

    Oidc::LogoutToken.consume!("encoded", verifier: stub(verify: claims))
    connection.expects(:close).with(reason: "Session revoked", reconnect: false)

    connection.transmit(type: "private-message")
  end

  test "does not transmit when policy fails after the session was loaded" do
    cookies.signed[:session_token] = sessions(:david_safari).token
    connect
    Oidc.stubs(:rollback_prepared?).raises(Oidc::PolicyUnavailable, Oidc::POLICY_UNAVAILABLE_MESSAGE)
    connection.expects(:close).with(reason: "Session revoked", reconnect: false)

    connection.transmit(type: "private-message")
  end

  test "does not transmit after required mode becomes unready" do
    connect_then_invalidate_required_readiness
    connection.expects(:close).with(reason: "Session revoked", reconnect: false)

    connection.transmit(type: "private-message")
  end

  test "rejects an incoming command after required mode becomes unready" do
    connect_then_invalidate_required_readiness
    connection.expects(:close).with(reason: "Session revoked", reconnect: false)

    result = catch(:abort) do
      connection.send :verify_current_session
      :continued
    end

    assert_nil result
  end

  test "does not query session state for internal heartbeats" do
    cookies.signed[:session_token] = sessions(:david_safari).token
    connect

    assert_queries_count(0) do
      assert_not connection.send(
        :application_message?, type: ActionCable::INTERNAL[:message_types][:ping], message: Time.current.to_i
      )
    end
  end

  test "authorization generation closes a socket after membership revocation fallback" do
    cookies.signed[:session_token] = sessions(:david_safari).token
    connect
    users(:david).increment!(:authorization_generation)
    connection.expects(:close).with(reason: "Session revoked", reconnect: false)

    connection.transmit(type: "private-room-message")
  end

  test "authorization generation rejects an incoming command after membership revocation" do
    cookies.signed[:session_token] = sessions(:david_safari).token
    connect
    users(:david).increment!(:authorization_generation)
    connection.expects(:close).with(reason: "Session revoked", reconnect: false)

    result = catch(:abort) do
      connection.send :verify_current_session
      :continued
    end

    assert_nil result
  end

  private
    def connect_then_invalidate_required_readiness
      configure_oidc(
        "OIDC_MODE" => "required",
        "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address
      )
      identities = User.active.without_bots.where.not(id: users(:jason).id).index_with do |user|
        Identity.create!(user:, issuer: Oidc.issuer, subject: "cable-readiness-#{user.id}")
      end
      accounts(:signal).update!(
        oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
        oidc_required_at: Time.current,
        oidc_break_glass_user: users(:jason)
      )
      session = users(:david).sessions.start!(
        user_agent: "Browser", ip_address: "192.0.2.1", identity: identities.fetch(users(:david)),
        oidc_issued_at: Time.current.to_i
      )
      cookies.signed[:session_token] = session.token
      Concurrent::ScheduledTask.stubs(:execute).returns(stub(cancel: nil))

      assert Oidc::Activation.ready?
      connect
      identities.fetch(users(:kevin)).destroy!
      assert_not Oidc::Activation.ready?
    end
end
