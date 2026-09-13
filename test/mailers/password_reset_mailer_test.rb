require "test_helper"

class PasswordResetMailerTest < ActionMailer::TestCase
  test "password reset" do
    email = PasswordResetMailer.with(email: "me@campfire.com", url: "http://www.example.com").password_reset_email

    assert_emails 1 do
      email.deliver_now
    end

    assert_equal [ ENV.fetch("SMTP_PASSWORD_RESET_EMAIL_FROM", ApplicationMailer::DEFAULT_BASE_FROM) ], email.from
    assert_equal [ "me@campfire.com" ], email.to
    assert_equal "Campfire Reset Password", email.subject

    # fixtures for mails have to be outside default fixtures directory, since there are no tables in DB for the mails
    assert_equal file_fixture("../../mailers/fixture_templates/password_reset_text_fixture.txt").read, email.text_part.body.to_s
    assert_equal file_fixture("../../mailers/fixture_templates/password_reset_html_fixture.txt").read,  email.html_part.body.to_s
  end
end
