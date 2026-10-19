require "test_helper"

class ResetPasswordScriptTest < ActiveSupport::TestCase
  test "resets a password without the current one and signs out every session" do
    assert_output "Password has been reset\n" do
      run_script "david@37signals.com", "a new secret123456"
    end

    assert users(:david).reload.authenticate("a new secret123456")
    assert_empty users(:david).sessions
  end

  private
    def run_script(*arguments)
      original_arguments = ARGV.dup
      ARGV.replace(arguments)
      load Rails.root.join("script/admin/reset-password").to_s
    ensure
      ARGV.replace(original_arguments)
    end
end
