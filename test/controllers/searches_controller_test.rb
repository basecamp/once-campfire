require "test_helper"

class SearchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @message = rooms(:designers).messages.create! body: "Hello world!", client_message_id: "search", creator: users(:david)
  end

  test "index initial view" do
    get searches_url

    assert_response :success
    assert_select ".message", count: 0
  end

  test "finding reachable messages" do
    get searches_url, params: { q: "hello" }

    assert_response :success
    assert_select ".message", text: /Hello world!/
  end

  test "unreachable messages are not found" do
    memberships(:david_designers).destroy!

    get searches_url, params: { q: "hello" }

    assert_response :success
    assert_select ".message", count: 0
  end

  test "create saves the search term" do
    assert_difference -> { users(:david).searches.count }, +1 do
      post searches_url, params: { q: "hello" }
    end

    assert_redirected_to searches_url(q: "hello")
    assert users(:david).searches.exists?(query: "hello")
  end

  test "request mutation fence failures return service unavailable" do
    User::MutationFence.stubs(:with).raises(User::MutationFence::Unavailable, "unavailable")

    assert_no_difference -> { users(:david).searches.count } do
      post searches_url, params: { q: "must not save" }
    end

    assert_response :service_unavailable
  end

  test "clear search history" do
    assert users(:david).searches.any?

    delete clear_searches_url

    assert users(:david).searches.none?
  end
end

class SearchesSessionRevocationConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test "an admitted mutation completes before its session can be revoked" do
    user = users(:david)
    browser = ActionDispatch::Integration::Session.new(Rails.application)
    browser.post session_url, params: {
      email_address: user.email_address, password: "secret123456"
    }
    assert_equal 302, browser.response.status
    current_session = user.sessions.order(:id).last
    entered_action = Queue.new
    continue_mutation = Queue.new
    request_result = Queue.new
    original_record_for = Search.method(:record_for!)
    Search.define_singleton_method(:record_for!) do |actor, query|
      if query == "fenced revocation"
        entered_action << true
        continue_mutation.pop
      end
      original_record_for.call(actor, query)
    end
    Session.any_instance.stubs(:disconnect_remote_connections)

    request = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        browser.post searches_url, params: { q: "fenced revocation" }
        request_result << browser.response.status
      end
    rescue StandardError => error
      request_result << error
    end
    entered_action.pop

    revocation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Session.find(current_session.id).revoke!
      end
    end

    assert_nil revocation.join(0.1), "session revocation overtook an admitted mutation"
    continue_mutation << true
    request.join
    revocation.join

    assert_equal 302, request_result.pop
    assert user.searches.exists?(query: "fenced revocation")
    assert_not Session.exists?(current_session.id)
  ensure
    Search.define_singleton_method(:record_for!, original_record_for) if original_record_for
    continue_mutation << true if request&.alive?
    request&.join(2)
    revocation&.join(2)
  end
end
