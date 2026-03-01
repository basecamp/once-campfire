module Message::Searchable
  extend ActiveSupport::Concern

  included do
    after_create_commit  :create_in_index
    after_update_commit  :update_in_index
    after_destroy_commit :remove_from_index

    scope :search, ->(query) { joins("join message_search_index idx on messages.id = idx.rowid").where("idx.body match ?", query).ordered }
  end

  private
    def create_in_index
      return if encrypted?
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
