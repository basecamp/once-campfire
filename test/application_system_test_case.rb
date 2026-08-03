require "test_helper"
require "securerandom"

WebMock.disable!

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  SYSTEM_TEST_BROWSER = ENV.fetch("SYSTEM_TEST_BROWSER", "headless_chrome")
  DESKTOP_SCREEN_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SCREEN_SIZE = [ 390, 844 ].freeze

  case SYSTEM_TEST_BROWSER
  when "headless_chrome"
    driven_by :selenium, using: :headless_chrome, screen_size: DESKTOP_SCREEN_SIZE,
      options: { name: :selenium_headless_chrome }
  when "headless_firefox"
    driven_by :selenium, using: :headless_firefox, screen_size: DESKTOP_SCREEN_SIZE,
      options: { name: :selenium_headless_firefox } do |options|
        options.web_socket_url = true
      end
  when "safari"
    driven_by :selenium, using: :safari, screen_size: DESKTOP_SCREEN_SIZE,
      options: { name: :selenium_safari }
  when "headless_chrome_mobile"
    driven_by :selenium, using: :headless_chrome, screen_size: MOBILE_SCREEN_SIZE,
      options: { name: :selenium_headless_chrome_mobile } do |options|
        options.add_emulation(
          device_metrics: { width: 390, height: 844, pixel_ratio: 3, touch: true, mobile: true },
          user_agent: "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 " \
            "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        )
      end
  else
    raise ArgumentError, "Unsupported SYSTEM_TEST_BROWSER=#{SYSTEM_TEST_BROWSER.inspect}; " \
      "expected headless_chrome, headless_firefox, safari, or headless_chrome_mobile"
  end

  include AccessibilityTestHelper, SystemTestHelper

  def after_teardown
    clear_emulated_media

    Array(@new_document_scripts).reverse_each do |transport, identifier|
      case transport
      when :cdp
        page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier:)
      when :bidi
        page.driver.browser.bidi.send_cmd("script.removePreloadScript", script: identifier)
      end
    end
  ensure
    super
  end

  private
    def install_new_document_script(source)
      script = case SYSTEM_TEST_BROWSER
      when "headless_chrome", "headless_chrome_mobile"
        result = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source:)
        [ :cdp, result.fetch("identifier") ]
      when "headless_firefox"
        result = page.driver.browser.bidi.send_cmd(
          "script.addPreloadScript", functionDeclaration: "() => {\n#{source}\n}"
        )
        [ :bidi, result.fetch("script") ]
      else
        raise NotImplementedError, "preload scripts are not available with #{SYSTEM_TEST_BROWSER}"
      end

      (@new_document_scripts ||= []) << script
    end

    def execute_script_in_page_realm(source)
      page.execute_script <<~JAVASCRIPT, source
        const script = document.createElement("script");
        script.textContent = arguments[0];
        document.documentElement.append(script);
        script.remove();
      JAVASCRIPT
    end

    def evaluate_module_script_in_page_realm(source, wait: 10)
      token = SecureRandom.hex(8)
      result_attribute = "data-system-test-result-#{token}"
      script_id = "system-test-module-#{token}"
      page.execute_script <<~JAVASCRIPT, source, result_attribute, script_id
        const source = arguments[0];
        const resultAttribute = arguments[1];
        const script = document.createElement("script");
        script.type = "module";
        script.id = arguments[2];
        script.textContent = [
          "(async () => {",
          "try {",
          "const value = await (async () => {",
          source,
          "})();",
          `document.documentElement.setAttribute(${JSON.stringify(resultAttribute)}, JSON.stringify({ value: value ?? null }));`,
          "} catch (error) {",
          "const detail = error && (error.stack || error.message) || String(error);",
          `document.documentElement.setAttribute(${JSON.stringify(resultAttribute)}, JSON.stringify({ error: String(detail) }));`,
          "}",
          "})();"
        ].join("\\n");
        document.documentElement.append(script);
      JAVASCRIPT

      unless page.has_css?("html[#{result_attribute}]", visible: false, wait:)
        raise "Page-realm module script did not finish within #{wait} seconds"
      end

      payload = JSON.parse(page.evaluate_script(
        "document.documentElement.getAttribute(#{result_attribute.to_json})"
      ))
      raise payload.fetch("error") if payload.key?("error")

      payload["value"]
    ensure
      if result_attribute && script_id
        page.execute_script <<~JAVASCRIPT
          document.documentElement.removeAttribute(#{result_attribute.to_json});
          document.getElementById(#{script_id.to_json})?.remove();
        JAVASCRIPT
      end
    end

    def emulate_media(features)
      skip "deterministic media emulation is only available in Chrome" unless chrome?

      page.driver.browser.execute_cdp(
        "Emulation.setEmulatedMedia",
        features: features.map { |name, value| { name:, value: } }
      )
      @media_emulated = true
    end

    def clear_emulated_media
      return unless @media_emulated

      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
      @media_emulated = false
    end

    def chrome?
      SYSTEM_TEST_BROWSER.in?(%w[ headless_chrome headless_chrome_mobile ])
    end

    def mobile_emulation?
      SYSTEM_TEST_BROWSER == "headless_chrome_mobile"
    end
end
