require 'hashids'

module Hashidable
  extend ActiveSupport::Concern

  class_methods do
    # Usage: hashidable_by field: :id, hashid_field: :hashid, salt: nil, min_length: 8
    def hashidable_by(field: :id, hashid_field: :hashid, salt: nil, min_length: 8)
      @hashidable_options = {
        field: field,
        hashid_field: hashid_field,
        salt: salt || Rails.application.class.module_parent_name,
        min_length: min_length
      }

      before_create :generate_unique_hashid
      validates hashid_field, uniqueness: true
      define_method(:hashid) do
        self.send(hashid_field)
      end
      define_method(:decode_hashid) do
        hashids = Hashids.new(self.class.hashidable_options[:salt], self.class.hashidable_options[:min_length])
        decoded = hashids.decode(self.send(hashid_field))
        decoded.first
      end
    end

    def hashidable_options
      @hashidable_options || {}
    end
  end

  private

  def generate_unique_hashid
    opts = self.class.hashidable_options
    field_value = self.send(opts[:field])
    hashids = Hashids.new(opts[:salt], opts[:min_length])
    candidate = nil
    loop do
      val = field_value || SecureRandom.random_number(1_000_000_000)
      candidate = hashids.encode(val)
      break unless self.class.exists?(opts[:hashid_field] => candidate)
      field_value = SecureRandom.random_number(1_000_000_000)
    end
    self.send("#{opts[:hashid_field]}=", candidate)
  end
end