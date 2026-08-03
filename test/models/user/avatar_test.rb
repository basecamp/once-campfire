require "test_helper"

class User::AvatarTest < ActiveSupport::TestCase
  test "avatar_variant is a resized variant of a variable avatar" do
    users(:kevin).avatar.attach io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg"

    assert_kind_of ActiveStorage::VariantWithRecord, users(:kevin).avatar_variant
  end

  test "avatar_variant is nil when the avatar cannot be resized" do
    users(:kevin).avatar.attach io: file_fixture("pixel.bmp").open, filename: "pixel.bmp", content_type: "image/bmp"

    assert_nil users(:kevin).avatar_variant
  end

  test "avatar_variant is nil without an avatar" do
    assert_nil users(:kevin).avatar_variant
  end

  test "a failed profile update preserves the prior avatar and discards the staged replacement" do
    user = users(:kevin)
    user.avatar.attach io: StringIO.new("old avatar"), filename: "old.txt", content_type: "text/plain"
    old_blob = user.avatar.blob
    User.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(user))

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        user.update_with_staged_avatar!({
          name: "Not committed",
          avatar: { io: StringIO.new("new avatar"), filename: "new.txt", content_type: "text/plain" }
        }, actor: user)
      end
    end

    assert_equal old_blob, user.reload.avatar.blob
    assert_equal "old avatar", user.avatar.download
  end

  test "a banned user cannot commit a staged profile update" do
    user = users(:kevin)
    user.ban_by! actor: users(:david)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_raises(User::AuthorizationError) do
        user.update_with_staged_avatar!({
          name: "Unauthorized",
          avatar: { io: StringIO.new("new avatar"), filename: "new.txt", content_type: "text/plain" }
        }, actor: user)
      end
    end

    assert_not_equal "Unauthorized", user.reload.name
  end

  test "a password account must verify its current password before changing email" do
    user = users(:kevin)
    original_email = user.email_address

    assert_raises(User::Avatar::PasswordVerificationFailed) do
      user.update_with_staged_avatar!(
        { email_address: "changed@example.com" }, actor: user, current_password: "wrong"
      )
    end
    assert_equal original_email, user.reload.email_address

    user.update_with_staged_avatar!(
      { email_address: "changed@example.com" }, actor: user, current_password: "secret123456"
    )
    assert_equal "changed@example.com", user.reload.email_address
  end

  test "an OIDC-linked account can change email without an unavailable local password" do
    configure_oidc
    user = users(:kevin)
    Identity.create!(user:, issuer: Oidc.issuer, subject: "oidc-only-profile-subject")
    user.update_column(:password_digest, BCrypt::Password.create(SecureRandom.hex(32)))

    assert_nothing_raised do
      user.update_with_staged_avatar!({ email_address: "oidc-only@example.com" }, actor: user)
    end
    assert_equal "oidc-only@example.com", user.reload.email_address
  end
end
