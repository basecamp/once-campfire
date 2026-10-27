require "application_system_test_case"

class CustomStylesXssTest < ApplicationSystemTestCase
  # A stored payload that breaks out of an inline <style> context and executes
  # as HTML. Rendered inline (the old behavior) this <script> runs and sets the
  # flag; delivered as an external text/css stylesheet it is inert text.
  PAYLOAD = %(</style><script>window.__xss_fired = true</script>)

  setup do
    accounts(:signal).update!(custom_styles: PAYLOAD)
    sign_in "jz@37signals.com"
  end

  test "custom styles payload loads as a stylesheet and never executes" do
    # Navigate to the page under test explicitly (matching the writebook
    # sibling) rather than leaning on the post-login landing page — otherwise
    # this coverage could silently evaporate if that landing changes.
    visit root_url

    # (a) custom styles arrive via an external stylesheet link, not inline markup
    assert_selector "link[rel='stylesheet'][href*='custom_styles']", visible: false

    # (b) the payload's <script> never executed — no breakout from CSS context
    assert_nil evaluate_script("window.__xss_fired")

    # (b') and it injected no live <script> element into the document
    assert_no_selector "script", text: "__xss_fired", visible: false

    # (c) the browser fetched the payload verbatim as text/css, so it is styled,
    #     never parsed as HTML
    fetched = page.evaluate_async_script(<<~JS)
      var done = arguments[arguments.length - 1];
      var href = document.querySelector("link[rel='stylesheet'][href*='custom_styles']").href;
      fetch(href).then(function(r) {
        return r.text().then(function(body) {
          done({ type: r.headers.get("content-type"), body: body });
        });
      });
    JS

    assert_includes fetched["type"], "text/css"
    assert_includes fetched["body"], PAYLOAD
  end
end
