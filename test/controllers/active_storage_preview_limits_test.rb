require "test_helper"

class ActiveStoragePreviewLimitsTest < ActionDispatch::IntegrationTest
  setup do
    @blob = ActiveStorage::Blob.create_and_upload! \
      io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg"
    @blob.analyze
    @pixels = @blob.metadata[:width] * @blob.metadata[:height]
    @variant = @blob.variant(resize_to_limit: [ 100, 100 ])
  end

  test "a representation is made on request within the pixel limit" do
    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, @pixels) do
      get rails_representation_path(@variant)
    end

    assert_response :redirect
    assert @variant.processed?
  end

  test "a representation isn't made on request past the pixel limit" do
    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, @pixels - 1) do
      get rails_representation_path(@variant)
    end

    assert_response :not_found
    assert_not @variant.processed?
  end

  test "a representation isn't made on request for a picture whose size only its uploader gave" do
    blob = ActiveStorage::Blob.create_and_upload! \
      io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg", metadata: { width: 1, height: 1 }
    variant = blob.variant(resize_to_limit: [ 100, 100 ])

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, @pixels - 1) do
      get rails_representation_path(variant)
    end

    assert_response :not_found
    assert_not variant.processed?
  end

  test "a direct upload can't claim to be analyzed to get a representation past the pixel limit" do
    sign_in :david
    bytes = file_fixture("moon.jpg").binread
    post rails_direct_uploads_path, as: :json, params: { blob: {
      filename: "moon.jpg", byte_size: bytes.bytesize, checksum: OpenSSL::Digest::MD5.base64digest(bytes),
      content_type: "image/jpeg", metadata: { analyzed: true, width: 1, height: 1 } } }
    upload = response.parsed_body
    put upload["direct_upload"]["url"], params: bytes, headers: upload["direct_upload"]["headers"]
    blob = ActiveStorage::Blob.find_signed!(upload["signed_id"])
    variant = blob.variant(resize_to_limit: [ 100, 100 ])

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, @pixels - 1) do
      get rails_representation_path(variant)
    end

    assert_not blob.reload.analyzed?
    assert_response :not_found
    assert_not variant.processed?
  end

  test "a representation made before is still served past the pixel limit" do
    @variant.processed

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, @pixels - 1) do
      get rails_representation_path(@variant)
    end

    assert_response :redirect
  end

  test "a video's preview isn't made on request past the pixel limit" do
    video = ActiveStorage::Blob.create_and_upload! \
      io: file_fixture("alpha-centuri.mov").open, filename: "alpha-centuri.mov", content_type: "video/quicktime"
    video.analyze
    preview = video.preview(resize_to_limit: [ 100, 100 ])

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, 1) do
      get rails_representation_path(preview)
    end

    assert_response :not_found
    assert_not video.reload.preview_image.attached?
  end

  test "a video's preview whose frame alone was drawn isn't finished on request past the pixel limit" do
    preview = video_preview
    # The frame without its variant, as a poster that failed to resize leaves it.
    preview.blob.preview_image.attach io: file_fixture("moon.jpg").open, filename: "frame.jpg", content_type: "image/jpeg"

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, 1) do
      get rails_representation_path(preview)
    end

    assert_response :not_found
    assert_not preview.image.variant(preview.variation).processed?
  end

  test "a video's preview made before is still served past the pixel limit" do
    preview = video_preview.processed

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, 1) do
      get rails_representation_path(preview)
    end

    assert_response :redirect
  end

  private
    def video_preview
      video = ActiveStorage::Blob.create_and_upload! \
        io: file_fixture("alpha-centuri.mov").open, filename: "alpha-centuri.mov", content_type: "video/quicktime"
      video.analyze
      video.preview(resize_to_limit: [ 100, 100 ])
    end
end
