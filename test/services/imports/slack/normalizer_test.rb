require "test_helper"

class Imports::Slack::NormalizerTest < ActiveSupport::TestCase
  test "slack_timestamp_to_time converts slack timestamp" do
    timestamp = "1699123456.123456"
    expected_time = Time.at(1699123456.123456)
    
    result = Imports::Slack::Normalizer.slack_timestamp_to_time(timestamp)
    
    assert_equal expected_time, result
  end

  test "slack_timestamp_to_time handles nil" do
    result = Imports::Slack::Normalizer.slack_timestamp_to_time(nil)
    assert_nil result
  end

  test "normalize_user_name extracts real_name from profile" do
    slack_user = {
      "profile" => { "real_name" => "John Doe" },
      "name" => "john.doe"
    }
    
    result = Imports::Slack::Normalizer.normalize_user_name(slack_user)
    
    assert_equal "John Doe", result
  end

  test "normalize_user_name falls back to name field" do
    slack_user = {
      "profile" => {},
      "name" => "john.doe"
    }
    
    result = Imports::Slack::Normalizer.normalize_user_name(slack_user)
    
    assert_equal "john.doe", result
  end

  test "normalize_user_name handles nil user" do
    result = Imports::Slack::Normalizer.normalize_user_name(nil)
    assert_equal "Unknown User", result
  end

  test "normalize_user_email extracts email from profile" do
    slack_user = {
      "profile" => { "email" => "john@example.com" }
    }
    
    result = Imports::Slack::Normalizer.normalize_user_email(slack_user)
    
    assert_equal "john@example.com", result
  end

  test "normalize_room_name handles channel types" do
    channel = { "type" => "channel", "name" => "general" }
    result = Imports::Slack::Normalizer.normalize_room_name(channel)
    assert_equal "general", result

    private_channel = { "type" => "group", "name" => "private-chat" }
    result = Imports::Slack::Normalizer.normalize_room_name(private_channel)
    assert_equal "private-chat", result

    im_channel = { "type" => "im" }
    result = Imports::Slack::Normalizer.normalize_room_name(im_channel)
    assert_nil result
  end

  test "normalize_message_body converts slack markdown" do
    user_mapping = {}
    slack_message = {
      "text" => "This is *bold* and _italic_ and `code`"
    }
    
    result = Imports::Slack::Normalizer.normalize_message_body(slack_message, user_mapping)
    
    assert_includes result, "<strong>bold</strong>"
    assert_includes result, "<em>italic</em>"
    assert_includes result, "<code>code</code>"
  end

  test "normalize_message_body converts user mentions" do
    user = users(:one)
    user_mapping = { "U123456" => user }
    slack_message = {
      "text" => "Hello <@U123456>!"
    }
    
    result = Imports::Slack::Normalizer.normalize_message_body(slack_message, user_mapping)
    
    assert_includes result, "@#{user.name}"
  end

  test "normalize_message_body adds thread indicator" do
    user_mapping = {}
    slack_message = {
      "text" => "This is a reply",
      "thread_ts" => "1699123400.000000",
      "ts" => "1699123456.000000"
    }
    
    result = Imports::Slack::Normalizer.normalize_message_body(slack_message, user_mapping)
    
    assert_includes result, "(thread)"
  end

  test "client_message_id uses slack client_msg_id when available" do
    slack_message = { "client_msg_id" => "abc-123-def" }
    channel_id = "C123456"
    
    result = Imports::Slack::Normalizer.client_message_id(slack_message, channel_id)
    
    assert_equal "abc-123-def", result
  end

  test "client_message_id falls back to composed id" do
    slack_message = { "ts" => "1699123456.123456" }
    channel_id = "C123456"
    
    result = Imports::Slack::Normalizer.client_message_id(slack_message, channel_id)
    
    assert_equal "slack:C123456:1699123456.123456", result
  end
end