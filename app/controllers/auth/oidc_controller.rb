class Auth::OidcController < ApplicationController
  allow_unauthenticated_access only: [:callback]

  def callback
    auth_hash = request.env['omniauth.auth']
    
    if auth_hash.present?
      user = find_or_create_user_from_oidc(auth_hash)
      if user
        start_new_session_for user
        redirect_to post_authenticating_url
      else
        flash[:alert] = "Authentication failed. Please try again."
        redirect_to new_session_url
      end
    else
      flash[:alert] = "Authentication failed. Please try again."
      redirect_to new_session_url
    end
  end

  def failure
    flash[:alert] = "Authentication failed: #{params[:message]}"
    redirect_to new_session_url
  end

  private

    def find_or_create_user_from_oidc(auth_hash)
      info = auth_hash.info
      uid = auth_hash.uid
      
      # Try to find existing user by email
      user = User.active.find_by(email_address: info.email)
      
      if user
        # Update user info if needed
        user.update!(
          name: info.name || info.nickname || info.email.split('@').first,
          email_address: info.email
        ) if user.name != (info.name || info.nickname || info.email.split('@').first)
        
        user
      elsif User.any? # Only allow new user creation if there are existing users (not first run)
        # Create new user
        User.create!(
          name: info.name || info.nickname || info.email.split('@').first,
          email_address: info.email,
          active: true,
          # Generate a random password since we're using OIDC
          password: SecureRandom.hex(32)
        )
      else
        # This is the first user (first run scenario)
        # Redirect to first run instead
        redirect_to first_run_url
        nil
      end
    end
end

