require "active_support/concern"

module ConcernsOnRails
  module Models
    module Publishable
      extend ActiveSupport::Concern

      included do
        class_attribute :publishable_field, instance_accessor: false, default: :published_at

        # All scopes branch on the column type: a boolean publishable column (which
        # the macro and instance methods also accept) needs equality predicates,
        # not the timestamp `<= now` / `> now` comparisons that produce nonsensical
        # SQL against a boolean.
        scope :published, lambda {
          if publishable_boolean_column?
            where(publishable_field => true)
          else
            where(arel_table[publishable_field].lteq(Time.zone.now))
          end
        }
        scope :unpublished, lambda {
          if publishable_boolean_column?
            unscope(where: publishable_field).where(publishable_field => [nil, false])
          else
            column = arel_table[publishable_field]
            unscope(where: publishable_field).where(column.eq(nil).or(column.gt(Time.zone.now)))
          end
        }
        # Set, but the publish time is still in the future (timestamp columns only).
        scope :scheduled, lambda {
          next none if publishable_boolean_column?

          unscope(where: publishable_field).where(arel_table[publishable_field].gt(Time.zone.now))
        }
        # Never published — a true draft.
        scope :draft, lambda {
          if publishable_boolean_column?
            unscope(where: publishable_field).where(publishable_field => [nil, false])
          else
            unscope(where: publishable_field).where(publishable_field => nil)
          end
        }
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        # Pass `default_scope: true` to hide unpublished records by default
        # (`.all` then returns only published). The negative scopes
        # (.unpublished/.scheduled/.draft) unscope the field, so they still work.
        def publishable_by(field = nil, default_scope: false)
          self.publishable_field = field || :published_at
          ensure_columns!("ConcernsOnRails::Models::Publishable", publishable_field)
          enable_published_default_scope if default_scope
        end

        # True when the configured column is a boolean (vs a datetime timestamp);
        # the scopes use this to pick equality vs time-comparison predicates.
        def publishable_boolean_column?
          columns_hash[publishable_field.to_s]&.type == :boolean
        end

        private

        # Routed through a helper so the `default_scope:` keyword doesn't shadow
        # the `default_scope` macro inside `publishable_by`.
        def enable_published_default_scope
          default_scope { published }
        end
      end

      # Instance methods
      # Publish the record
      # Example:
      #   record.publish!
      def publish!
        update(self.class.publishable_field => Time.zone.now)
      end

      # Unpublish the record
      # Example:
      #   record.unpublish!
      def unpublish!
        update(self.class.publishable_field => nil)
      end

      # Check if the record is published
      # Example:
      #   record.published?
      def published?
        value = self[self.class.publishable_field]
        return false unless value.present?

        value.respond_to?(:<=) ? value <= Time.zone.now : true
      end

      # Check if the record is unpublished
      # Example:
      #   record.unpublished?
      def unpublished?
        !published?
      end

      # Set, but the publish time is still in the future.
      def scheduled?
        value = self[self.class.publishable_field]
        return false if value.blank?

        value.respond_to?(:>) ? value > Time.zone.now : false
      end

      # Never set — a true draft.
      def draft?
        self[self.class.publishable_field].blank?
      end

      # Publish at an explicit time. A future time schedules the record.
      # Example:
      #   record.publish_at!(1.day.from_now)
      def publish_at!(time)
        update(self.class.publishable_field => time)
      end
    end
  end
end
