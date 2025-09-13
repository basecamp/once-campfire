class Current < ActiveSupport::CurrentAttributes
  attribute :user, :request, :importing

  delegate :host, :protocol, to: :request, prefix: true, allow_nil: true

  def account
    Account.first
  end
end
