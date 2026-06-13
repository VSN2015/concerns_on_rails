require "active_support/concern"
require "active_support/core_ext/object/deep_dup"
require "active_model/type"
require "bigdecimal"
require "json"
require "time"

module ConcernsOnRails
  module Models
    # Typed, defaulted, optionally-validated accessors over a single JSON (or
    # serialized-text) column ("store_attribute-lite"). Rails' native
    # `store_accessor` is untyped on every supported version (a form-submitted
    # "true" stays the String "true"), ships no defaults, and exposes no
    # per-key dirty methods — the gap that the store_attribute / jsonb_accessor
    # gems exist to fill. This concern closes it with no extra dependency.
    #
    #   class Account < ApplicationRecord
    #     include ConcernsOnRails::Storable
    #
    #     storable_by :settings,
    #       theme:          { type: :string,  default: "light", in: %w[light dark] },
    #       notifications:  { type: :boolean, default: true },
    #       items_per_page: { type: :integer, default: 25 },
    #       trial_ends_at:  { type: :datetime }
    #     storable_by :flags, { beta: { type: :boolean, default: false } }, prefix: :flag
    #   end
    #
    #   account.theme              # => "light" (virtual default; nothing stored yet)
    #   account.notifications = "0"
    #   account.notifications      # => false   (cast, not the String "0")
    #   account.notifications?     # => false   (boolean keys get a predicate)
    #   account.flag_beta          # => false   (prefixed accessor)
    #   account.items_per_page_changed?  # per-key dirty, computed off the column's _was
    #   account.reset_theme        # drop the key so the reader falls back to the default
    #
    # Per key: `type:` (:string default, :integer, :float, :decimal, :boolean,
    # :date, :datetime, :json), `default:` (a value, or a Proc instance_exec'd
    # per read), `in:` (an enumerable membership set). The macro is repeatable —
    # repeat calls for the SAME column merge keys; different columns are
    # independent. `prefix:`/`suffix:` rename the generated accessors as
    # `<prefix>_<key>_<suffix>`.
    #
    # Notes:
    #   * Whole-column dirty: writing one key reassigns (and so dirties) the
    #     entire column. Two requests writing different keys of the same row are
    #     last-write-wins on the whole hash — there is no per-key merge on save.
    #   * nil vs unset: a writer-stored nil (explicit JSON null) reads back as
    #     nil and does NOT fall back to the default; `reset_<key>` removes the
    #     key entirely so the reader resolves the default again.
    #   * :json values are passed through uncast and the reader returns a dup —
    #     reassign (`record.config = record.config.merge("k" => 1)`), don't
    #     mutate in place, or the write is silently lost.
    #   * Read-side casting never raises: corrupt column JSON decodes to {} and
    #     ungarbageable values cast to nil (ActiveModel semantics). :decimal is
    #     stored precision-safe as a String (BigDecimal), :date/:datetime as
    #     ISO8601 strings (datetime in UTC, microsecond precision).
    #   * Reserved option names: passing key specs as keyword arguments means a
    #     key literally named `prefix` or `suffix` would be swallowed by the
    #     affix options — declare those via the positional Hash escape hatch
    #     (`storable_by :col, { prefix: { type: :string } }`).
    #   * Reach for the store_attribute or jsonb_accessor gems when you need
    #     querying into the store, jsonb operators, or store-backed scopes.
    module Storable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Storable".freeze

      VALID_TYPES = %i[string integer float decimal boolean date datetime json].freeze
      ALLOWED_SPEC_KEYS = %i[type default in].freeze

      # Reusable ActiveModel casters for the JSON-native types. :decimal,
      # :date and :datetime round-trip through Strings and are handled
      # explicitly; :json is passed through uncast.
      CASTERS = {
        string: ActiveModel::Type::String.new,
        integer: ActiveModel::Type::Integer.new,
        float: ActiveModel::Type::Float.new,
        boolean: ActiveModel::Type::Boolean.new,
        date: ActiveModel::Type::Date.new,
        datetime: ActiveModel::Type::DateTime.new
      }.freeze

      included do
        # { column => { key => normalized_spec } }. Subclasses inherit and may
        # add keys; every write reassigns deep copies so a parent is never
        # mutated by a child.
        class_attribute :storable_keys, instance_accessor: false, default: {}
        # { generated_method_name => [column, key] } — lets a re-declaration of
        # the same key skip the collision guard while a different key claiming
        # an already-taken accessor still raises.
        class_attribute :storable_owned_methods, instance_accessor: false, default: {}

        validate :storable_validate_inclusions
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Declare typed accessors over `column`. Key specs may arrive as the
        # positional `keys` Hash or as trailing keyword arguments (they are
        # merged); the positional form is the escape hatch for keys literally
        # named `prefix`/`suffix`. See the module docs.
        def storable_by(column, keys = {}, prefix: nil, suffix: nil, **kw_keys)
          column = column.to_sym
          ensure_columns!(LABEL, column)

          prepared = storable_merge_key_specs(keys, kw_keys).map do |key, raw_spec|
            key = key.to_sym
            [key, storable_normalize_spec(key, raw_spec, prefix, suffix)]
          end

          storable_install_keys(column, prepared)
        end

        # Lazily decide — once per class/column, at first write when a DB
        # connection exists — whether the column's attribute type stores a Hash
        # natively (a :json column, or a host-app `serialize`d column) so we can
        # hand it the Hash; everything else gets a generated JSON String.
        def storable_native_hash_column?(column)
          cache = (@storable_native_hash_cache ||= {})
          name = column.to_sym
          return cache[name] if cache.key?(name)

          cache[name] = storable_detect_native_hash(column)
        end

        private

        def storable_merge_key_specs(keys, kw_keys)
          raise ArgumentError, "#{LABEL}: keys must be a Hash of name => spec (got #{keys.class})" unless keys.is_a?(Hash)

          keys.merge(kw_keys)
        end

        def storable_assert_spec_shape!(key, raw_spec)
          raise ArgumentError, "#{LABEL}: spec for ':#{key}' must be a Hash, got #{raw_spec.class}" unless raw_spec.is_a?(Hash)

          unknown = raw_spec.keys.map(&:to_sym) - ALLOWED_SPEC_KEYS
          return if unknown.empty?

          raise ArgumentError,
                "#{LABEL}: unknown option(s) #{unknown.join(', ')} in spec for ':#{key}' (allowed: #{ALLOWED_SPEC_KEYS.join(', ')})"
        end

        def storable_normalize_spec(key, raw_spec, prefix, suffix)
          storable_assert_spec_shape!(key, raw_spec)

          type = (raw_spec[:type] || :string).to_sym
          unless VALID_TYPES.include?(type)
            raise ArgumentError, "#{LABEL}: unknown type ':#{type}' for ':#{key}' (valid: #{VALID_TYPES.join(', ')})"
          end

          inclusion = raw_spec[:in]
          if !inclusion.nil? && !inclusion.respond_to?(:include?)
            raise ArgumentError, "#{LABEL}: in: for ':#{key}' must be enumerable (respond to #include?)"
          end

          { type: type, default: raw_spec[:default], in: inclusion,
            accessor: [prefix, key, suffix].compact.join("_").to_sym }
        end

        # Guard collisions against a working copy of the owners map (so two keys
        # in one call claiming the same accessor are caught too), then commit
        # the merged config and define the accessors.
        def storable_install_keys(column, prepared)
          owners = storable_owned_methods.dup
          prepared.each { |key, spec| storable_guard_collisions!(column, key, spec, owners) }

          merged = storable_keys.dup
          column_keys = (merged[column] || {}).dup
          prepared.each { |key, spec| column_keys[key] = spec }
          merged[column] = column_keys
          self.storable_keys = merged
          self.storable_owned_methods = owners

          prepared.each { |key, spec| storable_define_key_methods(column, key, spec) }
        end

        def storable_guard_collisions!(column, key, spec, owners)
          storable_method_names(spec[:accessor], spec[:type]).each do |method_name|
            owner = owners[method_name]
            if owner
              next if owner == [column, key] # our own re-declaration — merge, don't collide

              raise storable_collision_error(method_name)
            end
            raise storable_collision_error(method_name) if storable_method_taken?(method_name, spec[:accessor])

            owners[method_name] = [column, key]
          end
        end

        # The reader is intentionally listed first so a column-attribute clash
        # reports the bare accessor name.
        def storable_method_names(accessor, type)
          base = accessor.to_s
          names = [base, "#{base}=", "#{base}_changed?", "#{base}_was", "reset_#{base}"]
          names << "#{base}?" if type == :boolean
          names.map(&:to_sym)
        end

        # A name is taken when it shadows a column's (lazily defined) attribute
        # accessors or any already-defined instance method.
        def storable_method_taken?(method_name, accessor)
          return true if column_names.include?(accessor.to_s)

          method_defined?(method_name) || private_method_defined?(method_name)
        end

        def storable_collision_error(method_name)
          ArgumentError.new(
            "#{LABEL}: generated method '#{method_name}' collides with an existing method or column; " \
            "pass prefix: or suffix: to rename the accessors"
          )
        end

        # Methods look the spec up at call time (not via closure) so a later
        # merge that changes a key's type/default takes effect without redefining.
        def storable_define_key_methods(column, key, spec)
          base = spec[:accessor].to_s

          define_method(base) { storable_get(column, key) }
          define_method("#{base}=") { |value| storable_set(column, key, value) }
          define_method("#{base}_changed?") { storable_key_changed?(column, key) }
          define_method("#{base}_was") { storable_key_was(column, key) }
          define_method("reset_#{base}") { storable_reset(column, key) }
          define_method("#{base}?") { storable_get(column, key) == true } if spec[:type] == :boolean
        end

        def storable_detect_native_hash(column)
          name = column.to_s
          type = type_for_attribute(name)
          return true if defined?(ActiveRecord::Type::Serialized) && type.is_a?(ActiveRecord::Type::Serialized)

          col = columns_hash[name]
          !col.nil? && col.type == :json
        rescue StandardError
          false
        end
      end

      # ---- readers / writers (the generated accessors delegate here) ----

      private

      def storable_get(column, key)
        spec = storable_spec(column, key)
        storable_resolve(spec, storable_decode(self[column]), key)
      end

      def storable_set(column, key, value)
        spec = storable_spec(column, key)
        hash = storable_decode(self[column]).dup
        hash[key.to_s] = storable_cast_write(spec[:type], value)
        storable_assign(column, hash)
      end

      # Per-key dirty: decode the column's own _was value and compare the cast
      # per-key values. After a save (dirty reset) _was equals the current value,
      # so the key reads as unchanged.
      def storable_key_changed?(column, key)
        storable_key_was(column, key) != storable_get(column, key)
      end

      def storable_key_was(column, key)
        spec = storable_spec(column, key)
        storable_resolve(spec, storable_decode(attribute_was(column.to_s)), key)
      end

      # In-memory only (no save) — hence no bang. Removing the key lets the
      # reader fall back to the default again.
      def storable_reset(column, key)
        hash = storable_decode(self[column])
        return unless hash.key?(key.to_s)

        new_hash = hash.dup
        new_hash.delete(key.to_s)
        storable_assign(column, new_hash)
      end

      def storable_spec(column, key)
        self.class.storable_keys.fetch(column).fetch(key)
      end

      # absent -> default; present-but-nil -> nil (never the default); present ->
      # cast through the declared type.
      def storable_resolve(spec, hash, key)
        skey = key.to_s
        return storable_default(spec) unless hash.key?(skey)

        raw = hash[skey]
        return nil if raw.nil?

        storable_cast_read(spec[:type], raw)
      end

      # A Proc default is instance_exec'd per call; a mutable Hash/Array default
      # is deep-duped per call so one instance's mutation never leaks into another.
      def storable_default(spec)
        default = spec[:default]
        return instance_exec(&default) if default.is_a?(Proc)

        case default
        when Hash, Array then default.deep_dup
        else default
        end
      end

      # ---- storage codec ----

      # A native-json Hash is used as-is; a String is parsed tolerantly; anything
      # else (nil, an array, a stray scalar) decodes to {}.
      def storable_decode(raw)
        case raw
        when Hash then raw
        when String then storable_parse(raw)
        else {}
        end
      end

      def storable_parse(string)
        return {} if string.strip.empty?

        parsed = JSON.parse(string)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      # Reassigning the whole attribute is what marks the column dirty. Hand a
      # Hash to native/serialized columns; otherwise generate the JSON String.
      def storable_assign(column, hash)
        self[column] = if self.class.storable_native_hash_column?(column)
                         hash
                       else
                         JSON.generate(hash)
                       end
      end

      # ---- casting ----

      def storable_cast_read(type, raw)
        case type
        when :json     then raw.deep_dup
        when :decimal  then storable_read_decimal(raw)
        when :date     then CASTERS[:date].cast(raw)
        when :datetime then storable_read_time(raw)
        else CASTERS[type].cast(raw)
        end
      rescue StandardError
        # ActiveModel casting tolerates garbage already; BigDecimal()/Time.iso8601
        # do not, so swallow and follow the "cast to nil" convention.
        nil
      end

      def storable_read_decimal(raw)
        return raw if raw.is_a?(BigDecimal)

        BigDecimal(raw.to_s)
      end

      def storable_read_time(raw)
        return raw if raw.is_a?(Time)

        Time.iso8601(raw.to_s)
      end

      def storable_cast_write(type, value)
        case type
        when :json     then value
        when :decimal  then storable_write_decimal(value)
        when :date     then storable_write_date(value)
        when :datetime then storable_write_datetime(value)
        else CASTERS[type].cast(value)
        end
      end

      # Precision-safe String (the Auditable precedent): BigDecimal#to_s("F").
      def storable_write_decimal(value)
        return nil if value.nil?

        big = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        big.to_s("F")
      rescue ArgumentError, TypeError
        nil
      end

      def storable_write_date(value)
        CASTERS[:date].cast(value)&.iso8601
      end

      # UTC iso8601(6): microsecond precision, the lesson CursorPaginatable learned.
      def storable_write_datetime(value)
        storable_coerce_time(value)&.utc&.iso8601(6)
      end

      # A bare Date becomes midnight UTC (deterministic — Date#to_time would
      # anchor to the host's zone).
      def storable_coerce_time(value)
        case value
        when nil then nil
        when ActiveSupport::TimeWithZone, Time then value
        when DateTime then value.to_time
        when Date then Time.utc(value.year, value.month, value.day)
        else CASTERS[:datetime].cast(value)
        end
      rescue ArgumentError, TypeError
        nil
      end

      # ---- validation ----

      # One pass adds an inclusion error per `in:`-constrained key whose stored
      # value is present and non-nil but casts outside the allowed set. Absent
      # and nil values pass (compose with a presence validator if you need them).
      def storable_validate_inclusions
        self.class.storable_keys.each do |column, keys|
          decoded = storable_decode(self[column])
          keys.each do |key, spec|
            allowed = spec[:in]
            next unless allowed

            skey = key.to_s
            next unless decoded.key?(skey)

            raw = decoded[skey]
            next if raw.nil?

            value = storable_cast_read(spec[:type], raw)
            errors.add(spec[:accessor], "is not included in the list") unless allowed.include?(value)
          end
        end
      end
    end
  end
end
