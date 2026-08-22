import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "form", "status", "token" ]

  connect() {
    const token = new URLSearchParams(window.location.hash.slice(1)).get("token")
    if (!token) {
      this.statusTarget.textContent = "This private link is missing its code. Paste the code to continue."
      return
    }

    history.replaceState(history.state, "", `${window.location.pathname}${window.location.search}`)
    this.tokenTarget.value = token
    this.statusTarget.textContent = "Verifying the private link..."
    this.formTarget.requestSubmit()
  }
}
