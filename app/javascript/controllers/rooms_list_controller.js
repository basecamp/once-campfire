import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"
import { ignoringBriefDisconnects } from "helpers/dom_helpers"

export default class extends Controller {
  static targets = [ "room" ]
  static classes = [ "unread" ]

  #disconnected = true
  #connection = 0
  #readAt = new Map()

  async connect() {
    this.channel ??= await cable.subscribeTo({ channel: "UnreadRoomsChannel" }, {
      connected: this.#channelConnected.bind(this),
      disconnected: this.#channelDisconnected.bind(this),
      received: this.#unread.bind(this)
    })
  }

  disconnect() {
    ignoringBriefDisconnects(this.element, () => {
      this.#channelDisconnected()
      this.channel?.unsubscribe()
      this.channel = null
    })
  }

  loaded() {
    this.read({ detail: { roomId: Current.room.id } })
  }

  read({ detail: { roomId, at } }) {
    const room = this.#findRoomTarget(roomId)

    if (at) {
      this.#readAt.set(Number(roomId), Math.max(Number(at), this.#readAt.get(Number(roomId)) ?? 0))
    }

    if (room) {
      room.classList.remove(this.unreadClass)
      this.dispatch("read", { detail: { targetId: roomId } })
    }
  }

  async #channelConnected() {
    if (this.#disconnected) {
      this.#disconnected = false
      const connection = ++this.#connection
      // Reloading an unfinished frame aborts its response body reader.
      await this.element.loaded
      if (this.element.isConnected && !this.#disconnected && connection === this.#connection) {
        this.element.reload()
      }
    }
  }

  #channelDisconnected() {
    this.#disconnected = true
  }

  #unread({ roomId, at }) {
    const unreadRoom = this.#findRoomTarget(roomId)

    if (unreadRoom) {
      if (Current.room.id != roomId && !this.#readSince(roomId, at)) {
        unreadRoom.classList.add(this.unreadClass)
      }

      this.dispatch("unread", { detail: { targetId: unreadRoom.id } })
    }
  }

  // Notices fan out one member at a time, so one can arrive after the member has already
  // read the room in another tab. It still reorders the room, but doesn't mark it unread.
  #readSince(roomId, at) {
    return Number(at) <= this.#readAt.get(Number(roomId))
  }

  #findRoomTarget(roomId) {
    return this.roomTargets.find(roomTarget => roomTarget.dataset.roomId == roomId)
  }
}
