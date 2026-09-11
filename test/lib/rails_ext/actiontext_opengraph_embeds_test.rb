require "test_helper"

class ActionText::Attachment::OpengraphEmbedTest < ActiveSupport::TestCase
  test "keeps absolute http and https links and images" do
    embed = embed_from href: "http://example.com/page", url: "https://example.com/image.png"

    assert_equal "http://example.com/page", embed.href
    assert_equal "https://example.com/image.png", embed.url
  end

  test "drops a link and an image that aren't web URLs" do
    [ "javascript:alert(1)", "data:text/html,pwned", "vbscript:msgbox(1)", "//example.com/image.png",
      "/rooms/1", "rooms/1", "", "http://exa mple.com/ ",
      "https:/rooms/1", "https:rooms/1", "http:/rooms/1", "https://", "http://:80/rooms/1" ].each do |value|
      embed = embed_from href: value, url: value

      assert_nil embed.href, "expected #{value.inspect} to be dropped as a link"
      assert_nil embed.url, "expected #{value.inspect} to be dropped as an image"
    end
  end

  test "drops a link and an image on this Campfire's own host, however it is spelled" do
    Current.set request: ActionDispatch::TestRequest.create("HTTP_HOST" => "once.campfire.test") do
      [ "https://once.campfire.test/rooms/1", "http://once.campfire.test/rooms/1",
        "https://ONCE.Campfire.Test/rooms/1", "https://once.campfire.test./rooms/1",
        "https://%6fnce.campfire.test/rooms/1", "https://%77ww.example.com/x.png" ].each do |value|
        embed = embed_from href: value, url: value

        assert_nil embed.href, "expected #{value.inspect} to be dropped as a link"
        assert_nil embed.url, "expected #{value.inspect} to be dropped as an image"
      end

      embed = embed_from href: "https://example.com/page", url: "https://example.com/image.png"
      assert_equal "https://example.com/page", embed.href
      assert_equal "https://example.com/image.png", embed.url
    end
  end

  test "renders the image and the link when both are web URLs" do
    html = render_embed href: "https://example.com/page", url: "https://example.com/image.png"

    assert_match %r{<a rel="noreferrer" target="_blank" href="https://example\.com/page">Title</a>}, html
    assert_match %r{<img src="https://example\.com/image\.png"}, html
  end

  test "renders no image and no link when neither is a web URL" do
    html = render_embed href: "javascript:alert(1)", url: "data:image/svg+xml;base64,PHN2Zy8+"

    assert_no_match /javascript:/, html
    assert_no_match /data:/, html
    assert_no_match /<img/, html
    assert_no_match /<a /, html
    assert_match "Title", html
  end

  test "renders the title and the description as text" do
    html = render_embed href: "https://example.com/page", url: "https://example.com/image.png",
      filename: "<b>Title</b>", caption: "<img src=x onerror=alert(1)>"

    assert_no_match /<b>/, html
    assert_no_match /<img src=x/, html
    assert_match "&lt;b&gt;Title&lt;/b&gt;", html
    assert_match "&lt;img src=x onerror=alert(1)&gt;", html
  end

  private
    def attachment_for(href:, url:, filename: "Title", caption: "Description")
      html = %(<action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" ) +
        %(href="#{href}" url="#{url}" filename="#{filename}" caption="#{caption}"></action-text-attachment>)
      node = ActionText::Fragment.wrap(html).find_all(ActionText::Attachment.tag_name).first

      ActionText::Attachment.from_node(node)
    end

    def embed_from(**attributes)
      attachment_for(**attributes).attachable
    end

    def render_embed(**attributes)
      attachment = attachment_for(**attributes)

      ApplicationController.render partial: attachment.to_partial_path, locals: { opengraph_embed: attachment }
    end
end
