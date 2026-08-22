module SetCurrentRequest
  extend ActiveSupport::Concern

  included do
    before_action do
      Current.request = request
    end
  end

  def default_url_options
    if Oidc.enabled?
      {
        host: Oidc.configuration.redirect_host,
        protocol: "https",
        port: Oidc.configuration.redirect_port
      }
    else
      { host: Current.request_host, protocol: Current.request_protocol }.compact_blank
    end
  end

  private
    def canonical_request_url
      if Oidc.enabled?
        "#{Oidc.configuration.canonical_origin}#{request.fullpath}"
      else
        request.url
      end
    end
end
