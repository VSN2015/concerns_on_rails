require "active_support/concern"
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
    module Monetizable
      extend ActiveSupport::Concern

      included do
        class_attribute :monetizable_rules, instance_accessor: false, default: {}
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        def monetizable(*fields, as: nil, unit: "$", precision: 2, delimiter: ",", separator: ".", subunit_to_unit: 100)
          raise ArgumentError, "ConcernsOnRails::Models::Monetizable: at least one field is required" if fields.empty?

          raise ArgumentError, "ConcernsOnRails::Models::Monetizable: :as cannot be combined with multiple fields" if as && fields.size > 1

          ensure_columns!("ConcernsOnRails::Models::Monetizable", fields)
          config = { unit: unit, precision: precision, delimiter: delimiter, separator: separator, subunit_to_unit: subunit_to_unit }
          fields.each { |cents_field| define_money_accessors(cents_field.to_sym, as, config) }
        end
      end

      class_methods do # rubocop:disable Metrics/BlockLength
        private

        def define_money_accessors(cents_field, as, config)
          name = money_name(cents_field, as)
          subunit = config[:subunit_to_unit]
          self.monetizable_rules = monetizable_rules.merge(cents_field => name)

          define_method(name) do
            cents = self[cents_field]
            cents.nil? ? nil : BigDecimal(cents.to_s) / subunit
          end

          define_method("#{name}=") do |amount|
            self[cents_field] = amount.nil? ? nil : (BigDecimal(amount.to_s) * subunit).round
          end

          define_method("formatted_#{name}") do
            cents = self[cents_field]
            cents.nil? ? nil : ConcernsOnRails::Support::Money.format(cents, config)
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
