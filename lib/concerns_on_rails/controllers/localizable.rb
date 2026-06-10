require "active_support/concern"

module ConcernsOnRails
  module Controllers
    # Per-request locale selection from the request params and/or the
    # `Accept-Language` header, wrapped in an `around_action` so `I18n.locale`
    # is set for the action and restored afterwards.
    #
    #   class ApplicationController < ActionController::Base
    #     include ConcernsOnRails::Controllers::Localizable
    #
    #     localizable available: %i[en fr de], default: :en
    #     # localizable param: :lang, header: false   # params[:lang] only
    #   end
    #
    # Resolution order: `params[param]` → first match in `Accept-Language` →
    # `default` → `I18n.default_locale`. The chosen locale is always validated
    # against `I18n.available_locales` before use, so a stray param or a
    # mismatched `available:` list can never raise `I18n::InvalidLocale`.
    #
    # Options: `available:` (allow-list for param/header matching; defaults to
    # `I18n.available_locales`), `default:`, `param:` (default `:locale`),
    # `header:` (default `true`).
    module Localizable
      extend ActiveSupport::Concern

      included do
        class_attribute :localizable_options, instance_accessor: false, default: {}
        around_action :switch_locale
      end

      class_methods do
        def localizable(available: nil, default: nil, param: :locale, header: true)
          self.localizable_options = {
            available: available&.map(&:to_sym),
            default: default&.to_sym,
            param: param&.to_sym,
            header: header
          }
        end
      end

      # Public so subclasses can override; runs the action under the resolved locale.
      def switch_locale(&)
        I18n.with_locale(resolved_locale, &)
      end

      # The locale chosen for this request — always one I18n can switch to.
      def resolved_locale
        opts = self.class.localizable_options
        allowed = opts[:available].presence || I18n.available_locales
        candidate = locale_from_param(opts, allowed) || locale_from_header(opts, allowed) || opts[:default]

        candidate && I18n.available_locales.include?(candidate.to_sym) ? candidate.to_sym : I18n.default_locale
      end

      private

      def locale_from_param(opts, allowed)
        return nil unless opts[:param] && respond_to?(:params) && params

        match_locale(params[opts[:param]], allowed)
      end

      def locale_from_header(opts, allowed)
        return nil unless opts[:header]

        header = accept_language_header
        header.blank? ? nil : parse_accept_language(header, allowed)
      end

      def accept_language_header
        return nil unless respond_to?(:request)

        req = request
        req.respond_to?(:headers) ? req.headers["Accept-Language"] : nil
      end

      def parse_accept_language(header, allowed)
        ranked = header.split(",").filter_map do |part|
          token, *params = part.split(";").map(&:strip)
          quality = accept_language_quality(params)
          next if quality <= 0.0

          lang = token.to_s.split("-").first
          lang.present? ? [lang, quality] : nil
        end
        # Honor client preference order (RFC 7231): highest q first.
        ranked.sort_by { |(_lang, quality)| -quality }.each do |(lang, _quality)|
          match = match_locale(lang, allowed)
          return match if match
        end
        nil
      end

      # The q-value (relative quality) of an Accept-Language part: 1.0 when
      # absent, 0.0 when malformed. q=0 means "not acceptable" and is dropped.
      def accept_language_quality(params)
        qparam = params.find { |p| p.start_with?("q=") }
        return 1.0 unless qparam

        Float(qparam[2..], exception: false) || 0.0
      end

      def match_locale(candidate, allowed)
        return nil if candidate.blank?

        wanted = candidate.to_s.downcase
        allowed.find { |loc| loc.to_s.downcase == wanted }
      end
    end
  end
end
