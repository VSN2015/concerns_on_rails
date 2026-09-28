require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/sequence_calculator"

module ConcernsOnRails
  module Models
    # Generates ordered, human-friendly sequential reference numbers — invoice
    # numbers, order numbers, ticket numbers, support cases. Unlike Hashable /
    # Tokenizable (which produce *random* identifiers), Sequenceable produces
    # *ordered* ones backed by an integer column that is the source of truth.
    #
    #   class Invoice < ApplicationRecord
    #     include ConcernsOnRails::Sequenceable
    #
    #     sequenceable_by :sequence,        # integer column — source of truth
    #       into:    :number,               # optional string column for the formatted value
    #       prefix:  "INV-",
    #       padding: 5,
    #       scope:   :account_id,           # one counter per account
    #       reset:   :year                  # restart numbering each calendar year
    #   end
    #
    #   invoice = Invoice.create!(account_id: 1)
    #   invoice.sequence            # => 1, 2, 3 ... (per account, per year)
    #   invoice.number              # => "INV-2026-00001"
    #   invoice.formatted_sequence  # => "INV-2026-00001"
    #   Invoice.next_sequence(account_id: 1)  # peek the next value without creating
    #
    # The integer is computed as MAX(field) within the scope (+ period) + 1, so
    # numbering is dense and ordered. Generation is best-effort under concurrency
    # — pair the column(s) with a scoped unique DB index for a real guarantee.
    module Sequenceable
      extend ActiveSupport::Concern

      RESET_PERIODS = %i[never year month day].freeze
      ASSIGN_MODES = %i[create manual].freeze
      NAME = "ConcernsOnRails::Models::Sequenceable".freeze
      # Distinguishes "option not passed" from an explicit nil (into: nil,
      # time_zone: nil are meaningful), so a re-declaration knows which
      # options it names (see #sequenceable_merged_config).
      UNSET = Object.new.freeze
      DEFAULTS = { into: nil, prefix: "", padding: 0, separator: "-", start_at: 1, scope: [],
                   reset: :never, template: nil, assign: :create, time_zone: nil }.freeze
      # The options that shape the NUMBER — its format and the rows it counts
      # over (see #sequenceable_owner). A re-declaration passing any of them,
      # or no option at all, restates the format from DEFAULTS; one passing
      # only assign: and/or time_zone: keeps the current config. time_zone:
      # must match an owner it shares a counter with (see
      # #sequenceable_zone_matches!).
      FORMAT_KEYS = %i[prefix template padding reset scope into separator start_at].freeze
      # Two zones cut the same periods when their UTC offsets agree over this
      # window (see #sequenceable_same_zone?).
      ZONE_PROBE_FROM = Time.utc(1970)
      ZONE_PROBE_TO = Time.utc(2100)
      NORMALIZERS = {
        into: ->(value) { value&.to_sym },
        prefix: :to_s.to_proc, separator: :to_s.to_proc,
        padding: :to_i.to_proc, start_at: :to_i.to_proc,
        scope: ->(value) { Array(value).map(&:to_sym) },
        reset: :to_sym.to_proc, assign: :to_sym.to_proc
      }.freeze

      included do
        class_attribute :sequenceable_config, instance_accessor: false, default: {}
        # Fields whose before_create is already registered in this class chain.
        class_attribute :sequenceable_callback_fields, instance_accessor: false, default: [].freeze
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard
        include ConcernsOnRails::Support::SequenceCalculator

        # Configure a sequenceable field.
        #
        # Options:
        #   into:      string column to persist the formatted value into (default nil)
        #   prefix:    string prepended to the formatted value (default "")
        #   padding:   zero-pad width of the numeric portion (default 0 = no padding)
        #   separator: joins prefix / period token / number in the default format (default "-")
        #   start_at:  first value per scope/period when no rows exist yet (default 1)
        #   scope:     column or array of columns the counter is scoped to (default nil)
        #   reset:     :never (default) | :year | :month | :day — restart per period (needs created_at)
        #   time_zone: zone the reset: periods are cut in (name or ActiveSupport::TimeZone). Default:
        #              the app's config.time_zone (Time.zone_default), else UTC — never the
        #              per-request Time.zone, so every request agrees on which day/month/year it is
        #   template:  ->(seq, record) { ... } full custom formatter; overrides prefix/padding/period
        #   assign:    :create (default) numbers every record in before_create; :manual leaves the
        #              column NULL until `assign_<field>!` — invoices numbered when finalized
        #
        # Re-declaring a field (later on the same class, or on an STI subclass):
        # - passing assign: and/or time_zone: and NOTHING else keeps every
        #   other option of the field's current config, so a Draft's
        #   `sequenceable_by :sequence, assign: :manual` keeps the parent's
        #   into:/prefix:/reset:/template: — and its counter;
        # - any other call, a bare one included, restates the format: every
        #   option it omits takes its default, as in a first declaration.
        def sequenceable_by(field = :sequence, into: UNSET, prefix: UNSET, padding: UNSET,
                            separator: UNSET, start_at: UNSET, scope: UNSET, reset: UNSET,
                            template: UNSET, assign: UNSET, time_zone: UNSET)
          field = field.to_sym
          given = { into:, prefix:, padding:, separator:, start_at:, scope:, reset:, template:, assign:, time_zone: }
          cfg = sequenceable_merged_config(field, given.reject { |_, value| value.equal?(UNSET) })

          ensure_columns!(NAME, field, types: :integer)
          ensure_columns!(NAME, cfg[:into], types: :string) if cfg[:into]
          ensure_columns!(NAME, *cfg[:scope]) unless cfg[:scope].empty?
          ensure_columns!(NAME, :created_at, types: :datetime) unless cfg[:reset] == :never
          validate_sequenceable_options!(cfg[:reset], cfg[:template], cfg[:assign])

          self.sequenceable_config = sequenceable_config.merge(field => cfg)

          register_sequenceable_callback(field) if cfg[:assign] == :create
          define_sequenceable_methods(field)
        end
      end

      class_methods do # rubocop:disable Metrics/BlockLength
        private

        def define_sequenceable_methods(field)
          define_method("formatted_#{field}") do
            cfg = self.class.sequenceable_config.fetch(field)
            return self[cfg[:into]] if cfg[:into] && self[cfg[:into]].present?
            return nil if self[field].blank?

            self.class.send(:format_sequence, field, self[field], self)
          end

          define_singleton_method("next_#{field}") do |scope_attrs = {}|
            sequence_base_value(field, nil, scope_attrs)
          end

          # On-demand numbering (the only way under assign: :manual), a
          # predicate, and the "still awaiting a number" scope.
          define_method("assign_#{field}!") { sequenceable_assign!(field) }
          define_method("#{field}_assigned?") { self[field].present? }
          scope "pending_#{field}", -> { where(field => nil) }
        end

        # The passed options, normalized, over a base config, plus :owner — the
        # class whose rows share this counter (SequenceCalculator#sequence_relation).
        #
        # The base is the field's CURRENT config (inherited or from an earlier
        # call) only when the call passes assign: and/or time_zone: and no
        # FORMAT_KEYS option — the Draft case. Any other call, a bare one
        # included, restates the format from DEFAULTS, as it always did: a
        # subclass declared bare today owns a default-format series whose rows
        # carry no into: value, and inheriting would re-render them in the
        # parent's format (INV-1 shown twice). Merging a partial format onto
        # an inherited one would render numbers the declaration never spelled
        # out: a CN- prefix under an inherited template: (which ignores
        # prefix) renders the parent's "INV/1" from a counter of its own;
        # `start_at: 2` or `scope: :account_id` alone would keep the parent's
        # "INV-" and reissue its numbers; and a declaration written against
        # the old "omitted = default" rule would silently pick up a parent's
        # scope: (or reset:/padding:/template:) on upgrade, re-bucketing a
        # global CN- series per account and reissuing CN-3.
        def sequenceable_merged_config(field, given)
          current = sequenceable_config[field]
          inherit = current && !given.empty? && !given.keys.intersect?(FORMAT_KEYS)
          base = inherit ? current.except(:owner) : DEFAULTS
          options = given.to_h { |key, value| [key, normalize_sequenceable_option(key, value)] }
          merged = base.merge(options)
          merged.merge(owner: sequenceable_owner(field, merged))
        end

        # Which class's rows this declaration counts over. Walk up the
        # inherited owners (the declaring parent, then ITS inherited owner,
        # ...) and compare the full format tuple (FORMAT_KEYS) against each
        # owner's current config: the first identical one keeps that owner's
        # counter, so a manual Draft (assign: is not part of the format)
        # finalizes into its parent's series, and a subclass that went CN-
        # and back to INV- rejoins the parent's counter. Any other tuple
        # starts its own series (a CN- subclass), MAX over its own rows.
        #
        # LIMITS: a tuple that differs only in what does not show — scope:,
        # start_at:, into:, or a template: that is a NEW lambda object with the
        # same body (Procs compare by identity) — is its own series and CAN
        # render the parent's strings; so can siblings declaring one format
        # with no declaring ancestor in common. Give such series a distinct
        # prefix or scope: :type; a Draft re-declares with ONLY assign:.
        def sequenceable_owner(field, cfg)
          klass = superclass
          while klass.respond_to?(:sequenceable_config) && (inherited = klass.sequenceable_config[field])
            owner = inherited[:owner]
            ref = owner.sequenceable_config.fetch(field)
            if FORMAT_KEYS.all? { |key| ref[key] == cfg[key] }
              sequenceable_zone_matches!(field, klass, inherited, cfg.merge(owner: owner))
              return owner
            end
            klass = owner.superclass
          end
          self
        end

        # Sharing a counter (same format) with `peer`, whose config is
        # `peer_cfg`, needs the same zone: otherwise the two classes cut the
        # same "20260926" day at different instants, so a Tokyo row and a UTC
        # row could both read an empty range and issue "20260926-1" (into:'s
        # stored-token MAX cannot help without into:). Refused at macro time.
        #
        # Compatible only when both zones are omitted (both follow the app
        # default) or both explicit and the same zone. An omitted zone never
        # matches an explicit one, because it resolves at USE time
        # (#period_time) — config.time_zone may be applied after the model
        # loads, so "equal to the default" at macro time proves nothing.
        # Classes that number over different relations (an abstract declarer
        # vs a concrete table) never share a MAX, so they may differ.
        def sequenceable_zone_matches!(field, peer, peer_cfg, cfg)
          return if cfg[:reset] == :never
          return if sequenceable_zones_compatible?(peer_cfg[:time_zone], cfg[:time_zone])
          return unless sequence_numbering_class(cfg) == peer.send(:sequence_numbering_class, peer_cfg)

          raise ArgumentError, "#{NAME}: #{name || inspect}##{field} renders the same format as " \
                               "#{peer.name || peer.inspect} (one shared counter) but cuts its reset: periods in " \
                               "time_zone: #{sequenceable_zone_label(cfg[:time_zone])} vs " \
                               "#{sequenceable_zone_label(peer_cfg[:time_zone])}. One visible format needs one zone " \
                               "(both would issue the same number): pass the same explicit time_zone: on both (an " \
                               "omitted one follows config.time_zone at use time, so it never matches an explicit " \
                               "one), or use a different prefix:/template:"
        end

        def sequenceable_zones_compatible?(one, other)
          return one.nil? && other.nil? if one.nil? || other.nil?

          sequenceable_same_zone?(one, other)
        end

        # Aliases ("Kolkata" / "Asia/Calcutta") are one zone. The canonical
        # TZInfo identifier resolves them when the data source knows links
        # (tzinfo-data); the system zoneinfo reports a link as a zone of its
        # own, so fall back to what matters here: the UTC offsets in force
        # over ZONE_PROBE_FROM..ZONE_PROBE_TO, i.e. where every period starts.
        def sequenceable_same_zone?(one, other)
          one.tzinfo.canonical_identifier == other.tzinfo.canonical_identifier ||
            sequenceable_zone_offsets(one) == sequenceable_zone_offsets(other)
        end

        def sequenceable_zone_offsets(zone)
          tz = zone.tzinfo
          [tz.period_for_utc(ZONE_PROBE_FROM).utc_total_offset,
           tz.transitions_up_to(ZONE_PROBE_TO, ZONE_PROBE_FROM).map { |t| [t.at.to_i, t.offset.utc_total_offset] }]
        end

        def sequenceable_zone_label(zone)
          zone ? zone.tzinfo.identifier.inspect : "(omitted: the app default)"
        end

        def normalize_sequenceable_option(key, value)
          return sequenceable_time_zone!(value) if key == :time_zone # nil = app default, see #period_time

          NORMALIZERS.fetch(key, :itself.to_proc).call(value)
        end

        # ONE symbol before_create per FIELD, registered by the field's first
        # assign: :create declaration in the class chain — the position its
        # per-call lambda used to take, so a field a subclass declares after
        # its own before_create is numbered after that callback — and
        # inherited by subclasses. Re-declarations never add another. It reads
        # the receiving class's config at run time, so a later assign: :manual
        # re-declaration (same class or STI subclass) really stops numbering;
        # a lambda per call could never be taken back.
        def register_sequenceable_callback(field)
          return if sequenceable_callback_fields.include?(field)

          callback = :"assign_sequenceable_#{field}_on_create"
          define_method(callback) { sequenceable_assign_on_create(field) }
          private callback
          before_create callback
          self.sequenceable_callback_fields = (sequenceable_callback_fields + [field]).freeze
        end

        def validate_sequenceable_options!(reset, template, assign = :create)
          unless RESET_PERIODS.include?(reset)
            raise ArgumentError, "#{NAME}: unknown reset '#{reset}'. Valid values: #{RESET_PERIODS.join(', ')}"
          end
          unless ASSIGN_MODES.include?(assign)
            raise ArgumentError, "#{NAME}: unknown assign ':#{assign}'. Valid values: #{ASSIGN_MODES.join(', ')}"
          end
          return if template.nil? || template.respond_to?(:call)

          raise ArgumentError, "#{NAME}: template must be callable (respond to #call)"
        end
      end

      # The anchor instant of this record's reset: period, in the field's FIXED
      # zone — what the MAX range and the default period token use. A
      # template: that renders a date should read this rather than
      # created_at, which tz-aware attributes present in the request's zone.
      def sequenceable_period_time(field)
        self.class.send(:period_time, self.class.sequenceable_config.fetch(field.to_sym), self)
      end

      # A field's before_create: numbers it only while its CURRENT declaration
      # on this class is assign: :create. :manual fields wait for assign_<field>!.
      def sequenceable_assign_on_create(field)
        assign_sequenceable_value(field) if self.class.sequenceable_config.dig(field, :assign) == :create
      end
      private :sequenceable_assign_on_create

      # Assigns the sequence (and, when configured, the formatted string) only when
      # the integer column is blank, so callers can pass an explicit value.
      # MAX+1 (or start_at on an empty scope) cannot already be taken within the
      # same consistent read — the pre-1.26 exists? probe re-verified that
      # tautology with an extra query on EVERY create, and could not close the
      # concurrent-insert race anyway. Concurrency is the scoped unique index's
      # job (pair with Support::UniqueRetry around the create).
      def assign_sequenceable_value(field)
        cfg = self.class.sequenceable_config.fetch(field)
        sequenceable_pin_created_at(cfg)

        self[field] = self.class.send(:sequence_base_value, field, self, {}) if self[field].blank?

        return unless cfg[:into] && self[cfg[:into]].blank?

        self[cfg[:into]] = self.class.send(:format_sequence, field, self[field], self)
      end

      # Number the record now: the next value for its scope/period plus the
      # into: string, save!d when the record is persisted and left for the
      # caller's save when new. false (nothing rewritten) when already
      # numbered, so a "finalize" action can be retried safely.
      #
      # A failed save! (RecordNotUnique from a concurrent writer, a failed
      # validation) puts the field and the into: column back before
      # re-raising: otherwise the drawn number stays in memory, and a retry —
      # UniqueRetry.with_retries { invoice.assign_sequence! } — would see it
      # "already numbered" and return false with nothing saved. The save runs
      # in its own savepoint (requires_new) so a failed UPDATE inside a
      # caller's transaction does not poison it on PostgreSQL.
      def sequenceable_assign!(field)
        return false if self[field].present?

        previous = sequenceable_written_columns(field).to_h { |column| [column, self[column]] }
        assign_sequenceable_value(field)
        return true if new_record?

        sequenceable_save_or_restore!(previous)
      end
      private :sequenceable_assign!

      # The columns assign_sequenceable_value may write: the field, into:, and
      # created_at (sequenceable_pin_created_at stamps it under reset:).
      def sequenceable_written_columns(field)
        cfg = self.class.sequenceable_config.fetch(field)
        [field, cfg[:into], (:created_at unless cfg[:reset] == :never)].compact
      end
      private :sequenceable_written_columns

      def sequenceable_save_or_restore!(previous)
        saved = false
        begin
          self.class.transaction(requires_new: true) { saved = save! }
        ensure
          # Also covers an ActiveRecord::Rollback the savepoint swallowed.
          previous.each { |column, value| self[column] = value } unless saved
        end
        saved ? true : false
      end
      private :sequenceable_save_or_restore!

      # Pin the row inside the period its number is drawn from: with reset:
      # enabled the period is computed from "now" during before_create, but
      # created_at is stamped later, at INSERT time — across a year/month/day
      # boundary the row would carry a number from the old period with a
      # timestamp in the new one. AR honors a pre-set created_at.
      def sequenceable_pin_created_at(cfg)
        return if cfg[:reset] == :never || !created_at.nil?

        self.created_at = self.class.send(:base_time, self)
      end
      private :sequenceable_pin_created_at
    end
  end
end
