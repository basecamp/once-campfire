require "test_helper"

class MessagesHelperTest < ActionView::TestCase
  include ActiveRecord::Assertions::QueryAssertions

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
    def message_with_file_in_rich_text(file, content_type)
      blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture(file).open, filename: file, content_type: content_type)
      body = %(<div>Here: <action-text-attachment sgid="#{blob.attachable_sgid}"></action-text-attachment></div>)

      Message.create! room: rooms(:pets), body: body, client_message_id: "0015", creator: users(:jason)
    end
end
