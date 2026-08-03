const EMOJI_MATCHER = /^(\p{Emoji_Presentation}|\p{Extended_Pictographic}|\uFE0F)+$/gu

const SOUND_NAMES = [ "56k", "ballmer", "bell", "bezos", "bueller", "butts", "clowntown", "cottoneyejoe", "crickets", "curb", "dadgummit", "dangerzone", "danielsan", "deeper", "donotwant", "drama", "flawless", "glados", "gogogo", "greatjob", "greyjoy", "guarantee", "heygirl", "honk", "horn", "horror", "inconceivable", "letitgo", "live", "loggins", "makeitso", "noooo", "nyan", "ohmy", "ohyeah", "pushit", "rimshot", "rollout", "rumble", "sax", "secret", "sexyback", "story", "tada", "tmyk", "totes", "trololo", "trombone", "unix", "vuvuzela", "what", "whoomp", "wups", "yay", "yeah", "yodel" ]

export default class ClientMessage {
  #template
  #roomId

  constructor(template, roomId) {
    this.#template = template
    this.#roomId = roomId
  }

  render(clientMessageId, node) {
    const now = new Date()
    const body = this.#contentFromNode(node)

    return this.#createFromTemplate({
      clientMessageId,
      messageDomId: this.#messageDomId(clientMessageId),
      body,
      messageTimestamp: Math.floor(now.getTime()),
      messageDatetime: now.toISOString(),
      messageClasses: this.#containsOnlyEmoji(node.textContent) ? "message--emoji" : "",
    })
  }

  update(clientMessageId, body) {
    const element = this.#findWithId(clientMessageId)?.querySelector(".message__pending-upload")

    if (element) {
      element.outerHTML = body
    }
  }

  failed(clientMessageId, { kind = "message", permanent = false, retryable = true, status: statusCode, uncertain = false } = {}) {
    const element = this.#findWithId(clientMessageId)
    const status = element?.querySelector("[data-client-message-status]")
    const retryButton = element?.querySelector("[data-client-message-retry]")

    if (element && status && retryButton) {
      element.classList.add("message--failed")
      status.closest("[data-client-message-failure]").hidden = false
      this.#removeDiscardButton(element)

      if (permanent) {
        status.textContent = this.#permanentFailureMessage(kind, statusCode)
        this.#configureAction(retryButton, kind == "file" ? "Restore attachment" : "Restore message", "restore")
        retryButton.after(this.#discardButton(clientMessageId, kind))
      } else if (uncertain) {
        status.textContent = "Upload outcome is unknown. Retry to confirm whether the file was sent."
        this.#configureAction(retryButton, "Retry to confirm", "retry")
      } else {
        status.textContent = retryable ? "Message was not sent." : "File was not uploaded. It remains selected for retry."
        this.#configureAction(retryButton, "Retry sending", "retry", { hidden: !retryable })
      }
    }
  }

  retrying(clientMessageId, { kind = "message" } = {}) {
    const element = this.#findWithId(clientMessageId)
    const status = element?.querySelector("[data-client-message-status]")
    const retryButton = element?.querySelector("[data-client-message-retry]")

    if (element && status && retryButton) {
      element.classList.remove("message--failed")
      status.textContent = kind == "file" ? "Checking upload…" : "Retrying message…"
      this.#removeDiscardButton(element)
      this.#configureAction(retryButton, "Retry sending", "retry")
      retryButton.disabled = true
    }
  }

  #configureAction(button, label, action, { hidden = false } = {}) {
    button.textContent = label
    button.dataset.clientMessageAction = action
    button.hidden = hidden
    button.disabled = hidden
  }

  #discardButton(clientMessageId, kind) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn"
    button.dataset.action = "messages#requestPendingMessageRetry"
    button.dataset.clientMessageAction = "discard"
    button.dataset.clientMessageId = clientMessageId
    button.dataset.clientMessageDiscard = ""
    button.textContent = kind == "file" ? "Discard attachment" : "Discard message"
    return button
  }

  #removeDiscardButton(element) {
    element.querySelector("[data-client-message-discard]")?.remove()
  }

  #permanentFailureMessage(kind, statusCode) {
    const item = kind == "file" ? "File" : "Message"

    switch (Number(statusCode)) {
      case 403:
      case 404:
        return `${item} cannot be sent because access is no longer available.`
      case 413:
        return `${item} is too large to send.`
      default:
        return `${item} cannot be sent in its current form.`
    }
  }

  #findWithId(clientMessageId) {
    return document.getElementById(this.#messageDomId(clientMessageId))
  }

  #messageDomId(clientMessageId) {
    return `message_${this.#roomId}_${clientMessageId}`
  }

  #contentFromNode(node) {
    if (this.#isPlayCommand(node)) {
      return `<span class="pending">Playing ${this.#matchPlayCommand(node)}…</span>`
    } else if (this.#isRichText(node)) {
      return this.#richTextContent(node)
    } else {
      return node
    }
  }


  #isPlayCommand(node) {
    return this.#matchPlayCommand(node)
  }

  #matchPlayCommand(node) {
    return this.#stripWrapperElement(node)?.match(new RegExp(`^/play (${SOUND_NAMES.join("|")})`))?.[1]
  }

  #stripWrapperElement(node) {
    return node.innerHTML?.replace(/<div>(?:<!--[\s\S]*?-->)*([\s\S]*?)<\/div>/i, '$1')
  }


  #isRichText(node) {
    return typeof(node) != "string"
  }

  #richTextContent(node) {
    return `<div class="trix-content">${node.innerHTML}</div>`
  }


  #createFromTemplate(data) {
    let html = this.#template.innerHTML

    for (const key in data) {
      html = html.replaceAll(`$${key}$`, data[key])
    }

    return html
  }

  #containsOnlyEmoji(text) {
    return text?.match(EMOJI_MATCHER)
  }
}
