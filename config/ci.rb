# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"
  step "Code loading: Zeitwerk", "bin/rails zeitwerk:check"
  step "Style: GitHub Actions (actionlint)", "actionlint"
  step "Style: GitHub Actions (zizmor)", "zizmor ."
  step "Policy: Release and container controls", "script/ci/verify-release-policy"
  step "Integrity: Vendored axe-core", "cd test/support/axe && sha256sum --check axe-4.12.1.min.js.sha256"
  step "Accessibility: Manual AT template structure", "ruby test/support/accessibility/verify_manual_at_template.rb"
  step "Syntax: Tracked JavaScript", "script/ci/verify-javascript"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  step "Tests: Rails", "bin/rails test"
  step "Tests: System", "bin/rails test:system"
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"
  step "Tests: OIDC production boundary",
    "env OIDC_MODE=optional OIDC_ISSUER=https://idp.example.com OIDC_CLIENT_ID=campfire " \
      "OIDC_CLIENT_SECRET=local-ci-secret " \
      "OIDC_REDIRECT_URI=https://campfire.example.com/auth/openid_connect/callback " \
      "TLS_DOMAIN=campfire.example.com bin/rails test test/integration/oidc_full_stack_test.rb"
end
