class ContentFilters::StyleUnfurledTwitterAvatars < ActionText::Content::Filter
  def applicable?
    unfurled_twitter_avatars.present?
  end

  def apply
    fragment.update do |source|
      div = source.at_css("div")
      div["class"] = UNFURLED_TWITTER_AVATAR_CSS_CLASS
    end
  end

  private
    UNFURLED_TWITTER_AVATAR_CSS_CLASS = "cf-twitter-avatar"
    TWITTER_AVATAR_URL_PREFIX = "https://pbs.twimg.com/profile_images"

    def unfurled_twitter_avatars
      fragment.find_all(opengraph_css_selector).select do |node|
        ActionText::Attachment::OpengraphEmbed.from_node(node)&.url.to_s.start_with?(TWITTER_AVATAR_URL_PREFIX)
      end
    end

    def opengraph_css_selector
      "action-text-attachment[@content-type='#{ActionText::Attachment::OpengraphEmbed::OPENGRAPH_EMBED_CONTENT_TYPE}']"
    end
end
