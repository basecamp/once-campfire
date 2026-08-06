require "test_helper"

class Push::SubscriptionTest < ActiveSupport::TestCase
  P256DH_KEY = "BFOmkBtSAO-lpyLxV4IW0pEJEa7UB3GDaoL4uNHv-Y8s5pbQgvAB9hJMpE4ZV0u4pxg9EDKwtxJbuIraUnjhx4w"
  AUTH_KEY = "YWFhYWFhYWFhYWFhYWFhYQ"

  test "unbound legacy subscriptions remain quarantined until browser rebind" do
    push_subscriptions(:jz_chrome).update_column :session_id, nil

    assert_not_includes Push::Subscription.with_current_session, push_subscriptions(:jz_chrome)
  end

  test "required mode only delivers to current federated sessions" do
    configure_oidc("OIDC_MODE" => "required")
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "push-subject")
    session = users(:jz).sessions.start!(
      user_agent: "Browser", ip_address: "192.0.2.1", identity:,
      oidc_issued_at: Time.current.to_i
    )
    push_subscriptions(:jz_chrome).update!(session:)
    accounts(:signal).update!(
      oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
      oidc_required_at: Time.current
    )

    assert_includes Push::Subscription.with_current_session, push_subscriptions(:jz_chrome)
    assert_not_includes Push::Subscription.with_current_session, push_subscriptions(:david_chrome)
  end


  test "activated required mode rejects unresolved legacy subscriptions" do
    configure_oidc("OIDC_MODE" => "required")
    push_subscriptions(:jz_chrome).update_column :session_id, nil
    accounts(:signal).update!(
      oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
      oidc_required_at: Time.current
    )

    assert_not_includes Push::Subscription.with_current_session, push_subscriptions(:jz_chrome)
  end

  test "expired federated sessions stop push delivery" do
    configure_oidc
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "expired-push-subject")
    session = users(:jz).sessions.create!(
      identity:, authentication_method: "oidc", expires_at: 1.second.ago,
      oidc_session_generation: Oidc::SessionGeneration.current!, oidc_issued_at: Time.current.to_i
    )
    push_subscriptions(:jz_chrome).update!(session:)

    assert_not_includes Push::Subscription.with_current_session, push_subscriptions(:jz_chrome)
  end

  test "database rejects a session owned by another subscription user" do
    assert_raises(ActiveRecord::InvalidForeignKey) do
      push_subscriptions(:jz_chrome).update_columns(
        user_id: users(:david).id,
        session_id: sessions(:jz_chrome).id
      )
    end
  end

  test "database allows only one capability per session" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      users(:david).push_subscriptions.create!(
        session: sessions(:david_safari), endpoint: "https://example.com/duplicate-session",
        p256dh_key: P256DH_KEY, auth_key: AUTH_KEY
      )
    end
  end

  test "limits subscriptions per user" do
    user = users(:jz)
    (Push::Subscription::MAXIMUM_SUBSCRIPTIONS_PER_USER - user.push_subscriptions.count).times do |index|
      user.push_subscriptions.create!(
        endpoint: "https://push.example.com/#{index}",
        p256dh_key: P256DH_KEY, auth_key: AUTH_KEY
      )
    end

    subscription = user.push_subscriptions.build(
      session: sessions(:jz_chrome), endpoint: "https://push.example.com/excess",
      p256dh_key: P256DH_KEY, auth_key: AUTH_KEY
    )
    assert_not subscription.valid?
    assert_includes subscription.errors[:base], "too many Web Push subscriptions"
  end

  test "rejects malformed subscription keys and invalid P-256 points" do
    subscription = users(:jz).push_subscriptions.build(
      session: sessions(:jz_chrome), endpoint: "https://push.example.com/new",
      p256dh_key: P256DH_KEY, auth_key: AUTH_KEY
    )

    subscription.auth_key = "A"
    assert_not subscription.valid?
    assert_includes subscription.errors[:auth_key], "is invalid"

    subscription.auth_key = AUTH_KEY
    subscription.p256dh_key = Base64.urlsafe_encode64("\x04" + ("\0" * 64), padding: false)
    assert_not subscription.valid?
    assert_includes subscription.errors[:p256dh_key], "is invalid"
  end

  test "rejects malformed keys when updating a persisted subscription" do
    subscription = push_subscriptions(:jz_chrome)

    assert_not subscription.update(auth_key: "A")
    assert_equal AUTH_KEY, subscription.reload.auth_key
  end
end

class Push::SubscriptionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  P256DH_KEY = Push::SubscriptionTest::P256DH_KEY
  AUTH_KEY = Push::SubscriptionTest::AUTH_KEY

  test "concurrent creates cannot exceed the per-user quota" do
    user = users(:jz)
    fill_user_quota(user, leave: 1)
    first_created = Queue.new
    release = Queue.new
    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Push::Subscription.transaction do
          User.find(user.id).push_subscriptions.create!(
            endpoint: "https://concurrent-1.example.com/push",
            p256dh_key: P256DH_KEY, auth_key: AUTH_KEY
          )
          first_created << true
          release.pop
        end
        :created
      end
    end
    first_created.pop
    second_started = Queue.new
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        second_started << true
        User.find(user.id).push_subscriptions.create!(
          endpoint: "https://concurrent-2.example.com/push",
          p256dh_key: P256DH_KEY, auth_key: AUTH_KEY
        )
        :created
      rescue ActiveRecord::RecordInvalid
        :rejected
      end
    end
    second_started.pop
    sleep 0.05

    assert_predicate second, :alive?
    release << true
    assert_equal :created, first.value
    assert_equal :rejected, second.value
    assert_equal Push::Subscription::MAXIMUM_SUBSCRIPTIONS_PER_USER, user.push_subscriptions.count
  ensure
    release << true if first&.alive?
    first&.join(2)
    second&.join(2)
  end

  private
    def fill_user_quota(user, leave:)
      count = Push::Subscription::MAXIMUM_SUBSCRIPTIONS_PER_USER - user.push_subscriptions.count - leave
      count.times do |index|
        user.push_subscriptions.create!(
          endpoint: "https://quota-#{index}.example.com/push",
          p256dh_key: P256DH_KEY, auth_key: AUTH_KEY
        )
      end
    end
end
