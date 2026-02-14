import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "localVideo",
    "localPlaceholder",
    "localControls",
    "remoteVideos",
    "muteButton",
    "cameraButton",
    "screenShareButton",
    "joinLeaveButton",
    "joinLeaveIcon",
    "joinLeaveLabel",
    "errorMessage"
  ]
  static classes = [ "active", "muted", "hidden" ]

  static values = {
    roomId: Number,
    iconMessages: String,
    iconRemove: String,
    iconDisclosure: String,
    livekitConfigured: Boolean
  }

  #room = null
  #observerRoom = null
  #localVideoTrack = null
  #localAudioTrack = null
  #localScreenTrack = null
  #remoteParticipants = new Map()
  #startHandler = null
  #localAvatarUrl = null
  #participantAvatarUrls = new Map() // Store avatar URLs by participant identity
  #connectionCredentials = null // Store { url, token, roomName } for reconnection
  #reconnectionAttempts = 0
  #maxReconnectionAttempts = 10
  #reconnectionTimeout = null
  #isReconnecting = false
  #connectionQuality = null
  #videoPresets = null // Store VideoPresets for quality adaptation
  #joinLeaveDisabled = false
  #roomEventHandlers = new Map()
  #turboLoadHandler = null
  #screenShareEndHandlers = new Map() // Track screen share end handlers for cleanup

  async connect() {
    this.#setupEventListeners()
    this.#bindTurboHandlers()
    this.#updateRoomContextFromMeta()
    // Update button immediately - DOM should be ready in connect()
    this.#updateJoinLeaveButton()
    const livekitConfigured = this.#isLiveKitConfigured()
    this.#setJoinLeaveDisabled(!livekitConfigured)
    if (!livekitConfigured) {
      this.#showError("LiveKit is not configured for this deployment.", "config")
    }
    this.#updateSoloLayout()
    // Show placeholder initially if no camera track exists
    if (!this.#localVideoTrack && this.hasLocalPlaceholderTarget) {
      this.localPlaceholderTarget.style.display = "block"
      // Hide video if it exists
      if (this.hasLocalVideoTarget) {
        this.localVideoTarget.style.display = "none"
      }
    }
    // Update controls visibility immediately
    this.#updateLocalControlsVisibility()

    // FIXED: Coordinate active call adoption and observer mode
    const activeCall = this.#getActiveCall()
    if (activeCall && activeCall.roomId === this.roomIdValue) {
      await this.#adoptActiveCallIfPresent()
    } else {
      await this.#ensureObserverIfNeeded()
    }
  }

  disconnect() {
    // ALWAYS unbind Turbo handlers first (prevents memory leak)
    this.#unbindTurboHandlers()

    // Clear any pending reconnection attempts
    this.#clearReconnectionTimeout()

    if (this.#room && !this.#isUserDisconnect) {
      this.#persistActiveCall()
      return
    }

    // Only cleanup if controller is still connected to DOM
    if (this.element.isConnected) {
      this.leave()
    } else {
      if (this.#observerRoom) {
        this.#disconnectObserver()
      }
      // Element already removed, just cleanup resources
      if (this.#room) {
        this.#room.disconnect()
        this.#room = null
      }
      this.#cleanupLocalTracks()
      this.#cleanupRemoteTracks()
      this.#connectionCredentials = null
    }
  }

  toggleJoinLeave() {
    if (this.#room) {
      this.leave()
    } else {
      this.startVideoCall()
    }
  }


  async startVideoCall(event) {
    if (!this.#isLiveKitConfigured()) {
      this.#showError("LiveKit is not configured for this deployment.", "config")
      return
    }
    if (this.#room) {
      console.log("Already connected to room")
      return // Already connected
    }
    
    // Don't use event parameter for button clicks
    if (event && event.preventDefault) {
      event.preventDefault()
    }
    
    // If event has roomId detail, use it
    if (event?.detail?.roomId) {
      this.roomIdValue = event.detail.roomId
    }

      console.log("Starting video call...")
    try {
      this.#isUserDisconnect = false // Reset user disconnect flag
      await this.#endActiveCallIfNeeded()
      if (this.#observerRoom) {
        this.#disconnectObserver()
      }
      this.#setLoading(true)
      this.#updateConnectionState("connecting")
      
      // Container is always visible now, just mark as active
      this.element.classList.add(this.activeClass)
      
      const { token, url, room_name } = await this.#fetchToken()
      console.log("Got token, connecting to room...")

      await this.#connectToRoom(url, token, room_name)
      console.log("Connected to room, enabling camera/microphone...")

      await this.#enableCameraAndMicrophone()
      console.log("Camera/microphone setup complete")
      
      this.#setLoading(false)
      this.#setActiveCall({
        roomId: this.roomIdValue,
        room: this.#room,
        localVideoTrack: this.#localVideoTrack,
        localAudioTrack: this.#localAudioTrack,
        localScreenTrack: this.#localScreenTrack,
        connectionCredentials: this.#connectionCredentials
      })
      // Button state will be updated by RoomEvent.Connected handler
      this.dispatch("started", { detail: { room: this.#room } })
    } catch (error) {
      console.error("Failed to start video call:", error)
      this.#handleError(error)
      this.#setLoading(false)
    }
  }

  leave() {
    this.#isUserDisconnect = true
    this.#clearReconnectionTimeout()
    this.#connectionCredentials = null
    this.#reconnectionAttempts = 0
    this.#isReconnecting = false
    this.#clearActiveCall()
    
    // Disconnect room (this will clean up all event listeners)
    if (this.#room) {
      this.#unbindRoomEvents(this.#room)
      this.#room.disconnect()
      this.#room = null
    }

    if (this.#observerRoom) {
      this.#disconnectObserver()
    }

    // Clean up all tracks
    this.#cleanupLocalTracks()
    this.#cleanupRemoteTracks()
    
    // Clear all caches and maps
    this.#participantAvatarUrls.clear()
    this.#remoteParticipants.clear()
    this.#localAvatarUrl = null
    
    // Remove active class and connection state classes
    this.element.classList.remove(this.activeClass)
    this.#updateConnectionState("disconnected")
    
    // Hide error message if visible
    this.dismissError()
    
    this.#updateJoinLeaveButton()
    
    // Only dispatch if element is still connected
    if (this.element.isConnected) {
      this.dispatch("left")
    }
  }

  async toggleMute() {
    if (this.#localAudioTrack) {
      try {
        // Get current mute state from the button to determine action
        const isCurrentlyMuted = this.muteButtonTarget.classList.contains(this.mutedClass)
        
        if (isCurrentlyMuted) {
          await this.#localAudioTrack.unmute()
        } else {
          await this.#localAudioTrack.mute()
        }
        
        // Immediately update visual state (optimistic update)
        this.muteButtonTarget.classList.toggle(this.mutedClass, !isCurrentlyMuted)
        
        // Update state immediately - track mute/unmute is synchronous
        this.#updateMuteButtonState()
      } catch (error) {
        console.error("Error toggling mute:", error)
        // Fallback: try using the underlying MediaStreamTrack directly
        if (this.#localAudioTrack.mediaStreamTrack) {
          const wasEnabled = this.#localAudioTrack.mediaStreamTrack.enabled
          this.#localAudioTrack.mediaStreamTrack.enabled = !wasEnabled
          // Update state immediately after fallback
          this.#updateMuteButtonState()
        }
      }
    } else if (this.#room && this.#room.localParticipant) {
      // Track doesn't exist yet, try to create it
      try {
        const LiveKit = this.LiveKit || await this.#loadLiveKit()
        const { createLocalAudioTrack } = LiveKit
             const microphoneTrack = await this.#createMicrophoneTrack(createLocalAudioTrack)
               if (microphoneTrack) {
                 await this.#room.localParticipant.publishTrack(microphoneTrack)
                 this.#localAudioTrack = microphoneTrack
                 // Update state immediately after track is published
                 this.#updateMuteButtonState()
               }
      } catch (error) {
        console.error("Failed to enable microphone:", error)
      }
    }
  }

  async toggleCamera() {
    if (this.#localVideoTrack) {
      try {
        const currentlyMuted = this.#localVideoTrack.isMuted
        if (currentlyMuted) {
          await this.#localVideoTrack.unmute()
          // Hide placeholder, show video
          if (this.hasLocalPlaceholderTarget) {
            this.localPlaceholderTarget.style.display = "none"
          }
          if (this.hasLocalVideoTarget) {
            this.localVideoTarget.style.display = "block"
          }
        } else {
          await this.#localVideoTrack.mute()
          // Show placeholder, hide video
          if (this.hasLocalVideoTarget) {
            this.localVideoTarget.style.display = "none"
          }
          if (this.hasLocalPlaceholderTarget) {
            this.localPlaceholderTarget.style.display = "block"
          }
        }
               // Update controls visibility
               this.#updateLocalControlsVisibility()
               // Update camera button state immediately
               this.#updateCameraButtonState()
      } catch (error) {
        console.error("Error toggling camera:", error)
        // Fallback: try using the underlying MediaStreamTrack
        if (this.#localVideoTrack.mediaStreamTrack) {
          const wasEnabled = this.#localVideoTrack.mediaStreamTrack.enabled
          this.#localVideoTrack.mediaStreamTrack.enabled = !wasEnabled
          // Update UI based on enabled state
          if (!wasEnabled) {
            // Camera was off, turning on
            if (this.hasLocalPlaceholderTarget) {
              this.localPlaceholderTarget.style.display = "none"
            }
            if (this.hasLocalVideoTarget) {
              this.localVideoTarget.style.display = "block"
            }
          } else {
            // Camera was on, turning off
            if (this.hasLocalVideoTarget) {
              this.localVideoTarget.style.display = "none"
            }
            if (this.hasLocalPlaceholderTarget) {
              this.localPlaceholderTarget.style.display = "block"
            }
          }
          this.#updateLocalControlsVisibility()
          this.#updateCameraButtonState()
        }
      }
    }
  }

  #updateLocalControlsVisibility() {
    if (!this.hasLocalControlsTarget) return
    
    const hasVideoStream = this.hasLocalVideoTarget && this.localVideoTarget.srcObject && this.localVideoTarget.srcObject.active && this.localVideoTarget.style.display !== "none"
    const hasPlaceholder = this.hasLocalPlaceholderTarget && this.localPlaceholderTarget.style.display !== "none"
    const hasScreenShare = this.#localScreenTrack !== null && this.#localScreenTrack.video !== null
    
    if (hasVideoStream || hasPlaceholder || hasScreenShare) {
      this.localControlsTarget.style.display = "flex"
    } else {
      this.localControlsTarget.style.display = "none"
    }
  }

  #updateRemoteControlsVisibility(container) {
    if (!container) return
    
    const controls = container.querySelector('.video-call__remote-controls')
    if (!controls) return
    
    const videoElement = container.querySelector('[data-video-track="true"]')
    const placeholder = container.querySelector('.video-call__placeholder--remote')
    
    const hasVideoStream = videoElement && videoElement.srcObject && videoElement.srcObject.active && videoElement.style.display !== "none"
    const hasPlaceholder = placeholder && placeholder.style.display !== "none"
    
    // Always show controls if there's a placeholder or video stream
    // The CSS will handle the hover visibility
    if (hasVideoStream || hasPlaceholder) {
      controls.style.display = "flex"
    } else {
      controls.style.display = "none"
    }
  }

  toggleRemoteMute(event) {
    const participantIdentity = event.currentTarget.dataset.participantIdentity
    if (!participantIdentity || !this.hasRemoteVideosTarget) return
    
    const container = this.remoteVideosTarget.querySelector(
      `[data-participant-identity="${participantIdentity}"]`
    )
    if (!container) return
    
    let audioElement = container.querySelector('[data-audio-track="true"]')
    if (!audioElement) {
      const sink = this.#audioSink()
      if (sink) {
        audioElement = sink.querySelector(`[data-audio-track="true"][data-participant-identity="${participantIdentity}"]`)
      }
    }
    if (!audioElement) return
    
    const isMuted = container.dataset.audioMuted === "true"
    const muteButton = container.querySelector('[data-action*="toggleRemoteMute"]')
    
    if (isMuted) {
      // Unmute
      audioElement.muted = false
      container.dataset.audioMuted = "false"
      if (muteButton) {
        const muteIcon = muteButton.querySelector('.video-call__remote-control-icon img')
        if (muteIcon) {
          muteIcon.src = this.iconMessagesValue
          muteIcon.className = "colorize--white"
        } else {
          muteButton.querySelector('.video-call__remote-control-icon').innerHTML = `<img src="${this.iconMessagesValue}" class="colorize--white" width="16" height="16" aria-hidden="true" />`
        }
        muteButton.setAttribute("aria-label", "Mute participant")
      }
    } else {
      // Mute
      audioElement.muted = true
      container.dataset.audioMuted = "true"
      if (muteButton) {
        const muteIcon = muteButton.querySelector('.video-call__remote-control-icon img')
        if (muteIcon) {
          muteIcon.src = this.iconRemoveValue
          muteIcon.className = "colorize--white"
        } else {
          muteButton.querySelector('.video-call__remote-control-icon').innerHTML = `<img src="${this.iconRemoveValue}" class="colorize--white" width="16" height="16" aria-hidden="true" />`
        }
        muteButton.setAttribute("aria-label", "Unmute participant")
      }
    }
  }

  toggleFullscreen(event) {
    event.preventDefault()
    event.stopPropagation()
    
    const participantIdentity = event.currentTarget?.dataset?.participantIdentity
    if (!participantIdentity) {
      console.error("No participant identity found in fullscreen button")
      return
    }
    
    let videoElement = null
    let placeholderElement = null
    let containerElement = null
    
    if (participantIdentity === "local") {
      // Handle local video fullscreen
      if (!this.hasLocalVideoTarget) return
      videoElement = this.localVideoTarget
      placeholderElement = this.hasLocalPlaceholderTarget ? this.localPlaceholderTarget : null
      containerElement = this.element.querySelector('.video-call__local')
    } else {
      // Handle remote video fullscreen
      if (!this.hasRemoteVideosTarget) {
        console.error("No remote videos target available")
        return
      }
      
      containerElement = this.remoteVideosTarget.querySelector(
        `[data-participant-identity="${participantIdentity}"]`
      )
      if (!containerElement) {
        console.error("Could not find container for participant:", participantIdentity)
        return
      }
      
      videoElement = containerElement.querySelector('[data-video-track="true"]')
      placeholderElement = containerElement.querySelector('.video-call__placeholder--remote')
    }
    
    // Check if we have a video stream or placeholder - if neither, don't allow fullscreen
    const hasVideoStream = videoElement && videoElement.srcObject && videoElement.srcObject.active && videoElement.style.display !== "none"
    const hasPlaceholder = placeholderElement && placeholderElement.style.display !== "none"
    
    if (!hasVideoStream && !hasPlaceholder) {
      // No video or placeholder - don't allow fullscreen
      console.warn("No video stream or placeholder available for fullscreen")
      return
    }
    
    // Use the container element for fullscreen (this will include video/placeholder and name overlay)
    const elementToFullscreen = containerElement || ((hasVideoStream && videoElement) ? videoElement : (placeholderElement || videoElement))
    
    if (!elementToFullscreen) {
      console.error("No element available for fullscreen")
      return
    }
    
    if (!document.fullscreenElement) {
      // Enter fullscreen
      elementToFullscreen.requestFullscreen().catch(err => {
        console.error("Error attempting to enable fullscreen:", err)
        // Fallback: try webkit/moz prefixes
        if (elementToFullscreen.webkitRequestFullscreen) {
          elementToFullscreen.webkitRequestFullscreen()
        } else if (elementToFullscreen.mozRequestFullScreen) {
          elementToFullscreen.mozRequestFullScreen()
        }
      })
    } else {
      // Exit fullscreen
      if (document.exitFullscreen) {
        document.exitFullscreen().catch(err => console.error("Error exiting fullscreen:", err))
      } else if (document.webkitExitFullscreen) {
        document.webkitExitFullscreen()
      } else if (document.mozCancelFullScreen) {
        document.mozCancelFullScreen()
      }
    }
  }

  async toggleScreenShare() {
    if (this.#localScreenTrack) {
      await this.#stopScreenShare()
    } else {
      // Start screen sharing
      try {
        const screenTracks = await this.#createScreenTrack()
        
        // Don't unpublish camera - keep it published but show screen share in video element
        // Publish screen track with proper source metadata
        const LiveKit = this.LiveKit || await this.#loadLiveKit()
        const { Track } = LiveKit
        
        // Publish video track
        await this.#room.localParticipant.publishTrack(screenTracks.video, {
          source: Track.Source.ScreenShare,
          name: "screen-share-video"
        })
        
        // Publish audio track if available
        if (screenTracks.audio) {
          await this.#room.localParticipant.publishTrack(screenTracks.audio, {
            source: Track.Source.ScreenShareAudio,
            name: "screen-share-audio"
          })
        }
        
        this.#localScreenTrack = screenTracks
        
        // Show screen share in the video element (but keep camera published)
        if (this.hasLocalVideoTarget) {
          // Create a MediaStream with both video and audio (if available)
          const streams = [screenTracks.video]
          if (screenTracks.audio) {
            streams.push(screenTracks.audio)
          }
          this.localVideoTarget.srcObject = new MediaStream(streams)
          this.localVideoTarget.style.display = "block"
          // Remove mirror transform for screen share (don't mirror screen)
          this.localVideoTarget.style.transform = "none"
          this.localVideoTarget.classList.add("video-call__video--screen-share")
          // Hide placeholder when sharing screen
          if (this.hasLocalPlaceholderTarget) {
            this.localPlaceholderTarget.style.display = "none"
          }
        }
        // Update controls visibility
        this.#updateLocalControlsVisibility()
      } catch (error) {
        console.error("Failed to share screen:", error)
      }
    }
    this.#updateScreenShareButtonState()
  }

  // Private methods

  async #fetchToken(options = {}) {
    // Get room ID from value or current room
    const roomId = this.roomIdValue || Current?.room?.id
    if (!roomId) {
      throw new Error("Room ID not available")
    }

    const response = await fetch("/api/livekit/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
      },
      body: JSON.stringify({ room_id: roomId, mode: options.mode })
    })

    if (!response.ok) {
      const error = await response.json().catch(() => ({}))
      throw new Error(error.error || "Failed to get access token")
    }

    const data = await response.json()
    // Store avatar URL for later use
    this.#localAvatarUrl = data.avatar_url
    return data
  }

  async #connectToRoom(url, token, roomName) {
    const LiveKit = await this.#loadLiveKit()
    const { Room, VideoPresets } = LiveKit
    
    this.LiveKit = LiveKit
    this.#videoPresets = VideoPresets // Store for later use (don't assign to module)
    
    // Create room instance
    this.#room = new Room()

    // Store credentials for reconnection
    this.#connectionCredentials = { url, token, roomName }

    // Set up event handlers before connecting
    this.#bindRoomEvents(this.#room, { observer: false })
    
    // Handle connection event - subscribe to existing tracks and update button
    // Connect to room - adaptive streaming is handled automatically by LiveKit
    await this.#room.connect(url, token)
    
    // Update UI after connection attempt
    this.#updateJoinLeaveButton()
  }
  
  async #loadLiveKit() {
    if (window.LiveKit) {
      return window.LiveKit
    }
    
    // Dynamically import from CDN - using livekit-client package name
    // The package exports ESM at dist/livekit-client.esm.mjs
    const module = await import("https://cdn.jsdelivr.net/npm/livekit-client@2.15.13/dist/livekit-client.esm.mjs")
    window.LiveKit = module
    return module
  }

  async #enableCameraAndMicrophone() {
    try {
      const { createLocalVideoTrack, createLocalAudioTrack } = this.LiveKit || await this.#loadLiveKit()
      
      // Try to get microphone first (usually more critical)
             const microphoneTrack = await this.#createMicrophoneTrack(createLocalAudioTrack)
             if (microphoneTrack) {
               await this.#room.localParticipant.publishTrack(microphoneTrack)
               this.#localAudioTrack = microphoneTrack
               // Update button state immediately after track is published
               this.#updateMuteButtonState()
             }
      
      // Try to get camera, but don't fail if it's not available
      try {
        const cameraTrack = await this.#createCameraTrack(createLocalVideoTrack)
        if (cameraTrack) {
          await this.#room.localParticipant.publishTrack(cameraTrack)
          this.#localVideoTrack = cameraTrack
          if (this.hasLocalVideoTarget) {
            this.#attachVideoTrack(cameraTrack, this.localVideoTarget)
            // Ensure mirror transform for camera (not screen share)
            this.localVideoTarget.style.transform = "scaleX(-1)"
            this.localVideoTarget.classList.remove("video-call__video--screen-share")
            // Hide placeholder when camera is working
            if (this.hasLocalPlaceholderTarget) {
              this.localPlaceholderTarget.style.display = "none"
            }
          }
        }
      } catch (cameraError) {
        // Camera is optional - log but don't fail
        console.warn("Camera not available, continuing with audio only:", cameraError.message)
        // Show profile picture placeholder
        if (this.hasLocalVideoTarget) {
          this.localVideoTarget.style.display = "none"
        }
        if (this.hasLocalPlaceholderTarget) {
          this.localPlaceholderTarget.style.display = "block"
        }
      } finally {
        // If no camera track was created, ensure placeholder is visible
        if (!this.#localVideoTrack && this.hasLocalPlaceholderTarget) {
          this.localPlaceholderTarget.style.display = "block"
        }
      }

      this.#updateMuteButtonState()
      this.#updateCameraButtonState()
    } catch (error) {
      console.error("Failed to enable camera/microphone:", error)
      this.#handleError(error)
    }
  }

  async #createCameraTrack(createLocalVideoTrack) {
    try {
      if (!createLocalVideoTrack) {
        const LiveKit = await this.#loadLiveKit()
        createLocalVideoTrack = LiveKit.createLocalVideoTrack
      }
      
      // Use VideoPresets for better quality adaptation
      const VideoPresets = this.#videoPresets || (await this.#loadLiveKit()).VideoPresets
      
      // Start with medium quality (720p) - will adapt based on connection
      const initialPreset = VideoPresets?.h720_30 || { resolution: { width: 1280, height: 720 } }
      
      // Try to create camera track - this will prompt for permissions if needed
      // The browser will handle device availability checks
      return await createLocalVideoTrack({
        resolution: initialPreset.resolution || { width: 1280, height: 720 },
        // Enable adaptive encoding
        videoEncoder: initialPreset.encoding
      })
    } catch (error) {
      // Handle specific error types - camera is optional
      if (error.name === 'NotFoundError' || error.name === 'NotReadableError' || error.name === 'NotAllowedError') {
        console.warn("Camera not available:", error.message)
      } else {
        console.warn("Camera error (non-critical):", error.message)
      }
      return null
    }
  }

  async #createMicrophoneTrack(createLocalAudioTrack) {
    try {
      if (!createLocalAudioTrack) {
        const LiveKit = await this.#loadLiveKit()
        createLocalAudioTrack = LiveKit.createLocalAudioTrack
      }
      return await createLocalAudioTrack()
    } catch (error) {
      console.error("Failed to get microphone:", error)
      return null
    }
  }

  async #createScreenTrack() {
    try {
      // Get screen share stream using native API with audio enabled
      const stream = await navigator.mediaDevices.getDisplayMedia({
        video: {
          width: { ideal: 1920 },
          height: { ideal: 1080 }
        },
        audio: true // Enable audio capture for screen sharing
      })
      
      const LiveKit = this.LiveKit || await this.#loadLiveKit()
      
      // Get the video track
      const videoTrack = stream.getVideoTracks()[0]
      if (!videoTrack) {
        throw new Error("No video track in screen share stream")
      }

      // Store listener reference for cleanup
      const endHandler = () => { void this.#stopScreenShare() }
      videoTrack.addEventListener("ended", endHandler, { once: true })

      // Track for manual cleanup if needed
      this.#screenShareEndHandlers.set(videoTrack, endHandler)

      // Get the audio track if available (not all screen sharing includes audio)
      const audioTrack = stream.getAudioTracks()[0]

      // Return both tracks
      return {
        video: videoTrack,
        audio: audioTrack
      }
    } catch (error) {
      console.error("Failed to get screen share:", error)
      throw error
    }
  }

  #attachVideoTrack(track, element) {
    if (element && track) {
      try {
        track.attach(element)
        element.style.display = "block"
        console.log("Video track attached to element:", element)
        
        // Hide placeholder for local video
        if (this.hasLocalPlaceholderTarget && element === this.localVideoTarget) {
          this.localPlaceholderTarget.style.display = "none"
        }
        // Update controls visibility
        if (element === this.localVideoTarget) {
          this.#updateLocalControlsVisibility()
        }
      } catch (error) {
        console.error("Error attaching video track:", error)
        // Fallback: try setting srcObject directly
        if (track.mediaStreamTrack) {
          element.srcObject = new MediaStream([track.mediaStreamTrack])
          element.style.display = "block"
          
          // Hide placeholder for local video
          if (this.hasLocalPlaceholderTarget && element === this.localVideoTarget) {
            this.localPlaceholderTarget.style.display = "none"
          }
          // Update controls visibility
          if (element === this.localVideoTarget) {
            this.#updateLocalControlsVisibility()
          }
        }
      }
    }
  }

  #showRemotePlaceholder(participant) {
    if (!this.hasRemoteVideosTarget) return
    
    const container = this.remoteVideosTarget.querySelector(
      `[data-participant-identity="${participant.identity}"]`
    )
    if (!container) return
    
    const placeholder = container.querySelector('.video-call__placeholder--remote')
    const videoElement = container.querySelector('[data-video-track="true"]')
    
    if (placeholder) {
      placeholder.style.display = "block"
    }
    if (videoElement) {
      videoElement.style.display = "none"
    }
  }

  #hideRemotePlaceholder(participant) {
    if (!this.hasRemoteVideosTarget) return
    
    const container = this.remoteVideosTarget.querySelector(
      `[data-participant-identity="${participant.identity}"]`
    )
    if (!container) return
    
    const placeholder = container.querySelector('.video-call__placeholder--remote')
    if (placeholder) {
      placeholder.style.display = "none"
    }
  }

  async #getAvatarUrl(participant) {
    // Check if we already have the URL cached
    if (this.#participantAvatarUrls.has(participant.identity)) {
      return this.#participantAvatarUrls.get(participant.identity)
    }

    // Fetch avatar URL from API
    const roomId = this.roomIdValue || Current?.room?.id
    if (!roomId) {
      return this.#getFallbackAvatarUrl(participant)
    }

    try {
      // ADDED: 5 second timeout to prevent hanging
      const controller = new AbortController()
      const timeoutId = setTimeout(() => controller.abort(), 5000)

      const response = await fetch(
        `/api/livekit/participant_avatar?room_id=${roomId}&user_id=${participant.identity}`,
        {
          headers: {
            "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
          },
          signal: controller.signal
        }
      )

      clearTimeout(timeoutId)

      if (response.ok) {
        const data = await response.json()
        const url = data.avatar_url
        if (url) {
          this.#participantAvatarUrls.set(participant.identity, url)
          return url
        }
      }
    } catch (error) {
      if (error.name === 'AbortError') {
        console.warn(`Avatar fetch timeout for ${participant.identity}`)
      } else {
        console.warn(`Failed to fetch avatar for ${participant.identity}:`, error)
      }
    }

    return this.#getFallbackAvatarUrl(participant)
  }

  #getFallbackAvatarUrl(participant) {
    const initialsSvg = this.#generateInitialsSvg(participant)
    const url = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
    this.#participantAvatarUrls.set(participant.identity, url)
    return url
  }

  #generateInitialsSvg(participant) {
    const name = participant.name || participant.identity || "U"
    const initials = name.split(' ').map(n => n[0]?.toUpperCase() || '').slice(0, 2).join('') || name[0]?.toUpperCase() || 'U'
    // Generate a color based on the name
    const colors = ['#AF2E1B', '#CC6324', '#3B4B59', '#BFA07A', '#ED8008', '#ED3F1C', '#BF1B1B', '#736B1E', '#D07B53']
    const colorIndex = (name.charCodeAt(0) || 0) % colors.length
    const bgColor = colors[colorIndex]

    return `<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
      <rect width="512" height="512" fill="${bgColor}"/>
      <text x="256" y="320" font-family="Arial, sans-serif" font-size="200" font-weight="600" fill="white" text-anchor="middle" dominant-baseline="middle">${initials}</text>
    </svg>`
  }

  #createPlaceholderElement(participant) {
    const placeholder = document.createElement("img")
    placeholder.className = "video-call__placeholder video-call__placeholder--remote"
    placeholder.dataset.participantIdentity = participant.identity
    placeholder.alt = participant.name || participant.identity
    placeholder.style.display = "block"
    // Set up error handler for fallback to initials
    placeholder.onerror = () => {
      const initialsSvg = this.#generateInitialsSvg(participant)
      placeholder.src = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
    }
    return placeholder
  }

  #createLabelElement(participant) {
    const label = document.createElement("div")
    label.className = "video-call__participant-name"
    label.textContent = participant.name || participant.identity
    return label
  }

  #createControlsElement(participant) {
    const controls = document.createElement("div")
    controls.className = "video-call__remote-controls"
    controls.innerHTML = `
      <button type="button"
              class="video-call__remote-control-button"
              data-participant-identity="${participant.identity}"
              data-action="click->video-call#toggleRemoteMute"
              aria-label="Mute participant">
        <span class="video-call__remote-control-icon">
          <img src="${this.iconMessagesValue}" class="colorize--white" width="16" height="16" aria-hidden="true" />
        </span>
      </button>
      <button type="button"
              class="video-call__remote-control-button"
              data-participant-identity="${participant.identity}"
              data-action="click->video-call#toggleFullscreen"
              aria-label="Fullscreen">
        <span class="video-call__remote-control-icon">
          <img src="${this.iconDisclosureValue}" class="colorize--white" width="16" height="16" aria-hidden="true" />
        </span>
      </button>
    `
    return controls
  }

  async #loadAvatarForPlaceholder(participant, placeholder) {
    try {
      const url = await this.#getAvatarUrl(participant)
      if (url && placeholder.isConnected) {
        placeholder.src = url
      }
    } catch (error) {
      console.warn(`Failed to load avatar for ${participant.identity}:`, error)
      const initialsSvg = this.#generateInitialsSvg(participant)
      if (placeholder.isConnected) {
        placeholder.src = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
      }
    }
  }

  #onTrackSubscribed(track, publication, participant, options = {}) {
    const Track = this.LiveKit?.Track
    
    if (track.kind === Track?.Kind?.Video || track.kind === "video") {
      console.log("Video track subscribed for participant:", participant.identity)
      const videoElement = this.#createRemoteVideoElement(participant)
      if (videoElement) {
        this.#attachVideoTrack(track, videoElement)
        // Hide placeholder when video track is attached
        this.#hideRemotePlaceholder(participant)
        // Update controls visibility
        const container = this.remoteVideosTarget?.querySelector(
          `[data-participant-identity="${participant.identity}"]`
        )
        if (container) {
          this.#updateRemoteControlsVisibility(container)
        }
      } else {
        console.error("Could not create video element for participant:", participant.identity)
      }
    } else if (track.kind === Track?.Kind?.Audio || track.kind === "audio") {
      // Handle audio tracks - attach to an audio element
      const audioElement = this.#getOrCreateRemoteAudioElement(participant)
      if (audioElement) {
        track.attach(audioElement)
        if (options.observer) {
          audioElement.muted = true
        }
        console.log("Audio track attached for participant:", participant.identity)
      }
    }
  }

  #onTrackUnsubscribed(track, publication, participant) {
    const Track = this.LiveKit?.Track
    track.detach()
    
    if (track.kind === Track?.Kind?.Video || track.kind === "video") {
      // Show placeholder when video track is removed
      this.#showRemotePlaceholder(participant)
      // Don't remove the element, just hide video and show placeholder
      const container = this.remoteVideosTarget?.querySelector(
        `[data-participant-identity="${participant.identity}"]`
      )
      if (container) {
        const videoElement = container.querySelector('[data-video-track="true"]')
        if (videoElement) {
          videoElement.style.display = "none"
          videoElement.srcObject = null
        }
      }
    } else if (track.kind === Track?.Kind?.Audio || track.kind === "audio") {
      // Audio track unsubscribed - remove audio element if no more audio tracks
      this.#cleanupRemoteAudioElement(participant)
    }
  }

  #onParticipantConnected(participant) {
    this.#remoteParticipants.set(participant.identity, participant)
    this.#updateSoloLayout()
    this.dispatch("participant-joined", { detail: { participant } })
  }

  #onParticipantDisconnected(participant) {
    this.#remoteParticipants.delete(participant.identity)
    this.#removeRemoteVideoElement(participant)
    this.#updateSoloLayout()
    this.dispatch("participant-left", { detail: { participant } })
  }

  #onDisconnected(reason) {
    // Only attempt reconnection if we have credentials and haven't exceeded max attempts
    if (this.#connectionCredentials && this.#reconnectionAttempts < this.#maxReconnectionAttempts) {
      // Check if this was an unexpected disconnect (not user-initiated)
      if (!this.#isUserDisconnect) {
        this.#attemptReconnection()
      } else {
        // User-initiated disconnect, clean up
        this.leave()
      }
    } else {
      // Max attempts reached or no credentials, clean up
      if (this.#reconnectionAttempts >= this.#maxReconnectionAttempts) {
        this.#handleError(new Error("Failed to reconnect after multiple attempts"))
      }
      this.leave()
    }
  }

  #onReconnecting() {
    this.#isReconnecting = true
    this.#updateConnectionState("reconnecting")
    this.dispatch("reconnecting", { detail: { attempt: this.#reconnectionAttempts } })
  }

  #onReconnected() {
    this.#isReconnecting = false
    this.#reconnectionAttempts = 0
    this.#updateConnectionState("connected")
    this.dispatch("reconnected")
  }

  #onConnectionQualityChanged(quality) {
    this.#connectionQuality = quality
    this.#updateConnectionState("connected", quality)
    
    // Adapt video quality based on connection quality
    this.#adaptVideoQuality(quality)
    
    this.dispatch("connection-quality-changed", { detail: { quality } })
  }

  #adaptVideoQuality(quality) {
    if (!this.#localVideoTrack || !this.#videoPresets) return
    
    const VideoPresets = this.#videoPresets
    let videoPreset
    
    // Adjust video quality based on connection quality
    // ConnectionQuality enum: Excellent=4, Good=3, Fair=2, Poor=1, Lost=0
    switch (quality) {
      case 4: // Excellent
        videoPreset = VideoPresets.h1080_30
        break
      case 3: // Good
        videoPreset = VideoPresets.h720_30
        break
      case 2: // Fair
        videoPreset = VideoPresets.h540_30
        break
      case 1: // Poor
      case 0: // Lost
        videoPreset = VideoPresets.h360_30
        break
      default:
        videoPreset = VideoPresets.h720_30
    }
    
    try {
      // Update the video track encoding settings
      if (this.#localVideoTrack.setPublishingQuality) {
        this.#localVideoTrack.setPublishingQuality(videoPreset)
      } else if (this.#localVideoTrack.setEncoding) {
        // Alternative method if setPublishingQuality doesn't exist
        this.#localVideoTrack.setEncoding(videoPreset.encoding)
      }
      
      console.log(`Video quality adjusted to ${quality === 4 ? '1080p' : quality === 3 ? '720p' : quality === 2 ? '540p' : '360p'} based on connection quality: ${quality}`)
    } catch (error) {
      console.warn("Failed to adapt video quality:", error)
    }
  }

  #isUserDisconnect = false

  async #attemptReconnection() {
    if (!this.#connectionCredentials || this.#isReconnecting) {
      return
    }

    this.#reconnectionAttempts++
    this.#isReconnecting = true
    this.#updateConnectionState("reconnecting")
    
    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, max 30s
    const baseDelay = 1000
    const maxDelay = 30000
    const delay = Math.min(baseDelay * Math.pow(2, this.#reconnectionAttempts - 1), maxDelay)
    
    this.dispatch("reconnecting", { detail: { attempt: this.#reconnectionAttempts, nextAttemptIn: delay / 1000 } })
    
    this.#reconnectionTimeout = setTimeout(async () => {
      try {
        // Try to reconnect with existing credentials
        if (this.#room && this.#connectionCredentials) {
          await this.#room.connect(
            this.#connectionCredentials.url,
            this.#connectionCredentials.token
          )
        } else {
          // Room was destroyed, need full reconnection
          await this.#fullReconnection()
        }
      } catch (error) {
        console.error("Reconnection attempt failed:", error)
        // Will trigger onDisconnected again if connection fails
      }
    }, delay)
  }

  async #fullReconnection() {
    // Fetch new token and reconnect
    try {
      const { token, url, room_name } = await this.#fetchToken()
      this.#connectionCredentials = { url, token, roomName: room_name }
      
      if (this.#room) {
        await this.#room.connect(url, token)
      } else {
        // Room was destroyed, recreate connection
        await this.#connectToRoom(url, token, room_name)
        await this.#enableCameraAndMicrophone()
      }
    } catch (error) {
      console.error("Full reconnection failed:", error)
      this.#handleError(error)
    }
  }

  #clearReconnectionTimeout() {
    if (this.#reconnectionTimeout) {
      clearTimeout(this.#reconnectionTimeout)
      this.#reconnectionTimeout = null
    }
  }

  #updateConnectionState(state, quality = null) {
    // Remove existing state classes
    this.element.classList.remove(
      "video-call--connecting",
      "video-call--connected",
      "video-call--reconnecting",
      "video-call--disconnected",
      "video-call--quality-poor",
      "video-call--quality-fair",
      "video-call--quality-good",
      "video-call--quality-excellent"
    )
    
    // Add new state class
    const stateClass = `video-call--${state}`
    this.element.classList.add(stateClass)
    
    // Add quality class if provided
    if (quality !== null && state === "connected") {
      const qualityClass = `video-call--quality-${this.#getQualityString(quality)}`
      this.element.classList.add(qualityClass)
    }
    
    // Dispatch event for external listeners
    this.dispatch("connection-state-changed", { 
      detail: { state, quality: quality !== null ? this.#getQualityString(quality) : null }
    })
  }

  #getQualityString(quality) {
    // ConnectionQuality enum: Excellent=4, Good=3, Fair=2, Poor=1, Lost=0
    const qualityMap = {
      4: "excellent",
      3: "good",
      2: "fair",
      1: "poor",
      0: "poor"
    }
    return qualityMap[quality] || "unknown"
  }

  #createRemoteVideoElement(participant) {
    if (!this.hasRemoteVideosTarget) {
      console.warn("No remoteVideosTarget available")
      return null
    }

    // Check if container already exists
    let container = this.remoteVideosTarget.querySelector(
      `[data-participant-identity="${participant.identity}"]`
    )

    if (!container) {
      // OPTIMIZED: Create new container using DocumentFragment for batch DOM operations
      container = document.createElement("div")
      container.className = "video-call__remote-video"
      container.dataset.participantIdentity = participant.identity

      // Create all elements first
      const video = document.createElement("video")
      video.autoplay = true
      video.playsInline = true
      video.muted = false
      video.dataset.videoTrack = "true"

      const audio = document.createElement("audio")
      audio.autoplay = true
      audio.playsInline = true
      audio.dataset.audioTrack = "true"
      audio.dataset.participantIdentity = participant.identity

      const placeholder = this.#createPlaceholderElement(participant)
      const label = this.#createLabelElement(participant)
      const controls = this.#createControlsElement(participant)

      // Add all to container at once
      container.appendChild(video)
      container.appendChild(audio)
      container.appendChild(placeholder)
      container.appendChild(label)
      container.appendChild(controls)

      // Store mute state in dataset
      container.dataset.audioMuted = "false"

      // Single DOM insertion
      this.remoteVideosTarget.appendChild(container)

      // Load avatar URL asynchronously
      this.#loadAvatarForPlaceholder(participant, placeholder)

      console.log("Created remote video container for participant:", participant.identity)
    } else {
      // Container exists (maybe created by audio track), find or create video element
      let videoElement = container.querySelector('[data-video-track="true"]')
      if (!videoElement) {
        // Container exists but no video element - create it
        console.log("Container exists but no video element, creating video element for participant:", participant.identity)
        videoElement = document.createElement("video")
        videoElement.autoplay = true
        videoElement.playsInline = true
        videoElement.muted = false
        videoElement.dataset.videoTrack = "true"
        // Insert video at the start of the container
        container.insertBefore(videoElement, container.firstChild)
      } else {
        // Video element exists but might be hidden - show it
        videoElement.style.display = "block"
      }
      
      // OPTIMIZED: Ensure placeholder exists using helper method
      let placeholder = container.querySelector('.video-call__placeholder--remote')
      if (!placeholder) {
        placeholder = this.#createPlaceholderElement(participant)
        container.insertBefore(placeholder, container.firstChild)
        this.#loadAvatarForPlaceholder(participant, placeholder)
      }
      // Show placeholder if video element has no stream
      if (!videoElement.srcObject) {
        placeholder.style.display = "block"
        videoElement.style.display = "none"
      }

      // Ensure label exists and is updated
      let label = container.querySelector('.video-call__participant-name')
      if (!label) {
        label = this.#createLabelElement(participant)
        container.appendChild(label)
      } else {
        label.textContent = participant.name || participant.identity
      }

      // OPTIMIZED: Ensure controls exist using helper method
      let controls = container.querySelector('.video-call__remote-controls')
      if (!controls) {
        controls = this.#createControlsElement(participant)
        container.appendChild(controls)
      }
      
      // Update controls visibility based on whether there's a video or placeholder
      this.#updateRemoteControlsVisibility(container)
      
      return videoElement
    }
    
    // Return the video element (it should exist now)
    const videoElement = container.querySelector('[data-video-track="true"]')
    if (!videoElement) {
      console.error("Video element not found in container for participant:", participant.identity)
    }
    
    // Update controls visibility
    this.#updateRemoteControlsVisibility(container)
    
    return videoElement
  }

  #getOrCreateRemoteAudioElement(participant) {
    if (!this.hasRemoteVideosTarget) {
      const sink = this.#audioSink()
      if (sink) {
        return this.#getOrCreateSinkAudio(participant, sink)
      }
      return null
    }
    
    let container = this.remoteVideosTarget.querySelector(
      `[data-participant-identity="${participant.identity}"]`
    )
    
    if (!container) {
      // OPTIMIZED: Create container using helper methods to reduce duplication
      container = document.createElement("div")
      container.className = "video-call__remote-video"
      container.dataset.participantIdentity = participant.identity

      // Create video element placeholder (will be used when video track arrives)
      const video = document.createElement("video")
      video.autoplay = true
      video.playsInline = true
      video.muted = false
      video.dataset.videoTrack = "true"
      video.style.display = "none" // Hide until video track arrives

      const placeholder = this.#createPlaceholderElement(participant)
      const label = this.#createLabelElement(participant)
      const controls = this.#createControlsElement(participant)

      // Add all to container
      container.appendChild(video)
      container.appendChild(placeholder)
      container.appendChild(label)
      container.appendChild(controls)

      // Store mute state in dataset
      container.dataset.audioMuted = "false"

      // Update controls visibility
      this.#updateRemoteControlsVisibility(container)

      this.remoteVideosTarget.appendChild(container)

      // Load avatar asynchronously
      this.#loadAvatarForPlaceholder(participant, placeholder)
    }
    
    let audio = container.querySelector('[data-audio-track="true"]')
    if (!audio) {
      const sink = this.#audioSink()
      if (sink) {
        audio = this.#getOrCreateSinkAudio(participant, sink)
      } else {
        audio = document.createElement("audio")
        audio.autoplay = true
        audio.playsInline = true
        audio.dataset.audioTrack = "true"
        audio.dataset.participantIdentity = participant.identity
        container.appendChild(audio)
      }
    }
    
    // Update controls visibility
    this.#updateRemoteControlsVisibility(container)
    
    return audio
  }

  #cleanupRemoteAudioElement(participant) {
    if (!this.hasRemoteVideosTarget) {
      return
    }
    
    const container = this.remoteVideosTarget.querySelector(
      `[data-participant-identity="${participant.identity}"]`
    )
    
    if (container) {
      const audio = container.querySelector('[data-audio-track="true"]')
      if (audio) {
        audio.srcObject = null
        audio.remove()
      }
      
      // If no video track either, remove the whole container
      const video = container.querySelector('[data-video-track="true"]')
      if (!video || !video.srcObject) {
        container.remove()
      }
    }
    
    const sink = this.#audioSink()
    if (sink) {
      const sinkAudio = sink.querySelector(`[data-audio-track="true"][data-participant-identity="${participant.identity}"]`)
      if (sinkAudio) {
        sinkAudio.srcObject = null
        sinkAudio.remove()
      }
    }
  }

  #removeRemoteVideoElement(participant) {
    if (!this.hasRemoteVideosTarget) {
      return
    }
    
    const container = this.remoteVideosTarget.querySelector(
      `[data-participant-identity="${participant.identity}"]`
    )
    if (container) {
      container.remove()
    }
  }

  #cleanupLocalTracks() {
    // Stop all tracks properly
    try {
      this.#localVideoTrack?.stop()
    } catch (e) {
      // Track may already be stopped
    }
    try {
      this.#localAudioTrack?.stop()
    } catch (e) {
      // Track may already be stopped
    }
    if (this.#localScreenTrack) {
      try {
        this.#localScreenTrack.video?.stop()
      } catch (e) {
        // Track may already be stopped
      }
      try {
        this.#localScreenTrack.audio?.stop()
      } catch (e) {
        // Track may already be stopped
      }
    }
    
    // Clear references
    this.#localVideoTrack = null
    this.#localAudioTrack = null
    this.#localScreenTrack = null
    
    // Clean up video element
    if (this.hasLocalVideoTarget) {
      this.localVideoTarget.srcObject = null
      this.localVideoTarget.style.display = "none"
      // Remove mirror transform
      this.localVideoTarget.style.transform = ""
      this.localVideoTarget.classList.remove("video-call__video--screen-share")
    }
    
    // Show placeholder again when tracks are cleaned up
    if (this.hasLocalPlaceholderTarget) {
      this.localPlaceholderTarget.style.display = "block"
    }
    
    // Update controls visibility
    this.#updateLocalControlsVisibility()
  }

  #cleanupRemoteTracks() {
    this.#remoteParticipants.forEach(participant => {
      participant.trackPublications.forEach(publication => {
        if (publication.track) {
          publication.track.detach()
        }
      })
    })
    this.#remoteParticipants.clear()
    this.#participantAvatarUrls.clear() // Clear avatar URL cache
    if (this.remoteVideosTarget) {
      this.remoteVideosTarget.innerHTML = ""
    }
    const sink = this.#audioSink()
    if (sink) {
      sink.innerHTML = ""
    }
    this.#updateSoloLayout()
  }

  #setupEventListeners() {
    // Event listeners are now handled via data-action attributes in the template
    // This method is kept for any future manual event setup if needed
  }

  #updateMuteButtonState() {
    if (!this.hasMuteButton || !this.muteButtonTarget) return
    
    let isMuted = true // Default to muted if no track
    
    if (this.#localAudioTrack) {
      // Try multiple ways to determine mute state
      if ('isMuted' in this.#localAudioTrack && typeof this.#localAudioTrack.isMuted === 'boolean') {
        isMuted = this.#localAudioTrack.isMuted
      } else if (this.#localAudioTrack.mediaStreamTrack) {
        // If isMuted property doesn't exist, use mediaStreamTrack.enabled (inverted)
        isMuted = !this.#localAudioTrack.mediaStreamTrack.enabled
      } else {
        // Fallback: check if track is muted via publication
        const publication = this.#room?.localParticipant?.audioTrackPublications?.values().next().value
        if (publication) {
          isMuted = publication.isMuted ?? false
        }
      }
    }
    
    // Force add/remove the muted class (don't use toggle to ensure correct state)
    // Use remove() then add() to ensure state is correct
    this.muteButtonTarget.classList.remove(this.mutedClass)
    if (isMuted) {
      this.muteButtonTarget.classList.add(this.mutedClass)
    }
    const label = this.muteButtonTarget.querySelector(".video-call__button-label")
    if (label) {
      label.textContent = isMuted ? "Unmute" : "Mute"
    }
    this.muteButtonTarget.setAttribute("aria-label", isMuted ? "Unmute microphone" : "Mute microphone")
  }

  #updateCameraButtonState() {
    if (this.cameraButtonTarget) {
      const isMuted = this.#localVideoTrack?.isMuted ?? true
      this.cameraButtonTarget.classList.toggle(this.mutedClass, isMuted)
      const label = this.cameraButtonTarget.querySelector(".video-call__button-label")
      if (label) {
        label.textContent = isMuted ? "Camera On" : "Camera Off"
      }
      this.cameraButtonTarget.setAttribute("aria-label", isMuted ? "Turn camera on" : "Turn camera off")
    }
  }

  #updateScreenShareButtonState() {
    if (this.screenShareButtonTarget) {
      const isSharing = this.#localScreenTrack !== null && this.#localScreenTrack.video !== null
      this.screenShareButtonTarget.classList.toggle("video-call__button--active", isSharing)
    }
  }

  #setLoading(loading) {
    // Show/hide loading indicator
    if (loading) {
      this.#updateConnectionState("connecting")
    }
  }

  #handleError(error) {
    // Log full error details for debugging
    console.error("Video call error:", {
      name: error.name,
      message: error.message,
      stack: error.stack,
      timestamp: new Date().toISOString()
    })

    let userMessage = "An error occurred with the video call."
    let errorType = "unknown"

    // Browser-specific error detection
    const isSafari = /^((?!chrome|android).)*safari/i.test(navigator.userAgent)
    const isFirefox = navigator.userAgent.toLowerCase().indexOf('firefox') > -1

    // Determine error type with better detection
    if (error.name === "NotAllowedError" || error.message?.toLowerCase().includes("permission")) {
      userMessage = isSafari
        ? "Camera or microphone permission was denied. Go to Safari > Settings for this Website to allow access."
        : "Camera or microphone permission was denied. Please allow access in your browser settings."
      errorType = "permission"
    } else if (error.name === "NotFoundError" || error.message?.toLowerCase().includes("device not found")) {
      userMessage = "No camera or microphone found. Please check your devices and try again."
      errorType = "device"
    } else if (error.name === "NotReadableError") {
      userMessage = "Camera or microphone is already in use by another application. Please close other apps and try again."
      errorType = "device-busy"
    } else if (error.message?.includes("network") || error.message?.includes("Failed to fetch")) {
      userMessage = "Network error. Please check your internet connection and try again."
      errorType = "network"
    } else if (error.message?.includes("timeout")) {
      userMessage = "Connection timed out. Please check your network and try again."
      errorType = "timeout"
    } else if (error.message?.includes("token") || error.message?.includes("authentication")) {
      userMessage = "Authentication failed. Please refresh the page and try again."
      errorType = "auth"
    } else if (error.message?.includes("not configured")) {
      userMessage = "Video calling is not configured for this deployment."
      errorType = "config"
    }

    this.#showError(userMessage, errorType)
    this.dispatch("error", { detail: { error, message: userMessage, type: errorType } })
  }

  #showError(message, type = "unknown") {
    if (!this.hasErrorMessageTarget) return
    
    const errorElement = this.errorMessageTarget
    const textElement = errorElement.querySelector('.video-call__error-text')
    
    if (textElement) {
      textElement.textContent = message
    }
    
    errorElement.style.display = "flex"
    errorElement.className = `video-call__error video-call__error--${type}`
    errorElement.setAttribute("role", "alert")
    
    // Auto-dismiss after 10 seconds for non-critical errors
    if (type !== "reconnect" && type !== "config") {
      setTimeout(() => {
        this.dismissError()
      }, 10000)
    }
  }

  dismissError() {
    if (this.hasErrorMessageTarget) {
      this.errorMessageTarget.style.display = "none"
      const textElement = this.errorMessageTarget.querySelector('.video-call__error-text')
      if (textElement) {
        textElement.textContent = ""
      }
    }
  }

  #updateJoinLeaveButton() {
    // Try to find button element directly if target isn't available
    let button = null
    let icon = null
    let label = null
    
    if (this.hasJoinLeaveButton) {
      button = this.joinLeaveButtonTarget
      if (this.hasJoinLeaveIcon) {
        icon = this.joinLeaveIconTarget
      }
      if (this.hasJoinLeaveLabel) {
        label = this.joinLeaveLabelTarget
      }
    } else {
      // Fallback: find by querySelector
      button = this.element.querySelector('[data-video-call-target="joinLeaveButton"]')
      if (button) {
        icon = button.querySelector('[data-video-call-target="joinLeaveIcon"]')
        label = button.querySelector('[data-video-call-target="joinLeaveLabel"]')
      }
    }
    
    if (!button) {
      console.warn("Could not find joinLeaveButton element")
      return
    }

    if (this.#joinLeaveDisabled) {
      button.disabled = true
      button.setAttribute("aria-label", "Video call unavailable")
      if (label) {
        label.textContent = "Unavailable"
      }
      return
    }
    
    // Check multiple ways room might indicate connection
    const isConnected = this.#room && (
      this.#room.state === "connected" ||
      this.#room.state === "RTC_CONNECTED" ||
      this.#room.connectionState === "connected" ||
      (this.#room.localParticipant && this.#room.localParticipant.state === "connected")
    )
    
    console.log("Updating join/leave button:", { 
      isConnected, 
      roomState: this.#room?.state,
      connectionState: this.#room?.connectionState,
      hasRoom: !!this.#room,
      foundButton: !!button
    })
    
    if (isConnected) {
      button.classList.remove("video-call__button--join")
      button.classList.add("video-call__button--danger")
      button.setAttribute("aria-label", "Leave video call")
      
      if (icon) {
        // Icon is already an image tag, just update if needed
        const iconImg = icon.querySelector('img')
        if (iconImg) {
          iconImg.src = this.iconRemoveValue
        }
      }
      if (label) {
        label.textContent = "Leave"
      }
    } else {
      button.disabled = false
      button.classList.remove("video-call__button--danger")
      button.classList.add("video-call__button--join")
      button.setAttribute("aria-label", "Join video call")
      
      if (icon) {
        // Icon is already an image tag, just update if needed
        const iconImg = icon.querySelector('img')
        if (iconImg) {
          iconImg.src = this.iconMessagesValue
        }
      }
      if (label) {
        label.textContent = "Join"
      }
    }
  }

  #setJoinLeaveDisabled(disabled) {
    this.#joinLeaveDisabled = disabled
    this.#updateJoinLeaveButton()
  }

  #updateSoloLayout() {
    const hasRemotes = (this.#room?.remoteParticipants?.size || 0) > 0 || this.#remoteParticipants.size > 0
    this.element.classList.toggle("video-call--solo", !hasRemotes)
  }

  #voiceStore() {
    if (!window.CampfireVoice) {
      window.CampfireVoice = {}
    }
    return window.CampfireVoice
  }

  #getActiveCall() {
    return this.#voiceStore().active || null
  }

  #setActiveCall(active) {
    this.#voiceStore().active = active
  }

  #clearActiveCall() {
    const active = this.#getActiveCall()
    if (!active) return
    if (active.roomId === this.roomIdValue) {
      this.#voiceStore().active = null
    }
  }

  async #adoptActiveCallIfPresent() {
    const active = this.#getActiveCall()
    if (!active || active.roomId !== this.roomIdValue) {
      return
    }

    this.#room = active.room
    this.#localVideoTrack = active.localVideoTrack
    this.#localAudioTrack = active.localAudioTrack
    this.#localScreenTrack = active.localScreenTrack
    this.#connectionCredentials = active.connectionCredentials

    await this.#loadLiveKit()
    this.#bindRoomEvents(this.#room, { observer: false })
    this.#clearRemoteUi()
    this.#syncRemoteParticipants(this.#room)
    this.#attachLocalTracksForActiveCall()
    this.#updateJoinLeaveButton()
    this.#updateLocalControlsVisibility()
  }

  async #ensureObserverIfNeeded() {
    if (!this.#isLiveKitConfigured()) return

    const active = this.#getActiveCall()
    if (active && active.roomId === this.roomIdValue) {
      return
    }
    if (this.#observerRoom) return

    try {
      const { token, url } = await this.#fetchToken({ mode: "observe" })
      await this.#connectObserver(url, token)
    } catch (error) {
      console.warn("Observer connection failed:", error)
    }
  }

  async #connectObserver(url, token) {
    const LiveKit = await this.#loadLiveKit()
    const { Room } = LiveKit

    this.LiveKit = LiveKit
    this.#observerRoom = new Room()
    this.#bindRoomEvents(this.#observerRoom, { observer: true })
    await this.#observerRoom.connect(url, token)
    this.#syncRemoteParticipants(this.#observerRoom, { observer: true })
    this.#updateSoloLayout()
  }

  #disconnectObserver(alreadyDisconnected = false) {
    if (!this.#observerRoom) return
    this.#unbindRoomEvents(this.#observerRoom)
    if (!alreadyDisconnected) {
      this.#observerRoom.disconnect()
    }
    this.#observerRoom = null
    this.#cleanupRemoteTracks()
  }

  async #endActiveCallIfNeeded() {
    const active = this.#getActiveCall()
    if (!active || active.roomId === this.roomIdValue) return

    this.#stopActiveTracks(active)
    active.room.disconnect()
    this.#voiceStore().active = null
  }

  #stopActiveTracks(active) {
    try {
      active.localVideoTrack?.stop()
    } catch (e) {}
    try {
      active.localAudioTrack?.stop()
    } catch (e) {}
    if (active.localScreenTrack) {
      try {
        active.localScreenTrack.video?.stop()
      } catch (e) {}
      try {
        active.localScreenTrack.audio?.stop()
      } catch (e) {}
    }
  }

  #persistActiveCall() {
    this.#unbindRoomEvents(this.#room)
    this.#detachTracksFromDom()
    this.#detachRemoteVideoTracks(this.#room)
    this.#clearRemoteUi()
    this.#setActiveCall({
      roomId: this.roomIdValue,
      room: this.#room,
      localVideoTrack: this.#localVideoTrack,
      localAudioTrack: this.#localAudioTrack,
      localScreenTrack: this.#localScreenTrack,
      connectionCredentials: this.#connectionCredentials
    })
    this.#room = null
  }

  #detachTracksFromDom() {
    try {
      this.#localVideoTrack?.detach()
    } catch (e) {}
    try {
      this.#localAudioTrack?.detach()
    } catch (e) {}
  }

  #detachRemoteVideoTracks(room) {
    if (!room) return
    room.remoteParticipants.forEach((participant) => {
      participant.videoTrackPublications.forEach((publication) => {
        if (publication.track) {
          publication.track.detach()
        }
      })
    })
  }

  #clearRemoteUi() {
    if (this.remoteVideosTarget) {
      this.remoteVideosTarget.innerHTML = ""
    }
    this.#participantAvatarUrls.clear()
  }

  #audioSink() {
    return document.getElementById("voice-call-sink")
  }

  #getOrCreateSinkAudio(participant, sink) {
    let audio = sink.querySelector(`[data-audio-track="true"][data-participant-identity="${participant.identity}"]`)
    if (!audio) {
      audio = document.createElement("audio")
      audio.autoplay = true
      audio.playsInline = true
      audio.dataset.audioTrack = "true"
      audio.dataset.participantIdentity = participant.identity
      sink.appendChild(audio)
    }
    return audio
  }

  #bindTurboHandlers() {
    if (this.#turboLoadHandler) return
    this.#turboLoadHandler = () => {
      this.#updateRoomContextFromMeta()
      this.#updateJoinLeaveButton()
      void this.#adoptActiveCallIfPresent()
      void this.#ensureObserverIfNeeded()
    }
    document.addEventListener("turbo:load", this.#turboLoadHandler)
  }

  #unbindTurboHandlers() {
    if (!this.#turboLoadHandler) return
    document.removeEventListener("turbo:load", this.#turboLoadHandler)
    this.#turboLoadHandler = null
  }

  #updateRoomContextFromMeta() {
    const meta = document.querySelector('meta[name="current-room-id"]')
    const roomId = meta ? Number(meta.content) : this.roomIdValue
    if (!Number.isNaN(roomId) && roomId) {
      this.roomIdValue = roomId
    }
  }

  #attachLocalTracksForActiveCall() {
    if (this.#localScreenTrack && this.hasLocalVideoTarget) {
      const streams = [this.#localScreenTrack.video]
      if (this.#localScreenTrack.audio) {
        streams.push(this.#localScreenTrack.audio)
      }
      this.localVideoTarget.srcObject = new MediaStream(streams)
      this.localVideoTarget.style.display = "block"
      this.localVideoTarget.style.transform = "none"
      this.localVideoTarget.classList.add("video-call__video--screen-share")
      if (this.hasLocalPlaceholderTarget) {
        this.localPlaceholderTarget.style.display = "none"
      }
      return
    }

    if (this.#localVideoTrack && this.hasLocalVideoTarget) {
      this.#attachVideoTrack(this.#localVideoTrack, this.localVideoTarget)
      this.localVideoTarget.style.transform = "scaleX(-1)"
      this.localVideoTarget.classList.remove("video-call__video--screen-share")
      if (this.hasLocalPlaceholderTarget) {
        this.localPlaceholderTarget.style.display = "none"
      }
    } else if (this.hasLocalPlaceholderTarget) {
      this.localPlaceholderTarget.style.display = "block"
    }
  }

  #bindRoomEvents(room, { observer }) {
    const { RoomEvent } = this.LiveKit
    const handlers = {
      trackSubscribed: (track, publication, participant) => {
        this.#onTrackSubscribed(track, publication, participant, { observer })
      },
      trackUnsubscribed: this.#onTrackUnsubscribed.bind(this),
      participantConnected: this.#onParticipantConnected.bind(this),
      participantDisconnected: this.#onParticipantDisconnected.bind(this),
      connected: () => {
        if (observer) {
          this.#syncRemoteParticipants(room, { observer: true })
          this.#updateSoloLayout()
          return
        }
        this.#reconnectionAttempts = 0
        this.#isReconnecting = false
        this.#clearReconnectionTimeout()
        this.#updateConnectionState("connected")
        this.#syncRemoteParticipants(room)
        this.#updateJoinLeaveButton()
        this.#updateSoloLayout()
      }
    }

    room.on(RoomEvent.TrackSubscribed, handlers.trackSubscribed)
    room.on(RoomEvent.TrackUnsubscribed, handlers.trackUnsubscribed)
    room.on(RoomEvent.ParticipantConnected, handlers.participantConnected)
    room.on(RoomEvent.ParticipantDisconnected, handlers.participantDisconnected)
    room.on(RoomEvent.Connected, handlers.connected)

    if (observer) {
      handlers.disconnected = () => {
        this.#onObserverDisconnected(room)
      }
      room.on(RoomEvent.Disconnected, handlers.disconnected)
    } else {
      handlers.disconnected = this.#onDisconnected.bind(this)
      handlers.reconnecting = this.#onReconnecting.bind(this)
      handlers.reconnected = this.#onReconnected.bind(this)
      handlers.qualityChanged = this.#onConnectionQualityChanged.bind(this)
      room.on(RoomEvent.Disconnected, handlers.disconnected)
      room.on(RoomEvent.Reconnecting, handlers.reconnecting)
      room.on(RoomEvent.Reconnected, handlers.reconnected)
      room.on(RoomEvent.ConnectionQualityChanged, handlers.qualityChanged)
    }

    this.#roomEventHandlers.set(room, handlers)
  }

  #unbindRoomEvents(room) {
    const handlers = this.#roomEventHandlers.get(room)
    if (!handlers || !this.LiveKit) return
    const { RoomEvent } = this.LiveKit

    room.off(RoomEvent.TrackSubscribed, handlers.trackSubscribed)
    room.off(RoomEvent.TrackUnsubscribed, handlers.trackUnsubscribed)
    room.off(RoomEvent.ParticipantConnected, handlers.participantConnected)
    room.off(RoomEvent.ParticipantDisconnected, handlers.participantDisconnected)
    room.off(RoomEvent.Connected, handlers.connected)
    if (handlers.disconnected) {
      room.off(RoomEvent.Disconnected, handlers.disconnected)
    }
    if (handlers.reconnecting) {
      room.off(RoomEvent.Reconnecting, handlers.reconnecting)
    }
    if (handlers.reconnected) {
      room.off(RoomEvent.Reconnected, handlers.reconnected)
    }
    if (handlers.qualityChanged) {
      room.off(RoomEvent.ConnectionQualityChanged, handlers.qualityChanged)
    }
    this.#roomEventHandlers.delete(room)
  }

  #syncRemoteParticipants(room, options = {}) {
    if (!room) return
    room.remoteParticipants.forEach((participant) => {
      participant.audioTrackPublications.forEach((publication) => {
        if (publication.track && publication.isSubscribed) {
          this.#onTrackSubscribed(publication.track, publication, participant, options)
        }
      })
      participant.videoTrackPublications.forEach((publication) => {
        if (publication.track && publication.isSubscribed) {
          this.#onTrackSubscribed(publication.track, publication, participant, options)
        }
      })
    })
  }

  #onObserverDisconnected(room) {
    if (!room || room !== this.#observerRoom) return
    this.#disconnectObserver(true)
  }

  #isLiveKitConfigured() {
    if (this.hasLivekitConfiguredValue) {
      return this.livekitConfiguredValue
    }
    return true
  }

  async #stopScreenShare() {
    if (!this.#localScreenTrack) {
      return
    }

    const screenTrack = this.#localScreenTrack
    this.#localScreenTrack = null

    // Clean up event listener if it exists (prevents memory leak)
    if (screenTrack.video && this.#screenShareEndHandlers.has(screenTrack.video)) {
      const handler = this.#screenShareEndHandlers.get(screenTrack.video)
      screenTrack.video.removeEventListener("ended", handler)
      this.#screenShareEndHandlers.delete(screenTrack.video)
    }

    if (this.#room && screenTrack.video) {
      try {
        await this.#room.localParticipant.unpublishTrack(screenTrack.video)
      } catch (error) {
        console.warn("Failed to unpublish screen share video:", error)
      }
    }
    if (screenTrack.video) {
      screenTrack.video.stop()
    }
    if (screenTrack.audio) {
      if (this.#room) {
        try {
          await this.#room.localParticipant.unpublishTrack(screenTrack.audio)
        } catch (error) {
          console.warn("Failed to unpublish screen share audio:", error)
        }
      }
      screenTrack.audio.stop()
    }

    // Show camera again if available
    if (this.#localVideoTrack && this.hasLocalVideoTarget) {
      this.#attachVideoTrack(this.#localVideoTrack, this.localVideoTarget)
      // Ensure mirror transform for camera
      this.localVideoTarget.style.transform = "scaleX(-1)"
      this.localVideoTarget.classList.remove("video-call__video--screen-share")
      if (this.hasLocalPlaceholderTarget) {
        this.localPlaceholderTarget.style.display = "none"
      }
    } else if (this.hasLocalPlaceholderTarget) {
      // Show placeholder if no camera
      if (this.hasLocalVideoTarget) {
        this.localVideoTarget.style.display = "none"
      }
      this.localPlaceholderTarget.style.display = "block"
    }

    this.#updateLocalControlsVisibility()
    this.#updateScreenShareButtonState()
  }
}
