require "active_support/concern"
require "active_support/notifications"
require "active_support/hash_with_indifferent_access"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/string/filters"
require "concerns_on_rails/support/error_envelope"
require "concerns_on_rails/support/column_guard"
require "bigdecimal"
require "date"
require "time"

module ConcernsOnRails
  module Controllers
    # Declarative, typed params contracts — what strong parameters would be if
    # it also knew types, bounds, defaults, and why a request was bad. Strong
    # parameters (and Rails 8's `params.expect`) only answer "which keys may
    # pass"; a Permittable contract additionally casts each field, validates
    # it, applies defaults, and turns every failure into a machine-readable
    # 422 — and, because the contract is class-level data rather than code
    # inside the action, it is introspectable (`permittable_contracts`) and
    # can be checked against a model's schema at class-load time.
    #
    #   class UsersController < ApplicationController
    #     include ConcernsOnRails::Controllers::Permittable
    #
    #     permit_params :create, :update, root: :user, model: User do
    #       required :name,  :string,  length: 1..80, normalize: :squish
    #       required :email, :string,  format: URI::MailTo::EMAIL_REGEXP, normalize: :email
    #       optional :age,   :integer, in: 18..120
    #       optional :ssn,   :string,  sensitive: true
    #       optional :plan,  :string,  in: %w[free pro], default: "free"
    #       array    :tag_names, of: :string, length: 0..10, virtual: true
    #       optional :address do
    #         required :city, :string
    #         optional :zip,  :string, format: /\A\d{5}\z/
    #       end
    #     end
    #
    #     def create
    #       user = User.create!(permitted_params) # cast, validated, defaulted
    #     end
    #   end
    #
    # THE LAST MATCHING RULE WINS (the Deprecatable / Cacheable convention):
    # contracts are configuration, so a base controller's catch-all (a rule
    # declared with no actions) is overridden by a later action-specific
    # declaration in a subclass. Rules accumulate via reassignment, never
    # mutation, so subclasses inherit copy-on-write.
    #
    # Schema-drift guard — the reason `model:` exists. Every non-virtual
    # scalar field is checked against the model's columns THROUGH
    # Support::ColumnGuard when the macro runs, i.e. at controller class load.
    # Production eager-loads controllers, so a column dropped by a migration
    # fails the deploy, not the request; the error carries ColumnGuard's
    # copy-paste migration hint. Fields not backed by a column
    # (password_confirmation, terms flags) opt out with `virtual: true`;
    # nested and array fields are implicitly virtual. When the schema is
    # unreachable (db:create, assets:precompile) the check skips, exactly as
    # the model concerns do. In CI, one `Rails.application.eager_load!` spec
    # exercises every contract in the app.
    #
    # Validation is LAZY: it runs on the first `permitted_params` call, so an
    # action that never reads params never pays. `enforce: true` installs the
    # check as a before_action instead (the WebhookVerifiable stance: reject
    # before the action body runs).
    #
    # Coercion is deliberately STRICT — ActiveModel::Type is not used, because
    # its casts are lenient by design ("abc".to_i == 0, Boolean.cast("abc") ==
    # true) and silently corrupting untrusted input is exactly what a contract
    # must not do. A value the type cannot faithfully represent is a
    # violation, not a guess. nil and "" are both treated as ABSENT (the
    # query-param convention): absent optional fields are OMITTED from the
    # result (so partial updates never nil-out columns), absent required
    # fields violate, and `default:` fills absence. Clearing a column to NULL
    # is therefore outside a contract's vocabulary — do that explicitly.
    #
    # Failures raise InvalidParameters, rescued (on a real controller) into
    # the shared ErrorEnvelope shape with `details:` entries of
    # `{ param: "user.address.zip", code: "format" }`; a missing `root:` key
    # renders 400, field violations 422. Every violation also instruments
    # "invalid_parameters.concerns_on_rails" so failures can be dashboarded.
    #
    # `sensitive: true` registers the field name with the gem's live
    # FilterParameterRegistry (the Encryptable pipe), so the value is redacted
    # from logs via the Railtie-appended filter_parameters proc.
    #
    # Naming note: some legacy stacks (InheritedResources) define their own
    # `permitted_params`; don't include both on one controller.
    module Permittable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::Permittable".freeze
      SCALAR_TYPES = %i[string integer float decimal boolean date datetime].freeze
      UNKNOWN_MODES = %i[ignore log error].freeze
      # Rails merges routing bookkeeping into params; a top-level (root: false)
      # unknown-keys check must not flag them.
      ROUTING_KEYS = %w[controller action format].freeze

      NORMALIZERS = {
        squish:   ->(v) { v.squish },
        strip:    ->(v) { v.strip },
        downcase: ->(v) { v.downcase },
        upcase:   ->(v) { v.upcase },
        email:    ->(v) { v.strip.downcase },
      }.freeze

      # Raised when the request violates the matching contract. `details` is
      # an array of { param:, code: } hashes; `status` is :bad_request for a
      # missing root key, :unprocessable_entity for field violations.
      class InvalidParameters < StandardError
        attr_reader :details, :status

        def initialize(message, details: [], status: :unprocessable_entity)
          super(message)
          @details = details
          @status = status
        end
      end

      included do
        class_attribute :permittable_contracts, instance_accessor: false, default: []

        rescue_from InvalidParameters, with: :render_invalid_parameters if respond_to?(:rescue_from)
        before_action :enforce_params_contract if respond_to?(:before_action)
      end

      # Strict params-shaped coercion, shared by request-time validation and
      # macro-time `default:` checking. Every entry point returns
      # [:ok, cast_value] or [:error, code_string].
      module Coercion
        module_function

        TRUE_VALUES = [true, "true", "1", 1].freeze
        FALSE_VALUES = [false, "false", "0", 0].freeze

        # Full pipeline for one scalar field: normalize → cast → in / format /
        # length / validate.
        def check_scalar(field, value)
          value = apply_normalize(field[:normalize], value)
          status, value = cast(field[:type], value)
          return [status, value] unless status == :ok

          check_scalar_rules(field, value)
        end

        def check_scalar_rules(field, value)
          return [:error, "inclusion"] if field[:in] && !included_in?(field[:in], value)
          return [:error, "format"] if field[:format] && !field[:format].match?(value)
          return [:error, "length"] if field[:length] && !length_ok?(field[:length], value.length)

          check_custom(field[:validate], value)
        end

        # A custom validator returning a Symbol fails with that symbol as the
        # violation code; false/nil fails as "invalid"; any other truthy value
        # passes.
        def check_custom(validator, value)
          return [:ok, value] unless validator

          verdict = validator.call(value)
          return [:error, verdict.to_s] if verdict.is_a?(Symbol)
          return [:error, "invalid"] unless verdict

          [:ok, value]
        end

        def cast(type, value)
          return [:error, "invalid_type"] unless scalar_shaped?(value)

          public_send("cast_#{type}", value)
        end

        # Arrays, hashes, and nested ActionController::Parameters
        # (`?age[]=1`, `?age[x]=1`) can never satisfy a scalar type.
        def scalar_shaped?(value)
          return false if value.is_a?(Array) || value.is_a?(Hash)
          return false if defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters)

          true
        end

        def cast_string(value)
          case value
          when String then [:ok, value]
          when Numeric, true, false then [:ok, value.to_s]
          else [:error, "invalid_type"]
          end
        end

        def cast_integer(value)
          case value
          when Integer then [:ok, value]
          when Float then value == value.truncate ? [:ok, value.to_i] : [:error, "invalid_type"]
          when String then [:ok, Integer(value, 10)]
          else [:error, "invalid_type"]
          end
        rescue ArgumentError
          [:error, "invalid_type"]
        end

        def cast_float(value)
          case value
          when Numeric then [:ok, value.to_f]
          when String then [:ok, Float(value)]
          else [:error, "invalid_type"]
          end
        rescue ArgumentError
          [:error, "invalid_type"]
        end

        def cast_decimal(value)
          case value
          when Numeric, String then [:ok, BigDecimal(value.to_s)]
          else [:error, "invalid_type"]
          end
        rescue ArgumentError
          [:error, "invalid_type"]
        end

        def cast_boolean(value)
          return [:ok, true] if TRUE_VALUES.include?(value)
          return [:ok, false] if FALSE_VALUES.include?(value)

          [:error, "invalid_type"]
        end

        def cast_date(value)
          case value
          when Date then [:ok, value]
          when String then [:ok, Date.parse(value)]
          else [:error, "invalid_type"]
          end
        rescue ArgumentError, RangeError
          [:error, "invalid_type"]
        end

        # A zoneless String parses as UTC regardless of the host timezone
        # (deterministic — the Deprecatable stance); explicit offsets are
        # honoured and normalised to UTC.
        def cast_datetime(value)
          case value
          when ActiveSupport::TimeWithZone, Time then [:ok, value.to_time.utc]
          when DateTime then [:ok, value.to_time.utc]
          when Date then [:ok, Time.utc(value.year, value.month, value.day)]
          when String then [:ok, DateTime.parse(value).to_time.utc]
          else [:error, "invalid_type"]
          end
        rescue ArgumentError, RangeError
          [:error, "invalid_type"]
        end

        # Presets only make sense on String input; a non-String value (JSON
        # numbers, booleans) skips normalization and goes straight to the cast.
        def apply_normalize(normalizer, value)
          return value unless normalizer && value.is_a?(String)

          normalizer.call(value)
        end

        # Range#include? walks discrete ranges; cover? is the O(1) bounds check
        # and the right semantics for validation.
        def included_in?(allowed, value)
          allowed.is_a?(Range) ? allowed.cover?(value) : allowed.include?(value)
        end

        def length_ok?(spec, length)
          spec.is_a?(Range) ? spec.cover?(length) : spec == length
        end
      end

      # Builds the frozen field list from the permit_params block. Every
      # declaration is validated eagerly (Storable's stance): a bad contract
      # is a programmer error and should fail at class load, not at request
      # time.
      class ContractBuilder
        SCALAR_OPTS = %i[in format length default normalize validate virtual sensitive].freeze
        NESTED_OPTS = %i[virtual sensitive].freeze
        ARRAY_OPTS  = %i[of length default validate virtual sensitive required].freeze

        def initialize
          @fields = []
        end

        def build(&block)
          instance_eval(&block)
          @fields.map(&:freeze).freeze
        end

        # `required :name` defaults the type to :string. A block instead of a
        # type declares a nested hash of sub-fields.
        def required(name, type = nil, **opts, &block)
          add_field(name, type, required: true, opts: opts, &block)
        end

        def optional(name, type = nil, **opts, &block)
          add_field(name, type, required: false, opts: opts, &block)
        end

        # Array of scalars (`of:`, default :string) or, with a block, an array
        # of nested hashes. Optional unless `required: true`; `length:`
        # constrains the element COUNT.
        def array(name, **opts, &block)
          name = field_name!(name)
          assert_opts!(name, opts, ARRAY_OPTS)
          required = opts.delete(:required) ? true : false

          field = { name: name, kind: :array, required: required, **opts }
          if block
            raise ArgumentError, "#{LABEL}: array :#{name} takes of: OR a block, not both" if opts.key?(:of)

            field[:fields] = nested_fields!(name, &block)
            field.delete(:of)
          else
            field[:of] = scalar_type!(name, opts[:of] || :string)
          end
          validate_length!(name, field[:length]) if field.key?(:length)
          validate_callable!(name, :validate, field[:validate]) if field.key?(:validate)
          validate_array_default!(field) if field.key?(:default)
          @fields << field
        end

        private

        def add_field(name, type, required:, opts:, &block)
          name = field_name!(name)
          if block
            raise ArgumentError, "#{LABEL}: :#{name} takes a type OR a nested block, not both" if type

            assert_opts!(name, opts, NESTED_OPTS)
            @fields << { name: name, kind: :nested, required: required,
                         fields: nested_fields!(name, &block), **opts }
          else
            assert_opts!(name, opts, SCALAR_OPTS)
            field = { name: name, kind: :scalar, required: required,
                      type: scalar_type!(name, type || :string), **opts }
            validate_scalar_opts!(field)
            @fields << field
          end
        end

        def field_name!(name)
          name = name.to_sym
          if @fields.any? { |f| f[:name] == name }
            raise ArgumentError, "#{LABEL}: field :#{name} is declared twice in the same contract"
          end

          name
        end

        def assert_opts!(name, opts, allowed)
          unknown = opts.keys - allowed
          return if unknown.empty?

          raise ArgumentError,
                "#{LABEL}: unknown option(s) #{unknown.map(&:inspect).join(', ')} for field :#{name} " \
                "(allowed: #{allowed.map(&:inspect).join(', ')})"
        end

        def scalar_type!(name, type)
          type = type.to_sym
          return type if SCALAR_TYPES.include?(type)

          raise ArgumentError, "#{LABEL}: field :#{name} has unknown type :#{type} " \
                               "(supported: #{SCALAR_TYPES.join(', ')})"
        end

        def nested_fields!(name, &block)
          fields = ContractBuilder.new.build(&block)
          raise ArgumentError, "#{LABEL}: nested field :#{name} declares no sub-fields" if fields.empty?

          fields
        end

        def validate_scalar_opts!(field)
          name = field[:name]
          if field[:required] && field.key?(:default)
            raise ArgumentError, "#{LABEL}: field :#{name} is required and cannot have a :default (default implies optional)"
          end
          if field.key?(:in) && !field[:in].respond_to?(:include?)
            raise ArgumentError, "#{LABEL}: :in for field :#{name} must respond to include? (Range or Array)"
          end

          validate_string_only_opts!(field)
          validate_length!(name, field[:length]) if field.key?(:length)
          validate_callable!(name, :validate, field[:validate]) if field.key?(:validate)
          resolve_normalizer!(field)
          validate_default!(field)
        end

        # format / length / normalize reason about characters; on any other
        # type they would silently apply to a cast non-String and mislead.
        def validate_string_only_opts!(field)
          return if field[:type] == :string

          %i[format length normalize].each do |opt|
            next unless field.key?(opt)

            raise ArgumentError, "#{LABEL}: :#{opt} is only supported on :string fields (field :#{field[:name]} is :#{field[:type]})"
          end
        end

        def validate_length!(name, length)
          return if length.is_a?(Range) || length.is_a?(Integer)

          raise ArgumentError, "#{LABEL}: :length for :#{name} must be a Range or Integer"
        end

        def validate_callable!(name, opt, value)
          return if value.respond_to?(:call)

          raise ArgumentError, "#{LABEL}: :#{opt} for field :#{name} must be callable"
        end

        def resolve_normalizer!(field)
          normalizer = field[:normalize]
          return if normalizer.nil?
          return if normalizer.respond_to?(:call) && !normalizer.is_a?(Symbol)

          field[:normalize] = NORMALIZERS.fetch(normalizer.to_sym) do
            raise ArgumentError, "#{LABEL}: unknown :normalize preset :#{normalizer} for field :#{field[:name]} " \
                                 "(presets: #{NORMALIZERS.keys.join(', ')}, or pass a Proc)"
          end
        end

        # A default must satisfy the field's own contract — catching a bad
        # default at class load beats shipping it to every request.
        def validate_default!(field)
          return unless field.key?(:default)

          status, code = Coercion.check_scalar(field, field[:default])
          return if status == :ok

          raise ArgumentError, "#{LABEL}: :default for field :#{field[:name]} violates its own contract (#{code})"
        end

        def validate_array_default!(field)
          default = field[:default]
          raise ArgumentError, "#{LABEL}: :default for array :#{field[:name]} must be an Array" unless default.is_a?(Array)
          return unless field[:of]

          default.each do |element|
            status, code = Coercion.cast(field[:of], element)
            next if status == :ok

            raise ArgumentError, "#{LABEL}: :default for array :#{field[:name]} contains an element violating of: :#{field[:of]} (#{code})"
          end
        end
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Declare a params contract. No positional actions = catch-all for the
        # whole controller. Repeatable; the LAST rule matching the request's
        # action wins.
        #
        #   root:    key to unwrap first (`require(:user)` equivalent); false
        #            (default) reads top-level params. Missing root renders 400.
        #   model:   a model class (or `true` to infer from controller_name)
        #            enabling the ColumnGuard schema-drift check on every
        #            non-virtual scalar field.
        #   unknown: :ignore (default) / :log / :error — what to do with
        #            undeclared keys, at every nesting level.
        #   enforce: false (default) validates lazily on the first
        #            permitted_params call; true validates in a before_action.
        def permit_params(*actions, root: false, model: nil, unknown: :ignore, enforce: false, &block)
          raise ArgumentError, "#{LABEL}: permit_params requires a block declaring the contract fields" unless block

          unknown = unknown.to_sym
          raise ArgumentError, "#{LABEL}: :unknown must be one of #{UNKNOWN_MODES.join(', ')}" unless UNKNOWN_MODES.include?(unknown)

          fields = ContractBuilder.new.build(&block)
          raise ArgumentError, "#{LABEL}: a contract must declare at least one field" if fields.empty?

          model_class = resolve_permit_model(model)
          guard_contract_columns!(model_class, fields) if model_class
          register_sensitive_params(fields)

          rule = { actions: actions.flatten.map(&:to_s).freeze, root: root && root.to_sym,
                   model: model_class, unknown: unknown, enforce: !!enforce, fields: fields }.freeze
          self.permittable_contracts = permittable_contracts + [rule]
        end

        # The LAST declared rule matching `action`, or nil.
        def permit_rule_for(action)
          action = action.to_s
          permittable_contracts.reverse_each.find do |rule|
            rule[:actions].empty? || rule[:actions].include?(action)
          end
        end

        private

        def resolve_permit_model(model)
          case model
          when nil, false then nil
          when true then infer_permit_model
          else
            unless model.is_a?(Class) && model.respond_to?(:column_names)
              raise ArgumentError, "#{LABEL}: :model must be an ActiveRecord model class, true (infer from controller name), or nil"
            end

            model
          end
        end

        def infer_permit_model
          unless respond_to?(:controller_name)
            raise ArgumentError, "#{LABEL}: model: true needs controller_name to infer from — pass the class explicitly (model: SomeModel)"
          end

          name = controller_name.classify
          name.safe_constantize ||
            raise(ArgumentError, "#{LABEL}: model: true inferred #{name} from '#{controller_name}' but no such class exists — " \
                                 "pass the class explicitly (model: SomeModel)")
        end

        # The drift guard. Nested/array fields are implicitly virtual — only
        # scalar fields map one-to-one onto columns.
        def guard_contract_columns!(model_class, fields)
          checked = fields.select { |f| f[:kind] == :scalar && !f[:virtual] }
          return if checked.empty?

          types = checked.to_h { |f| [f[:name], f[:type]] }
          begin
            ensure_columns_on!(LABEL, model_class, *checked.map { |f| f[:name] }, types: types)
          rescue ArgumentError => e
            raise ArgumentError, "#{e.message} If this parameter is not backed by a column, declare it with virtual: true."
          end
        end

        def register_sensitive_params(fields)
          fields.each do |field|
            ConcernsOnRails.filter_parameter_registry.add(field[:name]) if field[:sensitive]
            register_sensitive_params(field[:fields]) if field[:fields]
          end
        end
      end

      # The contract's output: a HashWithIndifferentAccess of cast, validated,
      # defaulted values for the given action (default: the current action).
      # Absent optional fields are omitted. Raises InvalidParameters on
      # violation; raises ArgumentError when no contract covers the action
      # (that is a programmer error, not a client error). Memoized per action.
      def permitted_params(action = nil)
        action = (action || permittable_action_name).to_s
        raise ArgumentError, "#{LABEL}: no action given and action_name is not set" if action.empty?

        @permittable_validated ||= {}
        return @permittable_validated[action] if @permittable_validated.key?(action)

        rule = self.class.permit_rule_for(action)
        raise ArgumentError, "#{LABEL}: no params contract declared covering ##{action}" unless rule

        @permittable_validated[action] = validate_params_contract!(rule)
      end

      # before_action entry point (public so hosts can `skip_before_action
      # :enforce_params_contract`). Only rules that opted in with
      # `enforce: true` validate here.
      def enforce_params_contract
        action = permittable_action_name
        return nil unless action

        rule = self.class.permit_rule_for(action)
        permitted_params(action) if rule && rule[:enforce]
        nil
      end

      # rescue_from target — renders through the shared envelope (Respondable's
      # render_error when present, the identical inline shape otherwise).
      def render_invalid_parameters(error)
        ConcernsOnRails::Support::ErrorEnvelope.render(
          self, message: error.message, status: error.status,
          code: "invalid_parameters", details: error.details
        )
      end

      private

      def validate_params_contract!(rule)
        violations = []
        source = permittable_root_hash(rule, violations)
        result = ActiveSupport::HashWithIndifferentAccess.new
        if source
          result = permittable_check_hash(rule[:fields], source, path: rule[:root] ? rule[:root].to_s : nil,
                                          unknown: rule[:unknown], top_level: !rule[:root], violations: violations)
        end
        return result if violations.empty?

        raise_invalid_parameters!(violations, status: source ? :unprocessable_entity : :bad_request)
      end

      def raise_invalid_parameters!(violations, status:)
        violations.each(&:freeze)
        ActiveSupport::Notifications.instrument(
          "invalid_parameters.concerns_on_rails",
          controller: permittable_controller_name, action: permittable_action_name, details: violations
        )
        summary = violations.map { |v| "#{v[:param]} (#{v[:code]})" }.join(", ")
        raise InvalidParameters.new("Invalid parameters: #{summary}", details: violations, status: status)
      end

      def permittable_root_hash(rule, violations)
        raw = permittable_plain_params
        return raw unless rule[:root]

        value = raw[rule[:root].to_s]
        return value if value.is_a?(Hash)

        violations << { param: rule[:root].to_s, code: "missing" }
        nil
      end

      # One plain HashWithIndifferentAccess view of `params`, whatever the
      # stack: ActionController::Parameters (to_unsafe_h — this concern does
      # its own permitting, that is the point) or a plain hash in tests.
      def permittable_plain_params
        raw = params
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        ActiveSupport::HashWithIndifferentAccess.new(raw)
      end

      def permittable_check_hash(fields, hash, path:, unknown:, top_level:, violations:)
        result = ActiveSupport::HashWithIndifferentAccess.new
        fields.each do |field|
          key = field[:name].to_s
          full = permittable_path(path, key)
          value = hash[key]

          if permittable_absent?(value, hash, key)
            if field.key?(:default)
              result[key] = field[:default]
            elsif field[:required]
              violations << { param: full, code: "missing" }
            end
            next
          end

          permittable_check_field(field, value, full, result, unknown: unknown, violations: violations)
        end
        permittable_check_unknown(fields, hash, path: path, unknown: unknown, top_level: top_level, violations: violations)
        result
      end

      def permittable_check_field(field, value, full, result, unknown:, violations:)
        key = field[:name].to_s
        case field[:kind]
        when :scalar
          status, out = Coercion.check_scalar(field, value)
          status == :ok ? result[key] = out : violations << { param: full, code: out }
        when :nested
          if value.is_a?(Hash)
            result[key] = permittable_check_hash(field[:fields], ActiveSupport::HashWithIndifferentAccess.new(value),
                                                 path: full, unknown: unknown, top_level: false, violations: violations)
          else
            violations << { param: full, code: "invalid_type" }
          end
        when :array
          if value.is_a?(Array)
            result[key] = permittable_check_array(field, value, path: full, unknown: unknown, violations: violations)
          else
            violations << { param: full, code: "invalid_type" }
          end
        end
      end

      def permittable_check_array(field, value, path:, unknown:, violations:)
        if field[:length] && !Coercion.length_ok?(field[:length], value.length)
          violations << { param: path, code: "length" }
        end
        out = value.each_with_index.map do |element, index|
          permittable_check_element(field, element, "#{path}[#{index}]", unknown: unknown, violations: violations)
        end
        if field[:validate]
          status, code = Coercion.check_custom(field[:validate], out)
          violations << { param: path, code: code } unless status == :ok
        end
        out
      end

      def permittable_check_element(field, element, path, unknown:, violations:)
        if field[:fields]
          unless element.is_a?(Hash)
            violations << { param: path, code: "invalid_type" }
            return nil
          end
          return permittable_check_hash(field[:fields], ActiveSupport::HashWithIndifferentAccess.new(element),
                                        path: path, unknown: unknown, top_level: false, violations: violations)
        end

        status, out = Coercion.cast(field[:of], element)
        return out if status == :ok

        violations << { param: path, code: out }
        nil
      end

      # nil and "" are both ABSENT — see the module comment.
      def permittable_absent?(value, hash, key)
        !hash.key?(key) || value.nil? || (value.is_a?(String) && value.empty?)
      end

      def permittable_check_unknown(fields, hash, path:, unknown:, top_level:, violations:)
        return if unknown == :ignore

        declared = fields.map { |f| f[:name].to_s }
        extra = hash.keys.map(&:to_s) - declared
        extra -= ROUTING_KEYS if top_level
        return if extra.empty?

        if unknown == :error
          extra.each { |key| violations << { param: permittable_path(path, key), code: "unknown" } }
        elsif respond_to?(:logger) && logger
          logger.warn("#{LABEL}: unknown parameter(s) ignored by the ##{permittable_action_name} contract: " \
                      "#{extra.map { |key| permittable_path(path, key) }.join(', ')}")
        end
      end

      def permittable_path(path, key)
        path ? "#{path}.#{key}" : key
      end

      def permittable_action_name
        respond_to?(:action_name) && action_name ? action_name.to_s : nil
      end

      def permittable_controller_name
        return controller_path if respond_to?(:controller_path)

        self.class.name
      end
    end
  end
end
