require "active_support/concern"
require "concerns_on_rails/support/column_guard"

module ConcernsOnRails
  module Models
    # Concern-aware deep copy ("clone this invoice/template"). A bare
    # ActiveRecord `dup` copies identity-bearing columns — the slug, the API
    # token, the invoice number, the audit trail, even `created_at` (which AR
    # preserves on save when present) — so naive copies collide with unique
    # indexes or lie about their history. Duplicable knows its sibling
    # concerns and blanks exactly those columns, letting each concern
    # regenerate fresh values on save.
    #
    #   class Invoice < ApplicationRecord
    #     include ConcernsOnRails::Models::Duplicable
    #     include ConcernsOnRails::Models::Sequenceable
    #
    #     has_many :line_items
    #     sequenceable_by :sequence, into: :number, prefix: "INV-"
    #     duplicable_by associations: %i[line_items],
    #                   reset: %i[issued_at],
    #                   suffix: { title: " (copy)" }
    #   end
    #
    #   copy = invoice.duplicate                  # unsaved deep copy
    #   copy = invoice.duplicate!(title: "Q3")    # saved, with overrides
    #
    # What gets blanked automatically (identity, not business state):
    #   * created_at / updated_at (AR keeps a present created_at on save)
    #   * Sluggable slug — regenerated from the source field on save
    #   * Tokenizable / Hashable columns — regenerated on create
    #   * Sequenceable sequence + into: columns — next number on create
    #   * Auditable trail column — a copy inherits no history (its own
    #     creation is then audited normally, like any create)
    #   * SoftDeletable timestamp — a copy of trash is a live record
    #   * Lockable attempts (0) / locked_at (nil) — a copy starts unlocked
    # Business state (Publishable/Stateable/Activatable/...) is a judgment
    # call, so it is NOT auto-reset — list those columns in `reset:`.
    #
    # Associations (`associations:` allow-list, declared before the macro):
    #   * has_many / has_one — children are deep-copied. A child whose class
    #     also includes Duplicable is copied via ITS OWN `duplicate` (own
    #     resets, own nested associations) — recursive graphs stay declarative.
    #   * has_and_belongs_to_many — the copy links to the SAME records (join
    #     rows are duplicated, the associated records are not).
    #   * has_many :through — rejected; duplicate the direct association.
    #   * belongs_to — rejected; a copy shares its parent by keeping the FK.
    #
    # `duplicate` returns an UNSAVED record with unsaved children (persisted
    # together by `duplicate!` / `save!` via autosave). Override
    # `on_duplicate(copy)` for custom tweaks — it runs last, before return.
    module Duplicable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Duplicable".freeze
      SUPPORTED_MACROS = %i[has_many has_one has_and_belongs_to_many].freeze
      TIMESTAMP_COLUMNS = %w[created_at updated_at].freeze

      included do
        class_attribute :duplicable_config, instance_accessor: false,
                                            default: { associations: [], reset: [], suffix: {} }.freeze
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Configure the copy rules. Optional — `duplicate` works with bare
        # `include` (attribute copy + the automatic identity resets).
        def duplicable_by(associations: [], reset: [], suffix: {})
          associations = Array(associations).map(&:to_sym)
          reset = Array(reset).map(&:to_sym)
          suffix = suffix.to_h { |field, text| [field.to_sym, text.to_s] }

          duplicable_validate_associations!(associations)
          ensure_columns!(LABEL, reset) unless reset.empty?
          ensure_columns!(LABEL, suffix.keys) unless suffix.empty?

          self.duplicable_config = { associations: associations, reset: reset, suffix: suffix }.freeze
        end

        private

        def duplicable_validate_associations!(names)
          names.each do |name|
            reflection = reflect_on_association(name)
            if reflection.nil?
              raise ArgumentError,
                    "#{LABEL}: no association `#{name}` — declare it before `duplicable_by` " \
                    "(the CounterCacheable convention)"
            end
            duplicable_validate_reflection!(name, reflection)
          end
        end

        def duplicable_validate_reflection!(name, reflection)
          if reflection.through_reflection
            raise ArgumentError,
                  "#{LABEL}: `#{name}` is a has_many :through association — duplicate the direct " \
                  "association instead (the through rows follow from it)"
          end
          return if SUPPORTED_MACROS.include?(reflection.macro)

          raise ArgumentError,
                "#{LABEL}: `#{name}` is a #{reflection.macro} association; only " \
                "#{SUPPORTED_MACROS.join(' / ')} can be duplicated (a copy shares its belongs_to parents)"
        end
      end

      # Override point — receives the UNSAVED copy as the last step of
      # `duplicate`, so tweaks apply before any save.
      def on_duplicate(_copy); end

      # Unsaved deep copy: attributes via `dup`, identity columns blanked,
      # `reset:` columns blanked, `suffix:` strings appended, `overrides`
      # assigned, allow-listed associations copied, then `on_duplicate`.
      def duplicate(overrides = {})
        copy = dup
        duplicable_reset_attributes(copy)
        duplicable_apply_suffixes(copy)
        overrides.each { |attribute, value| copy.public_send("#{attribute}=", value) }
        duplicable_copy_associations(copy)
        on_duplicate(copy)
        copy
      end

      # Persisted deep copy — the copy and its copied children save together
      # (autosave) inside one transaction. Returns the saved copy.
      def duplicate!(overrides = {})
        copy = duplicate(overrides)
        transaction { copy.save! }
        copy
      end

      private

      def duplicable_reset_attributes(copy)
        (duplicable_auto_reset_columns + self.class.duplicable_config[:reset]).each do |column|
          copy[column] = nil if copy.class.column_names.include?(column.to_s)
        end
        copy[self.class.lockable_attempts_field] = 0 if duplicable_concern?(Lockable)
      end

      def duplicable_apply_suffixes(copy)
        self.class.duplicable_config[:suffix].each do |field, text|
          copy[field] = "#{copy[field]}#{text}" if copy[field].present?
        end
      end

      # Identity-bearing columns owned by sibling concerns (see module docs).
      def duplicable_auto_reset_columns
        columns = TIMESTAMP_COLUMNS.dup
        columns.concat(duplicable_generator_columns)
        columns << self.class.auditable_into if duplicable_concern?(Auditable)
        columns << self.class.soft_delete_field if duplicable_concern?(SoftDeletable)
        columns << self.class.lockable_locked_at_field if duplicable_concern?(Lockable)
        columns
      end

      # Columns whose values are generated per record (slug, tokens, sequence
      # numbers) — each concern regenerates them on the copy's save.
      def duplicable_generator_columns
        columns = []
        columns << self.class.friendly_id_config.slug_column if duplicable_concern?(Sluggable)
        columns.concat(self.class.tokenizable_fields.keys) if duplicable_concern?(Tokenizable)
        columns << self.class.hashable_field if duplicable_concern?(Hashable) && self.class.hashable_field
        columns.concat(duplicable_sequence_columns) if duplicable_concern?(Sequenceable)
        columns
      end

      def duplicable_sequence_columns
        self.class.sequenceable_config.flat_map do |field, cfg|
          [field, cfg[:into]].compact
        end
      end

      def duplicable_concern?(concern)
        self.class.include?(concern)
      end

      def duplicable_copy_associations(copy)
        self.class.duplicable_config[:associations].each do |name|
          reflection = self.class.reflect_on_association(name)
          case reflection.macro
          when :has_many
            public_send(name).each { |child| copy.public_send(name) << duplicable_child_copy(child) }
          when :has_one
            child = public_send(name)
            copy.public_send("#{name}=", duplicable_child_copy(child)) if child
          when :has_and_belongs_to_many
            copy.public_send("#{name}=", public_send(name).to_a)
          end
        end
      end

      # A child that is itself Duplicable copies by its OWN rules; anything
      # else gets a dup with the timestamps blanked (AR preserves a present
      # created_at on save).
      def duplicable_child_copy(child)
        return child.duplicate if child.class.include?(Duplicable)

        plain = child.dup
        TIMESTAMP_COLUMNS.each { |column| plain[column] = nil if plain.class.column_names.include?(column) }
        plain
      end
    end
  end
end
