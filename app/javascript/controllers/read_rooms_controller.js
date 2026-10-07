import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"
import { ignoringBriefDisconnects } from "helpers/dom_helpers"

export default class extends Controller {
  async connect() {
    this.channel ??= await cable.subscribeTo({ channel: "ReadRoomsChannel" }, {
      received: this.#read
    })
  }

  disconnect() {
    ignoringBriefDisconnects(this.element, () => {
      this.channel?.unsubscribe()
      this.channel = null
    })
  }

  #read = ({ room_id, at }) => {
    this.dispatch("read", { detail: { roomId: room_id, at } })
  }
}
