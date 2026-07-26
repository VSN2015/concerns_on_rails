module ConcernsOnRails
  module Support
    # One home for the error envelope the controller concerns emit: prefer
    # Respondable#render_error when the controller includes it, otherwise
    # render the identical inline shape. Behavior-preserving extraction of the
    # `respond_to?(:render_error) ? render_error(...) : render json: ...`
    # dance that was hand-copied across seven concerns — and the single place
    # to change when e.g. an RFC 9457 problem+json mode lands.
    module ErrorEnvelope
      module_function

      def render(controller, message:, status:, code: nil, details: nil)
        if controller.respond_to?(:render_error)
          # errors: only when there are details — several concerns document the
          # override contract as `render_error(message:, status:, code:)`, and
          # an unconditional errors: kwarg would break those implementations.
          kwargs = { message: message, code: code, status: status }
          kwargs[:errors] = details if details
          controller.render_error(**kwargs)
        else
          error = { message: message }
          error[:code] = code if code
          error[:details] = details if details
          controller.render(json: { success: false, error: error }, status: status)
        end
      end
    end
  end
end
