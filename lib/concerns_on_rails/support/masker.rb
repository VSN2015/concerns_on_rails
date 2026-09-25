require "active_support/concern"
require "bigdecimal"

module ConcernsOnRails
  module Support
    # Display-only value-masking helpers shared by Models::Maskable.
    #
    # nil stays nil. Any other non-String value (an Integer SSN column, a
    # bigint phone number) is stringified BEFORE masking — never returned
    # untouched, which would display the raw value: masking must fail closed.
    # Masking is for presentation only — callers keep the original value in
    # the database.
    #
    # Fail closed: a String that does not have the shape a preset expects
    # (no "@" for #email, four or fewer ASCII digits for #phone) gets the
    # full mask (#all) — never the raw value.
    module Masker
      module_function

      DEFAULT_MASK = "*".freeze

      # Replace every character with the mask character.
      def all(value, mask: DEFAULT_MASK)
        value = stringify(value)
        value.nil? ? nil : mask * value.length
      end

      # Keep only the last four characters visible.
      def last4(value, mask: DEFAULT_MASK)
        value = stringify(value)
        return nil if value.nil?

        value.length <= 4 ? mask * value.length : (mask * (value.length - 4)) + value[-4..]
      end

      # Mask the local part of an email, keeping the first character + domain:
      #   "john.doe@example.com" => "j*******@example.com"
      def email(value, mask: DEFAULT_MASK)
        value = stringify(value)
        return nil if value.nil?

        local, at, domain = value.partition("@")
        return all(value, mask: mask) if at.empty? # not email-shaped: reveal nothing

        masked_local = local.length <= 1 ? mask : local[0] + (mask * (local.length - 1))
        "#{masked_local}@#{domain}"
      end

      # Keep the last four digits of a phone number visible: "***-2671". With
      # four or fewer digits that would be the whole number, so mask it all.
      def phone(value, mask: DEFAULT_MASK)
        value = stringify(value)
        return nil if value.nil?

        digits = value.gsub(/\D/, "")
        return all(value, mask: mask) if digits.length <= 4

        "#{mask * 3}-#{digits[-4..]}"
      end

      # Keep the last four digits of a card number: "**** **** **** 4242".
      def credit_card(value, mask: DEFAULT_MASK)
        value = stringify(value)
        return nil if value.nil?

        digits = value.gsub(/\D/, "")
        return all(value, mask: mask) if digits.length <= 4

        "#{mask * 4} #{mask * 4} #{mask * 4} #{digits[-4..]}"
      end

      # nil, or the value as a String. A BigDecimal renders in plain notation
      # ("12345.67"), not BigDecimal#to_s's scientific "0.1234567e5".
      def stringify(value)
        case value
        when nil, String then value
        when BigDecimal then value.to_s("F")
        else value.to_s
        end
      end
    end
  end
end
