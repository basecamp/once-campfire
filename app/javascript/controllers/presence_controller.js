import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"
import { delay, nextFrame } from "helpers/timing_helpers"

const REFRESH_INTERVAL = 50 * 1000 // 50 seconds

// We delay transmitting visibility changes to ignore brief periods of invisibility,
// like switching to another tab and back
const VISIBILITY_CHANGE_DELAY = 5000 // 5 seconds

export default class extends Controller {
  async connect() {
    this.channel = await cable.subscribeTo({ channel: "PresenceChannel", room_id: Current.room.id }, {
      connected: this.#websocketConnected,
      disconnected: this.#websocketDisconnected
    })

    await nextFrame()
    this.dispatch("present", { detail: { roomId: Current.room.id } })
  }

  disconnect() {
    this.#stopRefreshTimer()
    this.channel?.unsubscribe()
  }

  visibilityChanged = () => {
    if (this.#isVisible) {
      this.#visible()
    } else {
      this.#hidden()
    }
  }

  // The server counts every new subscription as present, the one made again after a dropped
  // connection included, so a page that is hidden by then has to say it's absent once more.
  #websocketConnected = () => {
    this.connected = true
    this.wasVisible = true
    this.#startRefreshTimer()

    if (!this.#isVisible) this.#hidden()
  }

  #websocketDisconnected = () => {
    this.connected = false
    this.#stopRefreshTimer()
  }

  #visible = async () => {
    await delay(VISIBILITY_CHANGE_DELAY)

    if (this.connected && this.#isVisible && !this.wasVisible) {
      this.channel.send({ action: "present" })
      this.#startRefreshTimer()
      this.wasVisible = true
    }
  }

  #hidden = async () => {
    await delay(VISIBILITY_CHANGE_DELAY)

    if (this.connected && this.wasVisible && !this.#isVisible) {
      this.#stopRefreshTimer()
      this.channel.send({ action: "absent" })
      this.wasVisible = false
    }
  }

  #startRefreshTimer = () => {
    this.refreshTimer ??= setInterval(this.#refresh, REFRESH_INTERVAL)
  }

  #stopRefreshTimer = () => {
    clearInterval(this.refreshTimer)
    this.refreshTimer = null
  }

  #refresh = () => {
    this.channel.send({ action: "refresh" })
  }

  get #isVisible() {
    return document.visibilityState === "visible"
  }
}
