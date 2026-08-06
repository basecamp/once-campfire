import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "adminAction" ]
  static values = { creatorId: Number }

  connect() {
    if (this.#canAdministerPoll) {
      this.adminActionTargets.forEach((target) => target.hidden = false)
    }
  }

  get #canAdministerPoll() {
    return document.body.classList.contains("admin") || window.Current?.user?.id === this.creatorIdValue
  }
}
