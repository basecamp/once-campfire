class ContentFilters::SanitizeAttributes < ActionText::Content::Filter
  def applicable?
    true
  end

  # Scrub attributes on the tags that SanitizeTags allows, using Rails' safe-list
  # sanitizer so unsafe URI schemes and event-handler attributes are stripped.
  # Runs after SanitizeTags, so passing the same allowed tags makes the tag pass
  # a no-op and only attributes are scrubbed.
  def apply
    sanitizer.sanitize fragment.to_html, tags: allowed_tags, attributes: allowed_attributes
  end

  private
    # Presentation styling relies on class attributes (e.g. unfurled link embeds).
    # The sanitizer's default safe list already permits it, but ActionText lets an
    # app replace that list wholesale, so keep it explicit.
    EXTRA_ALLOWED_ATTRIBUTES = %w[ class ]

    # ActionText::ContentHelper.sanitizer is a single process-wide instance, and
    # rails-html-sanitizer reuses one mutable permit scrubber that it reconfigures
    # from the tags/attributes on every #sanitize call. Sharing it here would race
    # our stricter tag set against ActionText's default rendering on concurrent
    # requests, so use a dedicated instance of the same sanitizer class to keep the
    # scrubber isolated.
    def sanitizer
      sanitizer_class.new
    end

    def sanitizer_class
      ActionText::ContentHelper.sanitizer.class
    end

    def allowed_tags
      ContentFilters::SanitizeTags::ALLOWED_TAGS
    end

    def allowed_attributes
      standard_allowed_attributes + EXTRA_ALLOWED_ATTRIBUTES
    end

    # Mirrors ActionText::ContentHelper#sanitizer_allowed_attributes, which isn't
    # exposed at the module level.
    def standard_allowed_attributes
      ActionText::ContentHelper.allowed_attributes ||
        (sanitizer_class.allowed_attributes + ActionText::Attachment::ATTRIBUTES).to_a
    end
end
