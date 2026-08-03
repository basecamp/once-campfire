require "test_helper"

class QrCodeHelperTest < ActionView::TestCase
  test "renders private QR codes without a credential-bearing request URL" do
    html = link_to_zoom_qr_code("https://example.com/join#token=private") { "Show QR code" }
    link = Nokogiri::HTML5.fragment(html).at_css("a")

    assert link["href"].start_with?("data:image/svg+xml;base64,")
    assert_equal link["href"], link["data-lightbox-url-value"]
    assert_includes Base64.strict_decode64(link["href"].split(",", 2).last), "<svg"
    assert_not_includes link["href"], "/qr_code/"
  end
end
