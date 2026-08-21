class Boost < ApplicationRecord
  belongs_to :message, touch: true
  belongs_to :booster, class_name: "User", default: -> { Current.user }

  scope :ordered, -> { order(:created_at) }

  class << self
    def create_by!(message:, actor:, attributes:, authenticated_bot_key: nil)
      authenticated_bot_key = authenticated_bot_key&.dup
      User::MutationFence.with(actor.id) do
        transaction do
          current_actor = User.lock_room_member!(actor, message.room_id)
          User.verify_bot_key! current_actor, authenticated_bot_key if authenticated_bot_key
          current_message = current_actor.reachable_messages.lock.find(message.id)
          current_message.boosts.create!(attributes.merge(booster: current_actor))
        end
      end
    end

    def destroy_by!(id:, actor:, authenticated_bot_key: nil)
      authenticated_bot_key = authenticated_bot_key&.dup
      User::MutationFence.with(actor.id) do
        transaction do
          boost = lock.includes(:message).find(id)
          current_actor = User.lock_room_member!(actor, boost.message.room_id)
          User.verify_bot_key! current_actor, authenticated_bot_key if authenticated_bot_key
          raise User::AuthorizationError, "user cannot remove this boost" unless boost.booster_id == current_actor.id

          boost.destroy!
        end
      end
    rescue ActiveRecord::RecordNotFound
      raise User::AuthorizationError, "boost is not available"
    end
  end
end
