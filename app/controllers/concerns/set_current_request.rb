module SetCurrentRequest
  extend ActiveSupport::Concern

  included do
    before_action do
      Current.request = request
    end
  end

  def default_url_options
    { host: Current.request_host, port: Current.request&.optional_port, protocol: Current.request_protocol }.compact_blank
  end
end
