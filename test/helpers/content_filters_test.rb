require "test_helper"

class ContentFiltersTest < ActionView::TestCase
  test "entire message contains an unfurled URL" do
    text = "https://basecamp.com/"
    message = Message.create! room: rooms(:pets), body: unfurled_message_body_for_basecamp(text), client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_not_equal message.body.body.to_html, filtered.to_html
    assert_match /<div><action-text-attachment/, filtered.to_html
  end

  test "message includes additional text besides an unfurled URL" do
    text = "Hello https://basecamp.com/"
    message = Message.create! room: rooms(:pets), body: unfurled_message_body_for_basecamp(text), client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::TextMessagePresentationFilters.apply(message.body.body)
    assert_equal message.body.body.to_html, filtered.to_html
    assert_match %r{<div>Hello https://basecamp\.com/<action-text-attachment}, filtered.to_html
  end

  test "unfurled tweet without any image" do
    text = "<div>https://twitter.com/37signals/status/1750290547908952568<action-text-attachment content-type=\"application/vnd.actiontext.opengraph-embed\" url=\"https://pbs.twimg.com/profile_images/1671940407633010689/9P5gi6LF_200x200.jpg\" href=\"https://twitter.com/37signals/status/1750290547908952568\" filename=\"37signals (@37signals)\" caption=\"We're back up on all apps, everyone. Really sorry for the disruption to your day.\" content=\"<actiontext-opengraph-embed>\n      <div class=&quot;og-embed&quot;>\n        <div class=&quot;og-embed__content&quot;>\n          <div class=&quot;og-embed__title&quot;>37signals (@37signals)</div>\n          <div class=&quot;og-embed__description&quot;>We're back up on all apps, everyone. Really sorry for the disruption to your day.</div>\n        </div>\n        <div class=&quot;og-embed__image&quot;>\n          <img src=&quot;https://pbs.twimg.com/profile_images/1671940407633010689/9P5gi6LF_200x200.jpg&quot; class=&quot;image&quot; alt=&quot;&quot; />\n        </div>\n      </div>\n    </actiontext-opengraph-embed>\"></action-text-attachment></div>"
    message = Message.create! room: rooms(:pets), body: unfurled_message_body_for_basecamp(text), client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::StyleUnfurledTwitterAvatars.apply(message.body.body)
    assert_match %r{<div class="cf-twitter-avatar">}, filtered.to_html
  end

  test "unfurled tweet containing an image" do
    text = "<div>https://twitter.com/dhh/status/1748445489648050505<action-text-attachment content-type=\"application/vnd.actiontext.opengraph-embed\" url=\"https://pbs.twimg.com/media/GEO5l04bsAA9f6H.jpg\" href=\"https://twitter.com/dhh/status/1748445489648050505\" filename=\"DHH (@dhh)\" caption=\"We pay homage to the glorious MIT License with the ONCE license. May all our future legalese be as succinct!\" content=\"<actiontext-opengraph-embed>\n      <div class=&quot;og-embed&quot;>\n        <div class=&quot;og-embed__content&quot;>\n          <div class=&quot;og-embed__title&quot;>DHH (@dhh)</div>\n          <div class=&quot;og-embed__description&quot;>We pay homage to the glorious MIT License with the ONCE license. May all our future legalese be as succinct!</div>\n        </div>\n        <div class=&quot;og-embed__image&quot;>\n          <img src=&quot;https://pbs.twimg.com/media/GEO5l04bsAA9f6H.jpg&quot; class=&quot;image&quot; alt=&quot;&quot; />\n        </div>\n      </div>\n    </actiontext-opengraph-embed>\"></action-text-attachment></div>"
    message = Message.create! room: rooms(:pets), body: unfurled_message_body_for_basecamp(text), client_message_id: "0015", creator: users(:jason)

    filtered = ContentFilters::StyleUnfurledTwitterAvatars.apply(message.body.body)
    assert_no_match %r{<div class="cf-twitter-avatar">}, filtered.to_html
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
