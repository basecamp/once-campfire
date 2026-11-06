module RawRequestBody
  extend ActiveSupport::Concern

  private

  # The body is read as text, so it has to be UTF-8 like any parameter. Rails answers 400 to a form or JSON body that
  # isn't, and this answers the same for a type it doesn't parse, text/plain among them, instead of failing with 500.
  def raw_request_body
    request.body.rewind
    request.body.read.force_encoding("UTF-8").tap do |body|
      raise ActionController::BadRequest, "Request body isn't valid UTF-8" unless body.valid_encoding?
    end
  ensure
    request.body.rewind
  end
end
