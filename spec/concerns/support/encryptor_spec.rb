require "spec_helper"
require "securerandom"

describe ConcernsOnRails::Support::Encryptor do
  let(:key) { "a-reasonably-long-test-passphrase" }

  describe ".encrypt / .decrypt round-trip" do
    it "round-trips a value" do
      envelope = described_class.encrypt("123-45-6789", key: key)
      expect(described_class.decrypt(envelope, key: key)).to eq("123-45-6789")
    end

    it "returns a Base64 envelope that does not contain the plaintext" do
      envelope = described_class.encrypt("SENSITIVE", key: key)
      expect(envelope).to be_a(String)
      expect(envelope).not_to include("SENSITIVE")
    end

    it "produces different ciphertext for the same plaintext (random IV)" do
      a = described_class.encrypt("same", key: key)
      b = described_class.encrypt("same", key: key)
      expect(a).not_to eq(b)
      expect(described_class.decrypt(a, key: key)).to eq("same")
      expect(described_class.decrypt(b, key: key)).to eq("same")
    end

    it "passes nil through untouched on both paths" do
      expect(described_class.encrypt(nil, key: key)).to be_nil
      expect(described_class.decrypt(nil, key: key)).to be_nil
    end

    it "round-trips an empty string (distinct from nil)" do
      envelope = described_class.encrypt("", key: key)
      expect(envelope).not_to be_nil
      expect(described_class.decrypt(envelope, key: key)).to eq("")
    end
  end

  describe "envelope structure" do
    it "starts with the version and algorithm bytes and embeds the key id" do
      raw = described_class.encrypt("x", key: key, key_id: 7).unpack1("m0")
      ver, alg, key_id = raw.byteslice(0, 3).unpack("C3")
      expect([ver, alg, key_id]).to eq([0x01, 0x01, 7])
    end
  end

  describe "integrity" do
    it "raises DecryptionError on a wrong key" do
      envelope = described_class.encrypt("secret", key: key)
      expect { described_class.decrypt(envelope, key: "wrong-key") }
        .to raise_error(ConcernsOnRails::Encryption::DecryptionError)
    end

    it "raises DecryptionError when the ciphertext is tampered" do
      raw = described_class.encrypt("secret", key: key).unpack1("m0")
      flipped = raw[0..-2] + (raw[-1].ord ^ 0x01).chr
      tampered = [flipped].pack("m0")
      expect { described_class.decrypt(tampered, key: key) }
        .to raise_error(ConcernsOnRails::Encryption::DecryptionError)
    end

    it "raises DecryptionError when the header (AAD) is tampered" do
      raw = described_class.encrypt("secret", key: key).unpack1("m0").dup
      raw.setbyte(2, raw.getbyte(2) ^ 0x01) # flip a key_id bit -> AAD mismatch
      expect { described_class.decrypt([raw].pack("m0"), key: key) }
        .to raise_error(ConcernsOnRails::Encryption::DecryptionError)
    end

    it "raises DecryptionError on a malformed / too-short envelope" do
      expect { described_class.decrypt("not-a-real-envelope", key: key) }
        .to raise_error(ConcernsOnRails::Encryption::DecryptionError)
    end
  end

  describe ".normalize_key" do
    it "raises MissingKeyError on a blank key" do
      expect { described_class.normalize_key("") }
        .to raise_error(ConcernsOnRails::Encryption::MissingKeyError)
    end

    it "uses a raw 32-byte binary key as-is" do
      raw = SecureRandom.random_bytes(32)
      expect(described_class.normalize_key(raw)).to eq(raw)
      expect(described_class.normalize_key(raw).bytesize).to eq(32)
    end

    it "decodes a 64-char hex key to 32 bytes" do
      hex = "ab" * 32
      derived = described_class.normalize_key(hex)
      expect(derived.bytesize).to eq(32)
      expect(derived).to eq([hex].pack("H*"))
    end

    it "stretches a passphrase to a stable 32-byte key" do
      a = described_class.normalize_key("hunter2")
      b = described_class.normalize_key("hunter2")
      expect(a.bytesize).to eq(32)
      expect(a).to eq(b) # deterministic for a fixed salt
    end

    it "derives different keys for different salts" do
      a = described_class.normalize_key("hunter2", salt: "salt-a")
      b = described_class.normalize_key("hunter2", salt: "salt-b")
      expect(a).not_to eq(b)
    end

    it "resolves a Proc key" do
      envelope = described_class.encrypt("v", key: -> { key })
      expect(described_class.decrypt(envelope, key: -> { key })).to eq("v")
    end
  end
end
