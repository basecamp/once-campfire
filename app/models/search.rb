class Search < ApplicationRecord
  belongs_to :user

  after_create :trim_recent_searches

  scope :ordered, -> { order(updated_at: :desc) }

  class << self
    def record(query)
      find_or_create_by(query: query).touch
    end

    def record_for!(user, query)
      User::MutationFence.with(user.id) do
        transaction do
          User.lock_active!(user).searches.record(query)
        end
      end
    end

    def clear_for!(user)
      User::MutationFence.with(user.id) do
        transaction do
          User.lock_active!(user).searches.destroy_all
        end
      end
    end
  end

  private
    def trim_recent_searches
      user.searches.excluding(user.searches.ordered.limit(10)).destroy_all
    end
end
