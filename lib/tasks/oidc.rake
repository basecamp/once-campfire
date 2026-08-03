namespace :oidc do
  desc "Check whether required OIDC mode can be activated safely"
  task check: :environment do
    error = Oidc::Activation.new.preflight_error
    abort "OIDC preflight failed: #{error}" if error

    puts "OIDC preflight passed for #{Oidc.issuer}"
  end

  desc "Revoke incompatible sessions and activate required OIDC mode"
  task activate_required: :environment do
    require "io/console"
    password = ENV["OIDC_BREAK_GLASS_PASSWORD"]
    if password.blank? && $stdin.tty?
      $stderr.print "Recovery administrator password: "
      password = $stdin.noecho(&:gets).to_s.chomp
      $stderr.puts
    end
    abort "Set OIDC_BREAK_GLASS_PASSWORD or run this task from an interactive terminal." if password.blank?

    Oidc::Activation.new.activate!(recovery_password: password)
    puts "Required OIDC mode activated; incompatible sessions and unbound push subscriptions were revoked."
  rescue Oidc::Activation::Error => error
    abort "OIDC activation failed: #{error.message}"
  end

  desc "Quarantine credentials for an explicitly storage-compatible rollback target"
  task prepare_rollback: :environment do
    Oidc::Activation.new.prepare_rollback!(confirmation: ENV["CONFIRM"])
    puts "All sessions and push subscriptions were revoked. This does not make older Redis-incompatible releases safe."
  rescue Oidc::Activation::Error => error
    abort "OIDC rollback preparation failed: #{error.message}"
  end

  desc "Cancel rollback preparation so the current OIDC-capable image can be reverified"
  task cancel_rollback: :environment do
    require "io/console"
    password = ENV["OIDC_BREAK_GLASS_PASSWORD"]
    if password.blank? && $stdin.tty?
      $stderr.print "Recovery administrator password: "
      password = $stdin.noecho(&:gets).to_s.chomp
      $stderr.puts
    end
    abort "Set OIDC_BREAK_GLASS_PASSWORD or run this task from an interactive terminal." if password.blank?

    Oidc::Activation.new.cancel_rollback!(confirmation: ENV["CONFIRM"], recovery_password: password)
    puts "Rollback preparation canceled. Complete OIDC verification and activation before restoring traffic."
  rescue Oidc::Activation::Error => error
    abort "OIDC rollback cancellation failed: #{error.message}"
  end


  desc "Remove expired bounded sessions and their push subscriptions"
  task prune_expired_sessions: :environment do
    count = Session.prune_expired!(limit: Integer(ENV.fetch("LIMIT", "1000"), 10))
    puts "Removed #{count} expired sessions."
  end
end
