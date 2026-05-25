require "securerandom"

module ConcernsOnRails
  module Support
    # Shared random-value generation used by Hashable (:custom) and Tokenizable
    # (:alphanumeric / :numeric). Samples `length` characters uniformly from
    # `alphabet` using SecureRandom.
    module RandomValue
      module_function

      def from_alphabet(alphabet, length)
        Array.new(length) { alphabet[SecureRandom.random_number(alphabet.size)] }.join
      end
    end
  end
end
