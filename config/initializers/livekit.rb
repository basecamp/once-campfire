Rails.application.configure do
  config.x.livekit.url = ENV.fetch("LIVEKIT_URL") { "" }
  config.x.livekit.api_key = ENV.fetch("LIVEKIT_API_KEY") { "" }
  config.x.livekit.api_secret = ENV.fetch("LIVEKIT_API_SECRET") { "" }
end


