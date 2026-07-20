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
      # Trix serialized the embed's details as attributes of the
      # <action-text-attachment> node. Lexxy only serializes the sgid, content
      # and content-type, so newer attachments carry the details in their
      # content markup instead.
      def attributes_from_node(node)
        if node["href"].present?
          {
            href: node["href"],
            url: node["url"],
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
          href: link&.[]("href"),
          url: fragment.at_css(".og-embed__image img")&.[]("src"),
          filename: (link || title)&.text&.strip,
          description: fragment.at_css(".og-embed__description")&.text&.strip
        }
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
end
