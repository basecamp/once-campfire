require "test_helper"

class UploadedScriptGuardTest < ActiveSupport::TestCase
  # Every JavaScript MIME type essence in the MIME Sniffing Standard, plus
  # parameters and casing a signed Disk URL might carry.
  SCRIPT_TYPES = %w[
    application/ecmascript application/javascript application/x-ecmascript application/x-javascript
    text/ecmascript text/javascript text/javascript1.0 text/javascript1.1 text/javascript1.2 text/javascript1.3
    text/javascript1.4 text/javascript1.5 text/jscript text/livescript text/x-ecmascript text/x-javascript
  ] + [ "Text/JavaScript; charset=utf-8" ]

  test "uploads never leave with a script type, whatever the URL says" do
    SCRIPT_TYPES.each do |type|
      assert_equal ActiveStorage.binary_content_type, served_type(type, "#{ActiveStorage.routes_prefix}/disk/key/probe.js"), type
    end
  end

  test "media and downloads keep their type" do
    %w[ image/png video/mp4 audio/mpeg application/pdf text/plain ].each do |type|
      assert_equal type, served_type(type, "#{ActiveStorage.routes_prefix}/disk/key/file"), type
    end
  end

  test "multi-range responses keep their boundary" do
    type = "multipart/byteranges; boundary=AaB03x"
    assert_equal type, served_type(type, "#{ActiveStorage.routes_prefix}/blobs/proxy/key/movie.mp4")
  end

  test "direct upload responses keep their JSON type" do
    assert_equal "application/json", served_type("application/json", "#{ActiveStorage.routes_prefix}/direct_uploads", method: "POST")
  end

  test "application responses outside uploads are untouched" do
    assert_equal "text/javascript", served_type("text/javascript", "/assets/application-abc123.js")
  end

  private
    def served_type(type, path, method: "GET")
      app = ->(env) { [ 200, { "content-type" => type }, [ "" ] ] }
      UploadedScriptGuard.new(app).call(Rack::MockRequest.env_for(path, method: method))[1]["content-type"]
    end
end
