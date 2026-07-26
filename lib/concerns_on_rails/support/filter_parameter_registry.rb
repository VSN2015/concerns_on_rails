require "set"

module ConcernsOnRails
  module Support
    # Registry of sensitive parameter names (populated by Models::Encryptable)
    # surfaced to Rails' log filtering. Appending plain symbols to
    # `config.filter_parameters` at model-class-load time misses every consumer
    # that snapshots the list at boot (ActiveRecord's `filter_attributes` copy,
    # lograge-style initializers, precompiled filters). A proc appended once at
    # boot by ConcernsOnRails::Railtie consults this live registry at *filter
    # time*, so fields registered when a model class loads later (lazy loading
    # in development) are still redacted.
    #
    # Matching mirrors Rails symbol-filter semantics: case-insensitive
    # substring match on the parameter key.
    class FilterParameterRegistry
      FILTERED = "[FILTERED]".freeze

      def initialize
        @fields = Set.new
        @mutex = Mutex.new
        @pattern = nil
        # Stable object so the Railtie's idempotence check (`include?` before
        # `<<`) holds across repeated initializer runs. ActiveSupport's
        # ParameterFilter dups values before invoking proc filters, so in-place
        # String#replace is the supported redaction mechanism (non-String
        # values are left to the legacy symbol append in Encryptable).
        @proc = lambda do |key, value|
          value.replace(FILTERED) if value.is_a?(String) && include?(key)
        end
      end

      def add(field)
        name = field.to_s.downcase
        return if name.empty?

        @mutex.synchronize do
          @pattern = nil if @fields.add?(name)
        end
        nil
      end

      def include?(key)
        regexp = pattern
        !regexp.nil? && regexp.match?(key.to_s)
      end

      def pattern
        @mutex.synchronize do
          next nil if @fields.empty?

          @pattern ||= Regexp.new(@fields.map { |f| Regexp.escape(f) }.join("|"), Regexp::IGNORECASE)
        end
      end

      def to_proc
        @proc
      end

      # Spec hygiene — the registry is process-global.
      def reset!
        @mutex.synchronize do
          @fields.clear
          @pattern = nil
        end
      end
    end
  end
end
