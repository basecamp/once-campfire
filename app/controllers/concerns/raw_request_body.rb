module RawRequestBody
  extend ActiveSupport::Concern

  private

  def raw_request_body(maximum:, description:)
    request.body.rewind
    ContentLimits.verify!(request.content_length.to_i, maximum:, description:)
    ContentLimits.read(request.body, maximum:, description:).force_encoding("UTF-8")
  ensure
    request.body.rewind
  end
end
