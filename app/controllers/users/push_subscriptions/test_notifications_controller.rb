class Users::PushSubscriptions::TestNotificationsController < ApplicationController
  before_action :set_push_subscription

  def create
    return head :not_found unless Rails.env.development?

    @push_subscription.notification(title: "Campfire Test", body: Random.uuid, path: user_push_subscriptions_url).deliver
    redirect_to user_push_subscriptions_url
  end

  private
    def set_push_subscription
      @push_subscription = Current.user.push_subscriptions.find(params[:push_subscription_id])
    end
end
