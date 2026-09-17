require "active_support/concern"
require "concerns_on_rails/support/column_guard"

# Loaded here — with the concern, on first use — rather than at gem boot, so
# apps that never include Sluggable never load friendly_id.
begin
  require "friendly_id"
rescue LoadError
  raise ConcernsOnRails::MissingDependency,
        "ConcernsOnRails::Models::Sluggable requires the friendly_id gem. " \
        'Add `gem "friendly_id", "~> 5.4"` to your Gemfile to use it.'
end

module ConcernsOnRails
  module Models
    module Sluggable
      extend ActiveSupport::Concern

      # instance methods
      LABEL = "ConcernsOnRails::Models::Sluggable".freeze

      included do
        # declare class attributes and set default values
        class_attribute :sluggable_field, instance_accessor: false
        self.sluggable_field ||= :name
        # `candidates:` — friendly_id slug candidates tried in order before the
        # uuid fallback; `max_length:` — word-boundary truncation of the slug.
        class_attribute :sluggable_candidates, instance_accessor: false, default: nil
        class_attribute :sluggable_max_length, instance_accessor: false, default: nil

        extend FriendlyId

        # we need use a lambda to access the instance variable
        # instead of friendly_id :slug_source, use: :slugged
        friendly_id :slug_source, use: :slugged
        # friendly_id ->(record) { record.slug_source }, use: :slugged

        # we must override should_generate_new_friendly_id? to support update slug
        # if we don't override this method, friendly_id will not generate the new slug when update
        define_method :should_generate_new_friendly_id? do
          return true if @sluggable_force_regenerate # regenerate_slug!

          field = self.class.sluggable_field
          slug_column = self.class.friendly_id_config.slug_column

          # An explicitly-assigned slug wins — don't overwrite it with a generated
          # one when the slug column itself is being changed in this save.
          changing_slug = respond_to?("will_save_change_to_#{slug_column}?") &&
                          send("will_save_change_to_#{slug_column}?")
          return false if changing_slug

          source_changed = respond_to?("will_save_change_to_#{field}?") &&
                           send("will_save_change_to_#{field}?")
          # Backfill a missing slug even when the source did not change, so
          # legacy/imported rows with a NULL slug still self-heal.
          slug_missing = send(slug_column).blank? && slug_source.present?

          source_changed || slug_missing
        end

        # Defined on the class (like the method above) so it sits ABOVE
        # FriendlyId::Slugged in the ancestor chain — a module-level override
        # here would be shadowed by friendly_id's own. Truncates each candidate
        # at a word (separator) boundary; the uniqueness suffix friendly_id
        # appends on a conflict is added AFTER, on purpose — friendly_id's own
        # `slug_limit` hard-cuts characters and squeezes the uuid inside the
        # limit, which is rarely what a URL wants.
        define_method :normalize_friendly_id do |value|
          normalized = super(value)
          limit = self.class.sluggable_max_length
          return normalized unless limit && normalized.respond_to?(:truncate)

          normalized.truncate(limit, omission: "", separator: friendly_id_config.sequence_separator)
        end
      end

      # class methods
      # A real module (not `class_methods do`) so the macro and its private
      # helpers aren't constrained by Metrics/BlockLength (the Stateable
      # precedent). ActiveSupport::Concern auto-extends ClassMethods.
      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Define sluggable field, with optional friendly_id features.
        # Example:
        #   sluggable_by :wonderful_name
        #   sluggable_by :title, history: true            # old slugs keep resolving (needs a friendly_id_slugs table)
        #   sluggable_by :title, scope: :account_id       # slugs unique per scope column
        #   sluggable_by :title, reserved_words: %w[new]  # block these slugs (a UUID is appended instead)
        #   sluggable_by :title, finders: true            # Model.find accepts a slug directly
        #   sluggable_by :title, candidates: [:title, %i[title city]]   # try "title", then "title-city", then a uuid
        #   sluggable_by :title, max_length: 60                        # truncate at a word boundary
        def sluggable_by(field, history: false, scope: nil, reserved_words: nil, finders: false,
                         candidates: nil, max_length: nil)
          self.sluggable_field = field.to_sym
          self.sluggable_candidates = sluggable_validate_candidates!(candidates)
          self.sluggable_max_length = sluggable_validate_max_length!(max_length)
          # Validate the slug column too (a missing one used to fail at first save
          # with an opaque friendly_id error); an association scope: is exempt.
          scope_column = scope && reflect_on_association(scope.to_sym) ? nil : scope
          ensure_columns!("ConcernsOnRails::Models::Sluggable",
                          [sluggable_field, friendly_id_config.slug_column, scope_column].compact,
                          types: { friendly_id_config.slug_column.to_sym => "string:uniq" })
          return unless history || scope || reserved_words || finders

          reconfigure_friendly_id(history: history, scope: scope,
                                  reserved_words: reserved_words, finders: finders)
        end

        private

        # friendly_id's candidate shapes: a Symbol/String (method), a Proc, or an
        # Array of those (joined with the separator).
        def sluggable_validate_candidates!(candidates)
          return nil if candidates.nil?
          unless candidates.is_a?(Array) && candidates.any?
            raise ArgumentError,
                  "#{LABEL}: candidates: must be an Array of Symbols/Procs/Arrays (got #{candidates.inspect})"
          end

          candidates
        end

        def sluggable_validate_max_length!(max_length)
          return nil if max_length.nil?
          unless max_length.is_a?(Integer) && max_length.positive?
            raise ArgumentError,
                  "#{LABEL}: max_length: must be a positive Integer (got #{max_length.inspect})"
          end

          max_length
        end

        # Re-runs friendly_id with the extra modules. friendly_id merges config
        # across calls, so this layers :history / :scoped / :finders / :reserved onto :slugged.
        def reconfigure_friendly_id(history:, scope:, reserved_words: nil, finders: false)
          modules = [:slugged]
          modules << :history if history
          modules << :scoped if scope
          modules << :finders if finders
          modules << :reserved if reserved_words
          # friendly_id's second argument is a positional options hash (not kwargs),
          # so pass it positionally to stay correct on both Ruby 2.7 and 3.x.
          friendly_id(:slug_source, friendly_id_options(modules, scope, reserved_words))
        end

        # Build friendly_id's positional options hash from the resolved modules.
        def friendly_id_options(modules, scope, reserved_words)
          options = { use: modules }
          options[:scope] = scope if scope
          options[:reserved_words] = Array(reserved_words).map(&:to_s) if reserved_words
          options
        end
      end

      # Instance methods
      # Returns the source for the slug
      # we are calling the class attribute, so we can use it in the lambda
      # Example:
      #   record.slug_source
      def slug_source
        candidates = self.class.sluggable_candidates
        return candidates if candidates

        field = self.class.sluggable_field
        respond_to?(field) ? send(field) : to_s
      end

      # Rebuild the slug from the current source (candidates included) and
      # save — even over a slug that was assigned by hand, which a normal save
      # deliberately leaves alone. Conflicts still get friendly_id's suffix.
      def regenerate_slug!
        @sluggable_force_regenerate = true
        save!
      ensure
        @sluggable_force_regenerate = false
      end
    end
  end
end
