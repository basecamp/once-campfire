class Ban < ApplicationRecord
  belongs_to :user

  validate :ip_address_is_public

  def self.public_ip_address?(value)
    ip = IPAddr.new(value)
    !ip.loopback? && !ip.private? && !ip.link_local?
  rescue IPAddr::InvalidAddressError
    false
  end

  def self.banned?(ip_address)
    exists?(ip_address: ip_address)
  end

  private
    def ip_address_is_public
      errors.add(:ip_address, "cannot be a private or internal IP address") unless self.class.public_ip_address?(ip_address)
    end
end
