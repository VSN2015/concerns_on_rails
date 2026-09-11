require "active_support/concern"
require "concerns_on_rails/support/error_envelope"

module ConcernsOnRails
  module Controllers
    # Declarative, block-only per-action authorization gate. Each rule is a
    # predicate; the first rule that applies to the current action and returns a
    # falsey value halts the request with 403 (rendered via Respondable's
    # `render_error` when available, otherwise an inline envelope).
    #
    #   class Api::BaseController < ApplicationController
    #     include ConcernsOnRails::Controllers::Authorizable
    #
    #     authorize_by { current_user.present? }                       # every action
    #     authorize_by(only: %i[update destroy]) { |_action, user| user.admin? }
    #     require_role :admin, :editor, only: :publish                 # role sugar
    #   end
    #
    # The block is invoked with `instance_exec` so `current_user` (and any other
    # helper) resolves on the controller. It is arity-safe: write it with zero,
    # one (`|action|`), or two (`|action, user|`) parameters.
    #
    # Observability and control:
    #   * every denial instruments `authorization_denied.concerns_on_rails`
    #     (controller, action, actor, rule name, status, message) through the
    #     `on_authorization_denied(rule)` override point — give rules a `name:`
    #     to make the events readable;
    #   * `skip_authorization only: %i[index show]` exempts actions from every
    #     rule, including ones inherited from a parent controller;
    #   * `authorized?(action = action_name)` evaluates the rules without
    #     rendering, so a view can hide the buttons the user can't use.
    #
    # Non-goals (kept deliberately small): this is NOT a policy/ability framework.
    # No policy objects, no ability DSL, no resource inference — reach for Pundit
    # or CanCanCan when you outgrow a predicate per action.
    module Authorizable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::Authorizable".freeze
      # Sentinel so a nil only:/except: is distinguishable from "not passed".
      UNSET = Object.new.freeze

      included do
        class_attribute :authorizable_rules, instance_accessor: false, default: []
        class_attribute :authorizable_skip, instance_accessor: false, default: nil
        before_action :enforce_authorization
      end

      module ClassMethods
        # Register an authorization predicate. `only:`/`except:` scope it to a
        # subset of actions (mutually exclusive). `status:` (default :forbidden)
        # and `message:` control the denial response; `name:` labels the rule in
        # the `authorization_denied.concerns_on_rails` event payload.
        def authorize_by(only: nil, except: nil, status: :forbidden, message: "Forbidden", name: nil, &block)
          raise ArgumentError, "#{LABEL}: a block is required" unless block

          add_authorization_rule(check: block, only: only, except: except, status: status, message: message, name: name)
        end

        # Exempt actions from every rule — the declared ones AND the inherited
        # ones, which `skip_before_action` can't do selectively. `only:`/`except:`
        # (mutually exclusive) pick the actions; bare `skip_authorization`
        # exempts them all. Inherited by subclasses; re-declare to change it.
        def skip_authorization(only: UNSET, except: UNSET)
          validate_skip_authorization!(only, except)

          self.authorizable_skip = {
            only: skip_authorization_actions(only),
            except: skip_authorization_actions(except)
          }
        end

        # Sugar for the common "actor must have one of these roles" rule. The
        # actor is read via `via:` (default `:current_user`) and its role via
        # `role_method:` (default `:role`). Implemented as a proc, never a lambda,
        # so arity slicing can't raise.
        def require_role(*roles, via: :current_user, role_method: :role, only: nil, except: nil,
                         status: :forbidden, message: "Forbidden", name: nil)
          raise ArgumentError, "#{LABEL}: at least one role is required" if roles.empty?

          wanted = roles.map(&:to_s)
          check = proc do
            # respond_to?(via, true): current_user is usually private (Devise) or
            # a helper_method (which keeps it private on the instance), so the
            # default public-only check would resolve nil and deny everyone.
            actor = respond_to?(via, true) ? send(via) : nil
            # Array() handles both a scalar role and an array-valued `roles`
            # method — pre-1.22 an actor with roles = ["admin"] stringified to
            # '["admin"]' and was always denied.
            actor.respond_to?(role_method, true) &&
              Array(actor.send(role_method)).any? { |role| wanted.include?(role.to_s) }
          end
          add_authorization_rule(check: check, only: only, except: except, status: status, message: message, name: name)
        end

        private

        def validate_skip_authorization!(only, except)
          raise ArgumentError, "#{LABEL}: pass either :only or :except, not both" if only != UNSET && except != UNSET
          return unless only.nil? || except.nil?

          # A nil only:/except: must NOT silently degrade to the bare form.
          # `skip_authorization only: PUBLIC_ACTIONS` with a nil constant would
          # otherwise exempt EVERY action of this controller and all of its
          # subclasses — the widest possible failure from the smallest typo.
          raise ArgumentError,
                "#{LABEL}: skip_authorization was given a nil :only/:except. Pass a list of actions, " \
                "or call skip_authorization with no arguments to exempt every action."
        end

        def skip_authorization_actions(value)
          value == UNSET ? nil : Array(value).map(&:to_s)
        end

        def add_authorization_rule(check:, only:, except:, status:, message:, name:)
          raise ArgumentError, "#{LABEL}: pass either :only or :except, not both" if only && except

          rule = {
            check: check,
            only: only && Array(only).map(&:to_s),
            except: except && Array(except).map(&:to_s),
            status: status,
            message: message,
            name: name
          }
          self.authorizable_rules = authorizable_rules + [rule]
        end
      end

      # Public so subclasses can override. Iterates the declared rules in order
      # and denies on the first failing rule that applies to the current action.
      def enforce_authorization
        action = authorization_action_name
        return nil if authorization_skipped?(action)

        self.class.authorizable_rules.each do |rule|
          next unless authorization_rule_applies?(rule, action)
          next if invoke_authorization_check(rule[:check], action)

          on_authorization_denied(rule)
          return authorization_denied(status: rule[:status], message: rule[:message])
        end
        nil
      end

      # Would the rules let the current actor run `action`? Evaluates them the
      # same way `enforce_authorization` does but never renders — expose it as
      # a helper_method to hide the buttons a user can't use.
      def authorized?(action = authorization_action_name)
        action = action.to_s
        return true if authorization_skipped?(action)

        self.class.authorizable_rules.all? do |rule|
          !authorization_rule_applies?(rule, action) || invoke_authorization_check(rule[:check], action)
        end
      end

      # True when `skip_authorization` exempts the action.
      def authorization_skipped?(action = authorization_action_name)
        skip = self.class.authorizable_skip
        return false unless skip

        action = action.to_s
        return skip[:only].include?(action) if skip[:only]
        return !skip[:except].include?(action) if skip[:except]

        true
      end

      # Instruments `authorization_denied.concerns_on_rails` with the
      # controller, action, actor, rule name, status and message — the hook for
      # audit logs or alerting on repeated denials. Public override point; call
      # super to keep the event.
      def on_authorization_denied(rule)
        ActiveSupport::Notifications.instrument(
          "authorization_denied.concerns_on_rails",
          controller: authorization_controller_name, action: authorization_action_name,
          actor: authorization_actor, rule: rule[:name], status: rule[:status], message: rule[:message]
        )
      end

      # Public override point for how a denial is rendered. Fails CLOSED: when
      # there is no response object to render into, raise — returning nil here
      # (the pre-1.22 behavior) let the action run unauthorized.
      def authorization_denied(status:, message:)
        unless respond_to?(:response) && response
          raise "#{LABEL}: denial for '#{authorization_action_name}' " \
                "could not be rendered (no response object) — refusing to fail open"
        end

        ConcernsOnRails::Support::ErrorEnvelope.render(self, message: message, status: status, code: "forbidden")
      end

      private

      def authorization_rule_applies?(rule, action)
        return rule[:only].include?(action) if rule[:only]
        return !rule[:except].include?(action) if rule[:except]

        true
      end

      # Arity-safe: slice the args to the predicate's arity before instance_exec
      # so a zero/one/two-arg block all work. A negative arity (splat/optional)
      # receives every arg.
      def invoke_authorization_check(check, action)
        args = [action, authorization_actor]
        sliced = check.arity.negative? ? args : args.first(check.arity)
        instance_exec(*sliced, &check)
      end

      def authorization_actor
        # include_private: true — current_user is typically private/helper_method.
        respond_to?(:current_user, true) ? current_user : nil
      end

      def authorization_action_name
        respond_to?(:action_name) ? action_name.to_s : nil
      end

      def authorization_controller_name
        respond_to?(:controller_path) ? controller_path : self.class.name
      end
    end
  end
end
