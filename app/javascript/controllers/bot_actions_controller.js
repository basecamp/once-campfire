import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "button" ]
  static values = { messageId: Number, selectionMode: String, selectionUrl: String }

  connect() {
    if (this.#selectionEnabled) this.#restore()
  }

  choose({ currentTarget }) {
    if (!this.#selectionEnabled) return

    const value = currentTarget.dataset.botActionValue
    const values = this.selectionModeValue === "multiple" ? this.#selectedValues : []

    if (values.includes(value) || currentTarget.getAttribute("aria-pressed") === "true") {
      this.#select(values.filter((selectedValue) => selectedValue !== value))
    } else {
      this.#select([ ...values, value ])
    }
  }

  #select(values) {
    this.buttonTargets.forEach((button) => {
      button.setAttribute("aria-pressed", values.includes(button.dataset.botActionValue))
    })
  }

  async #restore() {
    const response = await fetch(this.selectionUrlValue, { headers: { "Accept": "application/json" } })
    if (response.ok) this.#select((await response.json()).values)
  }

  get #selectionEnabled() {
    return this.selectionModeValue !== "none"
  }

  get #selectedValues() {
    return this.buttonTargets.filter((button) => button.getAttribute("aria-pressed") === "true").map((button) => button.dataset.botActionValue)
  }
}
