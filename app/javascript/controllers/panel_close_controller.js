import { Controller } from "@hotwired/stimulus"

// Closes panels by triggering the existing back button when clicking outside
// the panel area. This preserves the exact same navigation and animations.
export default class extends Controller {
  connect() {
    this.onClick = this.onClick.bind(this)
    this.element.addEventListener("click", this.onClick)
  }

  disconnect() {
    this.element.removeEventListener("click", this.onClick)
  }

  onClick(event) {
    // Ignore clicks that originate inside any `.panel`
    if (event.target.closest(".panel")) return

    // Find the designated back button and trigger it
    const backLink = document.querySelector("[data-back-button]")
    if (backLink) {
      event.preventDefault()
      event.stopPropagation()
      backLink.click()
    }
  }
}
