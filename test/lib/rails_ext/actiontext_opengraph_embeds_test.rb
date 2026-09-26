require "test_helper"

# Every case runs against both ways an embed is stored: the Trix-era node
# attributes and the content markup Lexxy serializes.
class ActionText::Attachment::OpengraphEmbedTest < ActiveSupport::TestCase
  test "keeps absolute http and https links and images" do
    embeds_from(href: "http://example.com/page", url: "https://example.com/image.png").each do |embed|
      assert_equal "http://example.com/page", embed.href
      assert_equal "https://example.com/image.png", embed.url
    end
  end

  test "drops a link and an image that aren't web URLs" do
    [ "javascript:alert(1)", "data:text/html,pwned", "vbscript:msgbox(1)", "//example.com/image.png",
      "/rooms/1", "rooms/1", "", "http://exa mple.com/ ",
      "https:/rooms/1", "https:rooms/1", "http:/rooms/1", "https://", "http://:80/rooms/1" ].each do |value|
      embeds_from(href: value, url: value).each do |embed|
        assert_nil embed.href, "expected #{value.inspect} to be dropped as a link"
        assert_nil embed.url, "expected #{value.inspect} to be dropped as an image"
      end
    end
  end

  test "drops a link and an image on this Campfire's own host, however it is spelled" do
    Current.set request: ActionDispatch::TestRequest.create("HTTP_HOST" => "once.campfire.test") do
      [ "https://once.campfire.test/rooms/1", "http://once.campfire.test/rooms/1",
        "https://ONCE.Campfire.Test/rooms/1", "https://once.campfire.test./rooms/1",
        "https://%6fnce.campfire.test/rooms/1", "https://%77ww.example.com/x.png" ].each do |value|
        embeds_from(href: value, url: value).each do |embed|
          assert_nil embed.href, "expected #{value.inspect} to be dropped as a link"
          assert_nil embed.url, "expected #{value.inspect} to be dropped as an image"
        end
      end

      embeds_from(href: "https://example.com/page", url: "https://example.com/image.png").each do |embed|
        assert_equal "https://example.com/page", embed.href
        assert_equal "https://example.com/image.png", embed.url
      end
    end
  end

  test "drops a link and an image on a bare address rather than a domain name" do
    [ "http://127.0.0.1/rooms/1", "http://2130706433/rooms/1", "http://0177.0.0.1/rooms/1",
      "http://0x7f.0.0.1/rooms/1", "http://1.2.3.0xff/rooms/1", "http://[::1]/rooms/1",
      "http://localhost/rooms/1", "https://203.0.113.10/image.png" ].each do |value|
      embeds_from(href: value, url: value).each do |embed|
        assert_nil embed.href, "expected #{value.inspect} to be dropped as a link"
        assert_nil embed.url, "expected #{value.inspect} to be dropped as an image"
      end
    end
  end

  test "keeps an internationalized domain written in punycode" do
    embeds_from(href: "https://xn--80aswg.xn--p1ai/page", url: "https://xn--80aswg.xn--p1ai/image.png").each do |embed|
      assert_equal "https://xn--80aswg.xn--p1ai/page", embed.href
      assert_equal "https://xn--80aswg.xn--p1ai/image.png", embed.url
    end
  end

  test "reads the details out of content markup" do
    embed = content_attachment_for(href: "https://example.com/page", url: "https://example.com/image.png",
      filename: "Example title", caption: "Example description").attachable

    assert_equal "Example title", embed.filename
    assert_equal "Example description", embed.description
  end

  test "renders the image and the link when both are web URLs" do
    render_embeds(href: "https://example.com/page", url: "https://example.com/image.png").each do |html|
      assert_match %r{<a rel="noreferrer" target="_blank" href="https://example\.com/page">Title</a>}, html
      assert_match %r{<img src="https://example\.com/image\.png"}, html
    end
  end

  test "renders no image and no link when neither is a web URL" do
    render_embeds(href: "javascript:alert(1)", url: "data:image/svg+xml;base64,PHN2Zy8+").each do |html|
      assert_no_match /javascript:/, html
      assert_no_match /data:/, html
      assert_no_match /<img/, html
      assert_no_match /<a /, html
      assert_match "Title", html
    end
  end

  test "renders the title and the description as text" do
    render_embeds(href: "https://example.com/page", url: "https://example.com/image.png",
      filename: "<b>Title</b>", caption: "<img src=x onerror=alert(1)>").each do |html|
      assert_no_match /<b>/, html
      assert_no_match /<img src=x/, html
      assert_match "&lt;b&gt;Title&lt;/b&gt;", html
      assert_match "&lt;img src=x onerror=alert(1)&gt;", html
    end
  end

  private
    def attachments_for(**details)
      [ attribute_attachment_for(**details), content_attachment_for(**details) ]
    end

    def attribute_attachment_for(href:, url:, filename: "Title", caption: "Description")
      attachment_from %(<action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" ) +
        %(href="#{href}" url="#{url}" filename="#{filename}" caption="#{caption}"></action-text-attachment>)
    end

    def content_attachment_for(href:, url:, filename: "Title", caption: "Description")
      content = <<~HTML.squish
        <actiontext-opengraph-embed><div class="og-embed">
          <div class="og-embed__content">
            <div class="og-embed__title"><a href="#{ERB::Util.html_escape(href)}">#{ERB::Util.html_escape(filename)}</a></div>
            <div class="og-embed__description">#{ERB::Util.html_escape(caption)}</div>
          </div>
          <div class="og-embed__image"><img src="#{ERB::Util.html_escape(url)}"></div>
        </div></actiontext-opengraph-embed>
      HTML

      attachment_from %(<action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" ) +
        %(content="#{ERB::Util.html_escape(content)}"></action-text-attachment>)
    end

    def attachment_from(html)
      ActionText::Attachment.from_node ActionText::Fragment.wrap(html).find_all(ActionText::Attachment.tag_name).first
    end

    def embeds_from(**details)
      attachments_for(**details).map(&:attachable)
    end

    def render_embeds(**details)
      attachments_for(**details).map do |attachment|
        ApplicationController.render partial: attachment.to_partial_path, locals: { opengraph_embed: attachment }
      end
    end
end
