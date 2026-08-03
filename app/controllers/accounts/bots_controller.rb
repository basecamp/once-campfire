class Accounts::BotsController < ApplicationController
  before_action :ensure_can_administer
  before_action :set_bot, only: %i[ edit update destroy ]

  def index
    @bots = User.active_bots.ordered
  end

  def new
    @bot = User.active_bots.new
  end

  def create
    User.create_bot! bot_params, actor: Current.user
    redirect_to account_bots_url
  end

  def edit
  end

  def update
    @bot.update_bot! bot_params, actor: Current.user
    redirect_to account_bots_url
  end

  def destroy
    @bot.deactivate_by! actor: Current.user
    redirect_to account_bots_url
  end

  private
    def set_bot
      @bot = User.active_bots.find(params[:id])
    end

    def bot_params
      params.require(:user).permit(:name, :avatar, :webhook_url)
    end
end
