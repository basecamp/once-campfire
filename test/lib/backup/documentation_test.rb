require "test_helper"

class BackupDocumentationTest < ActiveSupport::TestCase
  test "ONCE and legacy Redis recovery limits are explicit" do
    readme = Rails.root.join("README.md").read
    guide = Rails.root.join("docs/self-hosting.md").read

    assert_includes readme, "Do not enable ONCE automatic updates"
    assert_not_includes readme, "keep your instance up to date automatically"
    assert_includes guide, "the old runtime holds Campfire's target-local exclusive operation"
    assert_includes guide, "configured Redis with `appendonly no`"
    assert_includes guide, "cannot prove recovery of pre-stop ephemeral Redis state"
    assert_includes guide, "single-threaded scripts"
    assert_includes guide, "remains mode `000`"
    assert_includes guide, "canonical physical"
  end
end
