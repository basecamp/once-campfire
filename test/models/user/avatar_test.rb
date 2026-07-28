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
end
