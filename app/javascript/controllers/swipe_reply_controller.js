import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["message", "replyIndicator"]
  static outlets = ["composer"]
  static values = {
    threshold: { type: Number, default: 80 },
    maxSwipe: { type: Number, default: 100 }
  }

  connect() {
    this.startX = 0
    this.currentX = 0
    this.isDragging = false
    this.hasTriggered = false
  }

  touchstart(event) {
    if (event.touches.length !== 1) return

    this.startX = event.touches[0].clientX
    this.startY = event.touches[0].clientY
    this.isDragging = false
    this.hasTriggered = false
    this.isHorizontalSwipe = null
  }

  touchmove(event) {
    if (!this.startX) return

    const currentX = event.touches[0].clientX
    const currentY = event.touches[0].clientY
    const deltaX = currentX - this.startX
    const deltaY = currentY - this.startY

    // Determine swipe direction on first significant movement
    if (this.isHorizontalSwipe === null && (Math.abs(deltaX) > 10 || Math.abs(deltaY) > 10)) {
      this.isHorizontalSwipe = Math.abs(deltaX) > Math.abs(deltaY)
    }

    // Only handle horizontal swipes (right swipe for reply)
    if (!this.isHorizontalSwipe || deltaX < 0) {
      this.#resetPosition()
      return
    }

    event.preventDefault()
    this.isDragging = true

    // Limit the swipe distance with easing
    const limitedDelta = Math.min(deltaX, this.maxSwipeValue)
    const easedDelta = this.#easeOutQuad(limitedDelta / this.maxSwipeValue) * this.maxSwipeValue

    this.currentX = easedDelta
    this.element.style.transform = `translateX(${easedDelta}px)`

    // Show reply indicator
    this.#updateReplyIndicator(easedDelta)

    // Haptic feedback at threshold
    if (easedDelta >= this.thresholdValue && !this.hasTriggered) {
      this.hasTriggered = true
      this.#vibrate()
    }
  }

  touchend(event) {
    if (!this.isDragging) {
      this.#resetPosition()
      return
    }

    if (this.currentX >= this.thresholdValue) {
      this.#triggerReply()
    }

    this.#animateBack()
  }

  #triggerReply() {
    // Find the reply controller and trigger reply
    const replyController = this.application.getControllerForElementAndIdentifier(this.element, "reply")
    if (replyController && replyController.reply) {
      replyController.reply()
    }
  }

  #updateReplyIndicator(delta) {
    if (!this.hasReplyIndicatorTarget) return

    const progress = Math.min(delta / this.thresholdValue, 1)
    const indicator = this.replyIndicatorTarget

    indicator.style.opacity = progress
    indicator.style.transform = `scale(${0.5 + progress * 0.5})`

    if (delta >= this.thresholdValue) {
      indicator.classList.add("swipe-reply--ready")
    } else {
      indicator.classList.remove("swipe-reply--ready")
    }
  }

  #animateBack() {
    this.element.style.transition = "transform 0.3s cubic-bezier(0.25, 0.46, 0.45, 0.94)"
    this.element.style.transform = "translateX(0)"

    if (this.hasReplyIndicatorTarget) {
      this.replyIndicatorTarget.style.opacity = 0
      this.replyIndicatorTarget.style.transform = "scale(0.5)"
      this.replyIndicatorTarget.classList.remove("swipe-reply--ready")
    }

    setTimeout(() => {
      this.element.style.transition = ""
      this.#resetPosition()
    }, 300)
  }

  #resetPosition() {
    this.startX = 0
    this.currentX = 0
    this.isDragging = false
    this.isHorizontalSwipe = null
  }

  #easeOutQuad(t) {
    return t * (2 - t)
  }

  #vibrate() {
    if ("vibrate" in navigator) {
      navigator.vibrate(10)
    }
  }
}
