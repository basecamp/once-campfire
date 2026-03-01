import { Controller } from "@hotwired/stimulus"
import encryptionManager from "lib/encryption/encryption_manager"

// Handles decryption of encrypted messages in the DOM
export default class extends Controller {
  static targets = ["ciphertext"]
  static values = {
    roomId: Number,
    initialized: { type: Boolean, default: false }
  }

  async connect() {
    if (!this.initializedValue) {
      await this.#initializeEncryption()
    }
    this.#decryptVisibleMessages()
  }

  ciphertextTargetConnected(target) {
    this.#decryptElement(target)
  }

  async #initializeEncryption() {
    const userId = Current.user.id
    const result = await encryptionManager.initialize(userId)

    if (!result.existing) {
      const publicKeyJwk = await encryptionManager.generateKeys()
      await this.#registerPublicKey(publicKeyJwk)
    }

    this.initializedValue = true
  }

  async #registerPublicKey(publicKeyJwk) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    await fetch("/users/me/encryption_key", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token
      },
      body: JSON.stringify({ identity_public_key: JSON.stringify(publicKeyJwk) })
    })
  }

  async #decryptVisibleMessages() {
    const encryptedMessages = document.querySelectorAll(".message--encrypted")

    for (const messageEl of encryptedMessages) {
      await this.#decryptMessageElement(messageEl)
    }
  }

  async #decryptElement(target) {
    const messageEl = target.closest(".message--encrypted")
    if (messageEl) {
      await this.#decryptMessageElement(messageEl)
    }
  }

  async #decryptMessageElement(messageEl) {
    if (messageEl.dataset.decrypted === "true") return
    if (!encryptionManager.isInitialized) return

    const { encryptedBody, encryptionNonce, senderId, roomId } = messageEl.dataset

    if (!encryptedBody || !encryptionNonce) return

    try {
      let plaintext

      // Try room-based decryption first, then direct
      const room = document.querySelector(`[data-room-encrypted="true"][data-room-id="${roomId}"]`)
      if (room) {
        plaintext = await encryptionManager.decryptRoomMessage(parseInt(roomId), encryptedBody, encryptionNonce)
      } else {
        plaintext = await encryptionManager.decryptDirectMessage(parseInt(senderId), encryptedBody, encryptionNonce)
      }

      const bodyContent = messageEl.querySelector(".message__body-content [data-encryption-target='ciphertext']")
      if (bodyContent) {
        bodyContent.innerHTML = `<div class="trix-content">${this.#escapeHtml(plaintext)}</div>`
        bodyContent.classList.remove("encrypted-placeholder")
        bodyContent.classList.add("decrypted")
      }

      messageEl.dataset.decrypted = "true"
    } catch (error) {
      console.warn("Failed to decrypt message:", error)
      const bodyContent = messageEl.querySelector(".message__body-content [data-encryption-target='ciphertext']")
      if (bodyContent) {
        bodyContent.textContent = "🔒 Unable to decrypt message"
        bodyContent.classList.add("decrypt-failed")
      }
    }
  }

  #escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
