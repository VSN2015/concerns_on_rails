require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/affix"
require "concerns_on_rails/support/batch_ops"

module ConcernsOnRails
  module Models
    module Publishable
      extend ActiveSupport::Concern

      SCOPE_BASES = %i[published unpublished scheduled draft].freeze

      included do
        class_attribute :publishable_field, instance_accessor: false, default: :published_at
        class_attribute :publishable_scope_names, instance_accessor: false,
                                                  default: SCOPE_BASES.to_h { |b| [b, b] }.freeze
        class_attribute :publishable_captured_scopes, instance_accessor: false, default: {}.freeze

        define_publishable_scopes(nil, nil)
        self.publishable_captured_scopes =
          ConcernsOnRails::Support::Affix.capture(self, SCOPE_BASES).freeze
      end

      class_methods do # rubocop:disable Metrics/BlockLength
        include ConcernsOnRails::Support::ColumnGuard

        # Pass `default_scope: true` to hide unpublished records by default
        # (`.all` then returns only published). The negative scopes
        # (.unpublished/.scheduled/.draft) unscope the field, so they still work.
        def publishable_by(field = nil, default_scope: false, prefix: nil, suffix: nil)
          self.publishable_field = field || :published_at
          @publishable_boolean_column = nil
          ensure_columns!("ConcernsOnRails::Models::Publishable", publishable_field, types: :datetime)

          if prefix || suffix
            define_publishable_scopes(prefix, suffix)
            ConcernsOnRails::Support::Affix.retire!(self, publishable_captured_scopes,
                                                    label: "ConcernsOnRails::Models::Publishable")
          end

          enable_published_default_scope if default_scope
        end

        # True when the configured column is a boolean (vs a datetime timestamp);
        # the scopes use this to pick equality vs time-comparison predicates.
        # Memoized per class once the schema is reachable — a columns_hash
        # lookup on every scope evaluation adds up on hot query paths.
        # (publishable_by resets the memo when the field changes.)
        def publishable_boolean_column?
          cached = @publishable_boolean_column
          return cached unless cached.nil?

          return false unless schema_reachable?

          @publishable_boolean_column = columns_hash[publishable_field.to_s]&.type == :boolean
        end

        # Publish every not-currently-published record in the relation.
        # Returns the Integer count. NOTE this includes *scheduled* rows,
        # whose future timestamp is overwritten with now — chain the draft
        # scope (`Post.draft.publish_all`) when that isn't what you want.
        #
        # The target predicate is built INLINE against `all` rather than
        # routed through the `unpublished` scope, whose body opens with
        # `unscope(where: publishable_field)` — that would strip the caller's
        # own constraint on the publish column right back off, so
        # `Post.draft.publish_all` used to silently publish scheduled rows
        # too and destroy their future timestamps.
        #
        # The composing consequence: on a model configured with
        # `publishable_by ..., default_scope: true`, `all` is already limited
        # to published rows, so a bare `Post.publish_all` targets nothing.
        # Chain `.draft` or `.unpublished` first — both unscope the field
        # themselves, so the chain resolves to the rows you mean.
        def publish_all
          pending = publishable_pending_relation
          if publishable_batch_fast_path?(:publish)
            value = publishable_boolean_column? || Time.zone.now
            return pending.update_all(
              ConcernsOnRails::Support::BatchOps.with_timestamps(self, publishable_field => value)
            )
          end

          ConcernsOnRails::Support::BatchOps.run(
            pending,
            label: "ConcernsOnRails::Models::Publishable",
            message: "failed to publish record",
            &:publish!
          )
        end

        # Unpublish every published record in the relation. Writes nil on both
        # column types, exactly as `unpublish!` does. The `published` scope
        # does NOT unscope the field, so a caller's own constraint on the
        # publish column composes here as it should.
        def unpublish_all
          live = all.public_send(publishable_scope_names.fetch(:published))
          if publishable_batch_fast_path?(:unpublish)
            return live.update_all(
              ConcernsOnRails::Support::BatchOps.with_timestamps(self, publishable_field => nil)
            )
          end

          ConcernsOnRails::Support::BatchOps.run(
            live,
            label: "ConcernsOnRails::Models::Publishable",
            message: "failed to unpublish record",
            &:unpublish!
          )
        end

        private

        # Scopes are built here rather than inline in `included do` so their
        # names can be affixed. `included do` calls this with no affix, so a
        # model that only includes the concern keeps the default names; an
        # affixed macro call rebuilds them under new names and retires the
        # originals.
        #
        # All scopes branch on the column type: a boolean publishable column
        # needs equality predicates, not the timestamp `<= now` / `> now`
        # comparisons that produce nonsensical SQL against a boolean.
        def define_publishable_scopes(prefix, suffix) # rubocop:disable Metrics/PerceivedComplexity
          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: publishable_field)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: publishable_field)
          self.publishable_scope_names = SCOPE_BASES.to_h do |base|
            [base, ConcernsOnRails::Support::Affix.name(base, prefix: prefix, suffix: suffix)]
          end.freeze

          scope publishable_scope_names[:published], lambda {
            if publishable_boolean_column?
              where(publishable_field => true)
            else
              where(arel_table[publishable_field].lteq(Time.zone.now))
            end
          }
          scope publishable_scope_names[:unpublished], lambda {
            if publishable_boolean_column?
              unscope(where: publishable_field).where(publishable_field => [nil, false])
            else
              column = arel_table[publishable_field]
              unscope(where: publishable_field).where(column.eq(nil).or(column.gt(Time.zone.now)))
            end
          }
          # Set, but the publish time is still in the future (timestamp columns only).
          scope publishable_scope_names[:scheduled], lambda {
            next none if publishable_boolean_column?

            unscope(where: publishable_field).where(arel_table[publishable_field].gt(Time.zone.now))
          }
          # Never published — a true draft.
          scope publishable_scope_names[:draft], lambda {
            if publishable_boolean_column?
              unscope(where: publishable_field).where(publishable_field => [nil, false])
            else
              unscope(where: publishable_field).where(publishable_field => nil)
            end
          }
        end

        # Routed through a helper so the `default_scope:` keyword doesn't shadow
        # the `default_scope` macro inside `publishable_by`.
        def enable_published_default_scope
          published_scope = publishable_scope_names.fetch(:published)
          default_scope { public_send(published_scope) }
        end

        # "Not currently published", built against the CURRENT relation: the
        # same predicate the `unpublished` scope body applies, minus the
        # `unscope` that would peel the caller's own constraint on the column
        # back off (see publish_all).
        def publishable_pending_relation
          return all.where(publishable_field => [nil, false]) if publishable_boolean_column?

          column = arel_table[publishable_field]
          all.where(column.eq(nil).or(column.gt(Time.zone.now)))
        end

        # Whether the single-UPDATE fast path is safe — hooks/bang methods
        # unoverridden AND the model declares no validations. The whole
        # decision, including why, lives in Support::BatchOps.fast_path?.
        def publishable_batch_fast_path?(kind)
          methods = if kind == :publish
                      %i[before_publish after_publish publish!]
                    else
                      %i[before_unpublish after_unpublish unpublish!]
                    end
          ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::Publishable, *methods)
        end
      end

      # Instance methods
      # Publish the record
      # Example:
      #   record.publish!
      # Lifecycle hooks — override in the model (mirrors SoftDeletable's hooks).
      def before_publish; end
      def after_publish; end
      def before_unpublish; end
      def after_unpublish; end

      def publish!
        publishable_write_with_hooks(Time.zone.now, :publish)
      end

      # Unpublish the record
      # Example:
      #   record.unpublish!
      def unpublish!
        publishable_write_with_hooks(nil, :unpublish)
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
      # Fires the publish hooks (same state change as publish!, so since 1.22
      # they no longer silently skip). Raises on a boolean publishable column:
      # the Time would cast to `true` and silently publish NOW instead of
      # scheduling — a boolean column cannot represent a future publish.
      # Example:
      #   record.publish_at!(1.day.from_now)
      def publish_at!(time)
        if self.class.publishable_boolean_column?
          raise ArgumentError,
                "ConcernsOnRails::Models::Publishable: publish_at! needs a timestamp column, but " \
                "'#{self.class.publishable_field}' is a boolean — a Time casts to true and would " \
                "publish immediately. Use publish!/unpublish!, or a datetime column to schedule."
        end

        publishable_write_with_hooks(time, :publish)
      end

      # Shared write path: hooks and the timestamp write in ONE transaction, so
      # a raising hook rolls the change back (SoftDeletable's pattern). Before
      # 1.22 a raising after_publish left the record published with the side
      # effect half-done. (Postfix private — the keyword form trips RuboCop's
      # scope analysis against the `private` inside the class_methods block.)
      def publishable_write_with_hooks(value, kind)
        result = false
        transaction do
          kind == :publish ? before_publish : before_unpublish
          result = update(self.class.publishable_field => value)
          (kind == :publish ? after_publish : after_unpublish) if result
        end
        result
      end
      private :publishable_write_with_hooks
    end
  end
end
