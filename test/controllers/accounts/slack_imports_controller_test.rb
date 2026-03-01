require "test_helper"
require "zip"

class Accounts::SlackImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "new" do
    get new_account_slack_import_url
    assert_response :ok
  end

  test "create imports slack messages and skips duplicates on re-import" do
    assert_difference -> { Room.opens.where(name: "general").count }, +1 do
      assert_difference -> { Message.count }, +2 do
        with_slack_export_upload(slack_export_entries) do |archive|
          post account_slack_import_url, params: { slack_import: { archive: archive } }
        end
      end
    end

    assert_redirected_to edit_account_url

    room = Room.opens.find_by!(name: "general")
    imported_messages = room.messages.ordered.last(2)

    assert_equal users(:david), imported_messages.first.creator
    assert_equal "Hey @David", imported_messages.first.body.to_plain_text

    assert_equal "Slack Import Bot", imported_messages.second.creator.name
    assert_equal "[Robot] Imported by bot", imported_messages.second.body.to_plain_text

    assert_no_difference -> { Message.count } do
      with_slack_export_upload(slack_export_entries) do |archive|
        post account_slack_import_url, params: { slack_import: { archive: archive } }
      end
    end
  end

  test "non-admins cannot import" do
    sign_in :kevin

    assert_no_difference -> { Message.count } do
      with_slack_export_upload(slack_export_entries) do |archive|
        post account_slack_import_url, params: { slack_import: { archive: archive } }
      end
    end

    assert_response :forbidden
  end

  test "create requires archive" do
    assert_no_difference -> { Message.count } do
      post account_slack_import_url, params: { slack_import: {} }
    end

    assert_redirected_to new_account_slack_import_url
    assert_equal "Choose a Slack export ZIP file.", flash[:alert]
  end

  test "create applies explicit slack to campfire user mappings" do
    assert_difference -> { Message.count }, +2 do
      with_slack_export_upload(slack_export_entries) do |archive|
        post account_slack_import_url, params: {
          slack_import: {
            archive: archive,
            user_mappings: "U1=#{users(:kevin).email_address}"
          }
        }
      end
    end

    assert_redirected_to edit_account_url

    imported_message = Room.opens.find_by!(name: "general").messages.ordered.last(2).first
    assert_equal users(:kevin), imported_message.creator
  end

  test "create rejects unknown mapped campfire users" do
    assert_no_difference -> { Message.count } do
      with_slack_export_upload(slack_export_entries) do |archive|
        post account_slack_import_url, params: {
          slack_import: {
            archive: archive,
            user_mappings: "U1=unknown-user@example.com"
          }
        }
      end
    end

    assert_redirected_to new_account_slack_import_url
    assert_equal "Unknown Campfire user 'unknown-user@example.com' on line 1.", flash[:alert]
  end

  private
    def with_slack_export_upload(entries)
      archive = Tempfile.new([ "slack-export", ".zip" ])

      Zip::File.open(archive.path, create: true) do |zip|
        entries.each do |name, content|
          zip.get_output_stream(name) { |stream| stream.write(content) }
        end
      end

      yield Rack::Test::UploadedFile.new(archive.path, "application/zip")
    ensure
      archive&.close!
    end

    def slack_export_entries
      {
        "users.json" => [
          { id: "U1", name: "david", real_name: "David", profile: { email: users(:david).email_address } },
          { id: "U2", name: "robot", real_name: "Robot" }
        ].to_json,
        "channels.json" => [ { id: "C1", name: "general" } ].to_json,
        "general/2024-03-18.json" => [
          { type: "message", user: "U1", text: "Hey <@U1>", ts: "1710000000.000001" },
          { type: "message", username: "Robot", text: "Imported by bot", ts: "1710000001.000002" }
        ].to_json
      }
    end
end
