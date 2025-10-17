class Auth::OidcController < ApplicationController
  allow_unauthenticated_access only: [:callback, :failure]

  before_action :check_sso_enabled, only: [:callback, :failure]

  def callback
    auth_hash = request.env['omniauth.auth']
    
    Rails.logger.info "OIDC Callback - Auth Hash: #{auth_hash.inspect}"
    
    if auth_hash.present?
      # Check if user has an allowed role
      unless user_has_allowed_role?(auth_hash)
        Rails.logger.warn "OIDC Login - User does not have an allowed role"
        flash[:alert] = "Access denied. Your account does not have the required permissions."
        redirect_to new_session_url
        return
      end
      
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
    def check_sso_enabled
      if ENV['DISABLE_SSO'].to_s.downcase == 'true'
        Rails.logger.warn "OIDC - SSO is disabled, redirecting to login"
        flash[:alert] = "SSO login is disabled."
        redirect_to new_session_url
      end
    end

    ALLOWED_ROLES = ["Administrator", "Paid Member", "Free Trial", "Student"].freeze

    def user_has_allowed_role?(auth_hash)
      # Extract roles from the auth hash
      # WordPress roles can be in different places depending on the OIDC provider configuration
      info = auth_hash['info'] || auth_hash.info
      extra = auth_hash['extra'] || auth_hash.extra
      raw_info = extra&.dig('raw_info') || {}
      
      # Try to find roles in various possible locations
      roles = info['roles'] || 
              info['role'] || 
              raw_info['roles'] || 
              raw_info['role'] ||
              raw_info['user_roles'] ||
              raw_info['wp_user_roles'] ||
              raw_info['wp_roles'] ||
              []
      
      # Ensure roles is an array
      roles = [roles] unless roles.is_a?(Array)
      roles = roles.compact.map(&:to_s)
      
      Rails.logger.info "OIDC - User roles: #{roles.inspect}"
      Rails.logger.info "OIDC - Full auth hash for debugging: #{auth_hash.to_json}"
      
      # If no roles are found, allow access temporarily until WordPress is configured
      # TODO: Change this to 'false' once WordPress is configured to send roles
      if roles.empty?
        Rails.logger.warn "OIDC - No roles found in response, allowing access (configure WordPress to send roles)"
        return true
      end
      
      # Check if user has at least one allowed role
      has_allowed_role = roles.any? { |role| ALLOWED_ROLES.include?(role) }
      
      Rails.logger.info "OIDC - Has allowed role: #{has_allowed_role}"
      
      has_allowed_role
    end

    def find_or_create_user_from_oidc(auth_hash)
      info = auth_hash['info'] || auth_hash.info
      extra = auth_hash['extra'] || auth_hash.extra
      raw_info = extra&.dig('raw_info') || {}
      
      email = info['email'] || info.email
      
      # Build name from first_name and last_name if available
      first_name = raw_info['first_name'] || info['first_name'] || ''
      last_name = raw_info['last_name'] || info['last_name'] || ''
      
      # Construct full name, falling back to other fields if first/last name are empty
      name = if first_name.present? || last_name.present?
               [first_name, last_name].reject(&:blank?).join(' ')
             else
               raw_info['display_name'] || 
               info['name'] || 
               info.name || 
               info['nickname'] || 
               info.nickname || 
               email&.split('@')&.first
             end
      
      Rails.logger.info "OIDC - Extracted email: #{email}, name: #{name} (from first_name: '#{first_name}', last_name: '#{last_name}')"
      
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

