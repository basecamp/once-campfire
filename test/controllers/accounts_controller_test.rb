require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "edit" do
    get edit_account_url
    assert_response :ok
  end

  test "edit groups administrators separately from members with a divider" do
    get edit_account_url

    assert_response :ok

    # Verify the divider exists between administrator and member sections
    assert_select "turbo-frame#account_users hr.separator.full-width"

    # Verify administrators appear before the divider and members appear after
    # by checking the order of user names in the response body
    administrators = users(:david, :jason).map(&:name)
    members = users(:jz, :kevin).map(&:name)

    response_body = response.body

    # Find positions of divider and user names
    divider_position = response_body.index('hr class="separator full-width"')
    assert divider_position, "Divider should exist in the response"

    administrators.each do |name|
      name_position = response_body.index("<strong>#{name}</strong>")
      assert name_position, "Administrator #{name} should appear in the response"
      assert name_position < divider_position, "Administrator #{name} should appear before the divider"
    end

    members.each do |name|
      name_position = response_body.index("<strong>#{name}</strong>")
      assert name_position, "Member #{name} should appear in the response"
      assert name_position > divider_position, "Member #{name} should appear after the divider"
    end
  end

  test "edit lists a page of members and the next page carries on from it" do
    User.insert_all 501.times.map { |i| { name: "Member #{i}", email_address: "member#{i}@37signals.com" } }
    users(:kevin).banned!

    get edit_account_url
    first_page = listed_user_ids
    get account_users_url(page: 2, format: :turbo_stream)
    next_page = listed_user_ids

    assert_not_empty next_page
    assert_equal User.where(status: [ :active, :banned ]).without_bots.ids.sort, (first_page + next_page).sort
  end

  test "update" do
    assert users(:david).administrator?

    put account_url, params: { account: { name: "Different" } }

    assert_redirected_to edit_account_url
    assert_equal accounts(:signal).name, "Different"
  end

  test "non-admins cannot update" do
    sign_in :kevin
    assert users(:kevin).member?

    put account_url, params: { account: { name: "Different" } }
    assert_response :forbidden
  end

  private
    def listed_user_ids
      response.body.scan(%r{href="/users/(\d+)"}).flatten.map(&:to_i)
    end
end
