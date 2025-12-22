# Preview all emails at http://localhost:3000/rails/mailers/password_mailer
class PasswordResetMailerPreview < ActionMailer::Preview
  def reset_password_email
    PasswordResetMailer.with(user: "test@test.com", url: "http://localhost:3000").password_reset_email
  end
end
