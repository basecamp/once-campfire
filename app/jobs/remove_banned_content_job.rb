class RemoveBannedContentJob < ApplicationJob
  def perform(user)
    user.remove_banned_content
  end
end
