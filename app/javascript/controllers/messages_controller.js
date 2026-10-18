import { Controller } from "@hotwired/stimulus"
import { nextEventLoopTick } from "helpers/timing_helpers"
import ClientMessage from "models/client_message"
import MessageFormatter, { ThreadStyle } from "models/message_formatter"
import MessagePaginator from "models/message_paginator"
import ScrollManager from "models/scroll_manager"

export default class extends Controller {
  static targets = [ "latest", "message", "body", "messages", "template" ]
  static classes = [ "firstOfDay", "formatted", "me", "mentioned", "threaded" ]
  static values = { pageUrl: String }

  #clientMessage
  #paginator
  #formatter
  #scrollManager

  // Lifecycle

  initialize() {
    this.#formatter = new MessageFormatter(Current.user.id, {
      firstOfDay: this.firstOfDayClass,
      formatted: this.formattedClass,
      me: this.meClass,
      mentioned: this.mentionedClass,
      threaded: this.threadedClass,
    })
  }

  connect() {
    this.#clientMessage = new ClientMessage(this.templateTarget)
    this.#paginator = new MessagePaginator(this.messagesTarget, this.pageUrlValue, this.#formatter, this.#allContentViewed.bind(this))
    this.#scrollManager = new ScrollManager(this.messagesTarget)

    if (this.#hasSearchResult) {
      this.#highlightSearchResult()
    } else {
      this.#scrollManager.autoscroll(true)
    }

    this.#paginator.monitor()
  }

  disconnect() {
    this.#paginator.disconnect()
  }

  messageTargetConnected(target) {
    this.#reconcilePendingMessage(target)
    this.#formatter.format(target, ThreadStyle.thread)
  }

  bodyTargetConnected(target) {
    this.#formatter.formatBody(target)
  }

  // Actions

  async beforeStreamRender(event) {
    const target = event.detail.newStream.getAttribute("target")

    if (target === this.messagesTarget.id) {
      const render = event.detail.render
      const upToDate = this.#paginator.upToDate
      const replacing = event.detail.newStream.getAttribute("action") === "update"

      if (upToDate) {
        event.detail.render = async (streamElement) => {
          const kept = replacing ? this.#messagesUnknownTo(streamElement) : []

          const didScroll = await this.#scrollManager.autoscroll(false, async () => {
            await render(streamElement)
            await nextEventLoopTick()

            this.#positionLastMessage()
            this.#playSoundForLastMessage()
            this.messagesTarget.append(...kept)
            this.#paginator.trimExcessMessages(true)
          })
          if (!didScroll) {
            this.latestTarget.hidden = false
          }
        }
      } else {
        // Older messages are on screen, so the latest page would only take the reader's place. Returning to the
        // latest loads it anyway.
        if (replacing) event.detail.render = () => {}
        this.latestTarget.hidden = false
      }
    }
  }

  async returnToLatest() {
    this.latestTarget.hidden = true
    await this.#ensureUpToDate()
    this.#scrollManager.autoscroll(true)
  }

  async editMyLastMessage() {
    const editorEmpty = document.querySelector("#composer lexxy-editor").isBlank

    if (editorEmpty && this.#paginator.upToDate) {
      this.#myLastMessage?.querySelector(".message__edit-btn")?.click()
    }
  }


  // Outlet actions

  async insertPendingMessage(clientMessageId, node) {
    await this.#ensureUpToDate()

    return this.#scrollManager.autoscroll(true, async () => {
      const message = this.#clientMessage.render(clientMessageId, node)
      this.messagesTarget.insertAdjacentHTML("beforeend", message)
    })
  }

  updatePendingMessage(clientMessageId, body) {
    this.#clientMessage.update(clientMessageId, body)
  }

  failPendingMessage(clientMessageId) {
    this.#clientMessage.failed(clientMessageId)
  }

  // Callbacks

  #allContentViewed() {
    this.latestTarget.hidden = true
  }


  // Internal

  // The composer inserts a pending message client-side using the client_message_id
  // as its DOM id. The server broadcast now renders the real message with a DOM id
  // derived from the record's primary key, so it no longer replaces the pending
  // element by id. Reconcile by matching the server message's client_message_id and
  // dropping our own pending placeholder. Only elements flagged data-pending-message
  // (client-side placeholders, never broadcast) are removed, so a message another
  // member posted reusing this client_message_id can never displace a real one.
  #reconcilePendingMessage(target) {
    const clientMessageId = target.dataset.clientMessageId

    if (target.dataset.messageId && clientMessageId) {
      const selector = `[data-pending-message][data-client-message-id="${CSS.escape(clientMessageId)}"]`

      this.messagesTarget.querySelectorAll(selector).forEach((pending) => {
        if (pending !== target) pending.remove()
      })
    }
  }

  async #ensureUpToDate() {
    if (!this.#paginator.upToDate) {
      await this.#paginator.resetToLastPage()
    }
  }

  #highlightSearchResult() {
    const highlightId = location.pathname.split("@").pop()
    const highlightMessage = this.messagesTarget.querySelector(`.message[data-message-id="${highlightId}"]`)
    if (highlightMessage) {
      highlightMessage.classList.add("search-highlight")
      highlightMessage.scrollIntoView({ behavior: "instant", block: "center" })
    }

    this.#paginator.upToDate = false
  }

  get #hasSearchResult() {
    return location.pathname.includes("@")
  }

  get #lastMessage() {
    return this.messagesTarget.children[this.messagesTarget.children.length - 1]
  }

  get #myLastMessage() {
    const myMessages = this.messagesTarget.querySelectorAll(`.${this.meClass}`)
    return myMessages[myMessages.length - 1]
  }

  #positionLastMessage() {
    const followingMessage = this.#followingMessage(this.#lastMessage)

    if (followingMessage) {
      followingMessage.before(this.#lastMessage)
    }
  }

  #playSoundForLastMessage() {
    const soundTarget = this.#lastMessage.querySelector(".sound")

    if (soundTarget) {
      this.dispatch("play", { target: soundTarget })
    }
  }

  #followingMessage(message) {
    const messageSortValue = this.#sortValue(message)
    let followingMessage = null
    let previousMessage = message.previousElementSibling

    while (messageSortValue < this.#sortValue(previousMessage)) {
      followingMessage = previousMessage
      previousMessage = previousMessage.previousElementSibling;
    }

    return followingMessage
  }

  // A refresh that missed more than a page replaces the messages with the latest one. That page can't know about
  // messages that arrived live after it was rendered, or about our own still being sent or that failed to send, whose
  // text is nowhere else: those stay.
  #messagesUnknownTo(streamElement) {
    const page = Array.from(streamElement.templateElement.content.querySelectorAll(".message"))
    const pageIds = new Set(page.map((message) => message.id))
    const pageClientMessageIds = new Set(page.map((message) => message.dataset.clientMessageId))
    const pageEnd = Math.max(0, ...page.map((message) => this.#sortValue(message)))

    return Array.from(this.messagesTarget.children).filter((element) => {
      if (element.dataset.pendingMessage) {
        return !pageClientMessageIds.has(element.dataset.clientMessageId)
      } else {
        return element.dataset.messageId && !pageIds.has(element.id) && this.#sortValue(element) >= pageEnd
      }
    })
  }

  #sortValue(node) {
    return (node && parseInt(node.dataset.sortValue)) || 0
  }
}
