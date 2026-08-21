require "digest"

class Oidc::SessionGeneration
  DISABLED_CONFIGURATION_FINGERPRINT = Digest::SHA256.hexdigest("oidc-disabled").freeze
  RETIREMENT_BATCH_SIZE = 100

  class << self
    def current!
      ensure_migrated!
      generation = synchronized_generation
      return generation if generation && !stale_sessions(generation).exists?

      generation ||= synchronize!
      retire_other_generations! generation
      generation
    rescue ActiveRecord::ActiveRecordError => error
      raise Oidc::PolicyUnavailable.new(Oidc::POLICY_UNAVAILABLE_MESSAGE), cause: error
    end

    def with_current
      ensure_migrated!
      Account.transaction do
        account_id = Account.pick(:id)
        raise ActiveRecord::RecordNotFound, "account is unavailable" unless account_id

        Account.where(id: account_id).update_all("oidc_session_generation = oidc_session_generation")
        generation = synchronize_account!(Account.lock.find(account_id))
        yield generation
      end
    end

    def ready?
      return false unless migrated?

      generation = current!
      !stale_sessions(generation).exists?
    rescue Oidc::PolicyUnavailable, ActiveRecord::ActiveRecordError
      false
    end

    def migrated?
      Account.table_exists? &&
        Account.column_names.include?("oidc_session_configuration_fingerprint") &&
        Account.column_names.include?("oidc_session_generation") &&
        Session.column_names.include?("oidc_session_generation")
    rescue ActiveRecord::ActiveRecordError
      false
    end

    private
      def synchronized_generation
        account = Account.select(
          :oidc_session_configuration_fingerprint, :oidc_session_generation
        ).sole
        generation = account.oidc_session_generation.to_i
        if generation.positive? &&
            account.oidc_session_configuration_fingerprint == configuration_fingerprint
          generation
        end
      end

      def synchronize!
        Account.transaction do
          synchronize_account! Account.lock.sole
        end
      end

      def synchronize_account!(account)
        fingerprint = configuration_fingerprint
        generation = account.oidc_session_generation.to_i
        unless generation.positive? && account.oidc_session_configuration_fingerprint == fingerprint
          generation += 1
          account.update_columns(
            oidc_session_configuration_fingerprint: fingerprint,
            oidc_session_generation: generation,
            updated_at: Time.current
          )
        end
        generation
      end

      def retire_other_generations!(generation)
        ids = stale_sessions(generation).order(:id).limit(retirement_batch_size).ids
        Session.revoke_all! Session.where(id: ids)
      end

      def stale_sessions(generation)
        stale = Session.where(authentication_method: "oidc")
          .where.not(oidc_session_generation: generation)
        Oidc.enabled? ? stale.or(Session.where(authentication_method: "transfer")) : stale
      end

      def retirement_batch_size
        RETIREMENT_BATCH_SIZE
      end

      def configuration_fingerprint
        Oidc.enabled? ? Oidc.configuration.fingerprint : DISABLED_CONFIGURATION_FINGERPRINT
      end

      def ensure_migrated!
        return if migrated?

        raise Oidc::PolicyUnavailable, Oidc::POLICY_UNAVAILABLE_MESSAGE
      end
  end
end
