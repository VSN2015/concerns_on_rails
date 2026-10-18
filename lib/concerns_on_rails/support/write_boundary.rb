module ConcernsOnRails
  module Support
    # The last moment of a save before its INSERT / UPDATE, for the concerns
    # that DERIVE a column from the values about to be written: Encryptable's
    # blind index (a digest of the plaintext) and Auditable's trail (one entry
    # per tracked change).
    #
    # No callback is late enough for that. Rails runs before_save, then
    # before_create / before_update, each kind in declaration order, and a
    # model declares its own callbacks below the concern macros — so a
    # `before_update { self.email = email.downcase }` ran after the digest was
    # taken (the row stored one value's ciphertext beside another value's
    # digest, and find_by_<field> missed it), and a `before_save { self.total
    # = ... }` ran after the audit capture (the trail left the change out, or
    # recorded a value that was never stored).
    #
    # Persistence#_create_record / #_update_record call the private
    # attributes_for_create / attributes_for_update inside the create /
    # update callbacks' block: after EVERY before_* callback, right before the
    # row is written, on every Rails line from 6.0 to 8.1. Dirty computed the
    # column list it hands in after the callbacks but before the consumers
    # ran, so each column a consumer changed is added to it. A column a
    # consumer left unchanged is not: an unchanged trail is never written, so
    # a stale instance cannot overwrite the entry a concurrent save appended.
    # A save that a callback aborts never gets here, so it derives nothing.
    #
    # The consumers run in a FIXED order, whatever the include order: blind
    # indexes first, then the audit entry, so an audited blind-index column
    # records the digest actually written. A friendly_id slug is built before
    # either (before validation, or in before_create for a generated source —
    # Support::GeneratedValues), so both see it.
    #
    # Each consumer concern includes this module; Ruby includes a module once
    # per ancestor chain, so a model with both runs one override.
    module WriteBoundary
      # Private instance methods a consumer defines. Each receives true on a
      # create and false on an update, and returns the names of the columns
      # it may have assigned.
      CONSUMER_HOOKS = %i[
        encryptable_before_write
        auditable_before_write
      ].freeze

      # Runs every consumer the record defines, in order, and returns the
      # columns they changed.
      def self.derive(record, create:)
        columns = CONSUMER_HOOKS.flat_map do |hook|
          record.respond_to?(hook, true) ? Array(record.send(hook, create)) : []
        end
        columns.map(&:to_s).uniq.select { |name| record.will_save_change_to_attribute?(name) }
      end

      private

      def attributes_for_create(attribute_names)
        super(attribute_names | ConcernsOnRails::Support::WriteBoundary.derive(self, create: true))
      end

      def attributes_for_update(attribute_names)
        super(attribute_names | ConcernsOnRails::Support::WriteBoundary.derive(self, create: false))
      end
    end
  end
end
