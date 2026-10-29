module ConcernsOnRails
  module Support
    # One home for the error envelope the controller concerns emit: prefer
    # Respondable#render_error when the controller includes it, otherwise
    # render the identical inline shape. Behavior-preserving extraction of the
    # `respond_to?(:render_error) ? render_error(...) : render json: ...`
    # dance that was hand-copied across seven concerns — and the single place
    # to change when e.g. an RFC 9457 problem+json mode lands.
    module ErrorEnvelope
      # The generic body of a 404: ErrorHandleable's missing-record handler and
      # Authorizable's `status: :not_found` concealment both render it, so a
      # client can never tell a hidden record from a missing one. ONE constant,
      # so the two cannot drift apart.
      NOT_FOUND_MESSAGE = "Resource not found".freeze

      # Rack 3.1+ renamed these status phrases (422 became "Unprocessable
      # Content"), and `Rack::Utils.status_code` warns "Status code
      # :unprocessable_entity is deprecated" on EVERY call for the old names.
      # Rails >= 8.1 rewrites them before calling Rack for exactly that reason;
      # `renderable_status` mirrors it for Rails 7.1-8.0 on Rack >= 3.1. (Rack's
      # own obsolete-symbol table is private_constant, so it cannot be consulted.)
      RENAMED_STATUS_SYMBOLS = {
        unprocessable_entity: :unprocessable_content,
        request_entity_too_large: :content_too_large,
        payload_too_large: :content_too_large,
        request_uri_too_long: :uri_too_long
      }.freeze

      module_function

      # The status to hand to `render`/`head`: a renamed symbol the running Rack
      # no longer lists becomes its new name; everything else (an Integer, a
      # symbol Rack knows -- all of them on Rack < 3.1, where the NEW name would
      # raise) is returned untouched.
      def renderable_status(status)
        return status unless status.is_a?(Symbol) && RENAMED_STATUS_SYMBOLS.key?(status)
        return status unless defined?(::Rack::Utils::SYMBOL_TO_STATUS_CODE)
        return status if ::Rack::Utils::SYMBOL_TO_STATUS_CODE.key?(status)

        RENAMED_STATUS_SYMBOLS.fetch(status)
      end

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
          controller.render(json: { success: false, error: error }, status: renderable_status(status))
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
