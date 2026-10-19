class Users::PushSubscriptionsController < ApplicationController
  before_action :set_push_subscriptions

  def index
  end

  def create
    subscription = @push_subscriptions.find_or_initialize_by(push_subscription_params)
    subscription.user_agent = request.user_agent if subscription.new_record?

    # Existing endpoints must pass current validations too
    if subscription.valid?
      head save_while_signed_in(subscription) ? :ok : :unauthorized
    else
      head :unprocessable_entity
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

    # A password change ends every session and subscription. A request that authenticated just before it mustn't
    # put one back, so the session is checked under the same write lock as the save. Validation, which looks up
    # the endpoint's address, runs before taking the lock.
    def save_while_signed_in(subscription)
      Push::Subscription.transaction do
        Session.exists?(Current.session.id) &&
          (subscription.new_record? ? subscription.save!(validate: false) : subscription.touch)
      end
    end

    def push_subscription_params
      params.require(:push_subscription).permit(:endpoint, :p256dh_key, :auth_key)
    end
end
