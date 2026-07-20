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
