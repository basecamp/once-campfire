import { Controller } from "@hotwired/stimulus"
import { post } from "@rails/request.js"

const SYNCED_SESSION_KEY = "push-subscription-synced-session"

// A password change removes the account's push subscriptions, the one this browser holds included. Post it again
// once per session, so a browser that's still signed in keeps getting notifications. A failure here leaves the
// browser's own subscription alone: the next session tries again.
export default class extends Controller {
  static values = { url: String, session: String }

  async connect() {
    if (this.#allowed && this.sessionValue && localStorage.getItem(SYNCED_SESSION_KEY) !== this.sessionValue) {
      const registration = await navigator.serviceWorker.getRegistration(window.location.origin)
      const subscription = await registration?.pushManager?.getSubscription()

      if (Notification.permission === "granted" && subscription) {
        await post(this.urlValue, { body: this.#payload(subscription), responseKind: "turbo-stream" })
        localStorage.setItem(SYNCED_SESSION_KEY, this.sessionValue)
      }
    }
  }

  get #allowed() {
    return navigator.serviceWorker && window.Notification
  }

  #payload(subscription) {
    const { endpoint, keys: { p256dh, auth } } = subscription.toJSON()
    return JSON.stringify({ push_subscription: { endpoint, p256dh_key: p256dh, auth_key: auth } })
  }
}
