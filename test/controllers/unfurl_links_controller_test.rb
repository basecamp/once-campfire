require "test_helper"

class UnfurlLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    Resolv.stubs(:getaddresses).with("www.example.com").returns([ "93.184.216.34" ])
    Resolv.stubs(:getaddresses).with("example.com").returns([ "93.184.216.34" ])
    Resolv.stubs(:getaddresses).with("fxtwitter.com").returns([ "93.184.216.34" ])
  end

  test "create" do
    stub_successful_request

    post unfurl_link_url, params: { url: "https://www.example.com" }
    assert_response :success

    json_response = JSON.parse(response.body)
    assert_equal "Hey!", json_response["title"]
    assert_equal "https://example.com", json_response["url"]
    assert_equal "https://example.com/image.png", json_response["image"]
    assert_equal "desc..", json_response["description"]
  end

  test "create with missing opengraph meta tags" do
    WebMock.stub_request(:get, "https://www.example.com/").to_return(status: 200, body: "<html><head></head></html>", headers: {})

    post unfurl_link_url, params: { url: "https://www.example.com" }
    assert_response :no_content
  end

  test "create with a missing URL" do
    assert_raise ActionController::ParameterMissing do
      post unfurl_link_url, params: { url: "" }
      assert_response :bad_request
    end
  end

  test "create for twitter.com" do
    stub_successful_request url: "https://fxtwitter.com/dhh/status/834146806594433025"

    post unfurl_link_url, params: { url: "https://twitter.com/dhh/status/834146806594433025" }
    assert_response :success
    assert_equal "Hey!", JSON.parse(response.body)["title"]
  end

  test "create for x.com" do
    stub_successful_request url: "https://fxtwitter.com/dhh/status/834146806594433025"

    post unfurl_link_url, params: { url: "https://x.com/dhh/status/834146806594433025" }
    assert_response :success
    assert_equal "Hey!", JSON.parse(response.body)["title"]
  end

  private
    def stub_successful_request(url: "https://www.example.com/")
      WebMock.stub_request(:get, url).to_return(
        status: 200,
        body: "<html><head><meta property=\"og:url\" content=\"https://example.com\"><meta property=\"og:title\" content=\"Hey!\"><meta property=\"og:description\" content=\"desc..\"><meta property=\"og:image\" content=\"https://example.com/image.png\"></head></html>",
        headers: { content_type: "text/html" }
      )

      WebMock.stub_request(:head, "https://example.com/image.png").to_return(
        status: 200,
        headers: { content_type: "image/png" }
      )
    end
end
