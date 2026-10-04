class BotActionSelection < ApplicationRecord
  belongs_to :message
  belongs_to :user

  validates :values, length: { maximum: Message::MAX_BOT_ACTIONS }
end
