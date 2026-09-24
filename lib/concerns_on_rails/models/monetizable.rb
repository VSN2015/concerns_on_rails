require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/money"

module ConcernsOnRails
  module Models
    # Money handling for an integer "subunit" column (e.g. cents) — exact,
    # float-free, via BigDecimal.
    #
    # Declaring `monetizable :price_cents` adds three methods derived from the
    # column name (the `_cents` suffix is stripped):
    #   * `price`            — the amount as a BigDecimal (cents / 100)
    #   * `price=`           — assign in major units; rounded to whole cents
    #   * `formatted_price`  — a display string ("$1,234.56")
    #
    #   class Product < ApplicationRecord
    #     include ConcernsOnRails::Models::Monetizable
    #
    #     monetizable :price_cents                       # => price / price= / formatted_price
    #     monetizable :shipping_cents, as: :shipping
    #     monetizable :total_cents, unit: "€", separator: ",", delimiter: "."
    #   end
    #
    #   product.price = 19.99   # stores price_cents = 1999
    #   product.price           # => 0.1999e2  (BigDecimal 19.99)
    #   product.formatted_price # => "$19.99"
    #
    # Options: `as:` (explicit method name — required when the column does not
    # end in `_cents`), `unit:` ("$"), `precision:` (2), `delimiter:` (","),
    # `separator:` ("."), `subunit_to_unit:` (100).
    #
    # Class-level aggregates come for free and follow the current scope:
    #   Product.sum_price                        # => BigDecimal, SUM(price_cents) / 100
    #   Product.in_stock.average_price           # average / minimum / maximum too; nil on empty sets
    #   Product.formatted_sum_price              # => "$1,234.56" — every aggregate has a formatted_ twin
    #   product.formatted_price(unit: "€", delimiter: ".", separator: ",")   # per-call display overrides
    module Monetizable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Monetizable".freeze
      AGGREGATES = %i[sum average minimum maximum].freeze

      included do
        class_attribute :monetizable_rules, instance_accessor: false, default: {}
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        def monetizable(*fields, as: nil, unit: "$", precision: 2, delimiter: ",", separator: ".", subunit_to_unit: 100)
          raise ArgumentError, "ConcernsOnRails::Models::Monetizable: at least one field is required" if fields.empty?

          raise ArgumentError, "ConcernsOnRails::Models::Monetizable: :as cannot be combined with multiple fields" if as && fields.size > 1

          # Coerce, don't just validate: a String like "100" passed the old
          # `.to_i.positive?` check but was stored raw — the writer's
          # `BigDecimal * "100"` then raised TypeError (swallowed to nil by the
          # form-garbage rescue) and the reader's division raised outright.
          # :precision likewise ("2" works; "two" raises). Per-call format
          # overrides go through the same coercion.
          config = ConcernsOnRails::Support::Money.coerce_numeric_options(
            { unit: unit, precision: precision, delimiter: delimiter, separator: separator, subunit_to_unit: subunit_to_unit },
            LABEL
          ).freeze

          ensure_columns!("ConcernsOnRails::Models::Monetizable", fields, types: :integer)
          fields.each do |cents_field|
            name = money_name(cents_field.to_sym, as)
            define_money_accessors(cents_field.to_sym, name, config)
            define_money_aggregates(cents_field.to_sym, name, config)
          end
        end
      end

      class_methods do # rubocop:disable Metrics/BlockLength
        private

        def define_money_accessors(cents_field, name, config)
          subunit = config[:subunit_to_unit]
          self.monetizable_rules = monetizable_rules.merge(cents_field => name)

          define_method(name) do
            cents = self[cents_field]
            cents.nil? ? nil : BigDecimal(cents.to_s) / subunit
          end

          # Strings are read canonically ("19.99") or in this field's display
          # format ("$1,234.50", "€1.234,50"), so formatted output round-trips.
          # Form garbage ("abc", "") and non-finite numbers (NaN, Infinity)
          # cast to nil — the ActiveModel convention Storable/Encryptable
          # follow — instead of raising out of the setter before validation.
          define_method("#{name}=") do |amount|
            decimal = amount.nil? ? nil : ConcernsOnRails::Support::Money.parse(amount, config)
            self[cents_field] = decimal && (decimal * subunit).round
          end

          define_method("formatted_#{name}") do |**overrides|
            options = ConcernsOnRails::Support::Money.format_options(config, overrides, LABEL)
            ConcernsOnRails::Support::Money.format_each(self[cents_field], options)
          end
        end

        # `sum_price` / `average_price` / `minimum_price` / `maximum_price` and
        # their `formatted_` twins. Defined on the singleton so a relation
        # (`Product.in_stock.sum_price`) delegates here inside its scoping;
        # `public_send(aggregate)` then runs against the current scope.
        def define_money_aggregates(cents_field, name, config)
          subunit = config[:subunit_to_unit]
          AGGREGATES.each do |aggregate|
            define_singleton_method("#{aggregate}_#{name}") do
              ConcernsOnRails::Support::Money.decimal(public_send(aggregate, cents_field), subunit)
            end

            define_singleton_method("formatted_#{aggregate}_#{name}") do |**overrides|
              options = ConcernsOnRails::Support::Money.format_options(config, overrides, LABEL)
              ConcernsOnRails::Support::Money.format_each(public_send(aggregate, cents_field), options)
            end
          end
        end

        def money_name(cents_field, as)
          return as.to_sym if as

          str = cents_field.to_s
          unless str.end_with?("_cents")
            raise ArgumentError,
                  "ConcernsOnRails::Models::Monetizable: cannot derive a money method name from '#{cents_field}' " \
                  "(it does not end in '_cents'); pass `as:` to name it explicitly"
          end

          str.delete_suffix("_cents").to_sym
        end
      end
    end
  end
end
