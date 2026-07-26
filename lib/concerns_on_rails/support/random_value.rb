require "securerandom"

module ConcernsOnRails
  module Support
    # Shared random-value generation used by Hashable (:custom) and Tokenizable
    # (:alphanumeric / :numeric). Samples `length` characters uniformly from
    # `alphabet` using SecureRandom.
    module RandomValue
      module_function

      def from_alphabet(alphabet, length)
        size = alphabet.size
        # Alphabets wider than a byte can't use the batched path below.
        return Array.new(length) { alphabet[SecureRandom.random_number(size)] }.join if size > 256

        # One batched CSPRNG draw with rejection sampling (drop bytes from the
        # biased tail so the distribution stays uniform) instead of one
        # SecureRandom call + one 1-char String per character.
        limit = (256 / size) * size
        result = String.new(capacity: length)
        while result.length < length
          SecureRandom.bytes(length - result.length).each_byte do |byte|
            next if byte >= limit

            result << alphabet[byte % size]
            break if result.length == length
          end
        end
        result
      end
    end
  end
end
