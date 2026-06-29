import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "error", "question" ]
  static values = { maxQuestionLength: Number }

  validate(event) {
    const question = this.questionTarget.editor.getDocument().toString().trim()

    if (question.length > this.maxQuestionLengthValue) {
      event.preventDefault()
      this.errorTarget.textContent = `Question is too long (max ${this.maxQuestionLengthValue} characters).`
      this.errorTarget.hidden = false
    } else {
      this.errorTarget.hidden = true
    }
  }
}
