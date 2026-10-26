require "test_helper"

class AccountTest < ActiveSupport::TestCase
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

  test "logo_variant is nil for a logo with more pixels than a preview may have" do
    accounts(:signal).logo.attach io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg"
    moon = Vips::Image.new_from_file(file_fixture("moon.jpg").to_s)

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, moon.width * moon.height - 1) do
      assert_nil accounts(:signal).logo_variant(:large)
    end
    assert_not accounts(:signal).logo.variant(:large).processed?

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, moon.width * moon.height) do
      assert accounts(:signal).logo_variant(:large).processed?
    end
  end

  test "logo_variant serves a variant made before, past the limit" do
    accounts(:signal).logo.attach io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg"
    accounts(:signal).logo_variant(:large)

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, 1) do
      assert accounts(:signal).logo_variant(:large).processed?
    end
  end

  test "logo_variant reads the size of a logo that wasn't analyzed yet" do
    blob = ActiveStorage::Blob.create_and_upload! io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg"
    accounts(:signal).logo.attach blob
    assert_not accounts(:signal).logo.analyzed?

    assert accounts(:signal).logo_variant(:large).processed?
  end
end
