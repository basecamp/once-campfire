require "restricted_http/private_network_guard"

class Opengraph::Location
  include ActiveModel::Validations

  attr_accessor :url, :parsed_url

  validate :validate_url, :validate_url_is_public

  def initialize(url)
    @url = url
  end

  def read_html
    fetch_html if http_url? && !url.to_s.match(FILES_AND_MEDIA_URL_REGEX)
  end

  def fetch_content_type
    Opengraph::Fetch.new.fetch_content_type(parsed_url) if http_url?
  rescue => e
    Rails.logger.warn "Failed to fetch #{parsed_url} (#{e})"
    nil
  end

  def resolved_ip
    public_addresses&.first
  end

  private
    FILES_AND_MEDIA_URL_REGEX = /\bhttps?:\/\/\S+\.(?:zip|tar|tar\.gz|tar\.bz2|tar\.xz|gz|bz2|rar|7z|dmg|exe|msi|pkg|deb|iso|jpg|jpeg|png|gif|bmp|mp4|mov|avi|mkv|wmv|flv|heic|heif|mp3|wav|ogg|aac|wma|webm|ogv|mpg|mpeg)\b/

    def validate_url
      errors.add :url, "is invalid" unless http_url?
    end

    def validate_url_is_public
      errors.add :url, "is not public" unless public_addresses.present?
    end

    def parsed_url
      return @parsed_url if defined? @parsed_url
      @parsed_url = URI.parse(url.to_s) rescue nil
    end

    def http_url?
      parsed_url.is_a?(URI::HTTP) && parsed_url.hostname.present?
    end

    def public_addresses
      return @public_addresses if defined? @public_addresses

      @public_addresses = Opengraph::Fetch.new.public_addresses(parsed_url.hostname) if http_url?
    rescue Opengraph::Fetch::DeniedError, Opengraph::Fetch::RequestTimeoutError, RestrictedHTTP::Violation
      @public_addresses = nil
    end

    def fetch_html
      Opengraph::Fetch.new.fetch_document(parsed_url)
    rescue => e
      Rails.logger.warn "Failed to fetch #{parsed_url} (#{e})"
      nil
    end
end
