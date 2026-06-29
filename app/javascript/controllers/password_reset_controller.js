import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "resetPasswordInput", "resetPasswordConfirmInput", "resetPasswordError", "resetPasswordSubmit"]

  resetPasswordCheckInputs() {
    if(this.#checkResetInputsValues()) {
      this.#hideErrorMessage()
      this.#enableSubmitButton()
    } else {
      this.#showErrorMessage()
      this.#disableSubmitButton()
    }
  }

  #showErrorMessage() {
    this.resetPasswordErrorTarget.style.visibility = "visible"
  }

  #hideErrorMessage() {
    this.resetPasswordErrorTarget.style.visibility = "hidden"
  }

  #enableSubmitButton() {
    this.resetPasswordSubmitTarget.disabled = false
  }

  #disableSubmitButton() {
    this.resetPasswordSubmitTarget.disabled = true
  }

  #checkResetInputsValues() {
    if (this.resetPasswordInputTarget.value.length < 0 || this.resetPasswordConfirmInputTarget.value.length < 0) return false
    if (this.resetPasswordInputTarget.value !== this.resetPasswordConfirmInputTarget.value) return false

    return true
  }
}
