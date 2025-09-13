# Content filter that replaces URLs with their page titles as clickable links
# This filter processes message content to make URLs more readable while keeping them functional
class ContentFilters::UrlTitleFilter < ActionText::Content::Filter
  # Check if the content contains any URLs that should be processed
  # @return [Boolean] True if the content contains URLs
  def applicable?
    contains_urls?(content.to_plain_text)
  end

  # Apply the URL title replacement to the content
  # Replaces URLs with clickable links containing the page title
  def apply
    plain_text = content.to_plain_text
    processed_text = replace_urls_with_titles(plain_text)
    
    fragment.update do |source|
      source.inner_html = processed_text
    end
  end

  private

  # Check if the text contains any HTTP/HTTPS URLs
  # @param text [String] The text to check
  # @return [Boolean] True if URLs are found
  def contains_urls?(text)
    text.match?(/(?:^|\s)(https?:\/\/[^\s]+)/)
  end

  # Replace URLs in text with clickable links containing page titles
  # @param text [String] The text containing URLs
  # @return [String] The text with URLs replaced by title links
  def replace_urls_with_titles(text)
    text.gsub(/(^|\s)(https?:\/\/[^\s]+)/) do |match|
      space = $1 # space or start of line
      url = $2   # the actual URL
      
      title = UrlTitleExtractor.extract_title(url)
      
      if title
        # Replace URL with clickable link containing the title
        "#{space}<a href=\"#{url}\" target=\"_blank\">#{title}</a>"
      else
        # Keep original URL if title extraction failed
        match
      end
    end
  end
end