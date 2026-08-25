class UnfurlLinksController < ApplicationController
  def create
    # Check if unfurling is enabled via environment variable
    unless ENV["ENABLE_URL_UNFURLING"] == "true"
      Rails.logger.info "URL unfurling is disabled via ENABLE_URL_UNFURLING environment variable"
      head :no_content
      return
    end

    url = url_param
    Rails.logger.info "Unfurl request for URL: #{url}"

    begin
      opengraph = Opengraph::Metadata.from_url(url)

      if opengraph.valid?
        Rails.logger.info "Successfully unfurled #{url}: #{opengraph.title}"
        render json: opengraph
      else
        Rails.logger.warn "Failed to unfurl #{url}: #{opengraph.errors.full_messages.join(', ')}"
        head :no_content
      end
    rescue => e
      Rails.logger.error "Error unfurling #{url}: #{e.message}"
      head :no_content
    end
  end

  private
    def url_param
      params.require(:url)
    end
end
