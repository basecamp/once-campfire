// IndexedDB-based key storage for E2E encryption private keys
// Private keys NEVER leave the browser - this is the core of E2E security

const DB_NAME = "campfire_e2e_keys"
const DB_VERSION = 1
const IDENTITY_STORE = "identity_keys"
const ROOM_KEYS_STORE = "room_keys"

function openDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION)

    request.onerror = () => reject(request.error)
    request.onsuccess = () => resolve(request.result)

    request.onupgradeneeded = (event) => {
      const db = event.target.result

      if (!db.objectStoreNames.contains(IDENTITY_STORE)) {
        db.createObjectStore(IDENTITY_STORE, { keyPath: "userId" })
      }

      if (!db.objectStoreNames.contains(ROOM_KEYS_STORE)) {
        db.createObjectStore(ROOM_KEYS_STORE, { keyPath: "roomId" })
      }
    }
  })
}

function performTransaction(storeName, mode, operation) {
  return openDatabase().then(db => {
    return new Promise((resolve, reject) => {
      const transaction = db.transaction(storeName, mode)
      const store = transaction.objectStore(storeName)
      const request = operation(store)

      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)

      transaction.oncomplete = () => db.close()
    })
  })
}

// Store identity key pair (private + public JWK)
export function saveIdentityKeyPair(userId, privateKeyJwk, publicKeyJwk) {
  return performTransaction(IDENTITY_STORE, "readwrite", (store) =>
    store.put({ userId, privateKeyJwk, publicKeyJwk, createdAt: Date.now() })
  )
}

// Retrieve identity key pair
export function getIdentityKeyPair(userId) {
  return performTransaction(IDENTITY_STORE, "readonly", (store) =>
    store.get(userId)
  )
}

// Delete identity key pair
export function deleteIdentityKeyPair(userId) {
  return performTransaction(IDENTITY_STORE, "readwrite", (store) =>
    store.delete(userId)
  )
}

// Store a decrypted room key (AES raw key as base64)
export function saveRoomKey(roomId, roomKeyBase64) {
  return performTransaction(ROOM_KEYS_STORE, "readwrite", (store) =>
    store.put({ roomId, roomKeyBase64, updatedAt: Date.now() })
  )
}

// Retrieve a room key
export function getRoomKey(roomId) {
  return performTransaction(ROOM_KEYS_STORE, "readonly", (store) =>
    store.get(roomId)
  )
}

// Delete a room key
export function deleteRoomKey(roomId) {
  return performTransaction(ROOM_KEYS_STORE, "readwrite", (store) =>
    store.delete(roomId)
  )
}

// Check if user has an identity key pair
export async function hasIdentityKey(userId) {
  const keyPair = await getIdentityKeyPair(userId)
  return keyPair !== undefined
}

// Export identity key pair for backup/transfer (user must explicitly trigger this)
export async function exportIdentityForBackup(userId) {
  const keyPair = await getIdentityKeyPair(userId)
  if (!keyPair) return null

  return JSON.stringify({
    version: 1,
    userId: keyPair.userId,
    privateKeyJwk: keyPair.privateKeyJwk,
    publicKeyJwk: keyPair.publicKeyJwk,
    exportedAt: Date.now()
  })
}

// Import identity key pair from backup
export async function importIdentityFromBackup(backupJson) {
  const backup = JSON.parse(backupJson)
  if (backup.version !== 1) throw new Error("Unsupported backup version")

  return saveIdentityKeyPair(backup.userId, backup.privateKeyJwk, backup.publicKeyJwk)
}
