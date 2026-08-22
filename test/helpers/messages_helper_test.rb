require "test_helper"

class MessagesHelperTest < ActionView::TestCase
  test "message_presentation neutralizes unsafe URI schemes in links" do
    message = Message.create! room: rooms(:pets), body: '<div><a href="javascript:alert(1)">x</a></div>', client_message_id: "0015", creator: users(:jason)

    presentation = view.message_presentation(message)
    assert_no_match /javascript:/, presentation
    assert_match /<a>x<\/a>/, presentation
  end

  test "message_presentation strips event handler attributes from allowed tags" do
    message = Message.create! room: rooms(:pets), body: '<div><a href="/x" onmouseover="alert(1)">x</a></div>', client_message_id: "0015", creator: users(:jason)

    presentation = view.message_presentation(message)
    assert_no_match /onmouseover/, presentation
    assert_match /<a href="\/x">x<\/a>/, presentation
  end

  test "message_presentation preserves safe links and formatting" do
    message = Message.create! room: rooms(:pets), body: '<div><a href="https://example.com">example</a> <strong>bold</strong></div>', client_message_id: "0015", creator: users(:jason)

    presentation = view.message_presentation(message)
    assert_match /<a href="https:\/\/example\.com"[^>]*>example<\/a>/, presentation
    assert_match /<strong>bold<\/strong>/, presentation
  end

  test "renders bot action icons on either side of the label" do
    left = Nokogiri::HTML.fragment(bot_action_content("label" => "Open", "icon" => "camera"))
    right = Nokogiri::HTML.fragment(bot_action_content("label" => "Open", "icon" => "camera", "icon_position" => "right"))

    assert_equal %w[ img span ], left.children.map(&:name)
    assert_equal %w[ span img ], right.children.map(&:name)
  end

  test "renders emoji on either side of the label" do
    left = Nokogiri::HTML.fragment(bot_action_content("label" => "Open", "emoji" => "📷"))
    right = Nokogiri::HTML.fragment(bot_action_content("label" => "Open", "emoji" => "📷", "icon_position" => "right"))

    assert_equal [ "📷", "Open" ], left.children.map(&:text)
    assert_equal [ "Open", "📷" ], right.children.map(&:text)
  end

  test "visually hides the accessible label for icon only actions" do
    content = Nokogiri::HTML.fragment(bot_action_content("label" => "Open camera", "icon" => "camera", "icon_only" => true))

    assert_equal "Open camera", content.at_css(".for-screen-reader").text
  end

  test "renders an icon only action with an automatic contrasting icon" do
    content = Nokogiri::HTML.fragment(bot_action_content(
      "label" => "Open camera", "icon" => "camera", "icon_only" => true, "background_color" => "#bbf7d0"
    ))

    assert_includes content.at_css("img")["class"], "colorize--black"
  end

  test "custom button colors choose a readable foreground by default" do
    assert_includes bot_action_style("background_color" => "#111827"), "--btn-color: white"
    assert_includes bot_action_style("background_color" => "#fbbf24"), "--btn-color: black"
    assert_includes bot_action_style("background_color" => "#ff0000"), "--btn-color: black"
  end

  test "custom button colors accept a foreground override" do
    style = bot_action_style("background_color" => "#111827", "text_color" => "#fef08a")

    assert_includes style, "--btn-color: #fef08a"
  end
end
