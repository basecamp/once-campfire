import { Controller } from "@hotwired/stimulus"
import { debounce } from "helpers/timing_helpers"

export default class extends Controller {
  static targets = [ "list" ]
  static classes = [ "active", "selected" ]

  initialize() {
    this.filter = debounce(this.filter.bind(this), 300)
  }

  connect() {
    this.element.focus()
  }

  filter(event) {
    this.#reset()

    if (event.target.value != "") {
      this.#selectMatches(event.target.value)
      this.#activate()
    }
  }

  #reset() {
    this.#deactivate()

    this.listTarget.querySelectorAll(`.${this.selectedClass}`).forEach((element) => {
      element.classList.remove(this.selectedClass)
    })
  }

  #activate() {
    this.listTarget.classList.add(this.activeClass)
  }

  #deactivate() {
    this.listTarget.classList.remove(this.activeClass)
  }

  #selectMatches(value) {
    this.listTarget.querySelectorAll(`[data-value*="${CSS.escape(value.toLowerCase())}"]`).forEach((element) => {
      element.classList.add(this.selectedClass)
    })
  }
}
