import { onNextEventLoopTick } from "helpers/timing_helpers"

const THREADING_TIME_WINDOW_MILLISECONDS = 5 * 60 * 1000 // 5 minutes

export const ThreadStyle = {
  none: 0,
  thread: 1,
}

export default class MessageFormatter {
  #userId
  #classes
  #dateFormatter = new Intl.DateTimeFormat(undefined, { dateStyle: "short" })

  constructor(userId, classes) {
    this.#userId = userId
    this.#classes = classes
  }

  format(message, threadstyle) {
    this.#setMeClass(message)
    this.#highlightMentions(message)

    if (threadstyle != ThreadStyle.none) {
      this.#threadMessage(message)
      this.#setFirstOfDayClass(message)
    }

    this.#makeVisible(message)
  }

  formatBody(body) {
    this.#highlightCode(body)
  }

  #setMeClass(message) {
    const isMe = message.dataset.userId == this.#userId
    message.classList.toggle(this.#classes.me, isMe)
  }

  #makeVisible(message) {
    message.classList.add(this.#classes.formatted)
  }

  #setFirstOfDayClass(message) {
    let showSeparator = true

    if (message.dataset.messageTimestamp && message.previousElementSibling?.dataset?.messageTimestamp) {
      const prev = new Date(Number(message.previousElementSibling.dataset.messageTimestamp))
      const curr = new Date(Number(message.dataset.messageTimestamp))

      showSeparator = this.#dateFormatter.format(prev) !== this.#dateFormatter.format(curr)
    }

    message.classList.toggle(this.#classes.firstOfDay, showSeparator)
  }

  #threadMessage(message) {
    if (message.previousElementSibling) {
      const isSameUser = message.previousElementSibling.dataset.userId == message.dataset.userId
      const previousMessageIsRecent = this.#previousMessageIsRecent(message)

      message.classList.toggle(this.#classes.threaded, isSameUser && previousMessageIsRecent)
    }
  }

  #highlightMentions(message) {
    const mentionsCurrentUser = message.querySelector(this.#selectorForCurrentUser) !== null
    message.classList.toggle(this.#classes.mentioned, mentionsCurrentUser)
  }

  #highlightCode(body) {
    body.querySelectorAll("pre").forEach(block => {
      onNextEventLoopTick(() => this.#highlightCodeBlock(block))
    })
  }

  #highlightCodeBlock(block) {
    this.#normalizeLineBreaks(block)

    if (this.#isPlainText(block)) {
      const language = block.dataset.language
      if (language && window.hljs.getLanguage(language)) {
        block.classList.add(`language-${language}`)
      }

      window.hljs.highlightElement(block)
    }
  }

  // Lexxy breaks code block lines with <br>, Trix-era blocks used newlines
  #normalizeLineBreaks(block) {
    block.querySelectorAll("br").forEach(br => br.replaceWith("\n"))
  }

  #isPlainText(element) {
    return Array.from(element.childNodes).every(node => node.nodeType === Node.TEXT_NODE)
  }

  #previousMessageIsRecent(message) {
    const previousTimestamp = message.previousElementSibling.dataset.messageTimestamp
    const threadTimestamp = message.dataset.messageTimestamp
    return Math.abs(previousTimestamp - threadTimestamp) <= THREADING_TIME_WINDOW_MILLISECONDS
  }

  get #selectorForCurrentUser() {
    return `.mention img[src^="/users/${Current.user.id}/avatar"]`
  }
}
