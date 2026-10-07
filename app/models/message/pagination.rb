module Message::Pagination
  extend ActiveSupport::Concern

  PAGE_SIZE = 40

  # Expose Rails' collection-preloading hook while preserving Array pagination and
  # validators. The renderer passes only cache misses to preload_associations.
  class Page < Array
    def self.load(relation, direction, size)
      new(relation.skip_preloading!.public_send(direction, size), relation)
    end

    def initialize(records, relation)
      super(records)
      @relation = relation
    end

    def loaded?
      true
    end

    def preload_associations(records)
      @relation.preload_associations(records)
    end
  end

  included do
    # Keep presentation data lazy until the collection cache knows which messages missed.
    scope :last_page, -> { last_page_of(PAGE_SIZE) }
    scope :first_page, -> { Page.load(ordered, :first, PAGE_SIZE) }

    scope :before, ->(message) { where("created_at < ?", message.created_at) }
    scope :after, ->(message) { where("created_at > ?", message.created_at) }

    scope :page_before, ->(message) { before(message).last_page }
    scope :page_after, ->(message) { after(message).first_page }

    scope :page_created_since, ->(time) { where("created_at > ?", time).first_page }
    # Sorting on +created_at, which no index covers, has SQLite find the few messages updated since
    # through (room_id, updated_at) and sort just those, instead of walking the whole room by
    # (room_id, created_at) looking for them.
    scope :page_updated_since, ->(time) { Page.load(where("updated_at > ?", time).reorder(Arel.sql("+messages.created_at")), :last, PAGE_SIZE) }
  end

  class_methods do
    def last_page_of(size)
      Page.load(ordered, :last, size)
    end

    def page_around(message)
      Page.new(page_before(message) + [ message ] + page_after(message), ordered)
    end

    def paged?
      offset(PAGE_SIZE).exists?
    end
  end
end
