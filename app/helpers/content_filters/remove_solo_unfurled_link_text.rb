class ContentFilters::RemoveSoloUnfurledLinkText < ActionText::Content::Filter
  def applicable?
    normalize_tweet_url(solo_unfurled_url) == normalize_tweet_url(content.to_plain_text)
  end

  def apply
    if fragment.find_all("div").any?
      # Trix-era bodies: one <div> wrapping the link text and the embed
      fragment.replace("div") { |node| node.tap { |n| n.inner_html = unfurled_links.first.to_s } }
    else
      # Lexxy bodies: the link sits in its own <p>, the embed follows it
      fragment.replace("p") { |node| node.at_css("action-text-attachment") ? node : nil }
    end
  end

  private
    TWITTER_DOMAINS = %w[ x.com twitter.com ]
    TWITTER_DOMAIN_MAPPING = { "x.com" => "twitter.com" }

    def solo_unfurled_url
      ActionText::Attachment::OpengraphEmbed.from_node(unfurled_links.first)&.href if unfurled_links.size == 1
    end

    def unfurled_links
      fragment.find_all("action-text-attachment[@content-type='#{ActionText::Attachment::OpengraphEmbed::OPENGRAPH_EMBED_CONTENT_TYPE}']")
    end

    def normalize_tweet_url(url)
      return url unless twitter_url?(url)

      uri = URI.parse(url)

      uri.dup.tap do |u|
        u.host = TWITTER_DOMAIN_MAPPING[uri.host&.downcase] || uri.host
        u.query = nil
      end.to_s
    rescue URI::InvalidURIError
      url
    end

    def twitter_url?(url)
      url.present? && TWITTER_DOMAINS.any? { |domain| url.strip.include?(domain) }
    end
end
