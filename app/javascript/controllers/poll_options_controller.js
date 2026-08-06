import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "list", "template", "row", "addButton" ]
  static values = { min: Number, max: Number }

  #nextIndex = 0

  connect() {
    this.#nextIndex = this.rowTargets.length
    this.#refresh()
  }

  add(event) {
    event.preventDefault()
    if (this.#visibleRows().length >= this.maxValue) return

    const index = this.#nextIndex++
    const html = this.templateTarget.innerHTML.replaceAll("__INDEX__", index)
    this.listTarget.insertAdjacentHTML("beforeend", html)
    this.normalizePositions()
    this.#refresh()
  }

  remove(event) {
    event.preventDefault()
    if (this.#visibleRows().length <= this.minValue) return

    const row = event.currentTarget.closest("[data-poll-options-target='row']")
    const destroyInput = row?.querySelector("[data-poll-options-destroy]")
    if (destroyInput) {
      destroyInput.value = "1"
      row.hidden = true
    } else {
      row?.remove()
    }
    this.normalizePositions()
    this.#refresh()
  }

  normalizePositions() {
    this.#visibleRows().forEach((row, index) => {
      const positionInput = row.querySelector("[data-poll-options-position]")
      if (positionInput) positionInput.value = index
    })
  }

  #refresh() {
    const visibleRows = this.#visibleRows()
    const atMin = visibleRows.length <= this.minValue

    this.addButtonTarget.disabled = visibleRows.length >= this.maxValue
    visibleRows.forEach((row) => {
      const removeButton = row.querySelector("[data-poll-options-remove]")
      if (removeButton) removeButton.disabled = atMin
    })
  }

  #visibleRows() {
    return this.rowTargets.filter((row) => !row.hidden)
  }
}
