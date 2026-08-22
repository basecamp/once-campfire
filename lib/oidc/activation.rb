module Oidc
  class Activation
    class Error < StandardError; end
    ACTIVATION_PROOF_LIFETIME = 15.minutes

    class << self
      def ready?
        readiness_error.nil?
      end

      def readiness_error
        new.readiness_error
      rescue ActiveRecord::ActiveRecordError
        "the database is unavailable or has not been migrated"
      end

      def record_successful_authentication!(account: Account.lock.sole)
        raise Identity::AuthenticationError, "rollback_prepared" if account.oidc_transition_state == "rollback_prepared"

        account.update!(
          oidc_verified_configuration_fingerprint: Oidc.configuration.fingerprint,
          oidc_verified_at: Time.current
        )
      end

      def active?
        new.active?
      rescue ActiveRecord::ActiveRecordError
        false
      end
    end

    def readiness_error
      return unless Oidc.required?
      return "the OIDC database migration has not completed" unless migrated?
      account = Account.first
      return "Campfire first-run setup has not completed" unless account
      return "rollback preparation is active" if account.oidc_transition_state == "rollback_prepared"
      unless account.oidc_required_at? && account.oidc_configuration_fingerprint == Oidc.configuration.fingerprint
        return "required mode has not been activated for this configuration"
      end
      return "the recovery administrator binding is invalid" unless valid_bound_recovery_user?(account)

      unlinked_count = unlinked_active_users(account).count
      "#{unlinked_count} active user(s) are not linked to the configured provider" if unlinked_count.positive?
    end

    def active?
      readiness_error.nil? && Oidc.required?
    end

    def activate!(recovery_password:)
      raise Error, "OIDC_MODE must be required" unless Oidc.required?
      raise Error, "the OIDC database migration has not completed" unless migrated?

      Account.transaction do
        account = Account.lock.sole
        recovery_user = Oidc.configured_break_glass_user&.lock!
        if error = preflight_error(recovery_password:, require_recovery_proof: true)
          raise Error, error
        end

        account.update!(
          oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
          oidc_required_at: Time.current,
          oidc_break_glass_user: recovery_user,
          oidc_transition_state: nil
        )
      end

      incompatible_sessions = Session.where.not(id: compatible_sessions.select(:id))
      Session.revoke_all_in_batches! incompatible_sessions
      Push::Subscription.where(session_id: nil).delete_all

      raise Error, "session cleanup was incomplete" if incompatible_sessions.exists?
      raise Error, "push cleanup was incomplete" if Push::Subscription.where(session_id: nil).exists?
    end

    def prepare_rollback!(confirmation:)
      unless confirmation == "DELETE ALL SESSIONS"
        raise Error, "set CONFIRM='DELETE ALL SESSIONS' to acknowledge global sign-out"
      end
      Account.transaction do
        account = Account.lock.sole
        if Identity.where(provisioned: true).exists?
          raise Error, "an OIDC-incompatible rollback would strand JIT-provisioned users; stay on an OIDC-capable image"
        end
        if User.active.without_bots.where(password_digest: [ nil, "" ]).exists?
          raise Error, "an OIDC-incompatible rollback would strand users without local passwords"
        end

        account.update!(
          oidc_configuration_fingerprint: nil,
          oidc_required_at: nil,
          oidc_verified_configuration_fingerprint: nil,
          oidc_verified_at: nil,
          oidc_transition_state: "rollback_prepared"
        )
      end

      Session.revoke_all_in_batches!
      Push::Subscription.delete_all
      raise Error, "session cleanup was incomplete" if Session.exists? || Push::Subscription.exists?
    end

    def cancel_rollback!(confirmation:, recovery_password:)
      raise Error, "OIDC_MODE must be required" unless Oidc.required?
      unless confirmation == "RESUME OIDC"
        raise Error, "set CONFIRM='RESUME OIDC' to acknowledge that required mode remains unavailable until reverified"
      end

      Account.transaction do
        account = Account.lock.sole
        raise Error, "rollback preparation is not active" unless account.oidc_transition_state == "rollback_prepared"
        unless Oidc.break_glass_user&.authenticate(recovery_password.to_s)
          raise Error, "the recovery administrator password could not be verified"
        end

        account.update!(oidc_transition_state: nil)
      end
    end

    def preflight_error(recovery_password: nil, require_recovery_proof: false)
      return "Campfire first-run setup has not completed" unless Account.one?
      recovery_user = Oidc.configured_break_glass_user
      return "OIDC_BREAK_GLASS_EMAIL must identify one active administrator" unless recovery_user
      return "the recovery administrator does not have a local password" if recovery_user.password_digest.blank?
      if require_recovery_proof && !recovery_user.authenticate(recovery_password.to_s)
        return "the recovery administrator password could not be verified"
      end

      account = Account.first
      unless account.oidc_verified_configuration_fingerprint == Oidc.configuration.fingerprint && account.oidc_verified_at?
        return "the exact OIDC configuration has not completed a successful authentication"
      end
      if account.oidc_verified_at < ACTIVATION_PROOF_LIFETIME.ago
        return "the successful OIDC authentication is too old; authenticate again before activation"
      end

      recently_verified = Identity.where(
        issuer: Oidc.issuer,
        provider_fingerprint: Oidc.provider_fingerprint,
        verified_configuration_fingerprint: Oidc.configuration.fingerprint,
        verified_at: ACTIVATION_PROOF_LIFETIME.ago..
      )

      unlinked = User.active.without_bots
        .where.not(id: recently_verified.select(:user_id))
        .where.not(id: recovery_user.id)
      if unlinked.exists?
        return "#{unlinked.count} active user(s) have not recently authenticated with the configured provider"
      end

      linked_administrator = User.active.where(role: :administrator)
        .where(id: recently_verified.select(:user_id))
      "no active administrator has recently authenticated with the configured provider" unless linked_administrator.exists?
    end

    private
      def compatible_sessions
        Session.unexpired.joins(:user).merge(User.active).where(
          authentication_method: "oidc",
          oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
          identity_id: Identity.where(
            issuer: Oidc.issuer, provider_fingerprint: Oidc.provider_fingerprint
          ).select(:id)
        )
      end

      def migrated?
        Account.column_names.include?("oidc_required_at") &&
          Account.column_names.include?("oidc_transition_state") &&
          Session.column_names.include?("authentication_method") &&
          Session.column_names.include?("oidc_configuration_fingerprint") &&
          ActiveRecord::Base.connection.data_source_exists?("identities") &&
          ActiveRecord::Base.connection.data_source_exists?("oidc_flows")
      end

      def valid_bound_recovery_user?(account)
        user = account.oidc_break_glass_user
        user&.active? && user.administrator? && user.password_digest.present?
      end

      def unlinked_active_users(account)
        linked_users = Identity.where(
          issuer: Oidc.issuer, provider_fingerprint: Oidc.provider_fingerprint
        ).select(:user_id)
        User.active.without_bots.where.not(id: linked_users).where.not(id: account.oidc_break_glass_user_id)
      end
  end
end
