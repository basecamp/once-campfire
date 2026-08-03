class Users::JoinIntentsController < ApplicationController
  require_unauthenticated_access

  before_action :reject_password_registration

  def create
    browser_intent = Account.transaction do
      account = Account.lock.sole
      supplied_code = params[:token].to_s
      unless supplied_code.bytesize == account.join_code.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(supplied_code, account.join_code)
        raise CredentialIntent::Invalid, "join credential is invalid"
      end

      CredentialIntent.issue_join! account.join_code
    end
    session[UsersController::JOIN_INTENT_SESSION_KEY] = browser_intent
    redirect_to join_path
  rescue CredentialIntent::Invalid
    session.delete UsersController::JOIN_INTENT_SESSION_KEY
    redirect_to join_path, alert: "That invitation link is invalid or has expired."
  rescue ActiveRecord::ActiveRecordError
    head :service_unavailable
  end

  private
    def reject_password_registration
      head :not_found if Oidc.required?
    end
end
