require "openssl"
require "concerns_on_rails/encryption"

module ConcernsOnRails
  module Support
    # Pure, stateless AES-256-GCM codec shared by Models::Encryptable. Like the
    # other Support modules (Masker, Money) it holds no state — key material is
    # always passed in — and uses only stdlib OpenSSL, matching the dependency
    # -free crypto already in Controllers::WebhookVerifiable.
    #
    # On-disk envelope (Base64 via pack("m0"), the gem's convention — avoids the
    # base64 gem, no longer default on Ruby 3.4):
    #
    #   ver(1)=0x01 | alg(1)=0x01 | key_id(1) | iv(12) | auth_tag(16) | ciphertext
    #
    # The 3-byte header is fed to GCM as additional authenticated data (AAD), so
    # the version/algorithm/key-id cannot be altered without failing the auth
    # tag. `alg 0x11` (deterministic) and a non-zero `key_id` (rotation) are
    # reserved for later features — the format tolerates them without a break.
    module Encryptor
      module_function

      VERSION_BYTE = 0x01
      ALG_GCM = 0x01
      HEADER_FORMAT = "C3".freeze
      HEADER_LEN = 3
      IV_LEN = 12          # 96-bit IV: GCM's recommended size
      TAG_LEN = 16         # 128-bit auth tag
      KEY_BYTES = 32       # AES-256
      CIPHER = "aes-256-gcm".freeze
      MIN_ENVELOPE_BYTES = HEADER_LEN + IV_LEN + TAG_LEN
      # Domain-separation label so the blind-index HMAC key differs from the AES
      # key even when both derive from the same configured secret.
      BLIND_INDEX_INFO = "concerns_on_rails/blind_index/v1".freeze

      # Encrypt a String, returning a Base64 envelope. nil passes through as nil
      # (a blank column stays blank / NULL-able), never an encrypted empty value.
      def encrypt(plaintext, key:, key_id: 0, salt: ConcernsOnRails::Encryption::DEFAULT_KDF_SALT)
        return nil if plaintext.nil?

        derived = normalize_key(key, salt: salt)
        cipher = OpenSSL::Cipher.new(CIPHER)
        cipher.encrypt
        cipher.key = derived
        iv = cipher.random_iv
        header = [VERSION_BYTE, ALG_GCM, key_id & 0xFF].pack(HEADER_FORMAT)
        cipher.auth_data = header
        ciphertext = cipher.update(plaintext.to_s) + cipher.final
        [header + iv + cipher.auth_tag + ciphertext].pack("m0")
      end

      # Decrypt a Base64 envelope back to the plaintext String. nil -> nil. A
      # wrong key, tampered ciphertext, or malformed envelope raises
      # Encryption::DecryptionError (never a raw OpenSSL error).
      def decrypt(envelope, key:, salt: ConcernsOnRails::Encryption::DEFAULT_KDF_SALT)
        return nil if envelope.nil?

        # "m0" is strict Base64 and raises ArgumentError on non-Base64 input.
        raw =
          begin
            envelope.to_s.unpack1("m0").to_s
          rescue ArgumentError
            raise ConcernsOnRails::Encryption::DecryptionError, "malformed encryption envelope"
          end
        raise ConcernsOnRails::Encryption::DecryptionError, "malformed encryption envelope" if raw.bytesize < MIN_ENVELOPE_BYTES

        header = raw.byteslice(0, HEADER_LEN)
        iv = raw.byteslice(HEADER_LEN, IV_LEN)
        tag = raw.byteslice(HEADER_LEN + IV_LEN, TAG_LEN)
        ciphertext = raw.byteslice((HEADER_LEN + IV_LEN + TAG_LEN)..) || ""

        derived = normalize_key(key, salt: salt)
        cipher = OpenSSL::Cipher.new(CIPHER)
        cipher.decrypt
        cipher.key = derived
        cipher.iv = iv
        cipher.auth_tag = tag
        cipher.auth_data = header
        cipher.update(ciphertext) + cipher.final
      rescue OpenSSL::Cipher::CipherError
        raise ConcernsOnRails::Encryption::DecryptionError,
              "could not decrypt value (wrong key or tampered ciphertext)"
      end

      # Deterministic keyed fingerprint (lowercase hex) for equality lookups — a
      # "blind index". The HMAC key is domain-separated from the AES key via
      # BLIND_INDEX_INFO, so the two are cryptographically independent. The same
      # value + key always yields the same digest, enabling an indexed WHERE.
      def blind_index(value, key:, salt: ConcernsOnRails::Encryption::DEFAULT_KDF_SALT)
        return nil if value.nil?

        master = normalize_key(key, salt: salt)
        subkey = OpenSSL::HMAC.digest("SHA256", master, BLIND_INDEX_INFO)
        OpenSSL::HMAC.hexdigest("SHA256", subkey, value.to_s)
      end

      # Coerce key material to a 32-byte AES key: raw 32-byte binary as-is, a
      # 64-hex string decoded, otherwise a passphrase stretched with PBKDF2. The
      # salt + iteration count are part of the derived key's identity.
      def normalize_key(value, salt: ConcernsOnRails::Encryption::DEFAULT_KDF_SALT)
        value = value.call if value.respond_to?(:call)
        material = value.to_s
        raise ConcernsOnRails::Encryption::MissingKeyError, "no encryption key configured" if material.empty?

        return material.b if material.bytesize == KEY_BYTES && material.encoding == Encoding::BINARY
        return [material].pack("H*") if material.match?(/\A\h{64}\z/)

        OpenSSL::KDF.pbkdf2_hmac(
          material,
          salt: salt.to_s,
          iterations: ConcernsOnRails::Encryption::KDF_ITERATIONS,
          length: KEY_BYTES,
          hash: "SHA256"
        )
      end
    end
  end
end
