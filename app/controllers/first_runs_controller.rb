class FirstRunsController < ApplicationController
  allow_unauthenticated_access

  before_action :prevent_repeats

  def show
    @user = User.new
  end

  def create
    attributes = user_params.to_h.symbolize_keys
    avatar = attributes.delete(:avatar)
    StagedUpload.with(avatar) do |blob|
      Account.transaction do
        user = FirstRun.create!(attributes.merge(avatar: blob).compact)
        start_new_session_for user
      end
    end

    redirect_to root_url
  rescue ActiveRecord::RecordNotUnique
    redirect_to root_url
  end

  private
    def prevent_repeats
      redirect_to root_url if Account.any?
    end

    def user_params
      params.require(:user).permit(:name, :avatar, :email_address, :password)
    end
end
