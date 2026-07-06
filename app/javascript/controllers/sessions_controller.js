import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "pushSubscriptionEndpoint" ]

  async logout(event) {
    await this.#unsubscribeFromWebPush()
    this.element.requestSubmit()
  }

  async #unsubscribeFromWebPush() {
    if ("serviceWorker" in navigator) {
      const registration = await navigator.serviceWorker.getRegistration(window.location.origin)

      if (registration) {
        const subscription = await registration.pushManager.getSubscription()

        if (subscription) {
          this.pushSubscriptionEndpointTarget.value = subscription.endpoint
          await subscription.unsubscribe()
        }
      }
    }
  }
}
