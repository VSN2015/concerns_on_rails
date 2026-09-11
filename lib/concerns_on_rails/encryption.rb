module ConcernsOnRails
  # Configuration and error types backing Models::Encryptable.
  #
  # The gem stays agnostic about where secrets live: the host app supplies the
  # key (commonly a Proc reading Rails credentials) via a small config object,
  # mirroring the existing ConcernsOnRails.deprecator accessor pattern:
  #
  #   ConcernsOnRails.configure_encryption do |c|
  #     c.key = -> { Rails.application.credentials.dig(:encryption, :key) }
  #   end
  #
  # A key may be raw 32-byte binary, a 64-char hex string, or any passphrase
  # (stretched to 32 bytes with PBKDF2-HMAC-SHA256). Resolution is lazy — a
  # missing key raises MissingKeyError at first encrypt/decrypt, never at
  # class-load, so a model file can be required before credentials load.
  module Encryption
    # The KDF salt and iteration count are part of the derived key's identity:
    # change them and existing ciphertext can no longer be decrypted. They are
    # deliberately fixed constants (the salt is overridable via config only for
    # apps that must diverge and are prepared to re-encrypt).
    DEFAULT_KDF_SALT = "concerns_on_rails/encryptable/v1".freeze
    KDF_ITERATIONS = 65_536

    # Sentinel returned by Config#resolve_material when no key is configured and
    # on_missing_key is :passthrough — callers then store/read plaintext.
    PASSTHROUGH = :__concerns_on_rails_passthrough__

    # Base class so callers can `rescue ConcernsOnRails::Encryption::Error`.
    class Error < StandardError; end

    # No key could be resolved at encrypt/decrypt time.
    class MissingKeyError < Error; end

    # Decryption failed: wrong key, tampered ciphertext (GCM auth-tag mismatch),
    # or a malformed envelope. Never surfaces raw OpenSSL exceptions to callers.
    class DecryptionError < Error; end

    class Config
      # key: raw 32-byte binary, 64-hex, passphrase, or a Proc returning one.
      # key_derivation_salt: PBKDF2 salt (part of key identity — keep stable).
      # on_missing_key: :raise (default) or :passthrough (dev/test escape hatch
      #   that stores/reads plaintext when no key is configured — never in prod).
      # raise_on_decrypt_error: true (default) raises DecryptionError on a bad
      #   read; false returns nil (a narrow reporting-path opt-out, less safe).
      # key_id: the id (0-255) stamped into envelopes written with `key`; bump it
      #   when rotating so old rows stay identifiable. Prefer 0..25 — see
      #   Models::Encryptable#needs_reencryption.
      # previous_keys: { key_id => material-or-Proc } still able to DECRYPT rows
      #   written before a rotation (never used to encrypt). Remove an id once
      #   `Model.reencrypt_all!` has rewritten every row under the current key.
      attr_accessor :key, :key_derivation_salt, :on_missing_key, :raise_on_decrypt_error
      attr_reader :key_id, :previous_keys

      def initialize
        @key = nil
        @key_derivation_salt = DEFAULT_KDF_SALT
        @on_missing_key = :raise
        @raise_on_decrypt_error = true
        @key_id = 0
        @previous_keys = {}.freeze
      end

      def key_id=(value)
        unless value.is_a?(Integer) && value.between?(0, 255)
          raise ArgumentError, "ConcernsOnRails::Encryption: key_id must be an Integer between 0 and 255 (got #{value.inspect})"
        end

        @key_id = value
      end

      def previous_keys=(value)
        unless value.is_a?(Hash) && value.keys.all? { |id| id.is_a?(Integer) && id.between?(0, 255) }
          # Report the SHAPE only. The rejected value is key material, and the
          # most likely mistake (String ids) would otherwise put a live secret
          # into the exception message, the backtrace, the log and the tracker.
          got = value.is_a?(Hash) ? "Hash with keys #{value.keys.inspect}" : value.class.to_s
          raise ArgumentError,
                "ConcernsOnRails::Encryption: previous_keys must map Integer key ids (0-255) to key material (got #{got})"
        end

        @previous_keys = value.dup.freeze
      end

      # Every id that can currently decrypt — the current key first, then the
      # previous ones in declaration order.
      def key_ids
        [key_id, *previous_keys.keys].uniq
      end

      # Raw material for the key an envelope names: the current key when the id
      # matches `key_id`, else the matching previous key (Procs resolved). nil
      # when the id is unknown.
      def key_material_for(id)
        return key_material if id == key_id

        material = previous_keys[id]
        material = material.call if material.respond_to?(:call)
        material = material.to_s unless material.nil?
        material.nil? || material.empty? ? nil : material
      end

      # Resolve the configured key (calling a Proc) to raw String material, or
      # nil when unset. Callers decide raise-vs-passthrough from that nil.
      def key_material
        material = key.respond_to?(:call) ? key.call : key
        return nil if material.nil?

        material = material.to_s
        material.empty? ? nil : material
      end

      def key?
        !key_material.nil?
      end

      # Resolve the effective key material for a field: a per-field override
      # (String or Proc) wins, else the global key. Returns PASSTHROUGH in the
      # escape-hatch mode, or raises MissingKeyError. Shared by encryption and
      # blind indexing so both derive from the same key.
      def resolve_material(field_key = nil)
        material = field_key.respond_to?(:call) ? field_key.call : field_key
        material = material.to_s unless material.nil?
        return material if material && !material.empty?

        global = key_material
        return global unless global.nil?
        return PASSTHROUGH if on_missing_key == :passthrough

        raise MissingKeyError,
              "ConcernsOnRails::Models::Encryptable: no encryption key configured. Set " \
              "ConcernsOnRails.configure_encryption { |c| c.key = ... } or pass key: to the macro."
      end
    end
  end
end
