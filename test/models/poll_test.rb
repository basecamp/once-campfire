require "test_helper"

class PollTest < ActiveSupport::TestCase
  test "requires question and at least two options" do
    poll = build_poll(question: "", options: [ "One" ])

    assert_not poll.valid?
    assert_includes poll.errors[:question], "can't be blank"
    assert_includes poll.errors[:options], "must have between 2 and 10 options"
  end

  test "question can include mentions" do
    poll = build_poll(question: "Hi #{mention_attachment_for(:david)}", options: [ "One", "Two" ])

    assert poll.valid?
    assert_equal [ users(:david) ], poll.message.mentionees
  end

  test "vote option must belong to poll" do
    poll = create_poll
    other_poll = create_poll
    vote = poll.votes.build(voter: users(:david), poll_option: other_poll.options.first)

    assert_not vote.valid?
    assert_includes vote.errors[:poll_option], "must belong to poll"
  end

  private
    def create_poll
      message = rooms(:designers).messages.create!(creator: users(:jason), body: "", client_message_id: SecureRandom.uuid)
      message.create_poll!(question: "Which one?", options_attributes: [ { body: "A", position: 0 }, { body: "B", position: 1 } ])
    end

    def build_poll(question:, options:)
      message = Message.new(room: rooms(:designers), creator: users(:jason), client_message_id: SecureRandom.uuid)
      message.build_poll(
        question:,
        options_attributes: options.each_with_index.map { |body, i| { body:, position: i } }
      )
    end
end
