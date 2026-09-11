class ActionText::Attachment::OpengraphEmbed
  include ActiveModel::Model

  OPENGRAPH_EMBED_CONTENT_TYPE = "application/vnd.actiontext.opengraph-embed"

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
      def attributes_from_node(node)
        {
          href: web_url(node["href"]),
          url: web_url(node["url"]),
          filename: node["filename"],
          description: node["caption"]
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
      # name: it has a dot and a letter in it, and no escapes. A bare address is
      # not one, and a browser rewrites the many spellings of an address into a
      # single one before it fetches, which is a race a comparison here loses.
      def named_host?(host)
        host.present? && host.exclude?("%") && host.include?(".") && host.match?(/[a-z]/i)
      end

      def canonical_host(host)
        host.downcase.delete_suffix(".")
      end
  end

  attr_accessor :href, :url, :filename, :description

  def attachable_content_type
    OPENGRAPH_EMBED_CONTENT_TYPE
  end

  def attachable_plain_text_representation(caption)
    ""
  end

  def to_partial_path
    "action_text/attachables/opengraph_embed"
  end

  def to_trix_content_attachment_partial_path
    "action_text/attachables/opengraph_embed"
  end
end
