require "test_helper"

class ActionText::AttachmentTest < ActiveSupport::TestCase
  setup do
    @user = users(:david)
  end

  test "from_node" do
    html = %Q(<action-text-attachment sgid="#{@user.attachable_sgid}"></action-text-attachment>)
    node = ActionText::Fragment.wrap(html).find_all(ActionText::Attachment.tag_name).first

    attachment = ActionText::Attachment.from_node(node)
    assert_equal @user, attachment.attachable
  end

  test "from_node with a Rails 7 SGID" do
    gid = @user.to_gid.to_s
    marshaled_gid = Base64.urlsafe_encode64(Marshal.dump(gid))
    rails7_payload = { "_rails" => { "message" => marshaled_gid, "exp" => nil, "pur" => "attachable" } }
    rails7_message = Base64.strict_encode64(JSON.generate(rails7_payload))
    rails7_sgid = "#{rails7_message}--invalidsignature"

    html = %Q(<action-text-attachment sgid="#{rails7_sgid}"></action-text-attachment>)
    node = ActionText::Fragment.wrap(html).find_all(ActionText::Attachment.tag_name).first

    attachment = ActionText::Attachment.from_node(node)
    assert_equal @user, attachment.attachable
  end

  test "from_node with an invalid SGID" do
    # A Room is not attachable; mint the sgid an attachable would carry
    # (`ActionText::Attachable#attachable_sgid` is exactly this call).
    sgid = rooms(:pets).to_sgid(expires_in: nil, for: ActionText::Attachable::LOCATOR_NAME).to_s

    html = %Q(<action-text-attachment sgid="#{sgid}invalid"></action-text-attachment>)
    node = ActionText::Fragment.wrap(html).find_all(ActionText::Attachment.tag_name).first

    attachment = ActionText::Attachment.from_node(node)
    assert_kind_of ActionText::Attachables::MissingAttachable, attachment.attachable
  end
end
