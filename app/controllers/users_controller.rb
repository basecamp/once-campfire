class UsersController < ApplicationController
  JOIN_INTENT_SESSION_KEY = "credential_intent.join"

  require_unauthenticated_access only: %i[ new create ]

  before_action :set_user, only: :show
  before_action :require_join_intent, only: :create
  before_action :reject_password_registration, only: %i[ new create ]

  def new
    if valid_join_intent?
      @user = User.new
    else
      session.delete JOIN_INTENT_SESSION_KEY
      render :join
    end
  end

  def create
    attributes = user_params.to_h.symbolize_keys
    avatar = attributes.delete(:avatar)
    StagedUpload.with(avatar) do |blob|
      Account.transaction do
        account = Account.lock.sole
        CredentialIntent.consume_join!(session[JOIN_INTENT_SESSION_KEY], account:) do
          if account.oidc_transition_state == "rollback_prepared"
            raise Oidc::Activation::Error, "rollback preparation is active"
          end

          @user = User.create!(attributes.merge(avatar: blob).compact)
          start_new_session_for @user
        end
      end
    end
    session.delete JOIN_INTENT_SESSION_KEY
    redirect_to root_url
  rescue ActiveRecord::RecordNotUnique
    redirect_to new_session_url(email_address: User.normalize_email_address(user_params[:email_address]))
  rescue CredentialIntent::Invalid, ActiveRecord::RecordNotFound
    session.delete JOIN_INTENT_SESSION_KEY
    head :not_found
  rescue Oidc::Activation::Error, ActiveRecord::ActiveRecordError
    head :service_unavailable
  end

  def show
  end

  private
    def set_user
      @user = User.find(params[:id])
    end

    def require_join_intent
      unless valid_join_intent?
        session.delete JOIN_INTENT_SESSION_KEY
        head :not_found
      end
    end

    def valid_join_intent?
      Current.account && CredentialIntent.valid_join?(session[JOIN_INTENT_SESSION_KEY], account: Current.account)
    end

    def reject_password_registration
      head :not_found if Oidc.required?
    end

    def user_params
      params.require(:user).permit(:name, :avatar, :email_address, :password)
    end
end
