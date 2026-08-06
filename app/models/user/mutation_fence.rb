require "fileutils"
require "digest"
require "securerandom"

class User::MutationFence
  STATE_KEY = :campfire_user_mutation_fences
  class Unavailable < StandardError; end

  class << self
    def with(user_ids, &block)
      ids = Array(user_ids).compact.map { Integer(_1) }.uniq.sort
      acquire(ids.map { [ _1, "#{_1}.lock" ] }, 0, &block)
    end

    def with_identity_subject(issuer:, subject:, &block)
      digest = identity_subject_digest(issuer, subject)
      acquire([ [ [ :identity_subject, digest ], "identity-#{digest}.lock" ] ], 0, &block)
    end

    def identity_subject_held?(issuer:, subject:)
      digest = identity_subject_digest(issuer, subject)
      state.fetch([ :identity_subject, digest ], 0).positive?
    end

    def held?(user_id)
      state.fetch(Integer(user_id), 0).positive?
    end

    def ready?
      readiness_check!
      true
    rescue Unavailable
      false
    end

    private
      def acquire(entries, index, &block)
        return yield if index == entries.length

        state_key, filename = entries.fetch(index)
        with_one(state_key, filename) { acquire(entries, index + 1, &block) }
      end

      def with_one(state_key, filename)
        if state.fetch(state_key, 0).positive?
          state[state_key] += 1
          begin
            yield
          ensure
            state[state_key] -= 1
          end
        else
          mutex_for(filename).synchronize do
            file = open_locked_file(lock_root.join(filename))
            state[state_key] = 1
            begin
              yield
            ensure
              state.delete state_key
              release_locked_file file
            end
          end
        end
      end

      def state
        Thread.current.thread_variable_get(STATE_KEY) ||
          Thread.current.thread_variable_set(STATE_KEY, {})
      end

      def lock_root
        Rails.root.join("storage", "user-mutation-fences")
      end

      def mutex_for(key)
        mutexes_guard.synchronize { mutexes[key] ||= Mutex.new }
      end

      def mutexes
        @mutexes ||= {}
      end

      def mutexes_guard
        @mutexes_guard ||= Mutex.new
      end

      def identity_subject_digest(issuer, subject)
        Digest::SHA256.hexdigest([ issuer, subject ].join("\0"))
      end

      def open_locked_file(path, exclusive: false)
        FileUtils.mkdir_p lock_root
        flags = File::RDWR | File::CREAT
        flags |= File::EXCL if exclusive
        file = File.open(path, flags, 0o600)
        unless file.flock(File::LOCK_EX | (exclusive ? File::LOCK_NB : 0))
          raise IOError, "mutation fence lock could not be acquired"
        end
        file
      rescue SystemCallError, IOError => error
        file&.close
        raise Unavailable.new("user mutation fence storage is unavailable"), cause: error
      end

      def release_locked_file(file)
        file.flock File::LOCK_UN
        file.close
      rescue SystemCallError, IOError => error
        file.close rescue nil
        raise Unavailable.new("user mutation fence storage is unavailable"), cause: error
      end

      def readiness_check!
        path = lock_root.join(".readiness-#{Process.pid}-#{SecureRandom.hex(12)}.lock")
        file = open_locked_file(path, exclusive: true)
        release_locked_file file
        file = nil
        File.delete path
      rescue Unavailable
        raise
      rescue SystemCallError, IOError => error
        raise Unavailable.new("user mutation fence storage is unavailable"), cause: error
      ensure
        begin
          release_locked_file(file) if file
          File.delete(path) if path&.exist?
        rescue SystemCallError, IOError => error
          raise Unavailable.new("user mutation fence storage is unavailable"), cause: error
        end
      end
  end
end
