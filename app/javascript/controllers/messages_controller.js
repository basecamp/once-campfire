import { Controller } from "@hotwired/stimulus"
import { nextEventLoopTick } from "helpers/timing_helpers"
import ClientMessage from "models/client_message"
import MessageFormatter, { ThreadStyle } from "models/message_formatter"
import MessagePaginator from "models/message_paginator"
import ScrollManager from "models/scroll_manager"

export default class extends Controller {
  static targets = [ "latest", "message", "body", "messages", "template", "deliveryStatus" ]
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
    this.#clientMessage = new ClientMessage(this.templateTarget, Current.room.id)
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
    this.#formatter.format(target, ThreadStyle.thread)
    if (target.dataset.messageId) {
      this.dispatch("committed", { detail: {
        clientMessageId: target.dataset.clientMessageId,
        userId: target.dataset.userId
      } })
    }
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

      if (upToDate) {
        event.detail.render = async (streamElement) => {
          const didScroll = await this.#scrollManager.autoscroll(false, async () => {
            await render(streamElement)
            await nextEventLoopTick()

            this.#positionLastMessage()
            this.#playSoundForLastMessage()
            this.#paginator.trimExcessMessages(true)
          })
          if (!didScroll) {
            this.latestTarget.hidden = false
          }
        }
      } else {
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
    const editorEmpty = document.querySelector("#composer trix-editor").matches(":empty")

    if (editorEmpty && this.#paginator.upToDate) {
      this.#myLastMessage?.querySelector(".message__edit-btn")?.click()
    }
  }


  // Outlet actions

  async insertPendingMessage(clientMessageId, node, { preservePagination = false } = {}) {
    if (!preservePagination) await this.#ensureUpToDate()
    const preserveCurrentPage = preservePagination && !this.#paginator.upToDate
    let inserted = false

    const insert = async () => {
      const existingMessages = this.#messagesWithClientId(clientMessageId)
      const committedMessage = existingMessages.find((message) => message.dataset.messageId != null)

      if (committedMessage) {
        existingMessages.filter((message) => message != committedMessage).forEach((message) => message.remove())
        return
      }

      const message = this.#clientMessage.render(clientMessageId, node)
      const [ pendingMessage, ...duplicates ] = existingMessages
      duplicates.forEach((message) => message.remove())

      if (pendingMessage) {
        pendingMessage.outerHTML = message
      } else {
        this.messagesTarget.insertAdjacentHTML("beforeend", message)
      }
      inserted = true
    }

    if (preserveCurrentPage) {
      await insert()
    } else {
      await this.#scrollManager.autoscroll(true, insert)
    }

    return inserted
  }

  updatePendingMessage(clientMessageId, body) {
    this.#clientMessage.update(clientMessageId, body)
  }

  failPendingMessage(clientMessageId, options) {
    this.#clientMessage.failed(clientMessageId, options)
  }

  retryPendingMessage(clientMessageId, options) {
    this.#clientMessage.retrying(clientMessageId, options)
  }

  removePendingMessage(clientMessageId) {
    this.#messagesWithClientId(clientMessageId)
      .filter((message) => message.dataset.messageId == null)
      .forEach((message) => message.remove())
  }

  removePendingFileMessages() {
    Array.from(this.messagesTarget.children)
      .filter((message) => message.dataset.messageId == null && message.querySelector(".message__pending-upload"))
      .forEach((message) => message.remove())
  }

  async announcePendingMessageSent(clientMessageId) {
    this.deliveryStatusTarget.textContent = ""
    await nextEventLoopTick()
    this.deliveryStatusTarget.textContent = "Message sent"

    const message = this.#messagesWithClientId(clientMessageId).find((candidate) =>
      candidate.dataset.messageId != null && Number(candidate.dataset.userId) == Number(Current.user.id)
    )
    if (message?.dataset.messageId) {
      message.tabIndex = -1
      message.focus({ preventScroll: true })
    }
  }

  pendingMessageCommitted(clientMessageId) {
    return this.#messagesWithClientId(clientMessageId).some((message) =>
      message.dataset.messageId != null && Number(message.dataset.userId) == Number(Current.user.id)
    )
  }

  requestPendingMessageRetry(event) {
    this.dispatch("retry-pending", { detail: {
      action: event.currentTarget.dataset.clientMessageAction || "retry",
      clientMessageId: event.currentTarget.dataset.clientMessageId
    } })
  }

  // Callbacks

  #allContentViewed() {
    this.latestTarget.hidden = true
  }


  // Internal

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

  #sortValue(node) {
    return (node && parseInt(node.dataset.sortValue)) || 0
  }

  #messagesWithClientId(clientMessageId) {
    return Array.from(this.messagesTarget.children).filter(
      (message) => message.dataset.clientMessageId == clientMessageId
    )
  }
}
