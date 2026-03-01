import { Controller } from "@hotwired/stimulus"
import encryptionManager from "lib/encryption/encryption_manager"
import { exportIdentityForBackup, importIdentityFromBackup } from "lib/encryption/key_store"

// Manages E2E encryption key setup and backup
export default class extends Controller {
  static targets = ["status", "fingerprint", "backupArea"]
  static values = { userId: Number }

  async connect() {
    await this.#checkKeyStatus()
  }

  async generateKeys() {
    try {
      const publicKeyJwk = await encryptionManager.generateKeys()
      await this.#registerPublicKey(publicKeyJwk)
      this.#updateStatus("active")
      this.#showFingerprint(publicKeyJwk)
    } catch (error) {
      console.error("Key generation failed:", error)
      this.#updateStatus("error")
    }
  }

  async exportBackup() {
    try {
      const backup = await exportIdentityForBackup(this.userIdValue)
      if (!backup) return

      const blob = new Blob([backup], { type: "application/json" })
      const url = URL.createObjectURL(blob)
      const a = document.createElement("a")
      a.href = url
      a.download = `campfire-e2e-keys-${this.userIdValue}.json`
      a.click()
      URL.revokeObjectURL(url)
    } catch (error) {
      console.error("Backup export failed:", error)
    }
  }

  async importBackup(event) {
    const file = event.target.files[0]
    if (!file) return

    try {
      const text = await file.text()
      await importIdentityFromBackup(text)

      const result = await encryptionManager.initialize(this.userIdValue)
      if (result.existing) {
        await this.#registerPublicKey(result.publicKey)
        this.#updateStatus("active")
      }
    } catch (error) {
      console.error("Backup import failed:", error)
      this.#updateStatus("error")
    }
  }

  async #checkKeyStatus() {
    const result = await encryptionManager.initialize(this.userIdValue)
    if (result.existing) {
      this.#updateStatus("active")
      this.#showFingerprint(result.publicKey)
    } else {
      this.#updateStatus("none")
    }
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

  #updateStatus(status) {
    if (!this.hasStatusTarget) return

    const messages = {
      none: "No encryption keys. Generate a key pair to enable E2E encryption.",
      active: "E2E encryption is active. Your private key is stored locally.",
      error: "Error with encryption keys. Try regenerating."
    }

    this.statusTarget.textContent = messages[status] || status
    this.statusTarget.dataset.encryptionStatus = status
  }

  #showFingerprint(publicKeyJwk) {
    if (!this.hasFingerprintTarget || !publicKeyJwk) return

    // Create a visual fingerprint from the public key
    const keyStr = JSON.stringify(publicKeyJwk)
    const hash = this.#simpleHash(keyStr)
    this.fingerprintTarget.textContent = hash.match(/.{1,4}/g).join(" ")
  }

  #simpleHash(str) {
    let hash = 0
    for (let i = 0; i < str.length; i++) {
      const char = str.charCodeAt(i)
      hash = ((hash << 5) - hash) + char
      hash = hash & hash
    }
    return Math.abs(hash).toString(16).toUpperCase().padStart(8, "0")
  }
}
