require "test_helper"

class IdentityTest < ActiveSupport::TestCase
  setup do
    configure_oidc
  end

  test "authenticates a returning identity by issuer and subject" do
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "returning-subject")
    auth = oidc_auth(subject: identity.subject, email: nil, claims: { "email_verified" => nil })

    assert_equal identity, Identity.authenticate(auth)
  end

  test "prepared authentication cannot complete after its subject fence is released" do
    auth = oidc_auth(subject: "released-fence-subject", email: users(:jz).email_address)
    authentication = Identity.with_authentication_fence(auth) { _1 }

    error = assert_raises(Identity::AuthenticationError) do
      authentication.complete!(
        linking_user: users(:jz), linking_authorization: { "method" => "password" }
      )
    end

    assert_equal "identity_policy_unavailable", error.message
    assert_not Identity.exists?(issuer: Oidc.issuer, subject: authentication.subject)
  end

  test "assigns an opaque stable SCIM identifier" do
    first = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "stable-scim-subject")
    second = Identity.create!(user: users(:kevin), issuer: Oidc.issuer, subject: "other-stable-scim-subject")

    assert_match Identity::SCIM_ID_PATTERN, first.scim_id
    assert_not_equal first.scim_id, second.scim_id
  end

  test "identity ownership and provider identifiers are immutable" do
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "immutable-subject")

    {
      user: users(:kevin),
      issuer: "https://attacker.example.com",
      subject: "replacement-subject",
      scim_id: SecureRandom.uuid
    }.each do |attribute, value|
      identity.assign_attributes(attribute => value)
      assert_not identity.save
      identity.reload
    end
  end

  test "extracts only a bounded provider session identifier" do
    assert_equal "provider-session", Identity.provider_session_id(
      oidc_auth(claims: { "sid" => "provider-session" })
    )
    assert_nil Identity.provider_session_id(oidc_auth)

    [ "", 123, "x" * 256 ].each do |sid|
      error = assert_raises(Identity::AuthenticationError) do
        Identity.provider_session_id(oidc_auth(claims: { "sid" => sid }))
      end
      assert_equal "invalid_session_identifier", error.message
    end
  end

  test "extracts the signed integer issue time needed for session ordering" do
    issued_at = Time.current.to_i

    assert_equal({ oidc_session_id: "provider-session", oidc_issued_at: issued_at },
      Identity.provider_session_attributes(
        oidc_auth(claims: { "sid" => "provider-session", "iat" => issued_at })
      ))

    [ nil, 1.5, 0 ].each do |value|
      error = assert_raises(Identity::AuthenticationError) do
        Identity.provider_session_attributes(oidc_auth(claims: { "iat" => value }))
      end
      assert_equal "invalid_token_lifetime", error.message
    end
  end

  test "requires explicit relinking when the provider client changes" do
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "changed-client-subject")
    configure_oidc("OIDC_CLIENT_ID" => "replacement-client")
    auth = oidc_auth(subject: identity.subject, email: users(:jz).email_address)

    error = assert_raises(Identity::AuthenticationError) { Identity.authenticate(auth) }
    assert_equal "provider_configuration_changed", error.message

    assert_equal identity, Identity.authenticate(
      auth, linking_user: users(:jz), linking_authorization: identity_authorization(identity.subject)
    )
    assert_equal Oidc.provider_fingerprint, identity.reload.provider_fingerprint
  end

  test "deterministically links an existing active user by canonical verified email" do
    auth = oidc_auth(subject: "jz-subject", email: "\tJZ@37SIGNALS.COM \n")

    identity = assert_difference -> { Identity.count }, +1 do
      Identity.authenticate(
        auth, linking_user: users(:jz), linking_authorization: password_authorization
      )
    end

    assert_equal users(:jz), identity.user
    assert_equal Oidc.issuer, identity.issuer
    assert_equal "jz-subject", identity.subject
    assert_equal Oidc.provider_fingerprint, identity.provider_fingerprint
  end

  test "fails closed when stored email identity columns disagree" do
    user = users(:jz)
    user.update_column(:normalized_email_address, "different@example.com")

    error = assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(
        oidc_auth(subject: "drifted-email-subject", email: user.email_address),
        linking_user: user, linking_authorization: password_authorization
      )
    end

    assert_equal "account_email_mismatch", error.message
    assert_not user.identities.exists?(issuer: Oidc.issuer)
  end

  test "does not link an existing password account without its authenticated session" do
    auth = oidc_auth(subject: "jz-subject", email: users(:jz).email_address)

    error = assert_raises(Identity::AuthenticationError) { Identity.authenticate(auth) }

    assert_equal "account_link_required", error.message
    assert_not users(:jz).identities.exists?
  end

  test "an email swap and restore cannot attach an attacker subject without password proof" do
    user = users(:jz)
    original_email = user.email_address
    attacker_email = "attacker-controlled@example.com"
    user.update_column(:email_address, attacker_email)

    error = assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(
        oidc_auth(subject: "attacker-subject", email: attacker_email), linking_user: user
      )
    end
    user.update_column(:email_address, original_email)

    assert_equal "password_reauthentication_required", error.message
    assert_not user.identities.exists?(issuer: Oidc.issuer)
    assert_equal original_email, user.reload.email_address
  end

  test "recent password proof authorizes a first identity" do
    user = users(:jz)

    identity = Identity.authenticate(
      oidc_auth(subject: "password-authorized-subject", email: user.email_address),
      linking_user: user, linking_authorization: password_authorization
    )

    assert_equal user, identity.user
    assert_equal "password-authorized-subject", identity.subject
  end

  test "an already-linked account accepts only its existing subject" do
    user = users(:jz)
    identity = Identity.create!(user:, issuer: Oidc.issuer, subject: "bound-subject")

    error = assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(
        oidc_auth(subject: "attacker-subject", email: user.email_address), linking_user: user,
        linking_authorization: identity_authorization(identity.subject)
      )
    end
    assert_equal "identity_conflict", error.message

    assert_equal identity, Identity.authenticate(
      oidc_auth(subject: identity.subject, email: nil, claims: { "email_verified" => nil }),
      linking_user: user, linking_authorization: identity_authorization(identity.subject)
    )
  end

  test "refuses first-time linking without a verified email" do
    auth = oidc_auth(email: users(:jz).email_address, claims: { "email_verified" => false })

    error = assert_raises(Identity::AuthenticationError) { Identity.authenticate(auth) }

    assert_equal "unverified_email", error.message
    assert_not users(:jz).identities.exists?
  end

  test "does not provision users unless JIT is enabled" do
    error = assert_raises(Identity::AuthenticationError) { Identity.authenticate(oidc_auth) }

    assert_equal "provisioning_disabled", error.message
  end

  test "provisions a member when JIT is enabled" do
    configure_oidc("OIDC_JIT_PROVISIONING" => "true")

    identity = assert_difference -> { User.count }, +1 do
      Identity.authenticate(oidc_auth(email: " OIDC@EXAMPLE.COM "))
    end

    assert_equal "OIDC User", identity.user.name
    assert_equal "oidc@example.com", identity.user.email_address
    assert_equal identity.user.email_address, identity.user.normalized_email_address
    assert identity.user.member?
    assert_not identity.user.authenticate(SecureRandom.hex)
  end

  test "never relinks a user to a new subject for the same issuer" do
    Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "original-subject")

    error = assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(
        oidc_auth(subject: "replacement-subject", email: users(:jz).email_address),
        linking_user: users(:jz), linking_authorization: identity_authorization("original-subject")
      )
    end

    assert_equal "identity_conflict", error.message
  end

  test "rejects inactive users" do
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "inactive-subject")
    users(:jz).deactivated!

    error = assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(subject: identity.subject))
    end

    assert_equal "inactive_user", error.message
  end

  test "rejects an identity durably revoked by its provider" do
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "revoked-subject")
    identity.update!(provider_revoked_at: Time.current)

    error = assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(subject: identity.subject))
    end

    assert_equal "identity_revoked", error.message
    identity.provider_revoked_at = nil
    assert_not identity.save
  end

  test "a subject tombstone blocks later linking and JIT provisioning" do
    configure_oidc("OIDC_JIT_PROVISIONING" => "true")
    subject = "deprovisioned-before-link-subject"
    Identity::Deprovisioning.deprovision!(issuer: Oidc.issuer, subject:)

    assert_no_changes -> { [ User.count, Identity.count ] } do
      error = assert_raises(Identity::AuthenticationError) do
        Identity.authenticate(oidc_auth(subject:, email: "blocked-jit@example.com"))
      end
      assert_equal "identity_revoked", error.message
    end

    identity = Identity.new(
      user: users(:jz), issuer: Oidc.issuer, subject:, provider_fingerprint: Oidc.provider_fingerprint
    )
    assert_not identity.save
    assert_includes identity.errors[:base], "identity was deprovisioned by its provider"
  end

  test "requires an ID token and exact issuer" do
    assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(id_token: nil))
    end

    assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(claims: { "iss" => "https://attacker.example.com" }))
    end
  end

  test "requires protocol identifiers to be strings" do
    error = assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(subject: 123, claims: { "sub" => 123 }))
    end

    assert_equal "invalid_subject", error.message
  end

  test "rejects malformed provider session identifiers during authentication" do
    identity = Identity.create!(user: users(:jz), issuer: Oidc.issuer, subject: "sid-claims-subject")

    error = assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(subject: identity.subject, claims: { "sid" => "" }))
    end

    assert_equal "invalid_session_identifier", error.message
  end

  test "rechecks linking ownership after a uniqueness race" do
    identity = Identity.create!(user: users(:kevin), issuer: Oidc.issuer, subject: "raced-subject")
    Identity.stubs(:find_by).returns(nil, identity)
    Identity.stubs(:link_identity!).raises(ActiveRecord::RecordNotUnique)

    error = assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(
        oidc_auth(subject: identity.subject, email: users(:jz).email_address),
        linking_user: users(:jz), linking_authorization: password_authorization
      )
    end

    assert_equal "identity_conflict", error.message
  end

  test "validates audience and authorized party" do
    assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(claims: { "aud" => "another-client" }))
    end

    assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(claims: { "aud" => [ Oidc.client_id, "api" ] }))
    end

    assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(
        claims: { "aud" => [ Oidc.client_id, "api" ], "azp" => Oidc.client_id }
      ))
    end

    [ nil, false, 123, "another-client" ].each do |authorized_party|
      error = assert_raises(Identity::AuthenticationError) do
        Identity.authenticate(oidc_auth(claims: { "azp" => authorized_party }))
      end
      assert_equal "invalid_authorized_party", error.message
    end

    auth = oidc_auth(
      email: users(:jz).email_address,
      claims: { "aud" => [ Oidc.client_id ], "azp" => Oidc.client_id }
    )
    assert Identity.authenticate(
      auth, linking_user: users(:jz), linking_authorization: password_authorization
    )
  end

  test "rejects expired and future-issued tokens" do
    assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(claims: { "exp" => 1.minute.ago.to_i }))
    end

    assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(claims: { "iat" => 5.minutes.from_now.to_i }))
    end

    assert_raises(Identity::AuthenticationError) do
      Identity.authenticate(oidc_auth(claims: { "nbf" => 5.minutes.from_now.to_i }))
    end
  end

  private
    def password_authorization
      { "method" => "password" }
    end

    def identity_authorization(subject)
      { "method" => "identity", "subject" => subject }
    end
end
