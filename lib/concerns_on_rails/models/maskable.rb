require "active_support/concern"
require "concerns_on_rails/support/column_guard"
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
    #
    # Serialization: `masked_attributes` returns every declared field masked
    # (String keys, like `attributes`), and `as_json(masked: true)` /
    # `to_json(masked: true)` / `serializable_hash(masked: true)` swap the
    # declared fields for their masked forms in the usual Rails serialization
    # path — `masked: [:email]` limits it to a subset — so an API can render
    # `user.as_json(masked: true)` without a serializer per audience.
    module Maskable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Maskable".freeze
      # What `masked:` accepts besides `true` — a field or a list of them.
      MASKED_OPTION_TYPES = [Symbol, String, Array].freeze
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

      module ClassMethods
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

      # Every declared field, masked, keyed like `attributes` (String keys):
      #   user.masked_attributes  # => { "email" => "j***@x.com", "card" => "**** **** **** 4242" }
      def masked_attributes
        self.class.maskable_rules.to_h { |field, masker| [field.to_s, masker.call(self[field])] }
      end

      # `masked: true` (all declared fields) or `masked: [:email, ...]` swaps
      # the masked form into the serialized hash — the entry point for
      # `as_json` / `to_json` too. Fields dropped by `only:`/`except:` stay
      # dropped; undeclared fields in `masked:` raise.
      def serializable_hash(options = nil)
        masked = options && options[:masked]
        return super unless masked

        # Rails hands a nested `include:` an empty options Hash, so a child
        # would serialize unmasked while the caller believes the whole
        # document is masked. Carry the request down; a child that is not
        # Maskable ignores the unknown option. Children mask all of their own
        # declared fields -- a parent's field list names the PARENT's columns.
        hash = super(maskable_masked_options(options))

        maskable_fields_for(masked).each do |field|
          next unless hash.key?(field.to_s)

          # Mask what was serialized, not the raw column: an overridden reader
          # or a Sanitizable(on: :read) field must not slip its unfiltered
          # value into the response through the masker.
          hash[field.to_s] = self.class.maskable_rules.fetch(field).call(hash[field.to_s])
        end
        hash
      end

      # Propagate `masked: true` into every `include:` entry that does not
      # already say otherwise, leaving the caller's Hash untouched.
      def maskable_masked_options(options)
        included = options[:include]
        return options if included.blank?

        options.merge(include: maskable_masked_includes(included))
      end

      def maskable_masked_includes(included)
        case included
        when Symbol, String then { included.to_sym => { masked: true } }
        when Array then included.map { |entry| maskable_masked_includes(entry) }.reduce({}, :merge)
        when Hash then included.to_h { |name, nested| [name, maskable_masked_child(nested)] }
        else included
        end
      end

      def maskable_masked_child(nested)
        return { masked: true } unless nested.is_a?(Hash)

        nested.key?(:masked) ? nested : nested.merge(masked: true)
      end

      def maskable_fields_for(masked)
        declared = self.class.maskable_rules.keys
        return declared if masked == true

        unless MASKED_OPTION_TYPES.any? { |type| masked.is_a?(type) }
          raise ArgumentError, "#{LABEL}: masked: takes true or a list of declared fields, got #{masked.class}"
        end

        Array(masked).map(&:to_sym).each do |field|
          next if declared.include?(field)

          raise ArgumentError, "#{LABEL}: #{field} is not a maskable field (declared: #{declared.join(', ')})"
        end
      end
      private :maskable_fields_for, :maskable_masked_options, :maskable_masked_includes, :maskable_masked_child
    end
  end
end
