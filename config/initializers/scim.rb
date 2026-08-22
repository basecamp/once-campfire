require "scim"

Scim.configuration = Scim::Configuration.new

Mime::Type.register Scim::MEDIA_TYPE, :scim
ActionDispatch::Request.parameter_parsers = ActionDispatch::Request.parameter_parsers.merge(
  scim: ->(body) { ActiveSupport::JSON.decode(body) }
)
