import { Controller } from "@hotwired/stimulus"
import { nextFrame } from "helpers/timing_helpers"

export default class extends Controller {
  async connect() {
    await nextFrame()
    const behavior = window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"
    this.element.scrollIntoView({ behavior, block: "center" })
  }
}
