import { Controller } from "@hotwired/stimulus"
import { get } from "@rails/request.js"
import { cable } from "@hotwired/turbo-rails"
import { pageIsTurboPreview } from "helpers/turbo_helpers"

const OFFLINE_AFTER_DISCONNECTED_TIMEOUT = 5_000
const REFRESH_AFTER_HIDDEN_TIMEOUT = 60_000

export default class extends Controller {
  static targets = [ "message" ]
  static values = { loadedAt: Number, url: String, }

  #lastLoadedAt
  #connected = false
  #offlineTimer = null
  #hiddenAt = null

  async connect() {
    if (!pageIsTurboPreview()) {
      this.#lastLoadedAt = this.loadedAtValue
      this.#channelDisconnected()

      this.channel = await cable.subscribeTo({ channel: "HeartbeatChannel" }, {
        connected: this.#channelConnected.bind(this),
        disconnected: this.#channelDisconnected.bind(this)
      })
    }
  }

  disconnect() {
    this.channel?.unsubscribe()
  }

  // Only a message that arrives while connected moves where the next refresh starts. One that arrives while
  // disconnected, like the answer to a message sent then, can be newer than others missed meanwhile.
  messageTargetConnected(target) {
    if (this.#connected) {
      this.#lastLoadedAt = Math.max(this.#lastLoadedAt, target.dataset.messageUpdatedAt || 0)
    }
  }

  visibilityChanged() {
    if (document.visibilityState === "visible") {
      if (this.#hiddenForTooLong()) {
        this.#refresh("visibility")
        this.dispatch("visible")
      }
      this.#hiddenAt = null
    } else {
      this.#hiddenAt = Date.now()
    }
  }

  online() {
    // Trigger reconnection attempt whenever the browser comes back
    // from being offline
    this.channel.consumer.connection.monitor.visibilityDidChange()
  }

  #channelConnected() {
    this.#connected = true
    this.#refresh("connection")

    clearTimeout(this.#offlineTimer)
    this.dispatch("online", { target: window })
  }

  #channelDisconnected() {
    this.#offlineTimer = setTimeout(() => {
      this.dispatch("offline", { target: window })
    }, OFFLINE_AFTER_DISCONNECTED_TIMEOUT)

    this.#connected = false
  }

  #refresh(reason) {
    get(this.urlValue, { query: { since: this.#lastLoadedAt, reason: reason }, responseKind: "turbo-stream" })
  }

  #hiddenForTooLong() {
    return this.#hiddenAt && Date.now() - this.#hiddenAt > REFRESH_AFTER_HIDDEN_TIMEOUT
  }
}
