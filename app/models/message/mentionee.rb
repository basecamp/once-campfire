module Message::Mentionee
  extend ActiveSupport::Concern

  def mentionees
    room.users.where(id: mentioned_users.map(&:id))
  end

  private
    def mentioned_users
      attachments = []
      attachments.concat(body.body.attachables) if body.body
      attachments.concat(poll.question.body.attachables) if poll&.question&.body
      attachments.grep(User).uniq
    end
end
