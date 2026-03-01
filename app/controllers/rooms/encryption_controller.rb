class Rooms::EncryptionController < ApplicationController
  before_action :set_room
  before_action :ensure_membership

  # GET /rooms/:room_id/encryption.json
  # Returns room encryption status and member public keys
  def show
    member_keys = @room.users.where.not(identity_public_key: nil).pluck(:id, :identity_public_key)
      .to_h { |id, key| [id, key] }

    membership = @room.memberships.find_by(user: Current.user)

    render json: {
      encrypted: @room.encrypted?,
      member_keys: member_keys,
      encrypted_room_key: membership&.encrypted_room_key,
      room_key_nonce: membership&.room_key_nonce
    }
  end

  # POST /rooms/:room_id/encryption
  # Enable encryption for a room and distribute room keys
  def create
    return render json: { error: "Room already encrypted" }, status: :unprocessable_entity if @room.encrypted?
    return render json: { error: "Not authorized" }, status: :forbidden unless Current.user.can_administer?(@room)

    @room.transaction do
      @room.update!(encrypted: true)

      # Store encrypted room keys for each member
      params[:member_keys]&.each do |user_id, key_data|
        membership = @room.memberships.find_by(user_id: user_id)
        next unless membership

        membership.update!(
          encrypted_room_key: key_data[:encrypted_key],
          room_key_nonce: key_data[:nonce]
        )
      end
    end

    render json: { status: "ok" }
  end

  # PATCH /rooms/:room_id/encryption
  # Update room keys (e.g., when adding new members)
  def update
    return render json: { error: "Room not encrypted" }, status: :unprocessable_entity unless @room.encrypted?

    params[:member_keys]&.each do |user_id, key_data|
      membership = @room.memberships.find_by(user_id: user_id)
      next unless membership

      membership.update!(
        encrypted_room_key: key_data[:encrypted_key],
        room_key_nonce: key_data[:nonce]
      )
    end

    render json: { status: "ok" }
  end

  private
    def set_room
      @room = Room.find(params[:room_id])
    end

    def ensure_membership
      head :forbidden unless Current.user.rooms.include?(@room)
    end
end
