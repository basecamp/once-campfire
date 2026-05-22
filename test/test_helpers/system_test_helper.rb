module SystemTestHelper
  def sign_in(email_address, password = "secret123456")
    visit root_url

    unless page.has_field?("email_address", wait: 2)
      if page.has_css?("summary", text: "Sign in with email and password", wait: 2)
        find("summary", text: "Sign in with email and password").click
      end
    end

    fill_in "email_address", with: email_address
    fill_in "password", with: password

    click_on "log_in"
    assert_selector "a.btn", text: "Designers"
  end

  def wait_for_cable_connection
    assert_selector "turbo-cable-stream-source[connected]", count: 3, visible: false
  end

  def join_room(room)
    visit room_url(room)
    wait_for_cable_connection
    dismiss_pwa_install_prompt
  end

  def send_message(message)
    fill_in_rich_text_area "message_body", with: message
    click_on "send"
  end

  def within_message(message, &block)
    within "#" + dom_id(message), &block
  end

  def assert_message_text(text, **options)
    assert_selector ".message__body", text: text, **options
  end

  def assert_room_read(room)
    assert_selector ".rooms a", class: "!unread", text: "#{room.name}", wait: 5
  end

  def assert_room_unread(room)
    assert_selector ".rooms a", class: "unread", text: "#{room.name}", wait: 5
  end

  def reveal_message_actions
    find(".message__options-btn").click
    rescue Capybara::ElementNotFound
      find(".message__options-btn", visible: false).hover.click
    ensure
      assert_selector ".message__boost-btn", visible: true
  end

  def dismiss_pwa_install_prompt
    if page.has_css?("[data-pwa-install-target~='dialog']", visible: :visible, wait: 5)
      click_on("Close")
    end
  end
end
