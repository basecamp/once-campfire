module MessagesHelper
  # auto_link re-sanitizes with Rails' default safe list, which lacks the
  # formatting the rich text editor produces
  AUTO_LINK_ALLOWED_TAGS = Rails::HTML5::SafeListSanitizer.allowed_tags + ContentFilters::EDITOR_FORMATTING_TAGS
  AUTO_LINK_ALLOWED_ATTRIBUTES = Rails::HTML5::SafeListSanitizer.allowed_attributes + ContentFilters::EDITOR_FORMATTING_ATTRIBUTES

  def message_area_tag(room, &)
    tag.div id: "message-area", class: "message-area", contents: true, data: {
      controller: "messages presence drop-target",
      action: [ messages_actions, drop_target_actions, presence_actions ].join(" "),
      messages_first_of_day_class: "message--first-of-day",
      messages_formatted_class: "message--formatted",
      messages_me_class: "message--me",
      messages_mentioned_class: "message--mentioned",
      messages_threaded_class: "message--threaded",
      messages_page_url_value: room_messages_url(room)
    }, &
  end

  def messages_tag(room, &)
    tag.div id: dom_id(room, :messages), class: "messages", data: {
      controller: "maintain-scroll refresh-room",
      action: [ maintain_scroll_actions, refresh_room_actions ].join(" "),
      messages_target: "messages",
      refresh_room_loaded_at_value: room.updated_at.to_fs(:epoch),
      refresh_room_url_value: room_refresh_url(room)
    }, &
  end

  def message_tag(message, &)
    message_timestamp_milliseconds = message.created_at.to_fs(:epoch)

    tag.div id: dom_id(message),
      class: "message #{"message--emoji" if message.plain_text_body.all_emoji?}",
      data: {
        controller: "reply",
        user_id: message.creator_id,
        message_id: message.id,
        client_message_id: message.client_message_id,
        message_timestamp: message_timestamp_milliseconds,
        message_updated_at: message.updated_at.to_fs(:epoch),
        sort_value: message_timestamp_milliseconds,
        messages_target: "message",
        search_results_target: "message",
        refresh_room_target: "message",
        reply_composer_outlet: "#composer"
      }, &
  rescue Exception => e
    Sentry.capture_exception(e, extra: { message: message })
    Rails.logger.error "Exception while rendering message #{message.class.name}##{message.id}, failed with: #{e.class} `#{e.message}`"

    render "messages/unrenderable"
  end

  def message_timestamp(message, **attributes)
    local_datetime_tag message.created_at, **attributes
  end

  def message_presentation(message)
    case message.content_type
    when "attachment"
      message_attachment_presentation(message)
    when "sound"
      message_sound_presentation(message)
    else
      text_message_presentation(message.body.body)
    end
  rescue Exception => e
    Sentry.capture_exception(e, extra: { message: message })
    Rails.logger.error "Exception while generating message representation for #{message.class.name}##{message.id}, failed with: #{e.class} `#{e.message}`"

    ""
  end

  def render_messages(messages)
    return render(partial: "messages/message", collection: messages) unless controller.perform_caching

    messages.preload_associations(messages) if messages.respond_to?(:preload_associations)
    # Native collection caching cannot bypass individual entries, so render
    # consecutive runs: attachments, mentions and direct-room names have further
    # dependencies and render fresh without costing their neighbours a cache hit.
    cached = ->(message) { message_fragment_cache_key(message) }
    safe_join messages.chunk_while { |a, b| message_fragment_cacheable?(a) == message_fragment_cacheable?(b) }.map { |run|
      render partial: "messages/message", collection: run, cached: (cached if message_fragment_cacheable?(run.first))
    }
  end

  def message_fragment_cache_key(message)
    # Read actual presentation inputs, not just updated_at: SQL writers can edit
    # leaf rows without touching their parents. Unrelated commits retain reuse.
    dependencies = [ message.attributes, message.room.attributes.slice("id", "type", "name"),
      message.creator.attributes.slice("id", "name", "bio", "updated_at"), message.body.body&.to_html,
      message.boosts.sort_by(&:created_at).map { |boost| [ boost.attributes, boost.booster.attributes.slice("id", "name", "bio", "updated_at") ] } ]
    [ "message-presentation-v8", Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(dependencies)) ]
  end

  private
    def message_fragment_cacheable?(message)
      !message.room.direct? && !message.attachment? && !message.body.body&.to_html.to_s.include?("<action-text-attachment")
    end

    def text_message_presentation(body)
      render = -> do
        auto_link h(ContentFilters::TextMessagePresentationFilters.apply(body)),
          html: { target: "_blank" }, sanitize_options: { tags: AUTO_LINK_ALLOWED_TAGS, attributes: AUTO_LINK_ALLOWED_ATTRIBUTES }
      end

      # Embedded attachments render database-backed metadata and signed URLs.
      # Plain text HTML depends only on its content, even after a foreign edit.
      html = body.to_html
      if controller.perform_caching && !html.include?("<action-text-attachment") && html.bytesize <= 1.megabyte
        Rails.cache.fetch([ "text-presentation-v2", Rails.configuration.x.presentation_cache_version, I18n.locale, Digest::SHA256.hexdigest(html) ]) { render.call }
      else
        render.call
      end
    end

    def messages_actions
      "turbo:before-stream-render@document->messages#beforeStreamRender keydown.up@document->messages#editMyLastMessage"
    end

    def maintain_scroll_actions
      "turbo:before-stream-render@document->maintain-scroll#beforeStreamRender"
    end

    def refresh_room_actions
      "visibilitychange@document->refresh-room#visibilityChanged online@window->refresh-room#online"
    end

    def presence_actions
      "visibilitychange@document->presence#visibilityChanged"
    end

    def message_attachment_presentation(message)
      Messages::AttachmentPresentation.new(message, context: self).render
    end

    def message_sound_presentation(message)
      sound = message.sound

      tag.div class: "sound", data: { controller: "sound", action: "messages:play->sound#play", sound_url_value: asset_path(sound.asset_path) } do
        play_button + (sound.image ? sound_image_tag(sound.image) : sound.text)
      end
    end

    def play_button
      tag.button "🔊", class: "btn btn--plain", data: { action: "sound#play" }
    end

    def sound_image_tag(image)
      image_tag image.asset_path, width: image.width, height: image.height, class: "align--middle"
    end

    def message_author_title(author)
      [ author.name, author.bio ].compact_blank.join(" – ")
    end
end
