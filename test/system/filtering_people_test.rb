require "application_system_test_case"

class FilteringPeopleTest < ApplicationSystemTestCase
  PERSON = "[data-filter-target=list] li"

  setup do
    # The filter shows up for more than 20 people.
    [ "Mary Ann Lee", "Mary Brown", "Sean O'Brien", "Dr. Who", "3D Studio", %(Dwayne "The Rock" Johnson) ].each { create_user _1 }
    16.times { create_user "Person #{_1}" }

    sign_in "david@37signals.com"
  end

  test "filtering people by part of a name" do
    filter_people "mary"

    assert_people "Mary Ann Lee", "Mary Brown"
  end

  test "filtering people by a full name" do
    filter_people "mary ann"

    assert_people "Mary Ann Lee"
  end

  test "filtering people by a name with punctuation or digits" do
    filter_people "o'brien"
    assert_people "Sean O'Brien"

    filter_people "dr."
    assert_people "Dr. Who"

    filter_people "3d"
    assert_people "3D Studio"

    filter_people %("the rock")
    assert_people %(Dwayne "The Rock" Johnson)
  end

  private
    def create_user(name)
      User.create!(name: name, email_address: "#{name.parameterize}@example.com", password: "secret123456")
    end

    # From a fresh list each time, so a count can only match once the filter has run.
    def filter_people(text)
      visit new_rooms_closed_url
      assert_selector PERSON, minimum: 21

      fill_in "search", with: text
    end

    def assert_people(*names)
      assert_selector PERSON, count: names.size
      names.each { assert_selector PERSON, text: _1 }
    end
end
