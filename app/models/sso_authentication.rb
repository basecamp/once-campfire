class SsoAuthentication
  class Error < StandardError; end

  EMAIL_ATTRIBUTE_KEYS = [
    "email",
    "mail",
    "emailAddress",
    "email_address",
    "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress",
    "urn:oid:0.9.2342.19200300.100.1.3",
    "urn:oid:1.2.840.113549.1.9.1"
  ].freeze

  def self.find_or_create_user_from(auth)
    provider = auth.provider.to_s
    uid      = auth.uid.to_s
    info     = auth.info || OmniAuth::AuthHash::InfoHash.new
    email    = extract_email(auth:, info:, uid:)

    raise Error, "No email provided by identity provider" if email.blank?
    raise Error, "No UID provided by identity provider" if uid.blank?

    # Find by SSO identity (returning user)
    user = User.find_by(sso_provider: provider, sso_uid: uid)
    return user if user

    # Find by email (link existing user to SSO on first SSO login)
    user = User.find_by(email_address: email)
    if user
      user.update!(sso_provider: provider, sso_uid: uid)
      return user
    end

    # Auto-create new user (SSO users bypass join code)
    User.create!(
      name: info[:name].presence || email.split("@").first,
      email_address: email,
      sso_provider: provider,
      sso_uid: uid,
      role: :member
    )
  end

  class << self
    private
      def extract_email(auth:, info:, uid:)
        candidate = normalize_email(info.email || info[:email] || info[:mail] || info[:email_address])
        return candidate if candidate.present?

        raw_info = auth.dig(:extra, :raw_info)
        candidate = normalize_email(fetch_first(raw_info, EMAIL_ATTRIBUTE_KEYS))
        return candidate if candidate.present?

        normalize_email(uid) if uid.to_s.include?("@")
      end

      def fetch_first(container, keys)
        return if container.nil?

        keys.each do |key|
          value = fetch_value(container, key)
          return value if value.present?
        end

        nil
      end

      def fetch_value(container, key)
        return container[key] if container.respond_to?(:[])

        nil
      rescue StandardError
        nil
      end

      def normalize_email(value)
        email = case value
        when Array
          value.find { _1.to_s.include?("@") }
        else
          value
        end

        email.to_s.downcase.strip.presence
      end
  end
end
