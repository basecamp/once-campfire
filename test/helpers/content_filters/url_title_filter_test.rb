require "test_helper"

class ContentFilters::UrlTitleFilterTest < ActiveSupport::TestCase
  test "is applicable when content contains URLs" do
    content = ActionText::Content.new("Check out https://example.com")
    filter = ContentFilters::UrlTitleFilter.new(content)
    
    assert filter.applicable?
  end

  test "is not applicable when content contains no URLs" do
    content = ActionText::Content.new("Just plain text")
    filter = ContentFilters::UrlTitleFilter.new(content)
    
    assert_not filter.applicable?
  end

  test "is not applicable when content contains @ URLs" do
    content = ActionText::Content.new("Check out @https://example.com")
    filter = ContentFilters::UrlTitleFilter.new(content)
    
    assert_not filter.applicable?
  end

  test "contains_urls? returns true for valid URLs" do
    filter = ContentFilters::UrlTitleFilter.new(ActionText::Content.new(""))
    
    assert filter.send(:contains_urls?, "https://example.com")
    assert filter.send(:contains_urls?, "http://example.com")
    assert filter.send(:contains_urls?, "Check out https://example.com")
  end

  test "contains_urls? returns false for invalid URLs" do
    filter = ContentFilters::UrlTitleFilter.new(ActionText::Content.new(""))
    
    assert_not filter.send(:contains_urls?, "just text")
    assert_not filter.send(:contains_urls?, "@https://example.com")
    assert_not filter.send(:contains_urls?, "ftp://example.com")
  end

  test "replace_urls_with_titles creates clickable links" do
    filter = ContentFilters::UrlTitleFilter.new(ActionText::Content.new(""))
    
    # Mock the title extractor
    UrlTitleExtractor.stubs(:extract_title).with("https://example.com").returns("Example Domain")
    
    result = filter.send(:replace_urls_with_titles, "Check out https://example.com")
    expected = 'Check out <a href="https://example.com" target="_blank">Example Domain</a>'
    
    assert_equal expected, result
  end

  test "replace_urls_with_titles preserves original URL when title extraction fails" do
    filter = ContentFilters::UrlTitleFilter.new(ActionText::Content.new(""))
    
    # Mock the title extractor to return nil
    UrlTitleExtractor.stubs(:extract_title).with("https://example.com").returns(nil)
    
    result = filter.send(:replace_urls_with_titles, "Check out https://example.com")
    expected = "Check out https://example.com"
    
    assert_equal expected, result
  end

  test "replace_urls_with_titles handles multiple URLs" do
    filter = ContentFilters::UrlTitleFilter.new(ActionText::Content.new(""))
    
    # Mock the title extractor
    UrlTitleExtractor.stubs(:extract_title).with("https://example.com").returns("Example Domain")
    UrlTitleExtractor.stubs(:extract_title).with("https://github.com").returns("GitHub")
    
    result = filter.send(:replace_urls_with_titles, "Check out https://example.com and https://github.com")
    expected = 'Check out <a href="https://example.com" target="_blank">Example Domain</a> and <a href="https://github.com" target="_blank">GitHub</a>'
    
    assert_equal expected, result
  end
end
