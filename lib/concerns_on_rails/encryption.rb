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
      attr_accessor :key, :key_derivation_salt, :on_missing_key, :raise_on_decrypt_error

      def initialize
        @key = nil
        @key_derivation_salt = DEFAULT_KDF_SALT
        @on_missing_key = :raise
        @raise_on_decrypt_error = true
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
