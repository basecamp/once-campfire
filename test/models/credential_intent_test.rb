require "test_helper"

class CredentialIntentTest < ActiveSupport::TestCase
  test "transfer grants and browser intents are each consumed once" do
    grant = CredentialIntent.issue_transfer_grant!(users(:david), expires_in: 1.hour)
    browser_intent = CredentialIntent.exchange_transfer!(grant)

    assert_raises(CredentialIntent::Invalid) { CredentialIntent.exchange_transfer!(grant) }
    assert_equal users(:david), CredentialIntent.consume_transfer!(browser_intent) { _1 }
    assert_raises(CredentialIntent::Invalid) { CredentialIntent.consume_transfer!(browser_intent) { _1 } }
  end

  test "join-code rotation invalidates an issued browser intent" do
    account = accounts(:signal)
    browser_intent = CredentialIntent.issue_join!(account.join_code)
    account.update!(join_code: "rotated-code")

    assert_not CredentialIntent.valid_join?(browser_intent, account: account)
    assert_raises(CredentialIntent::Invalid) do
      CredentialIntent.consume_join!(browser_intent, account:) { flunk "invalid intent was consumed" }
    end
  end

  test "stored records contain only digests" do
    raw = CredentialIntent.issue_transfer_grant!(users(:david), expires_in: 1.hour)
    intent = CredentialIntent.find_by!(purpose: "transfer_grant")

    assert_not_equal raw, intent.token_digest
    assert_no_match(/#{Regexp.escape(raw)}/, intent.attributes.to_json)
  end
end
