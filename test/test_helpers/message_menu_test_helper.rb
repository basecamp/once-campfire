module MessageMenuTestHelper
  # A room page carries the menu of its messages once, with $messageId$ where the message's id
  # goes. This is the menu as the browser builds it for the message when its menu is first opened.
  def message_menu_for(message)
    template = assert_select("script[type='text/template'][data-messages-target='actionsMenuTemplate']", count: 1).first
    Nokogiri::HTML5.fragment(template.text.gsub("$messageId$", message.id.to_s))
  end
end
