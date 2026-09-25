class PasswordResetMailer < ApplicationMailer
  default from: ENV.fetch("SMTP_PASSWORD_RESET_EMAIL_FROM", DEFAULT_BASE_FROM)

  def password_reset_email
    @email = params[:email]
    @url  = params[:url]
    mail(to: @email, subject: "Campfire Reset Password")
  end
end
