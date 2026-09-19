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
        # respond_to?(..., true) because render_error is very often declared
        # under `private` — the idiomatic way to keep a controller helper from
        # becoming a routable action — or exposed as a helper_method. The
        # public-only check silently missed those and fell through to the
        # inline body below, so an app rendering RFC 9457 problem+json got the
        # gem's non-conforming shape for every Authorizable 403,
        # WebhookVerifiable 401, Throttleable 429 and CursorPaginatable 400,
        # with no error or warning. Authorizable already uses this spelling for
        # current_user (`respond_to?(via, true)`) for exactly the same reason.
        if controller.respond_to?(:render_error, true)
          # errors: only when there are details AND the effective render_error
          # can actually accept them. Several concerns document the override
          # contract as `render_error(message:, status:, code:)`, so passing the
          # kwarg unconditionally raised `ArgumentError: unknown keyword:
          # :errors` at request time against those apps — turning a 422 into a
          # 500 on exactly the path that has something to report. Guarding on
          # `details` alone only covered the empty case, i.e. the one that was
          # never broken.
          kwargs = { message: message, code: code, status: status }
          kwargs[:errors] = details if details && accepts_errors?(controller)
          controller.send(:render_error, **kwargs)
        else
          error = { message: message }
          error[:code] = code if code
          error[:details] = details if details
          controller.render(json: { success: false, error: error }, status: status)
        end
      end

      # True when the controller's render_error takes an `errors:` keyword (or
      # a **rest that would swallow it). Fails open: if the method cannot be
      # reflected on, keep the old behaviour and pass the details.
      def accepts_errors?(controller)
        controller.method(:render_error).parameters.any? do |type, name|
          type == :keyrest || (%i[key keyreq].include?(type) && name == :errors)
        end
      rescue NameError
        true
      end
    end
  end
end
