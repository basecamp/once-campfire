class Auth::OidcController < ApplicationController
  allow_unauthenticated_access only: [:callback, :failure]

  def callback
    auth_hash = request.env['omniauth.auth']
    
    Rails.logger.info "OIDC Callback - Auth Hash: #{auth_hash.inspect}"
    
    if auth_hash.present?
      user = find_or_create_user_from_oidc(auth_hash)
      if user
        Rails.logger.info "OIDC Login - User found/created: #{user.email_address}"
        start_new_session_for user
        redirect_to post_authenticating_url
      else
        Rails.logger.error "OIDC Login - User creation failed"
        flash[:alert] = "Authentication failed. Could not create user."
        redirect_to new_session_url
      end
    else
      Rails.logger.error "OIDC Callback - No auth hash present"
      flash[:alert] = "Authentication failed. No authentication data received."
      redirect_to new_session_url
    end
  rescue StandardError => e
    Rails.logger.error "OIDC Callback Error: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
    flash[:alert] = "Authentication error: #{e.message}"
    redirect_to new_session_url
  end

  def failure
    Rails.logger.error "OIDC Failure - Message: #{params[:message]}, Strategy: #{params[:strategy]}"
    flash[:alert] = "Authentication failed: #{params[:message]}"
    redirect_to new_session_url
  end

  private

    def find_or_create_user_from_oidc(auth_hash)
      info = auth_hash['info'] || auth_hash.info
      email = info['email'] || info.email
      name = info['name'] || info.name || info['nickname'] || info.nickname || email&.split('@')&.first
      
      Rails.logger.info "OIDC - Extracted email: #{email}, name: #{name}"
      
      return nil if email.blank?
      
      # Try to find existing user by email
      user = User.active.find_by(email_address: email)
      
      if user
        Rails.logger.info "OIDC - Found existing user: #{user.id}"
        # Update user info if needed
        user.update!(name: name) if user.name != name && name.present?
        user
      elsif User.any?
        Rails.logger.info "OIDC - Creating new user with email: #{email}"
        # Create new user
        User.create!(
          name: name,
          email_address: email,
          active: true,
          password: SecureRandom.hex(32)
        )
      else
        Rails.logger.info "OIDC - No users exist, redirecting to first run"
        # This is the first user (first run scenario)
        redirect_to first_run_url
        nil
      end
    rescue StandardError => e
      Rails.logger.error "OIDC - User find/create error: #{e.class} - #{e.message}"
      nil
    end
end

