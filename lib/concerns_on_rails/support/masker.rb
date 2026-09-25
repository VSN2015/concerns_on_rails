require "active_support/concern"

module ConcernsOnRails
  module Support
    # Display-only value-masking helpers shared by Models::Maskable.
    #
    # Every method is string-safe: a non-String argument is returned untouched,
    # exactly like the Normalizable / Sanitizable preset lambdas. Masking is for
    # presentation only — callers keep the original value in the database.
    #
    # Fail closed: a String that does not have the shape a preset expects
    # (no "@" for #email, four or fewer ASCII digits for #phone) gets the
    # full mask (#all) — never the raw value.
    module Masker
      module_function

      DEFAULT_MASK = "*".freeze

      # Replace every character with the mask character.
      def all(value, mask: DEFAULT_MASK)
        value.is_a?(String) ? mask * value.length : value
      end

      # Keep only the last four characters visible.
      def last4(value, mask: DEFAULT_MASK)
        return value unless value.is_a?(String)

        value.length <= 4 ? mask * value.length : (mask * (value.length - 4)) + value[-4..]
      end

      # Mask the local part of an email, keeping the first character + domain:
      #   "john.doe@example.com" => "j*******@example.com"
      def email(value, mask: DEFAULT_MASK)
        return value unless value.is_a?(String)

        local, at, domain = value.partition("@")
        return all(value, mask: mask) if at.empty? # not email-shaped: reveal nothing

        masked_local = local.length <= 1 ? mask : local[0] + (mask * (local.length - 1))
        "#{masked_local}@#{domain}"
      end

      # Keep the last four digits of a phone number visible: "***-2671". With
      # four or fewer digits that would be the whole number, so mask it all.
      def phone(value, mask: DEFAULT_MASK)
        return value unless value.is_a?(String)

        digits = value.gsub(/\D/, "")
        return all(value, mask: mask) if digits.length <= 4

        "#{mask * 3}-#{digits[-4..]}"
      end

      # Keep the last four digits of a card number: "**** **** **** 4242".
      def credit_card(value, mask: DEFAULT_MASK)
        return value unless value.is_a?(String)

        digits = value.gsub(/\D/, "")
        return all(value, mask: mask) if digits.length <= 4

        "#{mask * 4} #{mask * 4} #{mask * 4} #{digits[-4..]}"
      end
    end
  end
end
