require "test_helper"

class SqliteUnicodeCasefoldTest < ActiveSupport::TestCase
  test "folds the case of letters in any script" do
    assert_equal "игорь émile ωmega", casefold("ИГОРЬ ÉMILE ΩMEGA")
  end

  test "folds letters that lowercasing leaves alone" do
    assert_equal "strasse", casefold("Straße")
  end

  test "keeps NULL" do
    assert_nil casefold(nil)
  end

  test "folds malformed text instead of failing the query" do
    assert_equal "a\uFFFDb", casefold("A\xFFB")
  end

  private
    def casefold(text)
      ActiveRecord::Base.connection.select_value("select unicode_casefold(?)", nil, [ text ])
    end
end
