ActiveSupport.on_load(:action_text_content) do
  class ActionText::Content::Filter
    class << self
      def apply(content)
        filter = new(content)
        filter.applicable? ? ActionText::Content.new(filter.apply, canonicalize: false) : content
      end
    end

    def initialize(content)
      @content = content
    end

    def applicable?
      raise NotImplementedError
    end

    def apply
      raise NotImplementedError
    end

    private
      attr_reader :content
      delegate :fragment, to: :content
  end
end
