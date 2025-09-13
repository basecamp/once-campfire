require 'cgi'
require 'net/http'
require 'uri'

# Service for extracting page titles from URLs
# Used by the UrlTitleFilter to replace URLs with their titles in chat messages
class UrlTitleExtractor
  # Extract the title from a given URL
  # @param url [String] The URL to extract the title from
  # @return [String, nil] The extracted title or nil if extraction fails
  def self.extract_title(url)
    return nil unless url.present?
    return nil unless url.match?(/\Ahttps?:\/\/.+/)
    
    begin
      response = fetch_page(url)
      return nil unless response&.is_a?(Net::HTTPSuccess)
      
      title = extract_title_from_html(response.body)
      return nil if title.blank?
      
      clean_title_text(title)
    rescue => e
      Rails.logger.warn "Failed to extract title from #{url}: #{e.message}"
      nil
    end
  end

  private

  # Fetch the webpage content
  # @param url [String] The URL to fetch
  # @return [Net::HTTPResponse, nil] The HTTP response or nil if failed
  def self.fetch_page(url)
    uri = URI.parse(url)
    
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 5) do |http|
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = 'Mozilla/5.0 (compatible; Campfire/1.0)'
      http.request(request)
    end
  rescue => e
    Rails.logger.warn "Failed to fetch #{url}: #{e.message}"
    nil
  end

  # Extract title from HTML content using multiple strategies
  # @param html [String] The HTML content
  # @return [String, nil] The extracted title or nil if not found
  def self.extract_title_from_html(html)
    extract_from_meta_tag(html, 'og:title') ||
      extract_from_meta_tag(html, 'twitter:title') ||
      extract_from_title_tag(html) ||
      extract_from_h1_tag(html)
  end

  # Extract title from OpenGraph or Twitter meta tags
  # @param html [String] The HTML content
  # @param property [String] The meta property name (e.g., 'og:title')
  # @return [String, nil] The meta content or nil if not found
  def self.extract_from_meta_tag(html, property)
    match = html.match(/<meta[^>]+(?:property|name)=["']#{Regexp.escape(property)}["'][^>]+content=["']([^"']+)["'][^>]*>/i)
    match ? match[1] : nil
  end

  # Extract title from HTML title tag
  # @param html [String] The HTML content
  # @return [String, nil] The title content or nil if not found
  def self.extract_from_title_tag(html)
    match = html.match(/<title[^>]*>([^<]+)<\/title>/i)
    match ? match[1] : nil
  end

  # Extract title from HTML h1 tag as fallback
  # @param html [String] The HTML content
  # @return [String, nil] The h1 content or nil if not found
  def self.extract_from_h1_tag(html)
    match = html.match(/<h1[^>]*>([^<]+)<\/h1>/i)
    match ? match[1] : nil
  end

  # Clean and format the extracted title
  # @param title [String] The raw title text
  # @return [String] The cleaned title
  def self.clean_title_text(title)
    title = CGI.unescapeHTML(title)
    title = title.strip
    title.length > 100 ? "#{title[0..96]}..." : title
  end
end