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

  test "avatar_variant is nil for an avatar with more pixels than a preview may have" do
    users(:kevin).avatar.attach io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg"
    moon = Vips::Image.new_from_file(file_fixture("moon.jpg").to_s)

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, moon.width * moon.height - 1) do
      assert_nil users(:kevin).avatar_variant
    end
    assert_not users(:kevin).avatar.variant(:square).processed?

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, moon.width * moon.height) do
      assert users(:kevin).avatar_variant.processed?
    end
  end

  test "avatar_variant serves a variant made before, past the limit" do
    users(:kevin).avatar.attach io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg"
    users(:kevin).avatar_variant

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, 1) do
      assert users(:kevin).avatar_variant.processed?
    end
  end

  test "avatar_variant reads the size of an avatar that wasn't analyzed yet" do
    blob = ActiveStorage::Blob.create_and_upload! io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg"
    users(:kevin).avatar.attach blob
    assert_not users(:kevin).avatar.analyzed?

    assert users(:kevin).avatar_variant.processed?
  end

  test "avatar_variant is nil without an avatar" do
    assert_nil users(:kevin).avatar_variant
  end
end
