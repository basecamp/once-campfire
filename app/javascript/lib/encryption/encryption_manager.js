// EncryptionManager - High-level API for E2E encryption operations
// Coordinates between crypto primitives, key storage, and server communication

import {
  generateIdentityKeyPair, exportPublicKey, exportPrivateKey,
  importPublicKey, importPrivateKey,
  deriveSharedKey, generateRoomKey,
  encryptMessage, decryptMessage,
  encryptRoomKeyForUser, decryptRoomKey,
  exportAesKey, importAesKey,
  arrayBufferToBase64, base64ToArrayBuffer
} from "lib/encryption/crypto"

import {
  saveIdentityKeyPair, getIdentityKeyPair, hasIdentityKey,
  saveRoomKey, getRoomKey
} from "lib/encryption/key_store"

class EncryptionManager {
  #userId = null
  #privateKey = null
  #publicKey = null
  #roomKeys = new Map()
  #peerPublicKeys = new Map()
  #initialized = false

  // Initialize encryption for a user
  async initialize(userId) {
    this.#userId = userId

    const stored = await getIdentityKeyPair(userId)
    if (stored) {
      this.#privateKey = await importPrivateKey(stored.privateKeyJwk)
      this.#publicKey = await importPublicKey(stored.publicKeyJwk)
      this.#initialized = true
      return { existing: true, publicKey: stored.publicKeyJwk }
    }

    return { existing: false, publicKey: null }
  }

  // Generate and store a new identity key pair
  async generateKeys() {
    const keyPair = await generateIdentityKeyPair()
    const publicKeyJwk = await exportPublicKey(keyPair)
    const privateKeyJwk = await exportPrivateKey(keyPair)

    await saveIdentityKeyPair(this.#userId, privateKeyJwk, publicKeyJwk)

    this.#privateKey = keyPair.privateKey
    this.#publicKey = keyPair.publicKey
    this.#initialized = true

    return publicKeyJwk
  }

  get isInitialized() {
    return this.#initialized
  }

  get publicKeyJwk() {
    return this.#publicKey ? exportPublicKey({ publicKey: this.#publicKey }) : null
  }

  // Cache a peer's public key
  async cachePeerPublicKey(userId, publicKeyJwk) {
    if (publicKeyJwk) {
      const key = await importPublicKey(publicKeyJwk)
      this.#peerPublicKeys.set(userId, key)
    }
  }

  // Get or fetch a peer's public key
  async getPeerPublicKey(userId) {
    if (this.#peerPublicKeys.has(userId)) {
      return this.#peerPublicKeys.get(userId)
    }

    // Fetch from server
    const response = await fetch(`/users/${userId}/encryption_key.json`)
    if (!response.ok) return null

    const data = await response.json()
    if (data.identity_public_key) {
      const jwk = JSON.parse(data.identity_public_key)
      const key = await importPublicKey(jwk)
      this.#peerPublicKeys.set(userId, key)
      return key
    }

    return null
  }

  // Encrypt a message for a direct conversation (ECDH-based)
  async encryptDirectMessage(recipientUserId, plaintext) {
    if (!this.#initialized) throw new Error("Encryption not initialized")

    const recipientPublicKey = await this.getPeerPublicKey(recipientUserId)
    if (!recipientPublicKey) throw new Error("Recipient has no encryption key")

    const sharedKey = await deriveSharedKey(this.#privateKey, recipientPublicKey, `dm-${this.#userId}-${recipientUserId}`)
    return await encryptMessage(sharedKey, plaintext)
  }

  // Decrypt a direct message
  async decryptDirectMessage(senderUserId, ciphertext, nonce) {
    if (!this.#initialized) throw new Error("Encryption not initialized")

    const senderPublicKey = await this.getPeerPublicKey(senderUserId)
    if (!senderPublicKey) throw new Error("Sender has no encryption key")

    const sharedKey = await deriveSharedKey(this.#privateKey, senderPublicKey, `dm-${senderUserId}-${this.#userId}`)
    return await decryptMessage(sharedKey, ciphertext, nonce)
  }

  // Encrypt a message for a room using room key
  async encryptRoomMessage(roomId, plaintext) {
    if (!this.#initialized) throw new Error("Encryption not initialized")

    const roomKey = await this.#getRoomKey(roomId)
    if (!roomKey) throw new Error("No room key available")

    return await encryptMessage(roomKey, plaintext)
  }

  // Decrypt a room message
  async decryptRoomMessage(roomId, ciphertext, nonce) {
    if (!this.#initialized) throw new Error("Encryption not initialized")

    const roomKey = await this.#getRoomKey(roomId)
    if (!roomKey) throw new Error("No room key available")

    return await decryptMessage(roomKey, ciphertext, nonce)
  }

  // Generate and distribute a room key to all members
  async createRoomKey(roomId, memberPublicKeys) {
    if (!this.#initialized) throw new Error("Encryption not initialized")

    const roomKey = await generateRoomKey()
    const rawKey = await exportAesKey(roomKey)
    const roomKeyBase64 = arrayBufferToBase64(rawKey)

    // Cache locally
    this.#roomKeys.set(roomId, roomKey)
    await saveRoomKey(roomId, roomKeyBase64)

    // Encrypt room key for each member
    const encryptedKeys = {}
    for (const [userId, publicKeyJwk] of Object.entries(memberPublicKeys)) {
      const memberPublicKey = await importPublicKey(publicKeyJwk)
      const encrypted = await encryptRoomKeyForUser(this.#privateKey, memberPublicKey, roomKey)
      encryptedKeys[userId] = encrypted
    }

    return encryptedKeys
  }

  // Receive and decrypt a room key from another member
  async receiveRoomKey(roomId, senderPublicKeyJwk, encryptedKeyBase64, nonceBase64) {
    if (!this.#initialized) throw new Error("Encryption not initialized")

    const senderPublicKey = await importPublicKey(senderPublicKeyJwk)
    const roomKey = await decryptRoomKey(this.#privateKey, senderPublicKey, encryptedKeyBase64, nonceBase64)

    const rawKey = await exportAesKey(roomKey)
    const roomKeyBase64 = arrayBufferToBase64(rawKey)

    this.#roomKeys.set(roomId, roomKey)
    await saveRoomKey(roomId, roomKeyBase64)

    return roomKey
  }

  // Get a room key from cache or IndexedDB
  async #getRoomKey(roomId) {
    if (this.#roomKeys.has(roomId)) {
      return this.#roomKeys.get(roomId)
    }

    const stored = await getRoomKey(roomId)
    if (stored) {
      const rawKey = base64ToArrayBuffer(stored.roomKeyBase64)
      const key = await importAesKey(rawKey)
      this.#roomKeys.set(roomId, key)
      return key
    }

    return null
  }
}

// Singleton instance
const encryptionManager = new EncryptionManager()
export default encryptionManager
