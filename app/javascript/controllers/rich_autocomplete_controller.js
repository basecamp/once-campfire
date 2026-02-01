import { Controller } from "@hotwired/stimulus"
import MentionsAutocompleteHandler from "lib/autocomplete/mentions_autocomplete_handler"
import EmojiAutocompleteHandler from "lib/autocomplete/emoji_autocomplete_handler"
import { debounce } from "helpers/timing_helpers"

export default class extends Controller {
  static values = { url: String }

  initialize() {
    this.handlers = []
    this.search = debounce(this.search.bind(this), 300)
  }

  connect() {
    if (this.element == document.activeElement) {
      this.#installHandlers()
    }
  }

  focus(event) {
    this.#installHandlers()
  }

  search(event) {
    const content = this.editor.getDocument().toString()
    const position = this.editor.getPosition()
    this.handlers.forEach(handler => handler.updateWithContentAndPosition(content, position))
  }

  blur(event) {
    this.#uninstallHandlers()
  }

  #installHandlers() {
    this.#uninstallHandlers()
    this.handlers = [
      new MentionsAutocompleteHandler(this.element, this.urlValue),
      new EmojiAutocompleteHandler(this.element)
    ]
  }

  #uninstallHandlers() {
    this.handlers.forEach(handler => handler.destroy())
    this.handlers = []
  }

  get editor() {
    return this.element.editor
  }
}
