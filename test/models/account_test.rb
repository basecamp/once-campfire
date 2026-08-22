require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "new accounts receive a canonical installation identifier" do
    account = Account.new(name: "Fresh Campfire")

    assert_predicate account, :valid?
    assert_match CampfireBackup::InstallationIdentity::PATTERN, account.installation_identifier
    assert_equal 32, account.installation_identifier.length
  end

  test "settings" do
    accounts(:signal).settings.restrict_room_creation_to_administrators = true
    assert accounts(:signal).settings.restrict_room_creation_to_administrators?
    assert_equal({ "restrict_room_creation_to_administrators" => true }, accounts(:signal)[:settings])

    accounts(:signal).update!(settings: { "restrict_room_creation_to_administrators" => "true" })
    assert accounts(:signal).reload.settings.restrict_room_creation_to_administrators?

    accounts(:signal).settings.restrict_room_creation_to_administrators = false
    assert_not accounts(:signal).settings.restrict_room_creation_to_administrators?
    assert_equal({ "restrict_room_creation_to_administrators" => false }, accounts(:signal)[:settings])
    accounts(:signal).update!(settings: { "restrict_room_creation_to_administrators" => "false" })
    assert_not accounts(:signal).reload.settings.restrict_room_creation_to_administrators?
  end

  test "logo_variant is a resized variant of a variable logo" do
    accounts(:signal).logo.attach io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg"

    assert_kind_of ActiveStorage::VariantWithRecord, accounts(:signal).logo_variant(:large)
  end

  test "logo_variant is nil when the logo cannot be resized" do
    accounts(:signal).logo.attach io: file_fixture("pixel.bmp").open, filename: "pixel.bmp", content_type: "image/bmp"

    assert_nil accounts(:signal).logo_variant(:large)
  end

  test "logo_variant is nil without a logo" do
    assert_nil accounts(:signal).logo_variant(:large)
  end

  test "a failed account update preserves the prior logo and discards the staged replacement" do
    account = accounts(:signal)
    account.logo.attach io: StringIO.new("old logo"), filename: "old.txt", content_type: "text/plain"
    old_blob = account.logo.blob
    Account.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(account))

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        account.update_with_staged_logo!({
          name: "Not committed",
          logo: { io: StringIO.new("new logo"), filename: "new.txt", content_type: "text/plain" }
        }, actor: users(:david))
      end
    end

    assert_equal old_blob, account.reload.logo.blob
    assert_equal "old logo", account.logo.download
  end

  test "a demoted administrator cannot commit a staged account update" do
    account = accounts(:signal)
    actor = users(:david)
    actor.update!(role: :member)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_raises(User::AuthorizationError) do
        account.update_with_staged_logo!({
          name: "Unauthorized",
          logo: { io: StringIO.new("new logo"), filename: "new.txt", content_type: "text/plain" }
        }, actor:)
      end
    end

    assert_not_equal "Unauthorized", account.reload.name
  end
end
