// E2E Encryption module using Web Crypto API
// Implements ECDH key exchange + AES-256-GCM encryption (Signal-inspired)

const ECDH_PARAMS = { name: "ECDH", namedCurve: "P-256" }
const AES_PARAMS = { name: "AES-GCM", length: 256 }
const HKDF_PARAMS = { name: "HKDF", hash: "SHA-256" }

// Generate an ECDH key pair for identity
export async function generateIdentityKeyPair() {
  return await crypto.subtle.generateKey(ECDH_PARAMS, true, ["deriveKey", "deriveBits"])
}

// Export public key as JWK for server storage
export async function exportPublicKey(keyPair) {
  return await crypto.subtle.exportKey("jwk", keyPair.publicKey)
}

// Export private key as JWK for IndexedDB storage
export async function exportPrivateKey(keyPair) {
  return await crypto.subtle.exportKey("jwk", keyPair.privateKey)
}

// Import a public key from JWK
export async function importPublicKey(jwk) {
  return await crypto.subtle.importKey("jwk", jwk, ECDH_PARAMS, true, [])
}

// Import a private key from JWK
export async function importPrivateKey(jwk) {
  return await crypto.subtle.importKey("jwk", jwk, ECDH_PARAMS, true, ["deriveKey", "deriveBits"])
}

// Derive a shared AES key from our private key and their public key using ECDH + HKDF
export async function deriveSharedKey(privateKey, publicKey, context) {
  const sharedBits = await crypto.subtle.deriveBits(
    { name: "ECDH", public: publicKey },
    privateKey,
    256
  )

  const encoder = new TextEncoder()
  const hkdfKey = await crypto.subtle.importKey("raw", sharedBits, "HKDF", false, ["deriveKey"])

  return await crypto.subtle.deriveKey(
    {
      ...HKDF_PARAMS,
      salt: encoder.encode("campfire-e2e-v1"),
      info: encoder.encode(context || "message-encryption")
    },
    hkdfKey,
    AES_PARAMS,
    true,
    ["encrypt", "decrypt"]
  )
}

// Generate a random AES-256 key for room/group encryption
export async function generateRoomKey() {
  return await crypto.subtle.generateKey(AES_PARAMS, true, ["encrypt", "decrypt"])
}

// Export AES key as raw bytes
export async function exportAesKey(key) {
  return await crypto.subtle.exportKey("raw", key)
}

// Import AES key from raw bytes
export async function importAesKey(rawKey) {
  return await crypto.subtle.importKey("raw", rawKey, AES_PARAMS, true, ["encrypt", "decrypt"])
}

// Encrypt a message with AES-256-GCM
export async function encryptMessage(key, plaintext) {
  const encoder = new TextEncoder()
  const nonce = crypto.getRandomValues(new Uint8Array(12))

  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce },
    key,
    encoder.encode(plaintext)
  )

  return {
    ciphertext: arrayBufferToBase64(ciphertext),
    nonce: arrayBufferToBase64(nonce)
  }
}

// Decrypt a message with AES-256-GCM
export async function decryptMessage(key, ciphertextBase64, nonceBase64) {
  const decoder = new TextDecoder()
  const ciphertext = base64ToArrayBuffer(ciphertextBase64)
  const nonce = base64ToArrayBuffer(nonceBase64)

  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: nonce },
    key,
    ciphertext
  )

  return decoder.decode(plaintext)
}

// Encrypt a room key for a specific user using ECDH-derived shared key
export async function encryptRoomKeyForUser(ourPrivateKey, theirPublicKey, roomKey) {
  const sharedKey = await deriveSharedKey(ourPrivateKey, theirPublicKey, "room-key-encryption")
  const rawRoomKey = await exportAesKey(roomKey)
  const nonce = crypto.getRandomValues(new Uint8Array(12))

  const encryptedRoomKey = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce },
    sharedKey,
    rawRoomKey
  )

  return {
    encryptedKey: arrayBufferToBase64(encryptedRoomKey),
    nonce: arrayBufferToBase64(nonce)
  }
}

// Decrypt a room key using ECDH-derived shared key
export async function decryptRoomKey(ourPrivateKey, theirPublicKey, encryptedKeyBase64, nonceBase64) {
  const sharedKey = await deriveSharedKey(ourPrivateKey, theirPublicKey, "room-key-encryption")
  const encryptedKey = base64ToArrayBuffer(encryptedKeyBase64)
  const nonce = base64ToArrayBuffer(nonceBase64)

  const rawRoomKey = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: nonce },
    sharedKey,
    encryptedKey
  )

  return await importAesKey(rawRoomKey)
}

// Utility: ArrayBuffer to Base64
export function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer)
  let binary = ""
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i])
  }
  return btoa(binary)
}

// Utility: Base64 to ArrayBuffer
export function base64ToArrayBuffer(base64) {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i)
  }
  return bytes.buffer
}
