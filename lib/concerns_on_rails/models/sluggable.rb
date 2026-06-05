require "active_support/concern"
require "friendly_id"

module ConcernsOnRails
  module Models
    module Sluggable
      extend ActiveSupport::Concern

      # instance methods
      included do
        # declare class attributes and set default values
        class_attribute :sluggable_field, instance_accessor: false
        self.sluggable_field ||= :name

        extend FriendlyId

        # we need use a lambda to access the instance variable
        # instead of friendly_id :slug_source, use: :slugged
        friendly_id :slug_source, use: :slugged
        # friendly_id ->(record) { record.slug_source }, use: :slugged

        # we must override should_generate_new_friendly_id? to support update slug
        # if we don't override this method, friendly_id will not generate the new slug when update
        define_method :should_generate_new_friendly_id? do
          field = self.class.sluggable_field
          respond_to?("will_save_change_to_#{field}?") && send("will_save_change_to_#{field}?")
        end
      end

      # class methods
      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        # Define sluggable field, with optional friendly_id features.
        # Example:
        #   sluggable_by :wonderful_name
        #   sluggable_by :title, history: true            # old slugs keep resolving (needs a friendly_id_slugs table)
        #   sluggable_by :title, scope: :account_id       # slugs unique per scope column
        #   sluggable_by :title, reserved_words: %w[new]  # block these slugs (a UUID is appended instead)
        #   sluggable_by :title, finders: true            # Model.find accepts a slug directly
        def sluggable_by(field, history: false, scope: nil, reserved_words: nil, finders: false)
          self.sluggable_field = field.to_sym
          ensure_columns!("ConcernsOnRails::Models::Sluggable", [sluggable_field, scope].compact)
          return unless history || scope || reserved_words || finders

          reconfigure_friendly_id(history: history, scope: scope,
                                  reserved_words: reserved_words, finders: finders)
        end

        private

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
        field = self.class.sluggable_field
        respond_to?(field) ? send(field) : to_s
      end
    end
  end
end
