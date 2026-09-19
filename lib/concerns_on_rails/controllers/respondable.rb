require "active_support/concern"
require "rack/utils"
require "concerns_on_rails/support/error_envelope"

module ConcernsOnRails
  module Controllers
    # Standardized JSON envelopes for API controllers.
    #
    #   class Api::ArticlesController < ApplicationController
    #     include ConcernsOnRails::Controllers::Respondable
    #
    #     def show
    #       article = Article.find_by(id: params[:id])
    #       return render_error(message: "Not found", status: :not_found) unless article
    #
    #       render_success(data: article)
    #     end
    #
    #     def create
    #       article = Article.new(article_params)
    #       if article.save
    #         render_created(data: article, location: article_url(article))   # 201 + Location
    #       else
    #         render_invalid(article)             # 422 record_invalid + errors.full_messages
    #       end
    #     end
    #   end
    #
    # `render_success` takes `location:` (the Location header — a String, or
    # anything `url_for` resolves) and `headers:` (extra response headers);
    # `render_created` is the 201 shorthand; `render_invalid(record)` renders a
    # record's (or an ActiveModel::Errors') full_messages the way
    # ErrorHandleable does for a rescued RecordInvalid, so `save` and `save!`
    # actions look identical to clients.
    #
    # Error format: the classic `{ success: false, error: { message, code, details } }`
    # envelope by default, or RFC 9457 Problem Details —
    #
    #   respondable_by error_format: :problem_details,
    #                  problem_type_base: "https://api.example.com/problems"
    #
    #   # => 422 application/problem+json
    #   # { "type": "https://api.example.com/problems/record_invalid",
    #   #   "title": "Unprocessable Content", "status": 422,
    #   #   "detail": "Validation failed", "instance": "/api/articles",
    #   #   "code": "record_invalid", "errors": ["Name can't be blank"] }
    #
    # Because every error-rendering concern in this gem (ErrorHandleable,
    # Throttleable, Idempotentable, CursorPaginatable, Deprecatable,
    # WebhookVerifiable, Authorizable) funnels through `render_error` when
    # Respondable is included, the switch is app-wide: one line and every 4xx
    # the gem produces is a problem document. `render_success` is unchanged.
    #
    # Note: `data:` is a keyword arg (not positional) to sidestep Ruby 3's
    # behavior of treating hash literals as kwargs when a method declares any
    # keyword params — this lets callers pass hash data without surprises.
    module Respondable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::Respondable".freeze
      # Rack 3.1+ renamed these status phrases; see problem_status_code.
      RENAMED_STATUS_SYMBOLS = {
        unprocessable_entity: :unprocessable_content,
        request_entity_too_large: :content_too_large,
        payload_too_large: :content_too_large,
        request_uri_too_long: :uri_too_long
      }.freeze

      ERROR_FORMATS = %i[envelope problem_details].freeze
      PROBLEM_JSON = "application/problem+json".freeze
      # Distinguishes "not passed" from an explicit nil in respondable_by.
      UNSET = Object.new.freeze
      # The bytes a header line cannot carry, stripped from every caller-supplied
      # header name and value. CR/LF are the response-splitting pair; the rest
      # are rejected outright by Rack::Lint and by Puma's own illegal-header
      # scan, which this mirrors (horizontal tab, \x09, stays legal).
      ILLEGAL_HEADER_BYTES = /[\x00-\x08\x0a-\x1f]/

      included do
        class_attribute :respondable_error_format, instance_accessor: false, default: :envelope
        class_attribute :respondable_problem_type_base, instance_accessor: false, default: nil
      end

      class_methods do
        # `error_format:` :envelope (default) or :problem_details (RFC 9457).
        # `problem_type_base:` is prefixed to `code` to form the `type` URI
        # (without it, or without a code, `type` is "about:blank").
        def respondable_by(error_format: UNSET, problem_type_base: UNSET)
          unless error_format == UNSET
            format = error_format.to_sym
            unless ERROR_FORMATS.include?(format)
              raise ArgumentError, "#{LABEL}: error_format must be one of #{ERROR_FORMATS.map(&:inspect).join(', ')}"
            end

            self.respondable_error_format = format
          end

          # A nil default would mean "not passed" here, so a subclass declaring
          # only error_format: would wipe an inherited problem_type_base (every
          # type back to about:blank), and a call passing only
          # problem_type_base: would silently switch the format back to
          # :envelope -- turning problem details off.
          self.respondable_problem_type_base = problem_type_base&.to_s unless problem_type_base == UNSET
        end
      end

      # Success envelope:
      #   { success: true, data: <data>, meta: <meta> }
      # `meta:` is omitted from the JSON when empty so simple responses stay clean.
      # `location:` sets the Location header (String as-is, anything else through
      # `url_for` when the controller has it); `headers:` adds arbitrary ones.
      def render_success(data: nil, status: :ok, meta: {}, location: nil, headers: {})
        respondable_set_headers(location, headers)
        body = { success: true, data: data }
        body[:meta] = meta if meta.is_a?(Hash) && meta.any?
        render json: body, status: status
      end

      # 201 Created with an optional Location — the create-action one-liner.
      # The headers are written here rather than forwarded, so an app that
      # overrode render_success with the older `(data:, status:, meta:)`
      # signature still gets its Location set and never sees an unknown
      # keyword.
      def render_created(data: nil, location: nil, meta: {}, headers: {})
        respondable_set_headers(location, headers)
        render_success(data: data, status: :created, meta: meta)
      end

      # A validation failure as an error envelope (or problem document):
      # `details` is the object's errors.full_messages, omitted when empty —
      # the exact shape ErrorHandleable renders for a rescued RecordInvalid.
      def render_invalid(record_or_errors, message: "Validation failed", status: :unprocessable_entity, code: "record_invalid")
        # Through the shared envelope: it omits the errors: keyword both when
        # there is nothing to report and when the effective render_error cannot
        # accept it (several concerns document the contract as
        # `render_error(message:, status:, code:)`, and an app carrying that
        # signature would otherwise get ArgumentError on every validation
        # failure -- the one path render_invalid exists for).
        ConcernsOnRails::Support::ErrorEnvelope.render(
          self, message: message, status: status, code: code,
                details: respondable_error_messages(record_or_errors).presence
        )
      end

      # Error envelope:
      #   { success: false, error: { message:, code?, details? } }
      # — or an RFC 9457 problem document when `respondable_by error_format:
      # :problem_details` is declared.
      def render_error(message:, status: :unprocessable_entity, code: nil, errors: nil)
        if self.class.respondable_error_format == :problem_details
          return render_problem_details(message: message, status: status, code: code, errors: errors)
        end

        error = { message: message }
        error[:code] = code if code
        error[:details] = errors if errors

        render json: { success: false, error: error }, status: status
      end

      private

      # respond_to?(..., true) for the same reason the charset guard below uses
      # it: the concern must not assume the reader is public on whatever the
      # host object turns out to be.
      def respondable_set_headers(location, headers)
        return unless respond_to?(:response, true) && response.respond_to?(:set_header)

        respondable_write_header("Location", respondable_header_token(respondable_location(location))) if location
        (headers || {}).each do |name, value|
          # An explicit nil means "no header", not an empty one.
          next if value.nil?

          respondable_write_header(respondable_header_token(name), respondable_header_token(value))
        end
      end

      # Link is additive by definition (RFC 8288) and Paginatable /
      # Deprecatable may already have written entries, so append to it rather
      # than dropping theirs. Everything else is a plain set. A name or value
      # that sanitized down to nothing is dropped: an empty `Location:` is
      # meaningless, and a nameless header is not a header.
      def respondable_write_header(name, value)
        return if name.empty? || value.empty?

        if name.casecmp("Link").zero? && (found = respondable_existing_header(name))
          key, existing = found
          name = key
          value = [existing, value].reject { |part| part.nil? || part.to_s.empty? }.join(", ")
        end

        response.set_header(name, value)
      end

      # `response.headers` is case-SENSITIVE before Rails 7.1 and
      # case-insensitive (Rack::Headers) from 7.1 on — the same split
      # Idempotentable scans around. Without the fallback, `headers: { "link"
      # => … }` alongside Paginatable's "Link" emits a SECOND Link header on
      # 6.1 instead of extending the first; append under the spelling that is
      # already there.
      def respondable_existing_header(name)
        headers = response.headers
        value = headers[name]
        return [name, value] unless value.nil?
        return nil unless headers.respond_to?(:find)

        headers.find { |header, _| header.to_s.casecmp(name).zero? }
      end

      # These are the gem's first response headers built from CALLER-supplied
      # data, so coerce to String (an Integer fails Rack::Lint and breaks any
      # middleware calling String methods on it) and strip the bytes a header
      # line cannot carry. Names go through it too: CR/LF in an interpolated
      # `headers:` KEY splits the response exactly as one in a value does.
      def respondable_header_token(value)
        value.to_s.gsub(ILLEGAL_HEADER_BYTES, "")
      end

      # A String is a URL already; a record / route Hash goes through the
      # controller's url_for when there is one (the fake harness has none).
      def respondable_location(location)
        return location if location.is_a?(String)

        respond_to?(:url_for, true) ? url_for(location) : location.to_s
      end

      def respondable_error_messages(record_or_errors)
        errors = record_or_errors.respond_to?(:full_messages) ? record_or_errors : nil
        errors ||= record_or_errors.errors if record_or_errors.respond_to?(:errors)
        unless errors.respond_to?(:full_messages)
          raise ArgumentError, "#{LABEL}: render_invalid expects a record (responding to #errors) or an ActiveModel::Errors, " \
                               "got #{record_or_errors.class}"
        end

        errors.full_messages
      end

      # RFC 9457: type (URI or about:blank), title (the status reason phrase),
      # status (integer), detail (the message), instance (request path when
      # known), plus `code` and `errors` as extension members.
      def render_problem_details(message:, status:, code:, errors:)
        status_code = problem_status_code(status)
        body = {
          type: problem_type_for(code),
          title: Rack::Utils::HTTP_STATUS_CODES.fetch(status_code, "Error"),
          status: status_code,
          detail: message
        }
        body[:instance] = request.path if respond_to?(:request, true) && request.respond_to?(:path) && request.path
        body[:code] = code if code
        body[:errors] = errors if errors

        # The Integer, not the original symbol: ActionDispatch::Response#status=
        # runs it through Rack::Utils.status_code, which deprecation-warns for
        # :unprocessable_entity -- render_error's own default, so every
        # validation failure printed one.
        result = render json: body, status: status_code, content_type: PROBLEM_JSON
        suppress_problem_charset
        result
      end

      # Rails appends "; charset=utf-8" to every rendered content type, but the
      # RFC 9457 registration for application/problem+json defines no
      # parameters -- a client comparing the header for equality rejects the
      # document. `charset = false` drops the parameter. Guarded because the
      # response object is not always a real ActionDispatch::Response.
      def suppress_problem_charset
        return unless respond_to?(:response, true) && response.respond_to?(:charset=)

        response.charset = false
      end

      def problem_type_for(code)
        base = self.class.respondable_problem_type_base
        return "about:blank" if code.nil? || base.nil?

        "#{base.chomp('/')}/#{code}"
      end

      # Symbol → integer. Rack 3.1+ renamed some phrases (422 became
      # "Unprocessable Content") and `Rack::Utils.status_code` warns on every
      # call for the old names. Rails >= 8.1 rewrites them before calling Rack
      # for exactly that reason; mirror it, so a problem-details app does not
      # log a deprecation line on every validation failure. (Rack's own
      # obsolete-symbol table is private_constant, so it cannot be consulted.)
      def problem_status_code(status)
        return status.to_i if status.is_a?(Integer) || status.to_s.match?(/\A\d+\z/)

        symbol = status.to_sym
        symbol = RENAMED_STATUS_SYMBOLS.fetch(symbol, symbol) unless Rack::Utils::SYMBOL_TO_STATUS_CODE.key?(symbol)
        Rack::Utils::SYMBOL_TO_STATUS_CODE[symbol] || Rack::Utils.status_code(symbol)
      end
    end
  end
end
