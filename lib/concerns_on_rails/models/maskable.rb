require "active_support/concern"
require "concerns_on_rails/support/masker"

module ConcernsOnRails
  module Models
    # Non-destructive display masking for sensitive string attributes.
    #
    # Masking is ALWAYS read-only: each declaration adds a `masked_<field>`
    # reader and never writes the stored column (the raw value stays in the DB,
    # because masking is a presentation concern). For stripping dangerous HTML
    # see Models::Sanitizable.
    #
    #   class User < ApplicationRecord
    #     include ConcernsOnRails::Models::Maskable
    #
    #     maskable :email, with: :email          # => user.masked_email  "j****@example.com"
    #     maskable :card,  with: :credit_card    # => user.masked_card   "**** **** **** 4242"
    #     maskable :ssn,   with: :last4, mask: "•"
    #     maskable :token, with: ->(v) { "#{v.to_s[0, 3]}…" }
    #   end
    #
    # Presets (the `with:` argument):
    #   :email       — mask the local part, keep first char + domain
    #   :phone       — keep the last 4 digits ("***-2671")
    #   :credit_card — keep the last 4 digits ("**** **** **** 4242")
    #   :last4       — keep the last 4 characters
    #   :all         — mask every character (the default)
    #   Proc         — used as-is (the caller owns the non-String guard)
    #
    # `mask:` sets the mask character (default "*") for the preset forms.
    module Maskable
      extend ActiveSupport::Concern

      PRESETS = %i[email phone credit_card last4 all].freeze

      included do
        class_attribute :maskable_rules, instance_accessor: false, default: {}
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        def maskable(*fields, with: :all, mask: "*")
          raise ArgumentError, "ConcernsOnRails::Models::Maskable: at least one field is required" if fields.empty?

          masker = resolve_masker(with, mask)
          ensure_columns!("ConcernsOnRails::Models::Maskable", fields)

          fields.each do |field|
            key = field.to_sym
            self.maskable_rules = maskable_rules.merge(key => masker)
            define_method("masked_#{field}") { masker.call(self[key]) }
          end
        end
      end

      class_methods do
        private

        def resolve_masker(with, mask)
          case with
          when Symbol
            unless PRESETS.include?(with)
              raise ArgumentError,
                    "ConcernsOnRails::Models::Maskable: unknown preset '#{with}'. " \
                    "Valid presets: #{PRESETS.join(', ')}"
            end

            ->(v) { ConcernsOnRails::Support::Masker.public_send(with, v, mask: mask) }
          when Proc then with
          else
            raise ArgumentError,
                  "ConcernsOnRails::Models::Maskable: :with must be a preset symbol or a Proc/lambda, got #{with.class}"
          end
        end
      end
    end
  end
end
