class Accounts::BotsController < ApplicationController
  prepend_around_action :with_administrator_roster_mutation_fence, only: :destroy
  before_action :ensure_can_administer
  before_action :set_bot, only: %i[ edit update destroy ]
  skip_around_action :with_session_mutation_fence, only: %i[ create update ]

  def index
    @bots = User.active_bots.ordered
  end

  def new
    @bot = User.active_bots.new
  end

  def create
    User.create_bot! bot_params, actor: Current.user, current_session: Current.session
    redirect_to account_bots_url
  rescue ActiveRecord::RecordInvalid => error
    render_invalid_bot :new, error
  end

  def edit
  end

  def update
    @bot.update_bot! bot_params, actor: Current.user, current_session: Current.session
    redirect_to account_bots_url
  rescue ActiveRecord::RecordInvalid => error
    render_invalid_bot :edit, error
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

    def render_invalid_bot(template, error)
      attributes = bot_params.to_h.symbolize_keys
      if template == :new
        @bot = User.active_bots.new(attributes.slice(:name))
      else
        @bot.reload.assign_attributes(attributes.slice(:name))
      end
      @bot.webhook_url = attributes[:webhook_url] if attributes.key?(:webhook_url)

      case error.record
      when Webhook
        messages = error.record.errors[:url].presence || error.record.errors.full_messages
        messages.each { @bot.errors.add(:webhook_url, _1.sub(/\AWebhook URL\s*/i, "")) }
      when User
        error.record.errors.each { @bot.errors.import(_1) }
      else
        raise error
      end
      render template, status: :unprocessable_entity
    end
end
