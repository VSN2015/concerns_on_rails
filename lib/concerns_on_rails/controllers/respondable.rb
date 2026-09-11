require "active_support/concern"
require "rack/utils"

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
    #         render_success(data: article, status: :created)
    #       else
    #         render_error(message: "Invalid", errors: article.errors.full_messages)
    #       end
    #     end
    #   end
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

      included do
        class_attribute :respondable_error_format, instance_accessor: false, default: :envelope
        class_attribute :respondable_problem_type_base, instance_accessor: false, default: nil
      end

      class_methods do
        # `error_format:` :envelope (default) or :problem_details (RFC 9457).
        # `problem_type_base:` is prefixed to `code` to form the `type` URI
        # (without it, or without a code, `type` is "about:blank").
        def respondable_by(error_format: :envelope, problem_type_base: nil)
          format = error_format.to_sym
          unless ERROR_FORMATS.include?(format)
            raise ArgumentError, "#{LABEL}: error_format must be one of #{ERROR_FORMATS.map(&:inspect).join(', ')}"
          end

          self.respondable_error_format = format
          self.respondable_problem_type_base = problem_type_base&.to_s
        end
      end

      # Success envelope:
      #   { success: true, data: <data>, meta: <meta> }
      # `meta:` is omitted from the JSON when empty so simple responses stay clean.
      def render_success(data: nil, status: :ok, meta: {})
        body = { success: true, data: data }
        body[:meta] = meta if meta.is_a?(Hash) && meta.any?
        render json: body, status: status
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
        body[:instance] = request.path if respond_to?(:request) && request.respond_to?(:path) && request.path
        body[:code] = code if code
        body[:errors] = errors if errors

        render json: body, status: status, content_type: PROBLEM_JSON
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
