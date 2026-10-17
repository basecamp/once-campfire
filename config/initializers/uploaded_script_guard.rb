# Uploaded files are served from this origin. Application pages only allow
# scripts from the asset directory (InlineScriptHashes), so an upload can't
# load as a script whatever type it's served with. This guard is the second
# layer: browsers accept sixteen spellings of a JavaScript type, and Disk URLs
# sign the type they were minted with, so instead of refusing a list of types,
# anything Active Storage serves that isn't plainly media goes out as a
# download, whatever its URL says. A multi-range response keeps its
# multipart/byteranges type and boundary, which no browser runs as a script.
# Only reads are touched: uploading (direct upload JSON, Disk PUT) answers in
# its own types.
#
# A cache that stored an upload under a script type before this shipped can
# still serve it that way until the entry expires (an hour for Disk URLs, and
# never for blob proxy URLs, which Rails caches as immutable). The policy's
# path restriction is what keeps such a copy from running.
class UploadedScriptGuard
  SERVABLE = %r{\A(image|video|audio)/|\A(application/pdf|application/octet-stream|text/plain|multipart/byteranges)\z}

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)

    if env["REQUEST_METHOD"].in?(%w[ GET HEAD ]) && env["PATH_INFO"].start_with?("#{ActiveStorage.routes_prefix}/") && (type = headers["content-type"])
      headers["content-type"] = ActiveStorage.binary_content_type unless type.split(";").first.strip.downcase.match?(SERVABLE)
    end

    [ status, headers, body ]
  end
end

Rails.application.config.middleware.use UploadedScriptGuard
