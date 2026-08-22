require "digest"
require "json"

module AccessibilityTestHelper
  AXE_CORE_PATH = Rails.root.join("test/support/axe/axe-4.12.1.min.js")
  AXE_CORE_SHA256 = "66a8aaa95a8b044a7fd74a5435873bf04ff65a1ca75567c921b7509742085a14"
  WCAG_TAGS = %w[ wcag2a wcag2aa wcag21a wcag21aa wcag22a wcag22aa ].freeze

  def assert_no_serious_accessibility_violations(context: nil)
    axe_source = AXE_CORE_PATH.binread
    assert_equal AXE_CORE_SHA256, Digest::SHA256.hexdigest(axe_source),
      "Vendored axe-core checksum mismatch: #{AXE_CORE_PATH}"
    axe_source.force_encoding(Encoding::UTF_8)

    page.execute_script(axe_source)
    result = page.evaluate_async_script <<~JAVASCRIPT
      const done = arguments[0];
      const selector = #{context.to_json};
      const root = selector ? document.querySelector(selector) : document;

      if (!root) {
        done({ error: `Accessibility audit context not found: ${selector}` });
      } else {
        axe.run(root, {
          resultTypes: ["violations"],
          runOnly: { type: "tag", values: #{WCAG_TAGS.to_json} }
        }).then(({ violations }) => {
          done({
            violations: violations
              .filter(({ impact }) => ["serious", "critical"].includes(impact))
              .map(({ id, impact, help, helpUrl, nodes }) => ({
                id, impact, help, helpUrl,
                nodes: nodes.map(({ target, html, failureSummary }) => ({ target, html, failureSummary }))
              }))
          });
        }, (error) => done({ error: error.stack || error.message }));
      }
    JAVASCRIPT

    flunk result.fetch("error") if result["error"]

    violations = result.fetch("violations")
    assert_empty violations, format_accessibility_violations(violations)
  end

  private
    def format_accessibility_violations(violations)
      return "No serious or critical WCAG violations" if violations.empty?

      violations.flat_map do |violation|
        header = "#{violation.fetch("impact").upcase}: #{violation.fetch("id")} - " \
          "#{violation.fetch("help")} (#{violation.fetch("helpUrl")})"
        nodes = violation.fetch("nodes").map do |node|
          "  #{node.fetch("target").join(" ")}\n" \
            "    #{node.fetch("failureSummary")}\n" \
            "    #{node.fetch("html")}"
        end
        [ header, *nodes ]
      end.join("\n")
    end
end
