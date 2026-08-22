import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "pushSubscriptionEndpoint" ]

  async logout(event) {
    try {
      await Promise.race([ this.#unsubscribeFromWebPush(), this.#timeout(2000) ])
    } finally {
      this.element.requestSubmit()
    }
  }

  async #unsubscribeFromWebPush() {
    if ("serviceWorker" in navigator) {
      const registration = await navigator.serviceWorker.getRegistration(window.location.origin)

      if (registration) {
        const notifications = registration.getNotifications ? await registration.getNotifications() : []
        notifications.forEach(notification => notification.close())
        const subscription = await registration.pushManager.getSubscription()

        if (subscription) {
          this.pushSubscriptionEndpointTarget.value = subscription.endpoint
          await subscription.unsubscribe()
        }
      }
    }
    if (navigator.clearAppBadge) await navigator.clearAppBadge()
  }

  #timeout(milliseconds) {
    return new Promise(resolve => setTimeout(resolve, milliseconds))
  }
}
