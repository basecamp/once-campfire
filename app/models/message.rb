require "uri"

class Message < ApplicationRecord
  BOT_ACTION_STYLES = %w[ default primary danger ].freeze
  BOT_ACTION_ICON_POSITIONS = %w[ left right ].freeze
  BOT_ACTION_ICONS = %w[
    add alert arrow-down arrow-left arrow-right arrow-up attachment bot camera cancel check download
    globe help help-circle link lock messages notification-bell-alert pencil person refresh reply search
    settings share trash web
  ].freeze
  BOT_ACTION_SELECTION_MODES = %w[ none single multiple ].freeze
  UNSAFE_BOT_ACTION_URL_SCHEMES = %w[ data file javascript vbscript ].freeze
  MAX_BOT_ACTIONS = 12
  MAX_BOT_ACTION_LABEL_LENGTH = 40
  MAX_BOT_ACTION_VALUE_LENGTH = 200
  MAX_BOT_ACTION_URL_LENGTH = 2048
  BOT_ACTION_COLOR_PATTERN = /\A#[0-9a-f]{3}(?:[0-9a-f]{3})?\z/i

  include Attachment, Broadcasts, Mentionee, Pagination, Searchable

  belongs_to :room, touch: true
  belongs_to :creator, class_name: "User", default: -> { Current.user }

  has_many :boosts, dependent: :destroy
  has_many :bot_action_selections, dependent: :destroy

  has_rich_text :body

  validate :bot_actions_are_valid, :bot_value_actions_have_a_webhook
  validates :bot_action_selection_mode, inclusion: { in: BOT_ACTION_SELECTION_MODES }

  before_create -> { self.client_message_id ||= Random.uuid } # Bots don't care
  after_create_commit -> { room.receive(self) }
  after_update :clear_bot_action_selections_if_configuration_changed

  scope :ordered, -> { order(:created_at) }
  scope :with_creator, -> { preload(creator: %i[ avatar_attachment webhook ]) }
  scope :with_attachment_details, -> {
    with_rich_text_body_and_embeds
    with_attached_attachment
      .includes(attachment_blob: :variant_records)
  }
  scope :with_boosts, -> { includes(boosts: :booster) }

  def plain_text_body
    body.to_plain_text.presence || attachment&.filename&.to_s || ""
  end

  def to_key
    [ client_message_id ]
  end

  def content_type
    case
    when attachment?    then "attachment"
    when sound.present? then "sound"
    else                     "text"
    end.inquiry
  end

  def sound
    plain_text_body.match(/\A\/play (?<name>\w+)\z/) do |match|
      Sound.find_by_name match[:name]
    end
  end

  def bot_action_with_value(value)
    bot_actions.find { |action| action["value"] == value }
  end

  private
    def bot_actions_are_valid
      unless bot_actions.is_a?(Array) && bot_actions.size <= MAX_BOT_ACTIONS
        errors.add :bot_actions, "must contain at most #{MAX_BOT_ACTIONS} actions"
        return
      end

      bot_actions.each do |action|
        unless valid_bot_action?(action)
          errors.add :bot_actions, "contains an invalid action"
          break
        end
      end

      values = bot_actions.filter_map { |action| action["value"] if action.is_a?(Hash) }
      errors.add :bot_actions, "must contain unique values" unless values.uniq.size == values.size
    end

    def bot_value_actions_have_a_webhook
      if creator&.bot? && bot_actions.any? { |action| action.is_a?(Hash) && action["value"].present? } && creator.webhook.blank?
        errors.add :bot_actions, "with values require the bot to have a webhook"
      end
    end

    def clear_bot_action_selections_if_configuration_changed
      if saved_change_to_bot_action_selection_mode? || bot_action_values_changed?
        bot_action_selections.delete_all
      end
    end

    def bot_action_values_changed?
      return false unless saved_change_to_bot_actions?

      before, after = saved_change_to_bot_actions
      bot_action_values(before) != bot_action_values(after)
    end

    def bot_action_values(actions)
      actions.filter_map { |action| action["value"] if action.is_a?(Hash) }
    end

    def valid_bot_action?(action)
      action.is_a?(Hash) &&
        action["label"].is_a?(String) && action["label"].present? && action["label"].length <= MAX_BOT_ACTION_LABEL_LENGTH &&
        valid_bot_action_destination?(action) &&
        (action["style"].blank? || action["style"].in?(BOT_ACTION_STYLES)) &&
        (action["background_color"].blank? || action["background_color"].is_a?(String) && action["background_color"].match?(BOT_ACTION_COLOR_PATTERN)) &&
        (action["text_color"].blank? || action["background_color"].present? && action["text_color"].is_a?(String) && action["text_color"].match?(BOT_ACTION_COLOR_PATTERN)) &&
        [ nil, false, true ].include?(action["icon_only"]) &&
        [ nil, false, true ].include?(action["disabled"]) &&
        (!action["icon_only"] || action["icon"].present? || action["emoji"].present?) &&
        valid_bot_action_adornment?(action)
    end

    def valid_bot_action_adornment?(action)
      return false if action["icon"].present? && action["emoji"].present?
      return action["icon_position"].blank? if action["icon"].blank? && action["emoji"].blank?

      (action["icon"].blank? || action["icon"].in?(BOT_ACTION_ICONS)) &&
        (action["emoji"].blank? || valid_bot_action_emoji?(action["emoji"])) &&
        (action["icon_position"].blank? || action["icon_position"].in?(BOT_ACTION_ICON_POSITIONS))
    end

    def valid_bot_action_emoji?(emoji)
      emoji.is_a?(String) && emoji.scan(/\X/).one? && (
        emoji.match?(/\p{Extended_Pictographic}/) ||
        emoji.match?(/\A\p{Regional_Indicator}{2}\z/) ||
        emoji.match?(/\A[#*0-9]\uFE0F?\u20E3\z/)
      )
    end

    def valid_bot_action_destination?(action)
      if action["url"].present?
        action["value"].blank? && valid_bot_action_url?(action["url"])
      else
        action["value"].is_a?(String) && action["value"].present? && action["value"].length <= MAX_BOT_ACTION_VALUE_LENGTH
      end
    end

    def valid_bot_action_url?(url)
      url.is_a?(String) && url.length <= MAX_BOT_ACTION_URL_LENGTH && URI.parse(url).then do |uri|
        uri.scheme.present? && !uri.scheme.in?(UNSAFE_BOT_ACTION_URL_SCHEMES) &&
          (!uri.scheme.in?(%w[ http https ]) || uri.host.present? && uri.userinfo.blank?)
      end
    rescue URI::InvalidURIError
      false
    end
end
