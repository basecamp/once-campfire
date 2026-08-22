require "application_system_test_case"

class BrowserContractsTest < ApplicationSystemTestCase
  test "sign in is operable by keyboard and exposes visible focus" do
    visit new_session_url

    assert_selector "input[name='email_address']:focus"
    fill_in "email_address", with: users(:jz).email_address
    find("input[name='email_address']").send_keys(:tab)
    unless page.has_css?("input[name='password']:focus", wait: 0.5)
      assert_selector "summary:focus"
      find("summary:focus").send_keys(:tab)
    end

    assert_selector "input[name='password']:focus"
    assert page.evaluate_script("document.activeElement.matches(':focus-visible')")
    focus_style = page.evaluate_script <<~JAVASCRIPT
      (() => {
        const indicator = document.activeElement.closest(".input--actor");
        return { boxShadow: getComputedStyle(indicator).boxShadow };
      })()
    JAVASCRIPT
    assert_not_equal "none", focus_style.fetch("boxShadow")

    find("input[name='password']").send_keys("secret123456", :enter)
    assert_selector "meta[name='current-user-id']", visible: false, wait: 10
  end

  test "forced colors preserves keyboard focus evidence" do
    emulate_media "forced-colors" => "active"
    visit new_session_url
    fill_in "email_address", with: users(:jz).email_address
    find("input[name='email_address']").send_keys(:tab)

    assert page.evaluate_script("matchMedia('(forced-colors: active)').matches")
    focus_style = page.evaluate_script <<~JAVASCRIPT
      (() => {
        const style = getComputedStyle(document.activeElement);
        return {
          color: style.outlineColor,
          style: style.outlineStyle,
          width: parseFloat(style.outlineWidth)
        };
      })()
    JAVASCRIPT
    assert_operator focus_style.fetch("width"), :>, 0
    assert_not_equal "none", focus_style.fetch("style")
    assert_not_equal "rgba(0, 0, 0, 0)", focus_style.fetch("color")
  end

  test "mobile emulation exposes its viewport touch input and usable composer targets" do
    skip "Chrome mobile emulation contract" unless mobile_emulation?

    sign_in users(:jz).email_address
    join_room rooms(:designers)

    contract = page.evaluate_script <<~JAVASCRIPT
      (() => {
        const targets = Array.from(document.querySelectorAll(
          ".composer :is(a, button, label.btn)"
        )).filter((element) => element.getClientRects().length > 0).map((element) => {
          const rect = element.getBoundingClientRect();
          return {
            name: element.innerText.trim() || element.getAttribute("aria-label") || element.className,
            width: rect.width,
            height: rect.height,
            touchAction: getComputedStyle(element).touchAction
          };
        });
        const composer = document.querySelector(".composer").getBoundingClientRect();

        return {
          coarsePointer: matchMedia("(pointer: coarse)").matches,
          devicePixelRatio: window.devicePixelRatio,
          maxTouchPoints: navigator.maxTouchPoints,
          viewportMeta: document.querySelector("meta[name=viewport]").content,
          viewportWidth: window.innerWidth,
          visualViewportWidth: window.visualViewport?.width,
          documentWidth: document.documentElement.scrollWidth,
          composerLeft: composer.left,
          composerRight: composer.right,
          targets
        };
      })()
    JAVASCRIPT

    assert_equal 390, contract.fetch("viewportWidth")
    assert_in_delta 390, contract.fetch("visualViewportWidth"), 1
    assert_equal 3, contract.fetch("devicePixelRatio")
    assert contract.fetch("coarsePointer")
    assert_operator contract.fetch("maxTouchPoints"), :>, 0
    assert_includes contract.fetch("viewportMeta"), "width=device-width"
    assert_operator contract.fetch("documentWidth"), :<=, contract.fetch("viewportWidth") + 1
    assert_operator contract.fetch("composerLeft"), :>=, -1
    assert_operator contract.fetch("composerRight"), :<=, contract.fetch("viewportWidth") + 1
    assert_predicate contract.fetch("targets"), :present?

    contract.fetch("targets").each do |target|
      assert_operator target.fetch("width"), :>=, 24, "#{target.fetch("name")} is too narrow"
      assert_operator target.fetch("height"), :>=, 24, "#{target.fetch("name")} is too short"
      assert_equal "manipulation", target.fetch("touchAction"), target.fetch("name")
    end
  end

  test "web manifest and service worker satisfy the installability contract" do
    visit new_session_url

    pwa = page.evaluate_async_script <<~JAVASCRIPT
      const done = arguments[0];
      (async () => {
        let registration;
        try {
          const manifestLink = document.querySelector("link[rel=manifest]");
          const manifestResponse = await fetch(manifestLink.href);
          const manifest = await manifestResponse.json();
          if (!("serviceWorker" in navigator)) throw new Error("Service workers are unavailable");

          registration = await navigator.serviceWorker.register("/service-worker.js");
          const ready = await Promise.race([
            navigator.serviceWorker.ready,
            new Promise((_, reject) => setTimeout(
              () => reject(new Error("Service worker activation timed out")), 10000
            ))
          ]);
          if (ready.active.state !== "activated") {
            await Promise.race([
              new Promise((resolve) => ready.active.addEventListener("statechange", () => {
                if (ready.active.state === "activated") resolve();
              })),
              new Promise((_, reject) => setTimeout(
                () => reject(new Error("Service worker did not reach activated state")), 10000
              ))
            ]);
          }

          return {
            manifest,
            manifestContentType: manifestResponse.headers.get("Content-Type"),
            scopePath: new URL(ready.scope).pathname,
            scriptPath: new URL(ready.active.scriptURL).pathname,
            state: ready.active.state
          };
        } finally {
          await registration?.unregister();
        }
      })().then((result) => done({ result }), (error) => done({ error: error.stack || error.message }));
    JAVASCRIPT

    flunk pwa.fetch("error") if pwa["error"]

    result = pwa.fetch("result")
    manifest = result.fetch("manifest")
    assert_includes result.fetch("manifestContentType"), "application/json"
    assert_equal "/", manifest.fetch("start_url")
    assert_equal "/", manifest.fetch("scope")
    assert_equal "standalone", manifest.fetch("display")
    assert manifest.fetch("icons").any? { |icon| icon["sizes"] == "192x192" }
    assert manifest.fetch("icons").any? { |icon| icon["sizes"] == "512x512" }
    assert manifest.fetch("icons").any? { |icon| icon["purpose"] == "maskable" }
    assert_equal "/", result.fetch("scopePath")
    assert_equal "/service-worker.js", result.fetch("scriptPath")
    assert_equal "activated", result.fetch("state")
  end
end
