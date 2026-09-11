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

      # A link preview points at what we unfurled, which is always an absolute
      # http or https URL. Drop anything else the message body asks for, so a
      # body written by hand can't aim the preview's link or its image at another
      # scheme or at a path on this Campfire.
      def web_url(value)
        value if value.present? && URI.parse(value).is_a?(URI::HTTP)
      rescue URI::InvalidURIError
        nil
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
