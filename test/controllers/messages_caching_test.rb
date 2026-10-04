require "test_helper"
require "active_record/testing/query_assertions"

class MessagesCachingTest < ActionDispatch::IntegrationTest
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    sign_in :david
  end

  test "cached pages skip presentation queries and refresh edited messages" do
    with_memory_cache do
      get room_messages_url(rooms(:watercooler))
      assert_response :success
      original = response.body

      assert_no_queries_match(/action_text_rich_texts|active_storage_attachments|boosts/) do
        get room_messages_url(rooms(:watercooler))
      end
      assert_response :success
      assert_equal original, response.body

      messages(:fourth).update! body: "Updated cached message"
      get room_messages_url(rooms(:watercooler))
      assert_response :success
      assert_select "#" + dom_id(messages(:fourth)), text: /Updated cached message/
    end
  end

  private
    def with_memory_cache
      old_cache = Rails.cache
      old_collection_cache = ActionView::PartialRenderer.collection_cache
      old_controller_cache = MessagesController.cache_store
      old_caching = MessagesController.perform_caching

      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      ActionView::PartialRenderer.collection_cache = Rails.cache
      MessagesController.cache_store = Rails.cache
      MessagesController.perform_caching = true
      yield
    ensure
      Rails.cache = old_cache
      ActionView::PartialRenderer.collection_cache = old_collection_cache
      MessagesController.cache_store = old_controller_cache
      MessagesController.perform_caching = old_caching
    end
end
