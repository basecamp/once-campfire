require "test_helper"

class MessagesHelperTest < ActionView::TestCase
  test "plain text presentation is reused by content rather than database epoch" do
    view.controller.stubs(:perform_caching).returns(true)
    FragmentCache.store.clear
    message = Message.create! room: rooms(:pets), body: "A reusable <strong>safe</strong> body", creator: users(:jason)
    first = view.message_presentation(message)
    assert_includes first, "A reusable <strong>safe</strong> body"
    ContentFilters::TextMessagePresentationFilters.expects(:apply).never
    assert_equal first, view.message_presentation(message)
  ensure
    FragmentCache.store.clear
  end

  test "message_presentation neutralizes unsafe URI schemes in links" do
    message = Message.create! room: rooms(:pets), body: '<div><a href="javascript:alert(1)">x</a></div>', client_message_id: "0015", creator: users(:jason)

    presentation = view.message_presentation(message)
    assert_no_match /javascript:/, presentation
    assert_match /<a>x<\/a>/, presentation
  end

  test "message_presentation strips event handler attributes from allowed tags" do
    message = Message.create! room: rooms(:pets), body: '<div><a href="/x" onmouseover="alert(1)">x</a></div>', client_message_id: "0015", creator: users(:jason)

    presentation = view.message_presentation(message)
    assert_no_match /onmouseover/, presentation
    assert_match /<a href="\/x">x<\/a>/, presentation
  end

  test "message_presentation preserves safe links and formatting" do
    message = Message.create! room: rooms(:pets), body: '<div><a href="https://example.com">example</a> <strong>bold</strong></div>', client_message_id: "0015", creator: users(:jason)

    presentation = view.message_presentation(message)
    assert_match /<a href="https:\/\/example\.com"[^>]*>example<\/a>/, presentation
    assert_match /<strong>bold<\/strong>/, presentation
  end

  test "message_presentation shows an image's thumbnail made when it was posted" do
    presentation = view.message_presentation(attachment_message("moon.jpg", "image/jpeg", processed: true))

    assert_match %r{<img[^>]+src="[^"]*/representations/[^"]*moon\.jpg"}, presentation
  end

  test "message_presentation links an image whose thumbnail wasn't made, rather than making it on view" do
    presentation = view.message_presentation(attachment_message("moon.jpg", "image/jpeg", processed: false))

    assert_no_match %r{/representations/}, presentation
    assert_match %r{<span>moon\.jpg</span>}, presentation
  end

  test "message_presentation gives a video the poster made when it was posted" do
    presentation = view.message_presentation(attachment_message("alpha-centuri.mov", "video/quicktime", processed: true))

    assert_match %r{<video[^>]+poster="[^"]*/representations/[^"]*alpha-centuri}, presentation
  end

  test "message_presentation shows a video whose poster wasn't made without one, rather than making it on view" do
    presentation = view.message_presentation(attachment_message("alpha-centuri.mov", "video/quicktime", processed: false))

    assert_match %r{<video[^>]+src="[^"]*alpha-centuri\.mov"}, presentation
    assert_no_match %r{poster=|/representations/}, presentation
  end

  test "message_presentation shows a video whose frame was drawn but whose poster wasn't made without one" do
    message = attachment_message("alpha-centuri.mov", "video/quicktime", processed: false)
    message.attachment.preview(format: :jpg).processed
    assert message.attachment.preview(:poster).processed?

    presentation = view.message_presentation(message.reload)

    assert_match %r{<video[^>]+src="[^"]*alpha-centuri\.mov"}, presentation
    assert_no_match %r{poster=|/representations/}, presentation
  end

  test "message_presentation shows an image in the rich text as a file, rather than making its preview on view" do
    message = Message.with_attachment_details.find(message_with_file_in_rich_text("moon.jpg", "image/jpeg").id)

    presentation = nil
    assert_no_queries_match(/active_storage_variant_records/) { presentation = view.message_presentation(message) }

    assert_no_match %r{/representations/}, presentation
    assert_match %r{<span class="attachment__name">moon\.jpg</span>}, presentation
  end

  test "message_presentation shows an image in the rich text as a file even when its preview was made" do
    message = message_with_file_in_rich_text("moon.jpg", "image/jpeg")
    message.body.embeds.first.blob.variant(resize_to_limit: [ 1024, 768 ]).processed

    presentation = view.message_presentation(message.reload)

    assert_no_match %r{/representations/}, presentation
    assert_match %r{<span class="attachment__name">moon\.jpg</span>}, presentation
  end

  test "message_presentation shows a video in the rich text as a file" do
    presentation = view.message_presentation(message_with_file_in_rich_text("alpha-centuri.mov", "video/quicktime"))

    assert_no_match %r{/representations/}, presentation
    assert_match %r{<span class="attachment__name">alpha-centuri\.mov</span>}, presentation
  end

  private
    def attachment_message(file, content_type, processed:)
      attributes = { creator: users(:jason), client_message_id: "0015", attachment: fixture_file_upload(file, content_type) }

      if processed
        rooms(:pets).messages.create_with_attachment!(attributes)
      else
        rooms(:pets).messages.create!(attributes)
      end
    end

    def message_with_file_in_rich_text(file, content_type)
      blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture(file).open, filename: file, content_type: content_type)
      body = %(<div>Here: <action-text-attachment sgid="#{blob.attachable_sgid}"></action-text-attachment></div>)

      Message.create! room: rooms(:pets), body: body, client_message_id: "0015", creator: users(:jason)
    end
end
