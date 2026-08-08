# Be sure to restart your server when you modify this file.

# Baseline application-wide Content-Security-Policy, deployed in Report-Only
# mode: browsers evaluate the policy and report violations (once a report
# endpoint is wired up) but enforce nothing, so rendering cannot break.
# Tune the policy against observed violations, then flip
# `content_security_policy_report_only` off to enforce it.
#
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src     :self
    policy.object_src      :none
    policy.base_uri        :self
    policy.frame_ancestors :self
    policy.form_action     :self
    # Specify URI for violation reports once a report sink is available
    # policy.report_uri "/csp-violation-report-endpoint"
  end

  # Report violations without enforcing the policy.
  config.content_security_policy_report_only = true
end
