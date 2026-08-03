require "test_helper"
require "json"
require "rbconfig"
require "campfire_backup/subprocess"

class CampfireBackup::SubprocessTest < ActiveSupport::TestCase
  test "backup helper subprocesses inherit only command and locale environment" do
    secrets = {
      "BACKUP_AUTHENTICATION_KEY" => "backup-secret",
      "BACKUP_ENCRYPTION_KEY" => "encryption-secret",
      "BACKUP_ENCRYPTION_KEY_ID" => "encryption-key-id",
      "BACKUP_ENCRYPTION_PREVIOUS_KEYS" => "retired-encryption-secrets",
      "SECRET_KEY_BASE" => "application-secret",
      "OIDC_CLIENT_SECRET" => "oidc-secret",
      "VAPID_PRIVATE_KEY" => "push-secret",
      "DATABASE_URL" => "database-secret"
    }
    previous = (secrets.keys + [ "LANG" ]).to_h { [ _1, ENV[_1] ] }
    secrets.each { ENV[_1] = _2 }
    ENV["LANG"] = "C"
    command = [
      RbConfig.ruby, "-rjson", "-e", "STDOUT.write(JSON.generate(ENV.to_h))"
    ]

    %i[ capture2 capture3 ].each do |capture|
      result = CampfireBackup::Subprocess.public_send(capture, *command)
      stdout, status = capture == :capture2 ? result : [ result.fetch(0), result.fetch(2) ]
      child_environment = JSON.parse(stdout)

      assert_predicate status, :success?
      assert_equal "C", child_environment.fetch("LANG")
      assert_equal ENV.fetch("PATH"), child_environment.fetch("PATH")
      assert_empty child_environment.keys & secrets.keys
    end
  ensure
    previous&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end
end
