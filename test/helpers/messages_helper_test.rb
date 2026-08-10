require "test_helper"

class MessagesHelperTest < ActionView::TestCase
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
end
