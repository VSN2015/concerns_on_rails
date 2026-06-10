require "active_support/concern"

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
    # Non-goals (kept deliberately small): this is NOT a policy/ability framework.
    # No policy objects, no ability DSL, no resource inference — reach for Pundit
    # or CanCanCan when you outgrow a predicate per action.
    module Authorizable
      extend ActiveSupport::Concern

      included do
        class_attribute :authorizable_rules, instance_accessor: false, default: []
        before_action :enforce_authorization
      end

      module ClassMethods
        # Register an authorization predicate. `only:`/`except:` scope it to a
        # subset of actions (mutually exclusive). `status:` (default :forbidden)
        # and `message:` control the denial response.
        def authorize_by(only: nil, except: nil, status: :forbidden, message: "Forbidden", &block)
          raise ArgumentError, "ConcernsOnRails::Controllers::Authorizable: a block is required" unless block

          add_authorization_rule(check: block, only: only, except: except, status: status, message: message)
        end

        # Sugar for the common "actor must have one of these roles" rule. The
        # actor is read via `via:` (default `:current_user`) and its role via
        # `role_method:` (default `:role`). Implemented as a proc, never a lambda,
        # so arity slicing can't raise.
        def require_role(*roles, via: :current_user, role_method: :role, only: nil, except: nil,
                         status: :forbidden, message: "Forbidden")
          raise ArgumentError, "ConcernsOnRails::Controllers::Authorizable: at least one role is required" if roles.empty?

          wanted = roles.map(&:to_s)
          check = proc do
            # respond_to?(via, true): current_user is usually private (Devise) or
            # a helper_method (which keeps it private on the instance), so the
            # default public-only check would resolve nil and deny everyone.
            actor = respond_to?(via, true) ? send(via) : nil
            actor.respond_to?(role_method, true) && wanted.include?(actor.send(role_method).to_s)
          end
          add_authorization_rule(check: check, only: only, except: except, status: status, message: message)
        end

        private

        def add_authorization_rule(check:, only:, except:, status:, message:)
          raise ArgumentError, "ConcernsOnRails::Controllers::Authorizable: pass either :only or :except, not both" if only && except

          rule = {
            check: check,
            only: only && Array(only).map(&:to_s),
            except: except && Array(except).map(&:to_s),
            status: status,
            message: message
          }
          self.authorizable_rules = authorizable_rules + [rule]
        end
      end

      # Public so subclasses can override. Iterates the declared rules in order
      # and denies on the first failing rule that applies to the current action.
      def enforce_authorization
        self.class.authorizable_rules.each do |rule|
          next unless authorization_rule_applies?(rule)
          next if invoke_authorization_check(rule[:check])

          return authorization_denied(status: rule[:status], message: rule[:message])
        end
        nil
      end

      # Public override point for how a denial is rendered.
      def authorization_denied(status:, message:)
        return unless respond_to?(:response) && response

        return render_error(message: message, status: status, code: "forbidden") if respond_to?(:render_error)

        render json: { success: false, error: { message: message, code: "forbidden" } }, status: status
      end

      private

      def authorization_rule_applies?(rule)
        action = authorization_action_name
        return rule[:only].include?(action) if rule[:only]
        return !rule[:except].include?(action) if rule[:except]

        true
      end

      # Arity-safe: slice the args to the predicate's arity before instance_exec
      # so a zero/one/two-arg block all work. A negative arity (splat/optional)
      # receives every arg.
      def invoke_authorization_check(check)
        args = [authorization_action_name, authorization_actor]
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
    end
  end
end
