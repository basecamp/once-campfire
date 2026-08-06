class Messages::PollVotesController < ApplicationController
  include ActionView::RecordIdentifier

  before_action :set_poll

  def create
    if @poll.closed?
      head :unprocessable_entity
      return
    end

    option = @poll.options.find_by(id: params[:poll_option_id])
    unless option
      head :not_found
      return
    end

    if @poll.multi_select?
      @poll.votes.find_or_create_by!(poll_option: option, voter: Current.user)
    else
      @poll.votes.where(voter: Current.user).delete_all
      @poll.votes.create!(poll_option: option, voter: Current.user)
    end

    broadcast_poll_update
    render_poll_update
  end

  def destroy
    if @poll.closed?
      head :unprocessable_entity
      return
    end

    option = @poll.options.find_by(id: params[:id])
    unless option
      head :not_found
      return
    end

    @poll.votes.where(voter: Current.user, poll_option: option).delete_all

    broadcast_poll_update
    render_poll_update
  end

  private
    def set_poll
      message = Current.user.reachable_messages.with_poll.find_by(id: params[:message_id])
      @poll = message&.poll

      head :not_found unless @poll
    end

    def broadcast_poll_update
      reload_poll

      # Results are shared, but the ballot includes the current voter's selected state.
      @poll.message.broadcast_replace_to @poll.message.room, :messages,
        target: [ @poll, :results ],
        partial: "messages/polls/results",
        locals: { poll: @poll },
        attributes: { maintain_scroll: true }
    end

    def render_poll_update
      render turbo_stream: turbo_stream.replace(dom_id(@poll, :ballot), partial: "messages/polls/ballot", locals: { poll: @poll, voter: Current.user })
    end

    def reload_poll
      @poll = Poll.includes(:message, options: { votes: :voter }).find(@poll.id)
    end
end
