require "active_support/concern"

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
      MAX_GENERATION_ATTEMPTS = 10
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
        def sequenceable_by(field = :sequence, into: nil, prefix: "", padding: 0,
                            separator: "-", start_at: 1, scope: nil, reset: :never, template: nil)
          field      = field.to_sym
          into       = into&.to_sym
          reset      = reset.to_sym
          scope_cols = Array(scope).map(&:to_sym)

          ensure_columns!(NAME, field)
          ensure_columns!(NAME, into) if into
          ensure_columns!(NAME, *scope_cols) unless scope_cols.empty?
          ensure_columns!(NAME, :created_at) unless reset == :never
          validate_sequenceable_options!(reset, template)

          self.sequenceable_config = sequenceable_config.merge(
            field => { into: into, prefix: prefix.to_s, padding: padding.to_i,
                       separator: separator.to_s, start_at: start_at.to_i,
                       scope: scope_cols, reset: reset, template: template }
          )

          before_create -> { assign_sequenceable_value(field) }
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
        end

        def validate_sequenceable_options!(reset, template)
          unless RESET_PERIODS.include?(reset)
            raise ArgumentError, "#{NAME}: unknown reset '#{reset}'. Valid values: #{RESET_PERIODS.join(', ')}"
          end

          return if template.nil? || template.respond_to?(:call)

          raise ArgumentError, "#{NAME}: template must be callable (respond to #call)"
        end
      end

      # Assigns the sequence (and, when configured, the formatted string) only when
      # the integer column is blank, so callers can pass an explicit value. The
      # increment-until-free loop is a best-effort guard against pre-taken values;
      # a scoped unique index is the real concurrency guarantee.
      def assign_sequenceable_value(field)
        cfg = self.class.sequenceable_config.fetch(field)

        if self[field].blank?
          candidate = self.class.send(:sequence_base_value, field, self, {})
          attempts = 0
          while self.class.send(:sequence_value_taken?, field, candidate, self, {})
            attempts += 1
            if attempts >= MAX_GENERATION_ATTEMPTS
              raise "#{NAME}: could not find a free value for '#{field}' after " \
                    "#{MAX_GENERATION_ATTEMPTS} attempts — add a scoped unique index"
            end
            candidate += 1
          end
          self[field] = candidate
        end

        return unless cfg[:into] && self[cfg[:into]].blank?

        self[cfg[:into]] = self.class.send(:format_sequence, field, self[field], self)
      end
    end
  end
end
