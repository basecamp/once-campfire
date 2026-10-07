class UnfurlLinksController < ApplicationController
  # The pasted link decides which hosts an unfurl looks up and fetches from, and how quickly they answer.
  DEADLINE = 10.seconds

  def create
    if opengraph = unfurl(url_param)
      render json: opengraph
    else
      head :no_content
    end
  end

  private
    def url_param
      params.require(:url)
    end

    # One deadline for everything the link leads to: DNS lookups, redirects, the page, the image check.
    def unfurl(url)
      Timeout.timeout(DEADLINE) do
        Opengraph::Metadata.from_url(url).then { |opengraph| opengraph if opengraph.valid? }
      end
    rescue Timeout::Error
      Rails.logger.warn "Gave up unfurling #{url} after #{DEADLINE.inspect}"
      nil
    end
end
