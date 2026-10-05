require "application_system_test_case"

class StartingPingsTest < ApplicationSystemTestCase
  setup do
    sign_in "kevin@37signals.com"
  end

  test "suggesting people to ping" do
    visit new_rooms_direct_url

    find("[data-autocomplete-target='input']").send_keys("Jas")

    assert_selector "suggestion-option[role='option']", text: "Jason"
  end
end
