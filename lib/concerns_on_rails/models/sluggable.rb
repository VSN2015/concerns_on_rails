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
        #   sluggable_by :title, history: true       # old slugs keep resolving (needs a friendly_id_slugs table)
        #   sluggable_by :title, scope: :account_id  # slugs unique per scope column
        def sluggable_by(field, history: false, scope: nil)
          self.sluggable_field = field.to_sym
          ensure_columns!("ConcernsOnRails::Models::Sluggable", [sluggable_field, scope].compact)
          reconfigure_friendly_id(history: history, scope: scope) if history || scope
        end

        private

        # Re-runs friendly_id with the extra modules. friendly_id merges config
        # across calls, so this layers :history / :scoped onto the base :slugged.
        def reconfigure_friendly_id(history:, scope:)
          modules = [:slugged]
          modules << :history if history
          modules << :scoped if scope
          options = { use: modules }
          options[:scope] = scope if scope
          # friendly_id's second argument is a positional options hash (not kwargs),
          # so pass it positionally to stay correct on both Ruby 2.7 and 3.x.
          friendly_id(:slug_source, options)
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
