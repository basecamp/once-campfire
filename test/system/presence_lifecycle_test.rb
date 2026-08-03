require "application_system_test_case"

class PresenceLifecycleTest < ApplicationSystemTestCase
  setup do
    sign_in users(:jz).email_address
    join_room rooms(:designers)
  end

  test "a subscription resolving after disconnect is immediately canceled" do
    result = evaluate_module_script_in_page_realm <<~JAVASCRIPT
        const nextTask = () => new Promise((resolve) => window.setTimeout(resolve, 0));
        const area = document.querySelector("#message-area");
        const identifiers = area.dataset.controller.split(/\s+/).filter((identifier) => identifier !== "presence");
        area.dataset.controller = identifiers.join(" ");
        await nextTask();

        const imports = JSON.parse(document.querySelector("script[type='importmap']").textContent).imports;
        const { cable } = await import(imports["@hotwired/turbo-rails"]);
        const consumer = await cable.getConsumer();
        let callbacks;
        let resolveSubscription;
        let presentEvents = 0;
        let refreshTimers = 0;
        let unsubscribeCalls = 0;
        const setInterval = window.setInterval;
        area.addEventListener("presence:present", () => presentEvents += 1);
        window.setInterval = (callback, delay, ...args) => {
          if (delay === 50000) {
            refreshTimers += 1;
            return 987654321;
          }
          return setInterval(callback, delay, ...args);
        };
        cable.setConsumer({
          subscriptions: {
            create: (_identifier, receivedCallbacks) => {
              callbacks = receivedCallbacks;
              return new Promise((resolve) => resolveSubscription = resolve);
            }
          }
        });

        area.dataset.controller = `${identifiers.join(" ")} presence`;
        while (!resolveSubscription) await nextTask();
        area.dataset.controller = identifiers.join(" ");
        await nextTask();
        resolveSubscription({
          send: () => {},
          unsubscribe: () => unsubscribeCalls += 1
        });
        await nextTask();
        callbacks.connected();
        await nextTask();

        cable.setConsumer(consumer);
        window.setInterval = setInterval;
        return { presentEvents, refreshTimers, unsubscribeCalls };
    JAVASCRIPT

    assert_nil result["error"]
    assert_equal 0, result.fetch("presentEvents")
    assert_equal 0, result.fetch("refreshTimers")
    assert_equal 1, result.fetch("unsubscribeCalls")
  end

  test "disconnect clears a pending return to visible" do
    result = evaluate_module_script_in_page_realm <<~JAVASCRIPT
        const nextTask = () => new Promise((resolve) => window.setTimeout(resolve, 0));
        const area = document.querySelector("#message-area");
        const identifiers = area.dataset.controller.split(/\s+/).filter((identifier) => identifier !== "presence");
        area.dataset.controller = identifiers.join(" ");
        await nextTask();

        const imports = JSON.parse(document.querySelector("script[type='importmap']").textContent).imports;
        const { cable } = await import(imports["@hotwired/turbo-rails"]);
        const consumer = await cable.getConsumer();
        const visibilityDescriptor = Object.getOwnPropertyDescriptor(document, "visibilityState");
        const setTimeout = window.setTimeout;
        const clearTimeout = window.clearTimeout;
        const visibilityTimer = 123456789;
        let callbacks;
        let cleared = false;
        let delayedVisibilityChange;
        let sends = 0;
        const channel = { send: () => sends += 1, unsubscribe: () => {} };
        cable.setConsumer({
          subscriptions: {
            create: (_identifier, receivedCallbacks) => {
              callbacks = receivedCallbacks;
              return channel;
            }
          }
        });
        window.setTimeout = (callback, delay, ...args) => {
          if (delay === 5000) {
            delayedVisibilityChange = callback;
            return visibilityTimer;
          }
          return setTimeout(callback, delay, ...args);
        };
        window.clearTimeout = (timer) => {
          if (timer === visibilityTimer) {
            cleared = true;
          } else {
            clearTimeout(timer);
          }
        };
        Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });

        area.dataset.controller = `${identifiers.join(" ")} presence`;
        while (!callbacks) await nextTask();
        await nextTask();
        callbacks.connected();
        Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
        document.dispatchEvent(new Event("visibilitychange"));
        area.dataset.controller = identifiers.join(" ");
        await nextTask();
        delayedVisibilityChange();

        cable.setConsumer(consumer);
        window.setTimeout = setTimeout;
        window.clearTimeout = clearTimeout;
        if (visibilityDescriptor) {
          Object.defineProperty(document, "visibilityState", visibilityDescriptor);
        } else {
          delete document.visibilityState;
        }
        return { cleared, sends };
    JAVASCRIPT

    assert_nil result["error"]
    assert result.fetch("cleared")
    assert_equal 1, result.fetch("sends")
  end

  test "a hidden initial connection and reconnect immediately become absent without refreshing" do
    result = evaluate_module_script_in_page_realm <<~JAVASCRIPT
        const nextTask = () => new Promise((resolve) => window.setTimeout(resolve, 0));
        const area = document.querySelector("#message-area");
        const identifiers = area.dataset.controller.split(/\s+/).filter((identifier) => identifier !== "presence");
        area.dataset.controller = identifiers.join(" ");
        await nextTask();

        const imports = JSON.parse(document.querySelector("script[type='importmap']").textContent).imports;
        const { cable } = await import(imports["@hotwired/turbo-rails"]);
        const consumer = await cable.getConsumer();
        const visibilityDescriptor = Object.getOwnPropertyDescriptor(document, "visibilityState");
        const setInterval = window.setInterval;
        let callbacks;
        let refreshTimers = 0;
        const sends = [];
        const channel = {
          send: (payload) => sends.push(payload.action),
          unsubscribe: () => {}
        };
        cable.setConsumer({
          subscriptions: {
            create: (_identifier, receivedCallbacks) => {
              callbacks = receivedCallbacks;
              return channel;
            }
          }
        });
        window.setInterval = (callback, delay, ...args) => {
          if (delay === 50000) {
            refreshTimers += 1;
            return 987654321;
          }
          return setInterval(callback, delay, ...args);
        };
        Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });

        area.dataset.controller = `${identifiers.join(" ")} presence`;
        while (!callbacks) await nextTask();
        await nextTask();
        callbacks.connected();
        await nextTask();
        callbacks.disconnected();
        callbacks.connected();
        await nextTask();

        area.dataset.controller = identifiers.join(" ");
        await nextTask();
        cable.setConsumer(consumer);
        window.setInterval = setInterval;
        if (visibilityDescriptor) {
          Object.defineProperty(document, "visibilityState", visibilityDescriptor);
        } else {
          delete document.visibilityState;
        }
        return { sends, refreshTimers };
    JAVASCRIPT

    assert_nil result["error"]
    assert_equal %w[ absent absent ], result.fetch("sends")
    assert_equal 0, result.fetch("refreshTimers")
  end
end
