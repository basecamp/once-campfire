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
    iconDisclosure: String
  }

  #room = null
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

  async connect() {
    this.#setupEventListeners()
    // Update button immediately - DOM should be ready in connect()
    this.#updateJoinLeaveButton()
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
  }

  disconnect() {
    // Clear any pending reconnection attempts
    this.#clearReconnectionTimeout()
    
    // Only cleanup if controller is still connected to DOM
    if (this.element.isConnected) {
      this.leave()
    } else {
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
    
    // Disconnect room (this will clean up all event listeners)
    if (this.#room) {
      this.#room.disconnect()
      this.#room = null
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
    
    const audioElement = container.querySelector('[data-audio-track="true"]')
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
      // Stop screen sharing
      if (this.#localScreenTrack.video) {
        await this.#room.localParticipant.unpublishTrack(this.#localScreenTrack.video)
        this.#localScreenTrack.video.stop()
      }
      if (this.#localScreenTrack.audio) {
        await this.#room.localParticipant.unpublishTrack(this.#localScreenTrack.audio)
        this.#localScreenTrack.audio.stop()
      }
      this.#localScreenTrack = null

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

  async #fetchToken() {
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
      body: JSON.stringify({ room_id: roomId })
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
    const { Room, RoomEvent, Track, ConnectionQuality, VideoPresets, createLocalVideoTrack, createLocalAudioTrack } = LiveKit
    
    this.LiveKit = LiveKit
    this.#videoPresets = VideoPresets // Store for later use (don't assign to module)
    
    // Create room instance
    this.#room = new Room()

    // Store credentials for reconnection
    this.#connectionCredentials = { url, token, roomName }

    // Set up event handlers before connecting
    this.#room.on(RoomEvent.TrackSubscribed, this.#onTrackSubscribed.bind(this))
    this.#room.on(RoomEvent.TrackUnsubscribed, this.#onTrackUnsubscribed.bind(this))
    this.#room.on(RoomEvent.ParticipantConnected, this.#onParticipantConnected.bind(this))
    this.#room.on(RoomEvent.ParticipantDisconnected, this.#onParticipantDisconnected.bind(this))
    this.#room.on(RoomEvent.Disconnected, this.#onDisconnected.bind(this))
    this.#room.on(RoomEvent.Reconnecting, this.#onReconnecting.bind(this))
    this.#room.on(RoomEvent.Reconnected, this.#onReconnected.bind(this))
    this.#room.on(RoomEvent.ConnectionQualityChanged, this.#onConnectionQualityChanged.bind(this))
    
    // Handle connection event - subscribe to existing tracks and update button
    this.#room.on(RoomEvent.Connected, () => {
      // Reset reconnection state on successful connection
      this.#reconnectionAttempts = 0
      this.#isReconnecting = false
      this.#clearReconnectionTimeout()
      this.#updateConnectionState("connected")
      
      // Subscribe to all existing participants' tracks (including audio)
      this.#room.remoteParticipants.forEach((participant) => {
        participant.audioTrackPublications.forEach((publication) => {
          if (publication.track && publication.isSubscribed) {
            this.#onTrackSubscribed(publication.track, publication, participant)
          }
        })
        participant.videoTrackPublications.forEach((publication) => {
          if (publication.track && publication.isSubscribed) {
            this.#onTrackSubscribed(publication.track, publication, participant)
          }
        })
      })
      
      // Update UI based on room state
      this.#updateJoinLeaveButton()
    })

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
      // Fallback to initials if no room ID
      const initialsSvg = this.#generateInitialsSvg(participant)
      return `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
    }
    
    try {
      const response = await fetch(`/api/livekit/participant_avatar?room_id=${roomId}&user_id=${participant.identity}`, {
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
        }
      })
      
      if (response.ok) {
        const data = await response.json()
        const url = data.avatar_url
        if (url) {
          this.#participantAvatarUrls.set(participant.identity, url)
          return url
        }
      }
    } catch (error) {
      console.warn("Failed to fetch avatar URL:", error)
    }
    
    // Fallback to initials SVG
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

  #onTrackSubscribed(track, publication, participant) {
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
    this.dispatch("participant-joined", { detail: { participant } })
  }

  #onParticipantDisconnected(participant) {
    this.#remoteParticipants.delete(participant.identity)
    this.#removeRemoteVideoElement(participant)
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
      // Create new container
      container = document.createElement("div")
      container.className = "video-call__remote-video"
      container.dataset.participantIdentity = participant.identity

      const video = document.createElement("video")
      video.autoplay = true
      video.playsInline = true
      video.muted = false // Make sure audio can play
      video.dataset.videoTrack = "true"
      container.appendChild(video)

      // Create audio element for remote audio
      const audio = document.createElement("audio")
      audio.autoplay = true
      audio.playsInline = true
      audio.dataset.audioTrack = "true"
      audio.dataset.participantIdentity = participant.identity
      container.appendChild(audio)

      // Create placeholder image for when no video
      const placeholder = document.createElement("img")
      placeholder.className = "video-call__placeholder video-call__placeholder--remote"
      placeholder.dataset.participantIdentity = participant.identity
      placeholder.alt = participant.name || participant.identity
      placeholder.style.display = "block" // Show by default until video arrives
      
      // Set up error handler first, before setting src
      placeholder.onerror = () => {
        const initialsSvg = this.#generateInitialsSvg(participant)
        placeholder.src = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
      }
      
      // Try to get avatar URL from API
      this.#getAvatarUrl(participant).then(url => {
        if (url) {
          placeholder.src = url
        } else {
          // If no URL, use initials
          const initialsSvg = this.#generateInitialsSvg(participant)
          placeholder.src = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
        }
      }).catch(() => {
        // Fallback to initials SVG if fetch fails
        const initialsSvg = this.#generateInitialsSvg(participant)
        placeholder.src = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
      })
      
      container.appendChild(placeholder)

      const label = document.createElement("div")
      label.className = "video-call__participant-name"
      label.textContent = participant.name || participant.identity
      container.appendChild(label)

      // Create controls container
      const controls = document.createElement("div")
      controls.className = "video-call__remote-controls"
      
      // Mute/unmute button for this participant's audio
      const muteButton = document.createElement("button")
      muteButton.type = "button"
      muteButton.className = "video-call__remote-control-button"
      muteButton.dataset.participantIdentity = participant.identity
      muteButton.dataset.action = "click->video-call#toggleRemoteMute"
      muteButton.setAttribute("aria-label", "Mute participant")
      muteButton.innerHTML = `<span class="video-call__remote-control-icon"><img src="${this.iconMessagesValue}" class="colorize--white" width="16" height="16" aria-hidden="true" /></span>`
      controls.appendChild(muteButton)
      
      // Fullscreen button
      const fullscreenButton = document.createElement("button")
      fullscreenButton.type = "button"
      fullscreenButton.className = "video-call__remote-control-button"
      fullscreenButton.dataset.participantIdentity = participant.identity
      fullscreenButton.dataset.action = "click->video-call#toggleFullscreen"
      fullscreenButton.setAttribute("aria-label", "Fullscreen")
      fullscreenButton.innerHTML = `<span class="video-call__remote-control-icon"><img src="${this.iconDisclosureValue}" class="colorize--white" width="16" height="16" aria-hidden="true" /></span>`
      controls.appendChild(fullscreenButton)
      
      container.appendChild(controls)
      
      // Store mute state in dataset
      container.dataset.audioMuted = "false"

      this.remoteVideosTarget.appendChild(container)
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
      
      // Ensure placeholder exists and is initially visible if no video stream
      let placeholder = container.querySelector('.video-call__placeholder--remote')
      if (!placeholder) {
        placeholder = document.createElement("img")
        placeholder.className = "video-call__placeholder video-call__placeholder--remote"
        placeholder.dataset.participantIdentity = participant.identity
        placeholder.alt = participant.name || participant.identity
        placeholder.style.display = "block"
        placeholder.onerror = () => {
          const initialsSvg = this.#generateInitialsSvg(participant)
          placeholder.src = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
        }
        this.#getAvatarUrl(participant).then(url => {
          if (url) {
            placeholder.src = url
          } else {
            // If no URL, use initials
            const initialsSvg = this.#generateInitialsSvg(participant)
            placeholder.src = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
          }
        }).catch(() => {
          // Fallback to initials SVG if fetch fails
          const initialsSvg = this.#generateInitialsSvg(participant)
          placeholder.src = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
        })
        container.insertBefore(placeholder, container.firstChild)
      }
      // Show placeholder if video element has no stream
      if (!videoElement.srcObject) {
        placeholder.style.display = "block"
        videoElement.style.display = "none"
      }
      
      // Ensure label exists and is updated
      let label = container.querySelector('.video-call__participant-name')
      if (!label) {
        label = document.createElement("div")
        label.className = "video-call__participant-name"
        container.appendChild(label)
      }
      label.textContent = participant.name || participant.identity
      
      // Ensure controls exist (they might not if container was created by audio)
      let controls = container.querySelector('.video-call__remote-controls')
      if (!controls) {
        controls = document.createElement("div")
        controls.className = "video-call__remote-controls"
        
        // Mute/unmute button
        const muteButton = document.createElement("button")
        muteButton.type = "button"
        muteButton.className = "video-call__remote-control-button"
        muteButton.dataset.participantIdentity = participant.identity
        muteButton.dataset.action = "click->video-call#toggleRemoteMute"
        muteButton.setAttribute("aria-label", "Mute participant")
        muteButton.innerHTML = `<span class="video-call__remote-control-icon"><img src="${this.iconMessagesValue}" class="colorize--white" width="16" height="16" aria-hidden="true" /></span>`
        controls.appendChild(muteButton)
        
        // Fullscreen button - only show if there's a video stream or placeholder
        const fullscreenButton = document.createElement("button")
        fullscreenButton.type = "button"
        fullscreenButton.className = "video-call__remote-control-button"
        fullscreenButton.dataset.participantIdentity = participant.identity
        fullscreenButton.dataset.action = "click->video-call#toggleFullscreen"
        fullscreenButton.setAttribute("aria-label", "Fullscreen")
        fullscreenButton.innerHTML = `<span class="video-call__remote-control-icon"><img src="${this.iconDisclosureValue}" class="colorize--white" width="16" height="16" aria-hidden="true" /></span>`
        controls.appendChild(fullscreenButton)
        
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
      return null
    }
    
    let container = this.remoteVideosTarget.querySelector(
      `[data-participant-identity="${participant.identity}"]`
    )
    
    if (!container) {
      // Create container if it doesn't exist (audio before video)
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
      container.appendChild(video)

      // Create placeholder image for when no video
      const placeholder = document.createElement("img")
      placeholder.className = "video-call__placeholder video-call__placeholder--remote"
      placeholder.dataset.participantIdentity = participant.identity
      placeholder.alt = participant.name || participant.identity
      placeholder.style.display = "block" // Show by default until video arrives
      
      // Set up error handler first, before setting src
      placeholder.onerror = () => {
        const initialsSvg = this.#generateInitialsSvg(participant)
        placeholder.src = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
      }
      
      // Try to get avatar URL from API
      this.#getAvatarUrl(participant).then(url => {
        if (url) {
          placeholder.src = url
        } else {
          // If no URL, use initials
          const initialsSvg = this.#generateInitialsSvg(participant)
          placeholder.src = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
        }
      }).catch(() => {
        // Fallback to initials SVG if fetch fails
        const initialsSvg = this.#generateInitialsSvg(participant)
        placeholder.src = `data:image/svg+xml,${encodeURIComponent(initialsSvg)}`
      })
      
      container.appendChild(placeholder)

      const label = document.createElement("div")
      label.className = "video-call__participant-name"
      label.textContent = participant.name || participant.identity
      container.appendChild(label)
      
      // Create controls container with buttons
      const controls = document.createElement("div")
      controls.className = "video-call__remote-controls"
      
      // Mute/unmute button
      const muteButton = document.createElement("button")
      muteButton.type = "button"
      muteButton.className = "video-call__remote-control-button"
      muteButton.dataset.participantIdentity = participant.identity
      muteButton.dataset.action = "click->video-call#toggleRemoteMute"
      muteButton.setAttribute("aria-label", "Mute participant")
      muteButton.innerHTML = `<span class="video-call__remote-control-icon"><img src="${this.iconMessagesValue}" class="colorize--white" width="16" height="16" aria-hidden="true" /></span>`
      controls.appendChild(muteButton)
      
      // Fullscreen button (will be visible when video or placeholder is present)
      const fullscreenButton = document.createElement("button")
      fullscreenButton.type = "button"
      fullscreenButton.className = "video-call__remote-control-button"
      fullscreenButton.dataset.participantIdentity = participant.identity
      fullscreenButton.dataset.action = "click->video-call#toggleFullscreen"
      fullscreenButton.setAttribute("aria-label", "Fullscreen")
      fullscreenButton.innerHTML = `<span class="video-call__remote-control-icon"><img src="${this.iconDisclosureValue}" class="colorize--white" width="16" height="16" aria-hidden="true" /></span>`
      controls.appendChild(fullscreenButton)
      
      container.appendChild(controls)
      
      // Store mute state in dataset
      container.dataset.audioMuted = "false"
      
      // Update controls visibility
      this.#updateRemoteControlsVisibility(container)
      
      this.remoteVideosTarget.appendChild(container)
    }
    
    let audio = container.querySelector('[data-audio-track="true"]')
    if (!audio) {
      audio = document.createElement("audio")
      audio.autoplay = true
      audio.playsInline = true
      audio.dataset.audioTrack = "true"
      audio.dataset.participantIdentity = participant.identity
      container.appendChild(audio)
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
  }

  #updateCameraButtonState() {
    if (this.cameraButtonTarget) {
      const isMuted = this.#localVideoTrack?.isMuted ?? true
      this.cameraButtonTarget.classList.toggle(this.mutedClass, isMuted)
    }
  }

  #updateScreenShareButtonState() {
    if (this.screenShareButtonTarget) {
      const isSharing = this.#localScreenTrack !== null && this.#localScreenTrack.video !== null
      this.screenShareButtonTarget.classList.toggle(this.activeClass, isSharing)
    }
  }

  #setLoading(loading) {
    // Show/hide loading indicator
    if (loading) {
      this.#updateConnectionState("connecting")
    }
  }

  #handleError(error) {
    console.error("Video call error:", error)
    
    let userMessage = "An error occurred with the video call."
    let errorType = "unknown"
    
    // Determine error type and user-friendly message
    if (error.name === "NotAllowedError" || error.message?.includes("permission") || error.message?.includes("denied")) {
      userMessage = "Camera or microphone permission was denied. Please allow access in your browser settings."
      errorType = "permission"
    } else if (error.name === "NotFoundError" || error.message?.includes("device not found")) {
      userMessage = "No camera or microphone found. Please check your devices."
      errorType = "device"
    } else if (error.message?.includes("network") || error.message?.includes("connection") || error.message?.includes("Failed to fetch")) {
      userMessage = "Network error. Please check your internet connection."
      errorType = "network"
    } else if (error.message?.includes("token") || error.message?.includes("authentication")) {
      userMessage = "Authentication failed. Please try again."
      errorType = "auth"
    } else if (error.message?.includes("reconnect")) {
      userMessage = "Connection lost. Attempting to reconnect..."
      errorType = "reconnect"
    } else if (error.message) {
      // Use error message if available, but make it user-friendly
      userMessage = error.message.charAt(0).toUpperCase() + error.message.slice(1)
    }
    
    // Show error message to user
    this.#showError(userMessage, errorType)
    
    // Dispatch error event for external listeners
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
    if (type !== "reconnect") {
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
}

