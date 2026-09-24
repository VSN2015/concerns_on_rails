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
    #   * counter-cache columns (0) maintained by a child — a child class's
    #     CounterCacheable rules or a native `belongs_to ..., counter_cache:`
    #     pointing at this class (found through its has_many / has_one
    #     reflections). A copy starts at zero and each child it actually
    #     carries re-increments it on save, so a deep copy counts its copied
    #     children and a shallow copy counts none. A plain (non-Duplicable)
    #     child copy gets the same zeroing for its own counters, since its
    #     children are never copied. A counter kept by a child with no
    #     has_many/has_one on this class is invisible here — list it in
    #     `reset:` (nil) or `on_duplicate`.
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
      #
      # `only:` / `except:` pick which of the macro's associations THIS copy
      # carries (`duplicate!(except: :line_items)`; `only: []` is a shallow
      # copy). An explicit nil counts as passed, not as absent, so
      # `only: params[:associations]` with nothing checked copies NO
      # associations rather than silently deep-copying every one. Braceless overrides arrive through **options too (Ruby 3
      # keyword rules), so `only`/`except` are reserved keys — an attribute
      # literally named that goes in a braced Hash.
      def duplicate(overrides = {}, **options)
        overrides = overrides.merge(options.except(:only, :except))
        associations = duplicable_selected_associations(options.slice(:only, :except))

        copy = dup
        duplicable_reset_attributes(copy)
        duplicable_apply_suffixes(copy)
        overrides.each { |attribute, value| copy.public_send("#{attribute}=", value) }
        Duplicable.keeping_counter_cache_columns(copy) { duplicable_copy_associations(copy, associations) }
        on_duplicate(copy)
        copy
      end

      # Persisted deep copy — the copy and its copied children save together
      # (autosave) inside one transaction. Returns the saved copy, its counter
      # columns re-read from the row the children's saves incremented.
      def duplicate!(overrides = {}, **)
        copy = duplicate(overrides, **)
        transaction { copy.save! }
        Duplicable.refresh_counter_cache_columns(copy)
        copy
      end

      private

      # The macro's list is the ceiling: a per-call name outside it raises, so
      # a controller param can never smuggle in an unvetted association.
      def duplicable_selected_associations(selection)
        declared = self.class.duplicable_config[:associations]
        raise ArgumentError, "#{LABEL}: pass either :only or :except, not both" if selection.size > 1
        return declared if selection.empty?

        mode, names = selection.first
        chosen = duplicable_validate_selection!(Array(names).map(&:to_sym), declared)
        mode == :only ? declared & chosen : declared - chosen
      end

      def duplicable_validate_selection!(chosen, declared)
        chosen.each do |name|
          next if declared.include?(name)

          raise ArgumentError, "#{LABEL}: #{name} is not a duplicable association (declared: #{declared.join(', ')})"
        end
      end

      def duplicable_reset_attributes(copy)
        (duplicable_auto_reset_columns + self.class.duplicable_config[:reset]).each do |column|
          copy[column] = nil if copy.class.column_names.include?(column.to_s)
        end
        copy[self.class.lockable_attempts_field] = 0 if duplicable_concern?(Lockable)
        Duplicable.zero_counter_cache_columns(copy)
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
        columns.concat(duplicable_lockable_columns) if duplicable_concern?(Lockable)
        columns
      end

      # Columns whose values are generated per record (slug, tokens, sequence
      # numbers) — each concern regenerates them on the copy's save.
      def duplicable_generator_columns
        columns = []
        columns << self.class.friendly_id_config.slug_column if duplicable_concern?(Sluggable)
        columns.concat(duplicable_token_columns) if duplicable_concern?(Tokenizable)
        columns << self.class.hashable_field if duplicable_concern?(Hashable) && self.class.hashable_field
        columns.concat(duplicable_sequence_columns) if duplicable_concern?(Sequenceable)
        columns
      end

      # A token and its `expires_in:` stamp must be cleared together. Blanking
      # only the token leaves the copy with a fresh secret carrying the
      # original's expiry — often already in the past, so the copy's token is
      # born dead.
      def duplicable_token_columns
        self.class.tokenizable_fields.flat_map do |field, config|
          next field unless config[:expires_in]

          [field, self.class.tokenizable_expiry_column(field)]
        end
      end

      # The lock stamp AND the unlock token: a copy is born unlocked, so it must
      # not inherit a live unlock link. Leaving the token would also put the
      # same secret on two rows, and unlock_by_token's lookup would then pick
      # an arbitrary one.
      def duplicable_lockable_columns
        [self.class.lockable_locked_at_field, self.class.lockable_unlock_token_field].compact
      end

      def duplicable_sequence_columns
        self.class.sequenceable_config.flat_map do |field, cfg|
          [field, cfg[:into]].compact
        end
      end

      def duplicable_concern?(concern)
        self.class.include?(concern)
      end

      def duplicable_copy_associations(copy, associations)
        associations.each do |name|
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
        Duplicable.zero_counter_cache_columns(plain)
        plain
      end

      class << self
        # Zero every counter-cache column on `record`'s class (see the module
        # docs): the copy's children re-increment it on save.
        def zero_counter_cache_columns(record)
          counter_cache_columns(record.class).each { |column| record[column] = 0 }
        end

        # Adding children to a has_many with no inverse (a scoped one, say)
        # makes Rails bump the OWNER's in-memory counter and clear the change.
        # The copy would then INSERT that bumped value (partial inserts off)
        # and each child's save would increment it again — 2 children, 4.
        # Put the pre-association values back so the INSERT carries them.
        def keeping_counter_cache_columns(record)
          before = counter_cache_columns(record.class).to_h { |column| [column, record[column]] }
          yield
          before.each { |column, value| record[column] = value }
        end

        # After the save the database holds the true counts (each child's
        # create incremented them); mirror them into the saved copy.
        def refresh_counter_cache_columns(record)
          columns = counter_cache_columns(record.class)
          return if columns.empty? || !record.persisted?

          values = record.class.unscoped.where(record.class.primary_key => record.id).pluck(*columns).first
          return if values.nil?

          columns.zip(Array(values)).each { |column, value| record[column] = value }
          record.send(:clear_attribute_changes, columns)
        end

        # Columns of `klass` maintained by a child's counter — CounterCacheable
        # rules or native belongs_to counter_cache — discovered through
        # klass's own has_many / has_one reflections (through associations
        # carry no counter of their own).
        def counter_cache_columns(klass)
          columns = klass.reflect_on_all_associations.flat_map do |reflection|
            next [] unless %i[has_many has_one].include?(reflection.macro) && !reflection.options[:through]

            child = counter_cache_safe_klass(reflection)
            next [] unless child

            counter_cacheable_columns(klass, child) + native_counter_cache_columns(klass, reflection, child)
          end
          columns.map(&:to_s).uniq & klass.column_names
        end

        private

        def counter_cacheable_columns(klass, child)
          return [] unless defined?(ConcernsOnRails::Models::CounterCacheable) &&
                           child.include?(ConcernsOnRails::Models::CounterCacheable)

          child.counter_cacheable_rules.filter_map do |rule|
            target = counter_cache_safe_klass(child.reflect_on_association(rule[:association]))
            rule[:count_column] if target && klass <= target
          end
        end

        # A polymorphic belongs_to counts on whichever owner declared the
        # matching `has_many ..., as:`; a plain one on its own target class.
        def native_counter_cache_columns(klass, reflection, child)
          child.reflect_on_all_associations(:belongs_to).filter_map do |belongs_to|
            next unless belongs_to.options[:counter_cache]

            owner = if belongs_to.polymorphic?
                      reflection.options[:as].to_s == belongs_to.name.to_s
                    else
                      target = counter_cache_safe_klass(belongs_to)
                      target && klass <= target
                    end
            belongs_to.counter_cache_column if owner
          end
        end

        # A reflection whose class can't be resolved (a typo'd class_name, a
        # model not loadable in this process) contributes no counters rather
        # than breaking every duplicate.
        def counter_cache_safe_klass(reflection)
          reflection&.klass
        rescue NameError, ArgumentError, ActiveRecord::ActiveRecordError
          nil
        end
      end
    end
  end
end
