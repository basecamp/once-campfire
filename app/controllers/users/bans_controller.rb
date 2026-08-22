class Users::BansController < ApplicationController
  prepend_around_action :with_administrator_roster_mutation_fence
  before_action :ensure_can_administer
  before_action :set_user

  def create
    @user.ban_by! actor: Current.user
    redirect_to @user
  end

  def destroy
    @user.unban_by! actor: Current.user
    redirect_to @user
  end

  private
    def set_user
      @user = User.find(params[:user_id])
    end
end
