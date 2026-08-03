require "campfire_backup/installation_identity"

class Account < ApplicationRecord
  include Joinable

  belongs_to :oidc_break_glass_user, class_name: "User", optional: true

  before_validation :set_installation_identifier, on: :create

  validates :installation_identifier, presence: true, uniqueness: true,
    format: { with: CampfireBackup::InstallationIdentity::PATTERN }
  validate :preserve_installation_identifier, on: :update

  has_one_attached :logo do |attachable|
    attachable.variant :large, resize_to_limit: [ 512, 512 ], format: :png
    attachable.variant :small, resize_to_limit: [ 192, 192 ], format: :png
  end

  has_json :settings, restrict_room_creation_to_administrators: false

  def logo_variant(size)
    logo.variant(size).processed if logo.variable?
  end

  def update_with_staged_logo!(attributes, actor:)
    attributes = attributes.to_h.symbolize_keys
    upload = attributes.delete(:logo)

    StagedUpload.with(upload) do |blob|
      transaction do
        User.lock_administrator! actor
        account = self.class.lock.find(id)
        account.update!(attributes)
        StagedUpload.attach! account.logo, blob if blob
      end
    end
    reload
  end

  def remove_logo!(actor:)
    transaction do
      User.lock_administrator! actor
      self.class.lock.find(id).logo.attachment&.destroy!
    end
    reload
  end

  def update_custom_styles!(attributes, actor:)
    transaction do
      User.lock_administrator! actor
      self.class.lock.find(id).update!(attributes)
    end
    reload
  end

  private
    def set_installation_identifier
      self.installation_identifier ||= CampfireBackup::InstallationIdentity.generate
    end

    def preserve_installation_identifier
      errors.add :installation_identifier, "cannot be changed" if will_save_change_to_installation_identifier?
    end
end
