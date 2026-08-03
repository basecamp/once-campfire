require "test_helper"

class Oidc::DocumentationTest < ActiveSupport::TestCase
  test "documents the enforced Thruster and external proxy boundaries" do
    sso_guide = Rails.root.join("docs/sso.md").read
    self_hosting_guide = Rails.root.join("docs/self-hosting.md").read

    assert_includes sso_guide, "Built-in Thruster TLS requires `443`"
    assert_includes sso_guide, "Thruster-prefixed `THRUSTER_TLS_DOMAIN`"
    assert_includes sso_guide, "rejects arbitrary HTTP Host values"
    assert_includes self_hosting_guide,
      "installs that validated host and port as the downstream request authority"
  end
end
