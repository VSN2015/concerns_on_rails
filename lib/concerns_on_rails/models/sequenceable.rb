require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/sequence_calculator"

module ConcernsOnRails
  module Models
    # Generates ordered, human-friendly sequential reference numbers — invoice
    # numbers, order numbers, ticket numbers, support cases. Unlike Hashable /
    # Tokenizable (which produce *random* identifiers), Sequenceable produces
    # *ordered* ones backed by an integer column that is the source of truth.
    #
    #   class Invoice < ApplicationRecord
    #     include ConcernsOnRails::Sequenceable
    #
    #     sequenceable_by :sequence,        # integer column — source of truth
    #       into:    :number,               # optional string column for the formatted value
    #       prefix:  "INV-",
    #       padding: 5,
    #       scope:   :account_id,           # one counter per account
    #       reset:   :year                  # restart numbering each calendar year
    #   end
    #
    #   invoice = Invoice.create!(account_id: 1)
    #   invoice.sequence            # => 1, 2, 3 ... (per account, per year)
    #   invoice.number              # => "INV-2026-00001"
    #   invoice.formatted_sequence  # => "INV-2026-00001"
    #   Invoice.next_sequence(account_id: 1)  # peek the next value without creating
    #
    # The integer is computed as MAX(field) within the scope (+ period) + 1, so
    # numbering is dense and ordered. Generation is best-effort under concurrency
    # — pair the column(s) with a scoped unique DB index for a real guarantee.
    module Sequenceable
      extend ActiveSupport::Concern

      RESET_PERIODS = %i[never year month day].freeze
      ASSIGN_MODES = %i[create manual].freeze
      NAME = "ConcernsOnRails::Models::Sequenceable".freeze

      included do
        class_attribute :sequenceable_config, instance_accessor: false, default: {}
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard
        include ConcernsOnRails::Support::SequenceCalculator

        # Configure a sequenceable field.
        #
        # Options:
        #   into:      string column to persist the formatted value into (default nil)
        #   prefix:    string prepended to the formatted value (default "")
        #   padding:   zero-pad width of the numeric portion (default 0 = no padding)
        #   separator: joins prefix / period token / number in the default format (default "-")
        #   start_at:  first value per scope/period when no rows exist yet (default 1)
        #   scope:     column or array of columns the counter is scoped to (default nil)
        #   reset:     :never (default) | :year | :month | :day — restart per period (needs created_at)
        #   template:  ->(seq, record) { ... } full custom formatter; overrides prefix/padding/period
        #   assign:    :create (default) numbers every record in before_create; :manual leaves the
        #              column NULL until `assign_<field>!` — invoices numbered when finalized
        def sequenceable_by(field = :sequence, into: nil, prefix: "", padding: 0,
                            separator: "-", start_at: 1, scope: nil, reset: :never, template: nil, assign: :create)
          field      = field.to_sym
          into       = into&.to_sym
          reset      = reset.to_sym
          assign     = assign.to_sym
          scope_cols = Array(scope).map(&:to_sym)

          ensure_columns!(NAME, field, types: :integer)
          ensure_columns!(NAME, into, types: :string) if into
          ensure_columns!(NAME, *scope_cols) unless scope_cols.empty?
          ensure_columns!(NAME, :created_at, types: :datetime) unless reset == :never
          validate_sequenceable_options!(reset, template, assign)

          self.sequenceable_config = sequenceable_config.merge(
            field => { into: into, prefix: prefix.to_s, padding: padding.to_i,
                       separator: separator.to_s, start_at: start_at.to_i,
                       scope: scope_cols, reset: reset, template: template, assign: assign }
          )

          before_create -> { assign_sequenceable_value(field) } if assign == :create
          define_sequenceable_methods(field)
        end
      end

      class_methods do
        private

        def define_sequenceable_methods(field)
          define_method("formatted_#{field}") do
            cfg = self.class.sequenceable_config.fetch(field)
            return self[cfg[:into]] if cfg[:into] && self[cfg[:into]].present?
            return nil if self[field].blank?

            self.class.send(:format_sequence, field, self[field], self)
          end

          define_singleton_method("next_#{field}") do |scope_attrs = {}|
            sequence_base_value(field, nil, scope_attrs)
          end

          # On-demand numbering (the only way under assign: :manual), a
          # predicate, and the "still awaiting a number" scope.
          define_method("assign_#{field}!") { sequenceable_assign!(field) }
          define_method("#{field}_assigned?") { self[field].present? }
          scope "pending_#{field}", -> { where(field => nil) }
        end

        def validate_sequenceable_options!(reset, template, assign = :create)
          unless RESET_PERIODS.include?(reset)
            raise ArgumentError, "#{NAME}: unknown reset '#{reset}'. Valid values: #{RESET_PERIODS.join(', ')}"
          end
          unless ASSIGN_MODES.include?(assign)
            raise ArgumentError, "#{NAME}: unknown assign ':#{assign}'. Valid values: #{ASSIGN_MODES.join(', ')}"
          end
          return if template.nil? || template.respond_to?(:call)

          raise ArgumentError, "#{NAME}: template must be callable (respond to #call)"
        end
      end

      # Assigns the sequence (and, when configured, the formatted string) only when
      # the integer column is blank, so callers can pass an explicit value.
      # MAX+1 (or start_at on an empty scope) cannot already be taken within the
      # same consistent read — the pre-1.26 exists? probe re-verified that
      # tautology with an extra query on EVERY create, and could not close the
      # concurrent-insert race anyway. Concurrency is the scoped unique index's
      # job (pair with Support::UniqueRetry around the create).
      def assign_sequenceable_value(field)
        cfg = self.class.sequenceable_config.fetch(field)
        sequenceable_pin_created_at(cfg)

        self[field] = self.class.send(:sequence_base_value, field, self, {}) if self[field].blank?

        return unless cfg[:into] && self[cfg[:into]].blank?

        self[cfg[:into]] = self.class.send(:format_sequence, field, self[field], self)
      end

      # Number the record now: the next value for its scope/period plus the
      # into: string, save!d when the record is persisted and left for the
      # caller's save when new. false (nothing rewritten) when already
      # numbered, so a "finalize" action can be retried safely.
      def sequenceable_assign!(field)
        return false if self[field].present?

        assign_sequenceable_value(field)
        save! unless new_record?
        true
      end
      private :sequenceable_assign!

      # Pin the row inside the period its number is drawn from: with reset:
      # enabled the period is computed from "now" during before_create, but
      # created_at is stamped later, at INSERT time — across a year/month/day
      # boundary the row would carry a number from the old period with a
      # timestamp in the new one. AR honors a pre-set created_at.
      def sequenceable_pin_created_at(cfg)
        return if cfg[:reset] == :never || !created_at.nil?

        self.created_at = self.class.send(:base_time, self)
      end
      private :sequenceable_pin_created_at
    end
  end
end
