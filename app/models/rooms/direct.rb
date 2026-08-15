# Rooms for direct message chats between users. These act as a singleton, so a single set of users will
# always refer to the same direct room.
class Rooms::Direct < Room
  class << self
    def find_or_create_for(users)
      hash = members_hash_for(users)
      find_for(hash, users) || create_for({ members_hash: hash }, users: users)
    end

    def members_hash_for(users)
      Digest::MD5.hexdigest(users.map(&:id).sort.join(","))
    end

    private
      def find_for(hash, users)
        find_by(members_hash: hash) ||
          find_by_users(users)&.tap { |room| room.update_column(:members_hash, hash) }
      end

      def find_by_users(users)
        user_ids = Set.new(users.map(&:id))
        includes(:users)
          .joins(:memberships)
          .group(:id)
          .having("COUNT(memberships.id) = ?", user_ids.size)
          .find { |room| Set.new(room.users.map(&:id)) == user_ids }
      end
  end

  def default_involvement
    "everything"
  end

  def compute_members_hash
    self.class.members_hash_for(users)
  end
end
