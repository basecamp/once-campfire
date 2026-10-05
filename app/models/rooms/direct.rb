# Rooms for direct message chats between users. These act as a singleton, so a single set of users will
# always refer to the same direct room.
class Rooms::Direct < Room
  class << self
    def find_or_create_for(users)
      find_for(users) || create_for({}, users: users)
    end

    private
      # Among the first user's rooms, the one whose members are exactly these users: as many
      # memberships as users, and all of them theirs.
      def find_for(users)
        user_ids = users.pluck(:id).uniq

        where(id: Membership.where(user_id: user_ids.first).select(:room_id))
          .joins(:memberships).group(:id)
          .having("COUNT(*) = :size AND COUNT(CASE WHEN memberships.user_id IN (:user_ids) THEN 1 END) = :size", size: user_ids.size, user_ids: user_ids)
          .first
      end
  end

  def default_involvement
    "everything"
  end
end
