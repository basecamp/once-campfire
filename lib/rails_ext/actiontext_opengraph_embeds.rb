class ActionText::Attachment::OpengraphEmbed
  include ActiveModel::Model

  OPENGRAPH_EMBED_CONTENT_TYPE = "application/vnd.actiontext.opengraph-embed"
  TWITTER_AVATAR_URL_PREFIX = "https://pbs.twimg.com/profile_images"

  class << self
    def from_node(node)
      if node["content-type"]
        if matches = node["content-type"].match(OPENGRAPH_EMBED_CONTENT_TYPE)
          attachment = new(attributes_from_node(node))
          attachment if attachment.valid?
        end
      end
    end

    private
      # Trix serialized the embed's details as attributes of the
      # <action-text-attachment> node. Lexxy only serializes the sgid, content
      # and content-type, so newer attachments carry the details in their
      # content markup instead.
      def attributes_from_node(node)
        if node["href"].present?
          {
            href: web_url(node["href"]),
            url: web_url(node["url"]),
            filename: node["filename"],
            description: node["caption"]
          }
        else
          attributes_from_content(node["content"].to_s)
        end
      end

      def attributes_from_content(content)
        fragment = Nokogiri::HTML.fragment(content)
        title = fragment.at_css(".og-embed__title")
        link = title&.at_css("a")

        {
          href: web_url(link&.[]("href")),
          url: web_url(fragment.at_css(".og-embed__image img")&.[]("src")),
          filename: (link || title)&.text&.strip,
          description: fragment.at_css(".og-embed__description")&.text&.strip
        }
      end

      # A link preview points at what we unfurled: an absolute http or https URL
      # on some other host. Drop anything else a message body asks for, so it
      # can't aim the preview's link or its image at this Campfire and have every
      # reader's browser fetch it with their session attached.
      def web_url(value)
        return if value.blank?

        parsed = URI.parse(value)
        value if parsed.is_a?(URI::HTTP) && elsewhere?(parsed.host)
      rescue URI::InvalidURIError
        nil
      end

      # "https:/rooms/1" parses as HTTPS with no host at all, and a browser
      # resolves both that and our own hostname against the origin Campfire is
      # served from. A percent-escape hides our hostname from this comparison
      # while a browser still unescapes it back to us, so an escaped host is out
      # too, and neither case is anything an unfurl could have produced.
      def elsewhere?(host)
        return false unless named_host?(host)

        canonical_host(host) != canonical_host(Current.request_host.to_s)
      end

      # A preview names a page on the public internet, so its host is a domain
      # name, written plainly. A bare address is not one, and a browser rewrites
      # the many spellings of an address ("2130706433", "0x7f.0.0.1") into a
      # single one before it fetches, which is a race a comparison here loses.
      def named_host?(host)
        host.present? && host.exclude?("%") && host.include?(".") && domain_ending?(host.split(".").last)
      end

      # What keeps a name from reading as an address is its last label, which is
      # a word: never a number, and never the hexadecimal spelling of one.
      def domain_ending?(label)
        label.match?(/[a-z]/i) && !label.match?(/\A0x/i)
      end

      def canonical_host(host)
        host.downcase.delete_suffix(".")
      end
  end

  attr_accessor :href, :url, :filename, :description

  def twitter_avatar?
    url.to_s.start_with?(TWITTER_AVATAR_URL_PREFIX)
  end

  def attachable_content_type
    OPENGRAPH_EMBED_CONTENT_TYPE
  end

  def attachable_plain_text_representation(caption)
    ""
  end

  def to_partial_path
    "action_text/attachables/opengraph_embed"
  end
end
