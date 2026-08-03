import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "image", "dialog", "zoomedImage", "download", "share" ]

  open(event) {
    event.preventDefault()

    this.dialogTarget.showModal()
    this.#set(event.target.closest("a"))
  }

  reset() {
    this.zoomedImageTarget.src = ""
    this.zoomedImageTarget.alt = ""
    this.downloadTarget.href = ""
    this.shareTarget.dataset.webShareFilesValue = "";
    this.shareTarget.dataset.webShareFilenameValue = "";
  }

  #set(target) {
    this.zoomedImageTarget.src = target.href
    this.zoomedImageTarget.alt = target.dataset.lightboxFilenameValue || "Attached image"
    this.downloadTarget.href = target.dataset.lightboxUrlValue;
    this.shareTarget.dataset.webShareFilesValue = target.dataset.lightboxUrlValue;
    this.shareTarget.dataset.webShareFilenameValue = target.dataset.lightboxFilenameValue;
  }
}
