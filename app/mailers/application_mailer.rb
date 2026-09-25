class ApplicationMailer < ActionMailer::Base
  DEFAULT_BASE_FROM="noreply@default.com"

  default from: ENV.fetch("SMTP_INFO_EMAIL_FROM", DEFAULT_BASE_FROM)
  layout "mailer"
end
