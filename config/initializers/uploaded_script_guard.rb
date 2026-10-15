# Uploaded files are served from this origin, so under script-src 'self' an
# upload served with any JavaScript MIME type would run as one of our scripts.
# Browsers accept sixteen spellings of that type, and Disk URLs sign the type
# they were minted with, so a list of types to refuse can't cover old links.
# Instead, anything Active Storage serves that isn't plainly media goes out as
# a download, whatever its URL says. Only reads are touched: uploading
# (direct upload JSON, Disk PUT) answers in its own types.
#
# Accepted on upgrade: a browser that cached an upload under a script type
# before this guard shipped can still run it from that cache until the entry
# expires, up to an hour after it was fetched (config/initializers/active_storage.rb).
# Revalidation doesn't help, since a 304 carries no content type.
class UploadedScriptGuard
  SERVABLE = %r{\A(image|video|audio)/|\A(application/pdf|application/octet-stream|text/plain)\z}

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
