require "active_support/concern"
require "bigdecimal"
require "json"

module ConcernsOnRails
  module Models
    # Lightweight change history ("paper_trail-lite") stored as JSON entries in
    # a single text column on the same table — no extra tables, no versioning
    # engine — so it works on any database, including SQLite.
    #
    #   class Product < ApplicationRecord
    #     include ConcernsOnRails::Auditable
    #
    #     auditable_by :price, :status                       # default column :audit_log
    #     # auditable_by :price, into: :history,
    #     #              actor: -> { Current.user&.email },  # stamps "by"
    #     #              max_entries: 50                     # keep the newest 50
    #   end
    #
    #   product.update!(price: 200)
    #   product.audit_trail
    #   # => [{"field"=>"price", "from"=>100, "to"=>200,
    #   #      "at"=>"2026-06-10T12:34:56Z", "by"=>"admin@shop.com"}]
    #   product.last_change_for(:price)            # newest entry for one field
    #   product.audited_changes_since(1.day.ago)
    #   product.clear_audit_trail!                 # wipe the column (skips callbacks)
    #
    # Notes:
    #   * One entry per changed field per save; creates record `"from" => nil`.
    #     "by" is omitted entirely when no actor is configured (or it returns nil).
    #   * Entries are appended in the same INSERT/UPDATE via before_save — no
    #     extra queries. Writes that skip callbacks (update_column(s), touch,
    #     increment!) are NOT audited.
    #   * Values are JSON-coerced: times → ISO8601 UTC strings, BigDecimal →
    #     plain numeric string, symbols → strings.
    #   * A corrupt or non-array column decodes as [] and is overwritten on the
    #     next tracked save. Concurrent saves of one row are last-writer-wins.
    #   * Reach for paper_trail/audited when you need reify/undo, who-dunnit
    #     queries across models, or association tracking.
    module Auditable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Auditable".freeze
      DEFAULT_INTO = :audit_log
      DEFAULT_MAX_ENTRIES = 200

      included do
        class_attribute :auditable_fields, instance_accessor: false, default: []
        class_attribute :auditable_into, instance_accessor: false, default: DEFAULT_INTO
        class_attribute :auditable_actor, instance_accessor: false, default: nil
        class_attribute :auditable_max_entries, instance_accessor: false, default: DEFAULT_MAX_ENTRIES
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Configure the tracked fields and the audit column. See the module docs.
        def auditable_by(*fields, into: DEFAULT_INTO, actor: nil, max_entries: DEFAULT_MAX_ENTRIES)
          fields = fields.flatten.map(&:to_sym).uniq
          into = into.to_sym
          validate_auditable!(fields, into: into, actor: actor, max_entries: max_entries)

          self.auditable_fields = fields
          self.auditable_into = into
          self.auditable_actor = actor
          self.auditable_max_entries = max_entries
          ensure_columns!(LABEL, into, *fields)

          before_save :auditable_capture_changes
        end

        private

        def validate_auditable!(fields, into:, actor:, max_entries:)
          raise ArgumentError, "#{LABEL}: auditable_by requires at least one field" if fields.empty?
          raise ArgumentError, "#{LABEL}: cannot track the audit column ':#{into}' itself" if fields.include?(into)
          raise ArgumentError, "#{LABEL}: max_entries must be a positive Integer or nil" unless valid_max_entries?(max_entries)
          raise ArgumentError, "#{LABEL}: actor must be callable (respond to #call)" unless actor.nil? || actor.respond_to?(:call)
        end

        def valid_max_entries?(value)
          value.nil? || (value.is_a?(Integer) && value.positive?)
        end
      end

      # ---- instance methods ----

      # Decoded audit entries, oldest first. [] for blank/corrupt columns.
      def audit_trail
        auditable_decode(self[self.class.auditable_into])
      end

      # The most recent entry recorded for `field`, or nil.
      def last_change_for(field)
        name = field.to_s
        audit_trail.reverse_each.find { |entry| entry["field"] == name }
      end

      # Entries recorded at or after `time`, oldest first. Entries whose "at"
      # is missing or unparseable are excluded.
      def audited_changes_since(time)
        audit_trail.select do |entry|
          at = auditable_parse_time(entry["at"])
          at && at >= time
        end
      end

      # Wipe the trail with a single UPDATE. Deliberately uses update_column so
      # clearing can never itself be captured or run other callbacks/validations.
      def clear_audit_trail!
        update_column(self.class.auditable_into, nil)
      end

      private

      # before_save hook — appends one entry per changed tracked field so the
      # audit column rides the same INSERT/UPDATE statement.
      def auditable_capture_changes
        fields = self.class.auditable_fields
        return if fields.blank?

        pending = respond_to?(:changes_to_save) ? changes_to_save : changes
        tracked = pending.slice(*fields.map(&:to_s))
        return if tracked.empty?

        entries = audit_trail + auditable_build_entries(tracked)
        max = self.class.auditable_max_entries
        entries = entries.last(max) if max
        self[self.class.auditable_into] = JSON.generate(entries)
      end

      def auditable_build_entries(tracked)
        at = Time.now.utc.iso8601
        by = auditable_resolve_actor
        tracked.map do |field, (from, to)|
          entry = { "field" => field, "from" => auditable_json_value(from), "to" => auditable_json_value(to), "at" => at }
          entry["by"] = by unless by.nil?
          entry
        end
      end

      def auditable_resolve_actor
        actor = self.class.auditable_actor
        return nil unless actor

        auditable_json_value(instance_exec(&actor))
      end

      # Coerce a Ruby value to a JSON-safe primitive. Times → ISO8601 UTC,
      # BigDecimal → plain numeric string (precision-safe), Symbol → String.
      # TimeWithZone is caught by `when Time` (it masquerades via #is_a?).
      def auditable_json_value(value)
        case value
        when nil, true, false, Integer, Float, String then value
        when BigDecimal then value.to_s("F")
        when Time, DateTime then value.to_time.utc.iso8601
        when Date then value.iso8601
        when Symbol then value.to_s
        else value.as_json
        end
      end

      def auditable_parse_time(raw)
        Time.iso8601(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      # Tolerant decode: blank, invalid JSON or non-array payloads become [].
      def auditable_decode(raw)
        return [] if raw.nil? || raw.to_s.strip.empty?

        parsed = JSON.parse(raw)
        parsed.is_a?(Array) ? parsed.grep(Hash) : []
      rescue JSON::ParserError
        []
      end
    end
  end
end
