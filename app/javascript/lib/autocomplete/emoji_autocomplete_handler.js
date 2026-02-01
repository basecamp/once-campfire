import BaseAutocompleteHandler from "lib/autocomplete/base_autocomplete_handler"
import { PUNCTUATION_PATTERN } from "lib/autocomplete/constants"
import EMOJI_LIST from "lib/emoji/emoji_list"

export default class extends BaseAutocompleteHandler {
  get pattern() {
    return new RegExp(`^:(.*?)(${PUNCTUATION_PATTERN.source}*)$`)
  }

  loadAutocompletables(_query, callback) {
    this.setAutocompletables(EMOJI_LIST)
    callback()
  }

  insertAutocompletable(autocompletable, range, terminator, options = {}) {
    const emoji = autocompletable?.emoji || ""
    this.#insertEmojiAtRange(emoji, range, terminator, options)
  }

  // Override to set selector's position relative to the cursor in the editor
  getOffsetsAtPosition(position) {
    return this.#getOffsetsFromEditorAtPosition(this.#editor, position)
  }

  #insertEmojiAtRange(emoji, range, terminator, { editor } = {}) {
    const targetEditor = editor || this.#editor
    if (!targetEditor || !emoji) return

    if (range) { targetEditor.setSelectedRange(range) }
    targetEditor.deleteInDirection("forward")
    targetEditor.insertString(emoji)
    targetEditor.insertString(terminator)
  }

  get #editor() {
    return this.element.editor
  }

  #getOffsetsFromEditorAtPosition(editor, position) {
    const rect = editor.getClientRectAtPosition(position)
    return rect ? rect : {}
  }
}
