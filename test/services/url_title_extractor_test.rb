require "test_helper"

class UrlTitleExtractorTest < ActiveSupport::TestCase
  test "returns nil for invalid URL" do
    title = UrlTitleExtractor.extract_title("not-a-url")
    assert_nil title
  end

  test "returns nil for empty URL" do
    title = UrlTitleExtractor.extract_title("")
    assert_nil title
  end

  test "returns nil for nil URL" do
    title = UrlTitleExtractor.extract_title(nil)
    assert_nil title
  end

  test "returns nil for URL with @ symbol" do
    title = UrlTitleExtractor.extract_title("@https://example.com")
    assert_nil title
  end

  test "returns nil for non-HTTP URL" do
    title = UrlTitleExtractor.extract_title("ftp://example.com")
    assert_nil title
  end

  test "returns nil for malformed URL" do
    title = UrlTitleExtractor.extract_title("https://")
    assert_nil title
  end
end