class Users::PushSubscriptionsController < ApplicationController
  before_action :set_push_subscriptions

  def index
  end

  def create
    if subscription = @push_subscriptions.find_by(push_subscription_params)
      subscription.touch
      head :ok
    else
      subscription = @push_subscriptions.create push_subscription_params.merge(user_agent: request.user_agent)
      head subscription.persisted? ? :ok : :unprocessable_entity
    end
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
