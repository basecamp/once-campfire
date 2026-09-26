require "test_helper"

class ContentFiltersTest < ActionView::TestCase
  include MessagesHelper, ERB::Util
  test "entire message contains an unfurled URL" do
    text = "https://basecamp.com/"
    message = Message.create! room: rooms(:pets), body: unfurled_message_body_for_basecamp(text), client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_not_equal message.body.body.to_html, filtered.to_html
    assert_match /<div><action-text-attachment/, filtered.to_html
  end

  test "entire message contains an unfurled URL in a lexxy body" do
    text = "https://basecamp.com/"
    body = "<p><a href=\"#{text}\">#{text}</a></p>#{unfurled_link_trix_attachment_for_basecamp}"
    message = Message.create! room: rooms(:pets), body: body, client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_no_match %r{>\s*https://basecamp\.com/\s*</a>}, filtered.to_html
    assert_match /<action-text-attachment/, filtered.to_html
  end

  test "message includes additional text besides an unfurled URL" do
    text = "Hello https://basecamp.com/"
    message = Message.create! room: rooms(:pets), body: unfurled_message_body_for_basecamp(text), client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_equal message.body.body.to_html, filtered.to_html
    assert_match %r{<div>Hello https://basecamp\.com/<action-text-attachment}, filtered.to_html
  end

  test "unfurled tweet with an avatar image gets the twitter avatar treatment" do
    body = %(<div>https://twitter.com/37signals/status/1750290547908952568<action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" url="https://pbs.twimg.com/profile_images/1671940407633010689/9P5gi6LF_200x200.jpg" href="https://twitter.com/37signals/status/1750290547908952568" filename="37signals (@37signals)" caption="We're back up on all apps, everyone."></action-text-attachment></div>)
    message = Message.create! room: rooms(:pets), body: body, client_message_id: "0015", creator: users(:jason)

    assert_match /og-embed--twitter-avatar/, message_presentation(message)
  end

  test "unfurled tweet with an avatar image in a lexxy body gets the twitter avatar treatment" do
    content = %(<actiontext-opengraph-embed><div class="og-embed gap"><div class="og-embed__content"><div class="og-embed__title"><a href="https://twitter.com/x/status/1">Tweet</a></div><div class="og-embed__description">desc</div></div><div class="og-embed__image"><img src="https://pbs.twimg.com/profile_images/x.jpg" class="image center" alt="" /></div></div></actiontext-opengraph-embed>)
    body = %(<p><a href="https://twitter.com/x/status/1">https://twitter.com/x/status/1</a></p><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" content="#{CGI.escapeHTML(content)}"></action-text-attachment>)
    message = Message.create! room: rooms(:pets), body: body, client_message_id: "0015", creator: users(:jason)

    assert_match /og-embed--twitter-avatar/, message_presentation(message)
  end

  test "unfurled tweet with a content image is not styled as an avatar" do
    body = %(<div>https://twitter.com/dhh/status/1748445489648050505<action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" url="https://pbs.twimg.com/media/GEO5l04bsAA9f6H.jpg" href="https://twitter.com/dhh/status/1748445489648050505" filename="DHH (@dhh)" caption="We pay homage to the glorious MIT License!"></action-text-attachment></div>)
    message = Message.create! room: rooms(:pets), body: body, client_message_id: "0015", creator: users(:jason)

    assert_no_match /og-embed--twitter-avatar/, message_presentation(message)
  end

  test "entire message contains an unfurled URL from x.com but unfurls to twitter.com" do
    text = "https://x.com/dhh/status/1752476663303323939"
    message = Message.create! room: rooms(:pets), body: unfurled_message_body_for_twitter(text), client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_not_equal message.body.body.to_html, filtered.to_html
    assert_match /<div><action-text-attachment/, filtered.to_html
  end

  test "entire message contains an unfurled URL from x.com with query params" do
    text = "https://x.com/dhh/status/1752476663303323939?s=20"
    message = Message.create! room: rooms(:pets), body: unfurled_message_body_for_twitter(text), client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_not_equal message.body.body.to_html, filtered.to_html
    assert_match /<div><action-text-attachment/, filtered.to_html
  end

  test "message keeps strikethrough, underline and code block formatting" do
    body = %(<p>Hello <s>struck</s> <u>under</u> <mark>marked</mark></p><pre data-language="ruby">def x<br>end</pre>)
    message = Message.create! room: rooms(:pets), body: body, client_message_id: "0016", creator: users(:jason)

    html = message_presentation(message)
    assert_match %r{<s>struck</s>}, html
    assert_match %r{<u>under</u>}, html
    assert_match %r{<mark>marked</mark>}, html
    assert_match %r{<pre data-language="ruby">}, html
  end

  test "message contains a forbidden tag" do
    exploit_image_tag = 'Hello <img src="https://ssecurityrise.com/tests/billionlaughs-cache.svg">World'
    message = Message.create! room: rooms(:pets), body: exploit_image_tag, client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_equal "Hello World", filtered.to_html
  end

  test "message with a link using an unsafe URI scheme" do
    message = Message.create! room: rooms(:pets), body: '<div><a href="javascript:alert(1)">x</a></div>', client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_no_match /javascript:/, filtered.to_html
    assert_match /<a>x<\/a>/, filtered.to_html
  end

  test "message with an event handler attribute on an allowed tag" do
    message = Message.create! room: rooms(:pets), body: '<div><a href="/x" onmouseover="alert(1)">x</a> <span onclick="alert(2)">y</span></div>', client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_no_match /onmouseover/, filtered.to_html
    assert_no_match /onclick/, filtered.to_html
    assert_match /<a href="\/x">x<\/a>/, filtered.to_html
    assert_match /<span>y<\/span>/, filtered.to_html
  end

  test "message with a data URI link" do
    message = Message.create! room: rooms(:pets), body: '<div><a href="data:text/html,pwned">x</a></div>', client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_no_match /data:/, filtered.to_html
    assert_match /<a>x<\/a>/, filtered.to_html
  end

  test "message with a safe link and formatting is preserved" do
    body = '<div><a href="https://example.com">example</a> <strong>bold</strong> <code>code</code><ul><li>one</li><li>two</li></ul></div>'
    message = Message.create! room: rooms(:pets), body: body, client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_match /<a href="https:\/\/example\.com">example<\/a>/, filtered.to_html
    assert_match /<strong>bold<\/strong>/, filtered.to_html
    assert_match /<code>code<\/code>/, filtered.to_html
    assert_match /<ul>\s*<li>one<\/li>\s*<li>two<\/li>\s*<\/ul>/, filtered.to_html
  end

  test "SanitizeAttributes uses an isolated sanitizer rather than the shared ActionText instance" do
    filter = ContentFilters::SanitizeAttributes.new(ActionText::Content.new("<div>x</div>"))

    isolated = filter.send(:sanitizer)
    assert_not_same ActionText::ContentHelper.sanitizer, isolated,
      "must not reuse the process-wide ActionText sanitizer, whose permit scrubber is mutated per call"
    assert_not_same isolated, filter.send(:sanitizer),
      "each call must build a fresh sanitizer so concurrent requests never share scrubber state"
    assert_kind_of ActionText::ContentHelper.sanitizer.class, isolated
  end

  test "SanitizeAttributes neutralizes unsafe input and preserves benign content on its isolated sanitizer" do
    body = <<~HTML.squish
      <div><a href="javascript:alert(1)" onclick="x()">link</a>
      <a href="data:text/html,pwned">data</a>
      <span class="cf-twitter-avatar" onmouseover="y()">avatar</span>
      <img src="https://evil.example/x.svg"> Hey #{mention_attachment_for(:david)}</div>
    HTML
    message = Message.create! room: rooms(:pets), body: body, client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::SanitizeAttributes.apply(message.body.body).to_html

    assert_no_match /javascript:/, filtered
    assert_no_match /data:text\/html/, filtered
    assert_no_match /onclick/, filtered
    assert_no_match /onmouseover/, filtered
    assert_no_match /evil\.example/, filtered
    assert_match /<span class="cf-twitter-avatar">avatar<\/span>/, filtered
    assert_match />link</, filtered
    assert_match /<action-text-attachment sgid="#{users(:david).attachable_sgid}"/, filtered
  end

  test "message with a table keeps the table" do
    body = "<figure class=\"lexxy-content__table-wrapper\"><table><tbody><tr><th><p>Name</p></th></tr><tr><td><p>Jason</p></td></tr></tbody></table></figure>"
    message = Message.create! room: rooms(:pets), body: body, client_message_id: "0016", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body).to_html

    assert_equal body, filtered
    assert_match %r{<table>.*<th><p>Name</p></th>.*<td><p>Jason</p></td>}m, message_presentation(message)
  end

  test "message with a mention attachment" do
    message = Message.create! room: rooms(:pets), body: "<div>Hey #{mention_attachment_for(:david)}</div>", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    expected = /<action-text-attachment sgid="#{users(:david).attachable_sgid}" content-type="application\/vnd\.campfire\.mention" content="(.*?)"><\/action-text-attachment>/m

    assert_match expected, filtered.to_html
  end

  private
    def unfurled_message_body_for_basecamp(text)
      "<div>#{text}#{unfurled_link_trix_attachment_for_basecamp}</div>"
    end

    def unfurled_link_trix_attachment_for_basecamp
      <<~BASECAMP
      <action-text-attachment content-type=\"application/vnd.actiontext.opengraph-embed\" url=\"https://basecamp.com/assets/general/opengraph.png\" href=\"https://basecamp.com/\" filename=\"Project management software, online collaboration\" caption=\"Trusted by millions, Basecamp puts everything you need to get work done in one place. It’s the calm, organized way to manage projects, work with clients, and communicate company-wide.\" content=\"<actiontext-opengraph-embed>\n      <div class=&quot;og-embed&quot;>\n        <div class=&quot;og-embed__content&quot;>\n          <div class=&quot;og-embed__title&quot;>Project management software, online collaboration</div>\n          <div class=&quot;og-embed__description&quot;>Trusted by millions, Basecamp puts everything you need to get work done in one place. It’s the calm, organized way to manage projects, work with clients, and communicate company-wide.</div>\n        </div>\n        <div class=&quot;og-embed__image&quot;>\n          <img src=&quot;https://basecamp.com/assets/general/opengraph.png&quot; class=&quot;image&quot; alt=&quot;&quot; />\n        </div>\n      </div>\n    </actiontext-opengraph-embed>\"></action-text-attachment>
      BASECAMP
    end

    def unfurled_message_body_for_twitter(text)
      "<div>#{text}#{unfurled_link_trix_attachment_for_twitter}</div>"
    end

    def unfurled_link_trix_attachment_for_twitter
      <<~TWEET
      <action-text-attachment content-type=\"application/vnd.actiontext.opengraph-embed\" url=\"https://pbs.twimg.com/ext_tw_video_thumb/1752476502791503873/pu/img/WEAqUgarUxWjPNHD.jpg\" href=\"https://twitter.com/dhh/status/1752476663303323939\" filename=\"DHH (@dhh)\" caption=\"We're playing with adding easy extension points to ONCE/Campfire. Here's one experiment for allowing any type of CSS to be easily added.\" content=\"&lt;actiontext-opengraph-embed&gt;\n      &lt;div class=&quot;og-embed&quot;&gt;\n        &lt;div class=&quot;og-embed__content&quot;&gt;\n          &lt;div class=&quot;og-embed__title&quot;&gt;DHH (@dhh)&lt;/div&gt;\n          &lt;div class=&quot;og-embed__description&quot;&gt;We're playing with adding easy extension points to ONCE/Campfire. Here's one experiment for allowing any type of CSS to be easily added.&lt;/div&gt;\n        &lt;/div&gt;\n        &lt;div class=&quot;og-embed__image&quot;&gt;\n          &lt;img src=&quot;https://pbs.twimg.com/ext_tw_video_thumb/1752476502791503873/pu/img/WEAqUgarUxWjPNHD.jpg&quot; class=&quot;image&quot; alt=&quot;&quot; /&gt;\n        &lt;/div&gt;\n      &lt;/div&gt;\n    &lt;/actiontext-opengraph-embed&gt;\"><figure class=\"attachment attachment--content attachment--og\">\n  \n    <div class=\"og-embed gap\">\n      <div class=\"og-embed__content\">\n        <div class=\"og-embed__title\">\n          <a href=\"https://twitter.com/dhh/status/1752476663303323939\">DHH (@dhh)</a>\n        </div>\n        <div class=\"og-embed__description\">We're playing with adding easy extension points to ONCE/Campfire. Here's one experiment for allowing any type of CSS to be easily added.</div>\n      </div>\n        <div class=\"og-embed__image\">\n          <img src=\"https://pbs.twimg.com/ext_tw_video_thumb/1752476502791503873/pu/img/WEAqUgarUxWjPNHD.jpg\" class=\"image center\" alt=\"\">\n        </div>\n    </div>\n  \n</figure></action-text-attachment>
      TWEET
    end
end
