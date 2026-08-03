class Membership < ApplicationRecord
  include Connectable

  belongs_to :room
  belongs_to :user

  before_destroy { user.increment!(:authorization_generation) }
  before_create :ensure_direct_participant_insertion_allowed
  before_update :ensure_direct_participant_reassignment_allowed,
    if: -> { will_save_change_to_room_id? || will_save_change_to_user_id? }
  before_update -> { user.increment!(:authorization_generation) }, if: :will_save_change_to_involvement?
  after_destroy_commit { user.disconnect_remote_connections reconnect: true }
  after_update_commit -> { user.disconnect_remote_connections reconnect: true }, if: :saved_change_to_involvement?

  enum :involvement, %w[ invisible nothing mentions everything ].index_by(&:itself), prefix: :involved_in

  scope :with_ordered_room, -> { includes(:room).joins(:room).order("LOWER(rooms.name)") }
  scope :without_direct_rooms, -> { joins(:room).where.not(room: { type: "Rooms::Direct" }) }

  scope :visible, -> { where.not(involvement: :invisible) }
  scope :unread,  -> { where.not(unread_at: nil) }

  def read
    with_lock do
      update_columns(
        unread_at: nil, presence_generation: presence_generation + 1, updated_at: Time.current
      )
    end
  end

  def unread?
    unread_at.present?
  end

  def destroy
    ensure_direct_participant_removal_allowed
    with_webhook_delivery_fence { super }
  end

  def destroy!
    ensure_direct_participant_removal_allowed
    with_webhook_delivery_fence { super }
  end

  def delete
    ensure_direct_participant_removal_allowed
    super
  end

  private
    def ensure_direct_participant_insertion_allowed
      if canonical_direct_room? && !room.send(:creating_initial_participants?)
        raise Rooms::Direct::ParticipantMutationError, "direct room participants are immutable"
      end
    end

    def ensure_direct_participant_removal_allowed
      if canonical_direct_room?
        raise Rooms::Direct::ParticipantMutationError, "direct room participants are immutable"
      end
    end

    def ensure_direct_participant_reassignment_allowed
      room_ids = [ room_id_in_database, room_id ].compact.uniq
      if Rooms::Direct.where(id: room_ids).where.not(direct_participant_key: nil).exists?
        raise Rooms::Direct::ParticipantMutationError, "direct room participants are immutable"
      end
    end

    def canonical_direct_room?
      room.is_a?(Rooms::Direct) && room.direct_participant_key?
    end

    def with_webhook_delivery_fence(&block)
      if User.where(id: user_id, role: :bot).exists?
        User::MutationFence.with(user_id, &block)
      else
        yield
      end
    end
end
