require "test_helper"

class ApplicationInteractionTestCase < RailsJsdom::TestCase
  include SystemTestHelper
  include RichTextEditorHelper

  def assert_room_read(room)
    assert_selector ".rooms a:not(.unread)", text: room.name
  end

  def assert_room_unread(room)
    assert_selector ".rooms a.unread", text: room.name
  end

  def dismiss_pwa_install_prompt
    click_on "Close" if has_css?("[data-pwa-install-target~='dialog']")
  end
end
