require "test_helper"

class RichTextHelperTest < ActionView::TestCase
  include ActionText::ContentHelper
  test "editable_body renders legacy opengraph embeds into the content attribute" do
    body = %(<div>https://example.com/ <action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" url="https://example.com/image.png" href="https://example.com/" filename="Example title" caption="Example description"></action-text-attachment></div>)
    message = Message.create! room: rooms(:pets), body: body, client_message_id: "0017", creator: users(:jason)

    node = editable_body(message).body.fragment.find_all("action-text-attachment").first
    content = Nokogiri::HTML.fragment(node["content"])

    assert_equal "Example title", content.at_css(".og-embed__title a").text.strip
    assert_equal "https://example.com/", content.at_css(".og-embed__title a")["href"]
    assert_equal "Example description", content.at_css(".og-embed__description").text.strip
    assert_equal "https://example.com/image.png", content.at_css(".og-embed__image img")["src"]
  end

  test "editable_body leaves bodies without legacy embeds unchanged" do
    message = Message.create! room: rooms(:pets), body: "<p>Plain text</p>", client_message_id: "0018", creator: users(:jason)

    assert_equal message.body.body.to_html, editable_body(message).body.to_html
  end
end
