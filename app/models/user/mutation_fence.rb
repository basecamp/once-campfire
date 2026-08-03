require "fileutils"

class User::MutationFence
  STATE_KEY = :campfire_user_mutation_fences

  class << self
    def with(user_ids, &block)
      ids = Array(user_ids).compact.map { Integer(_1) }.uniq.sort
      acquire(ids, 0, &block)
    end

    def held?(user_id)
      state.fetch(Integer(user_id), 0).positive?
    end

    private
      def acquire(ids, index, &block)
        return yield if index == ids.length

        with_one(ids.fetch(index)) { acquire(ids, index + 1, &block) }
      end

      def with_one(user_id)
        if held?(user_id)
          state[user_id] += 1
          yield
        else
          mutex_for(user_id).synchronize do
            FileUtils.mkdir_p lock_root
            File.open(lock_root.join("#{user_id}.lock"), File::RDWR | File::CREAT, 0o600) do |file|
              file.flock File::LOCK_EX
              state[user_id] = 1
              yield
            ensure
              state.delete user_id
              file.flock File::LOCK_UN
            end
          end
        end
      ensure
        if state[user_id].to_i > 1
          state[user_id] -= 1
        end
      end

      def state
        Thread.current.thread_variable_get(STATE_KEY) ||
          Thread.current.thread_variable_set(STATE_KEY, {})
      end

      def lock_root
        Rails.root.join("storage", "user-mutation-fences")
      end

      def mutex_for(user_id)
        mutexes_guard.synchronize { mutexes[user_id] ||= Mutex.new }
      end

      def mutexes
        @mutexes ||= {}
      end

      def mutexes_guard
        @mutexes_guard ||= Mutex.new
      end
  end
end
