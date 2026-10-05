import Collection from "lib/autocomplete/collection"
import SuggestionController from "lib/autocomplete/suggestion_controller"
import { generateUUID } from "lib/autocomplete/helpers"
import { Renderer } from "lib/autocomplete/renderer"

export default class BaseAutocompleteHandler {
  #autocompletables
  #url

  constructor(element, url) {
    this.element = element
    this.#url = url
    if (!this.element.id) { this.element.id = `autocomplete_${generateUUID()}` }
    this.suggestionController = new SuggestionController(this)
  }

  updateWithContentAndPosition(content, position) {
    if (this.suggestionController && this.shouldAutocompleteWithContentAndPosition(content, position)) {
      this.suggestionController.updateWithContentAndPosition(content, position)
    }
  }

  destroy() {
    this.#closeSuggestionController()
  }

  // Subclass methods

  get pattern() {
    return null
  }

  shouldAutocompleteWithContentAndPosition(content, position) {
    return true
  }

  getAutocompletable(value) {
    return this.#autocompletables.get(value)
  }

  autocompletablesMatchingQuery(query) {
    return this.#autocompletables.matchingQuery(query).toArray()
  }

  loadAutocompletables(query, callback) {
    const url = query ? this.#autocompletablesUrl(query) : this.#url

    this.#fetchAutocompletables(url).then((autocompletables) => {
      this.setAutocompletables(autocompletables)
      callback()
    })
  }

  setAutocompletables(autocompletables) {
    this.#autocompletables = new Collection(autocompletables)
  }

  // SuggestionController Delegate

  getSuggestionsIdentifier() {
    return `${this.element.id}_suggestions`
  }

  matchQueryAndTerminatorForWord(word) {
    if (!this.pattern) return

    const match = word.match(this.pattern)
    if (match) {
      return {
        query: match[1],
        terminator: match?.[2] || ""
      }
    }
  }

  getOffsetsAtPosition(position) {
    return this.element.getBoundingClientRect()
  }

  getResultsPlacement() {
    return this.#suggestionResultsPlacement
  }

  fetchResultsForQuery(query, callback) {
    this.loadAutocompletables(query, () => {
      const autocompletables = this.autocompletablesMatchingQuery(query)
      const html = new Renderer().renderAutocompletableSuggestions(autocompletables)
      callback(html)
    })
  }

  willCommitValueAtRangeWithTerminator(value, range, terminator) {
    const autocompletable = this.getAutocompletable(value)
    this.insertAutocompletable(autocompletable, range, terminator)
  }

  didShowResults(selectElement) {
    selectElement.classList.add("rich_text")
  }

  #autocompletablesUrl(query) {
    const separator = this.#url.includes('?') ? '&' : '?'
    return `${this.#url}${separator}query=${query}`
  }

  get #suggestionResultsPlacement() {
    return this.element.dataset.suggestionResultsPlacement
  }

  #closeSuggestionController() {
    if (!this.suggestionController) return

    if (this.suggestionController.active) {
      this.suggestionController.hideResults()
    } else {
      this.suggestionController.destroy()
      this.suggestionController = null
    }
  }

  #fetchAutocompletables(url) {
    if (url) {
      return fetch(url, { headers: { Accept: "application/json" } }).then(response => response.json())
    } else {
      return Promise.resolve()
    }
  }
}
