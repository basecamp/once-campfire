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

  test "editable_body rebuilds a hand-written embed from its validated details" do
    content = <<~HTML.squish
      <actiontext-opengraph-embed data-controller="pwn" data-action="click->pwn#run">
        <div class="og-embed"><div class="og-embed__title"><a href="/rooms/1">Free cookies</a></div>
        <div class="og-embed__image"><img src="/rooms/1/avatar" data-action="load->pwn#run"></div></div>
      </actiontext-opengraph-embed>
    HTML
    body = %(<p><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" url="https://example.com/image.png" content="#{ERB::Util.html_escape(content)}"></action-text-attachment></p>)
    message = Message.create! room: rooms(:pets), body: body, client_message_id: "0019", creator: users(:jason)

    node = editable_body(message).body.fragment.find_all("action-text-attachment").first
    rebuilt = Nokogiri::HTML.fragment(node["content"])

    assert_equal "Free cookies", rebuilt.at_css(".og-embed__title").text.strip
    assert_no_match /rooms\/1/, node["content"]
    assert_no_match /data-/, node["content"]
    assert_nil rebuilt.at_css("a")
    assert_nil rebuilt.at_css("img")
  end

  test "editable_body restores the content type of a mention edited under Trix" do
    body = %(<div>Hey <action-text-attachment sgid="#{users(:david).attachable_sgid}" content-type="application/octet-stream"></action-text-attachment></div>)
    message = Message.create! room: rooms(:pets), body: body, client_message_id: "0020", creator: users(:jason)

    node = editable_body(message).body.fragment.find_all("action-text-attachment").first

    assert_equal "application/vnd.campfire.mention", node["content-type"]
    assert_match "David", node["content"]
  end

  test "editable_body leaves bodies without attachments unchanged" do
    message = Message.create! room: rooms(:pets), body: "<p>Plain text</p>", client_message_id: "0018", creator: users(:jason)

    assert_equal message.body.body.to_html, editable_body(message).body.to_html
  end
end
