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

  test "operator words are searched for as words" do
    rooms(:designers).messages.create! body: "Salt and pepper", client_message_id: "operators", creator: users(:david)

    get searches_url, params: { q: "salt AND" }

    assert_response :success
    assert_select ".message", text: /Salt and pepper/
  end

  test "searching for an operator word alone doesn't fail" do
    %w[ AND OR NOT ].each do |word|
      get searches_url, params: { q: word }

      assert_response :success
      assert_select ".message", count: 0
    end
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

  test "clear search history" do
    assert users(:david).searches.any?

    delete clear_searches_url

    assert users(:david).searches.none?
  end
end
