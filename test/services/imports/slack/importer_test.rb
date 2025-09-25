require "test_helper"

class Imports::Slack::ImporterTest < ActiveSupport::TestCase
  def setup
    @creator = users(:one)
    @test_export_path = Rails.root.join("tmp", "test_slack_export")
    setup_test_export_data
  end

  def teardown
    FileUtils.rm_rf(@test_export_path) if @test_export_path.exist?
  end

  test "importer runs successfully with sample data" do
    importer = Imports::Slack::Importer.new(path: @test_export_path, creator: @creator)
    
    assert_difference "User.count", 2 do
      assert_difference "Room.count", 1 do
        assert_difference "Message.count", 2 do
          stats = importer.run
          
          assert_equal 2, stats[:users_created]
          assert_equal 1, stats[:rooms_created]
          assert_equal 2, stats[:messages_created]
          assert_equal 0, stats[:messages_skipped]
          assert_empty stats[:errors]
        end
      end
    end
  end

  test "importer is idempotent on second run" do
    importer = Imports::Slack::Importer.new(path: @test_export_path, creator: @creator)
    
    # First run
    importer.run
    
    # Second run should skip existing messages
    assert_no_difference "User.count" do
      assert_no_difference "Room.count" do
        assert_no_difference "Message.count" do
          stats = importer.run
          
          assert_equal 0, stats[:users_created]
          assert_equal 0, stats[:rooms_created]
          assert_equal 0, stats[:messages_created]
          assert_equal 2, stats[:messages_skipped]
        end
      end
    end
  end

  test "importer handles importing flag correctly" do
    importer = Imports::Slack::Importer.new(path: @test_export_path, creator: @creator)
    
    # Mock the room.receive method to verify it's not called
    Room.any_instance.expects(:receive).never
    
    importer.run
    
    # Verify importing flag is reset
    assert_not Current.importing
  end

  private

  def setup_test_export_data
    FileUtils.mkdir_p(@test_export_path)
    FileUtils.mkdir_p(@test_export_path.join("C123456"))

    # Create users.json
    users_data = [
      {
        "id" => "U111111",
        "name" => "alice",
        "profile" => {
          "real_name" => "Alice Smith",
          "email" => "alice@example.com"
        },
        "deleted" => false,
        "is_bot" => false
      },
      {
        "id" => "U222222",
        "name" => "bob",
        "profile" => {
          "real_name" => "Bob Jones",
          "email" => "bob@example.com"
        },
        "deleted" => false,
        "is_bot" => false
      }
    ]
    File.write(@test_export_path.join("users.json"), users_data.to_json)

    # Create channels.json
    channels_data = [
      {
        "id" => "C123456",
        "name" => "general",
        "type" => "channel",
        "is_archived" => false,
        "members" => ["U111111", "U222222"]
      }
    ]
    File.write(@test_export_path.join("channels.json"), channels_data.to_json)

    # Create messages for the channel
    messages_data = [
      {
        "user" => "U111111",
        "text" => "Hello everyone!",
        "ts" => "1699123400.000000",
        "client_msg_id" => "msg-001"
      },
      {
        "user" => "U222222",
        "text" => "Hi <@U111111>! How are you?",
        "ts" => "1699123456.000000",
        "client_msg_id" => "msg-002"
      }
    ]
    File.write(@test_export_path.join("C123456", "2023-11-04.json"), messages_data.to_json)
  end
end