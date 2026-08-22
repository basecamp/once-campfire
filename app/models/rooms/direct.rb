require "digest"

# Rooms for direct message chats between users. These act as a singleton, so a single set of users will
# always refer to the same direct room.
class Rooms::Direct < Room
  PARTICIPANT_KEY_VERSION = "v1"
  class ParticipantMutationError < StandardError; end

  validates :direct_participant_key, presence: true, on: :create
  validate :created_through_participant_factory, on: :create

  class << self
    def find_or_create_for(users, actor:)
      requested_user_ids = Array(users).flat_map { _1.respond_to?(:id) ? _1.id : _1 }.compact.map(&:to_i).uniq.sort
      participant_key = participant_key_for(requested_user_ids)

      transaction do
        current_actor = User.lock_active!(actor)
        raise User::AuthorizationError, "user is not a direct room participant" unless requested_user_ids.include?(current_actor.id)

        participants = User.active.lock.where(id: requested_user_ids).order(:id).to_a
        unless participants.map(&:id) == requested_user_ids
          raise User::AuthorizationError, "direct room participants are not active"
        end

        room = find_by(direct_participant_key: participant_key) || claim_legacy_room(requested_user_ids, participant_key)
        if room
          authorize_participant_set! room, requested_user_ids
        else
          create_canonical_room!(current_actor, participant_key, participants)
        end
      end
    rescue ActiveRecord::RecordNotUnique
      transaction do
        current_actor = User.lock_active!(actor)
        find_by!(direct_participant_key: participant_key).tap do |room|
          raise User::AuthorizationError, "user is not a direct room member" unless room.users.exists?(current_actor.id)
        end
      end
    end

    def participant_key_for(user_ids)
      ids = Array(user_ids).map { _1.respond_to?(:id) ? _1.id : _1 }.compact.map(&:to_i).uniq.sort
      "#{PARTICIPANT_KEY_VERSION}:#{Digest::SHA256.hexdigest(ids.join(":"))}"
    end

    private
      def create_canonical_room!(creator, participant_key, participants)
        new(creator:, direct_participant_key: participant_key).send(:create_canonically!, participants)
      end

      def claim_legacy_room(user_ids, participant_key)
        where(direct_participant_key: nil).find_each do |room|
          if room.user_ids.sort == user_ids
            room.update!(direct_participant_key: participant_key)
            return room
          end
        end
        nil
      end

      def authorize_participant_set!(room, user_ids)
        unless room.user_ids.sort == user_ids
          raise User::AuthorizationError, "direct room membership changed"
        end

        room
      end
  end

  def default_involvement
    "everything"
  end

  private
    def created_through_participant_factory
      errors.add :base, "direct rooms must be created with their canonical participants" unless @creating_canonical_room
    end

    def create_canonically!(participants)
      @creating_canonical_room = true
      save!
      create_initial_participants! participants
      self
    ensure
      @creating_canonical_room = false
    end

    def create_initial_participants!(participants)
      participant_ids = participants.map(&:id).uniq.sort
      if memberships.exists? || self.class.participant_key_for(participant_ids) != direct_participant_key
        raise ParticipantMutationError, "direct room participants do not match the canonical key"
      end

      @creating_initial_participants = true
      participants.each do |participant|
        Membership.create!(room: self, user: participant, involvement: default_involvement)
      end
    ensure
      @creating_initial_participants = false
    end

    def creating_initial_participants?
      @creating_initial_participants == true
    end
end
