module Message::Searchable
  extend ActiveSupport::Concern

  included do
    after_create_commit  :create_in_index
    after_update_commit  :update_in_index
    after_destroy_commit :remove_from_index

    scope :search, ->(query) { joins("join message_search_index idx on messages.id = idx.rowid").where("idx.body match ?", match_terms(query)).ordered }
  end

  class_methods do
    # Quotes each word, so that FTS5 searches for AND, OR, NOT and NEAR rather than
    # parsing them as operators, which fails on a query like "AND" or "salt AND".
    def match_terms(query)
      query.split.map { |word| %("#{word.gsub('"', '""')}") }.join(" ")
    end
  end

  class_methods do
    # Orders by the index's rowid, which is the message id, so SQLite walks the full-text index
    # newest first and stops at the page. Ordering by created_at sorted every match before paging.
    def last_page_of_matches(size)
      Message::Pagination::Page.load(reorder("idx.rowid"), :last, size)
    end
  end

  private
    def create_in_index
      execute_sql_with_binds "insert into message_search_index(rowid, body) values (?, ?)", id, plain_text_body
    end

    def update_in_index
      execute_sql_with_binds "update message_search_index set body = ? where rowid = ?", plain_text_body, id
    end

    def remove_from_index
      execute_sql_with_binds "delete from message_search_index where rowid = ?", id
    end

    def execute_sql_with_binds(*statement)
      self.class.connection.execute self.class.sanitize_sql(statement)
    end
end
