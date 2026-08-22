class Users::PushSubscriptionsController < ApplicationController
  before_action :set_push_subscriptions

  def index
  end

  def create
    capability = push_subscription_params.to_h.symbolize_keys
    Push::Subscription.synchronize!(
      capability:, user: Current.user, session: Current.session,
      user_agent: request.user_agent.to_s.first(Push::Subscription::MAXIMUM_USER_AGENT_LENGTH)
    )

    head :ok
  rescue ActiveRecord::RecordInvalid
    head :unprocessable_entity
  end

  def destroy
    @push_subscriptions.destroy_by(id: params[:id])
    redirect_to user_push_subscriptions_url
  end

  private
    def set_push_subscriptions
      @push_subscriptions = Current.user.push_subscriptions
    end

    def push_subscription_params
      params.require(:push_subscription).permit(:endpoint, :p256dh_key, :auth_key)
    end
end
