class Users::EncryptionKeysController < ApplicationController
  before_action :set_user, only: :show

  # GET /users/:user_id/encryption_key.json
  # Returns a user's public key for E2E encryption
  def show
    render json: { identity_public_key: @user.identity_public_key }
  end

  # POST /users/me/encryption_key
  # Register or update the current user's public key
  def create
    Current.user.update!(identity_public_key: params[:identity_public_key])
    render json: { status: "ok" }
  end

  private
    def set_user
      @user = User.find(params[:user_id])
    end
end
