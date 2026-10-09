module Message::Mentionee
  extend ActiveSupport::Concern

  def mentionees
    ids = mentioned_users.map(&:id)
    ids.empty? ? User.none : room.users.where(id: ids)
  end

  private
    def mentioned_users
      if body.body
        body.body.attachables.grep(User).uniq
      else
        []
      end
    end
end
