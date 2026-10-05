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

  test "boosts are cached inside their message instead of one fragment each" do
    with_memory_cache do
      cache_keys = []
      subscriber = ActiveSupport::Notifications.subscribe(/\Acache_(read|read_multi|write|write_multi)\.active_support\z/) do |*, payload|
        cache_keys.concat(payload[:key].is_a?(Hash) ? payload[:key].keys : Array(payload[:key]))
      end

      get room_messages_url(rooms(:watercooler))
      assert_response :success
      assert_select "#" + dom_id(boosts(:fourth_by_bender))
      assert_select "#" + dom_id(boosts(:thirteenth))
      assert_empty cache_keys.grep(%r{messages/boosts/_boost})

      boost = messages(:fourth).boosts.create! booster: users(:jason), content: "🎉"
      get room_messages_url(rooms(:watercooler))
      refreshed = response.body

      Rails.cache.clear
      get room_messages_url(rooms(:watercooler))
      assert_equal refreshed, response.body
      assert_select "##{dom_id(messages(:fourth))} ##{dom_id(boost)}", text: /🎉/
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  test "messages render their preloaded boosts in order without querying them again" do
    earlier = messages(:fourth).boosts.create! booster: users(:jason), content: "🥇", created_at: 1.day.ago
    in_order = [ dom_id(earlier), dom_id(boosts(:fourth_by_bender)) ]

    assert_no_queries_match(/ORDER BY "boosts"/) do
      get room_messages_url(rooms(:watercooler))
    end
    assert_response :success
    assert_equal in_order, css_select("##{dom_id(messages(:fourth), :boosts)} .boost").map { it["id"] }

    get message_boosts_url(messages(:fourth))
    assert_equal in_order, css_select("##{dom_id(messages(:fourth), :boosts)} .boost").map { it["id"] }
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
