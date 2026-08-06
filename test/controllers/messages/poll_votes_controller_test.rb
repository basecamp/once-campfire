require "test_helper"

class Messages::PollVotesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @poll = create_poll
    @message = @poll.message
  end

  test "create vote" do
    option = @poll.options.first

    assert_difference -> { @poll.votes.count }, 1 do
      post message_poll_votes_url(@message, format: :turbo_stream), params: { poll_option_id: option.id }
      assert_response :success
    end
  end

  test "single-select replaces prior vote" do
    first_option, second_option = @poll.options.first(2)
    post message_poll_votes_url(@message, format: :turbo_stream), params: { poll_option_id: first_option.id }

    assert_no_difference -> { @poll.votes.count } do
      post message_poll_votes_url(@message, format: :turbo_stream), params: { poll_option_id: second_option.id }
    end

    assert_equal [ second_option.id ], @poll.votes.where(voter: users(:david)).pluck(:poll_option_id)
  end

  test "destroy vote" do
    option = @poll.options.first
    @poll.votes.create!(poll_option: option, voter: users(:david))

    assert_difference -> { @poll.votes.count }, -1 do
      delete message_poll_vote_url(@message, option, format: :turbo_stream)
      assert_response :success
    end
  end

  test "closed polls cannot be voted" do
    @poll.close!

    assert_no_difference -> { @poll.votes.count } do
      post message_poll_votes_url(@message, format: :turbo_stream), params: { poll_option_id: @poll.options.first.id }
      assert_response :unprocessable_entity
    end
  end

  test "create vote with stale option id returns not found" do
    assert_no_difference -> { @poll.votes.count } do
      post message_poll_votes_url(@message, format: :turbo_stream), params: { poll_option_id: 0 }
      assert_response :not_found
    end
  end

  test "destroy vote with stale option id returns not found" do
    assert_no_difference -> { @poll.votes.count } do
      delete message_poll_vote_url(@message, 0, format: :turbo_stream)
      assert_response :not_found
    end
  end

  test "create vote is not allowed outside rooms the user can reach" do
    poll = create_poll(room: rooms(:watercooler))
    sign_in :jz

    assert_no_difference -> { poll.votes.count } do
      post message_poll_votes_url(poll.message, format: :turbo_stream), params: { poll_option_id: poll.options.first.id }
      assert_response :not_found
    end
  end

  test "destroy vote is not allowed outside rooms the user can reach" do
    poll = create_poll(room: rooms(:watercooler))
    option = poll.options.first
    poll.votes.create!(poll_option: option, voter: users(:david))
    sign_in :jz

    assert_no_difference -> { poll.votes.count } do
      delete message_poll_vote_url(poll.message, option, format: :turbo_stream)
      assert_response :not_found
    end
  end

  private
    def create_poll(room: rooms(:designers))
      message = room.messages.create!(creator: users(:jason), body: "", client_message_id: SecureRandom.uuid)
      message.create_poll!(question: "Choose", options_attributes: [ { body: "A", position: 0 }, { body: "B", position: 1 } ])
    end
end
