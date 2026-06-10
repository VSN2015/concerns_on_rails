require "active_support/concern"

module ConcernsOnRails
  module Controllers
    # Installs `rescue_from` handlers for the three most common controller
    # exceptions and renders them as the JSON error envelope used by Respondable.
    #
    #   class Api::BaseController < ApplicationController
    #     include ConcernsOnRails::Controllers::Respondable      # optional, but recommended
    #     include ConcernsOnRails::Controllers::ErrorHandleable
    #   end
    #
    # Handled:
    #   * ActiveRecord::RecordNotFound          → 404 not_found
    #   * ActionController::ParameterMissing    → 400 parameter_missing
    #   * ActiveRecord::RecordInvalid           → 422 record_invalid (with field errors)
    #
    # If Respondable is also included on the controller, the handlers delegate
    # to `render_error` so the envelope shape stays in one place. Otherwise the
    # handlers render the same envelope inline.
    #
    # Each handler is a public instance method, so subclasses can override the
    # message wording or response shape without re-declaring the `rescue_from`.
    module ErrorHandleable
      extend ActiveSupport::Concern

      included do
        rescue_from "ActiveRecord::RecordNotFound",       with: :handle_record_not_found
        rescue_from "ActionController::ParameterMissing", with: :handle_parameter_missing
        rescue_from "ActiveRecord::RecordInvalid",        with: :handle_record_invalid
      end

      def handle_record_not_found(_error)
        # Use a generic message: the raw RecordNotFound message leaks the model
        # class name and the queried attribute/value to API clients. Subclasses
        # can override this method to surface detail in non-production envs.
        render_error_envelope(
          message: "Resource not found",
          code: "not_found",
          status: :not_found
        )
      end

      def handle_parameter_missing(error)
        render_error_envelope(
          message: "Parameter missing: #{error.param}",
          code: "parameter_missing",
          status: :bad_request
        )
      end

      def handle_record_invalid(error)
        record = error.respond_to?(:record) ? error.record : nil
        details = record.respond_to?(:errors) ? record.errors.full_messages : nil

        render_error_envelope(
          message: error.message,
          code: "record_invalid",
          status: :unprocessable_entity,
          errors: details
        )
      end

      private

      def render_error_envelope(message:, code:, status:, errors: nil)
        return render_error(message: message, code: code, status: status, errors: errors) if respond_to?(:render_error)

        error = { message: message, code: code }
        error[:details] = errors if errors
        render json: { success: false, error: error }, status: status
      end
    end
  end
end
