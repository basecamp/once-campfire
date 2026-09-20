require "test_helper"

class ActionTextAttachmentTest < ActiveSupport::TestCase
  setup do
    @user = users(:david)
  end

  test "lookup user attachable with invalid sgid" do
    message, signature = @user.attachable_sgid.split("--")

    html = %Q(<action-text-attachment sgid="#{message}--invalid"></action-text-attachment>)
    node = ActionText::Fragment.wrap(html).find_all(ActionText::Attachment.tag_name).first

    attachment = ActionText::Attachment.from_node(node)
    assert_equal @user, attachment.attachable
  end

  test "lookup attachable with nil sgid" do
    html = %Q(<action-text-attachment></action-text-attachment>)
    node = ActionText::Fragment.wrap(html).find_all(ActionText::Attachment.tag_name).first

    attachment = ActionText::Attachment.from_node(node)
    assert_kind_of ActionText::Attachables::MissingAttachable, attachment.attachable
  end

  test "lookup invalid sgid for an attachable requiring a valid sgid" do
    # A Room is not attachable; mint the sgid an attachable would carry
    # (`ActionText::Attachable#attachable_sgid` is exactly this call) so
    # the lookup is exercised on a signature that does not verify.
    message, signature = rooms(:pets).to_sgid(expires_in: nil, for: ActionText::Attachable::LOCATOR_NAME).to_s.split("--")

    html = %Q(<action-text-attachment sgid="#{message}--invalid"></action-text-attachment>)
    node = ActionText::Fragment.wrap(html).find_all(ActionText::Attachment.tag_name).first

    attachment = ActionText::Attachment.from_node(node)
    assert_kind_of ActionText::Attachables::MissingAttachable, attachment.attachable
  end
end
