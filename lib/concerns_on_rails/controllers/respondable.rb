require "active_support/concern"

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
    # Note: `data:` is a keyword arg (not positional) to sidestep Ruby 3's
    # behavior of treating hash literals as kwargs when a method declares any
    # keyword params — this lets callers pass hash data without surprises.
    module Respondable
      extend ActiveSupport::Concern

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
      def render_error(message:, status: :unprocessable_entity, code: nil, errors: nil)
        error = { message: message }
        error[:code] = code if code
        error[:details] = errors if errors

        render json: { success: false, error: error }, status: status
      end
    end
  end
end
