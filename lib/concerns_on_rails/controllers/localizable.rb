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
    # Every response carries `Content-Language: <resolved locale>` (BCP 47
    # form, `pt_BR` → `pt-BR`) and, when the header is a locale source,
    # `Vary: Accept-Language` appended to any existing Vary — written before
    # the action runs, so a rescued error still carries them. Both are behind
    # `response_headers:` (default `true`).
    #
    # Options: `available:` (allow-list for param/header matching; defaults to
    # `I18n.available_locales`), `default:`, `param:` (default `:locale`),
    # `header:` (default `true`), `response_headers:` (default `true`).
    module Localizable
      extend ActiveSupport::Concern

      included do
        class_attribute :localizable_options, instance_accessor: false, default: {}
        around_action :switch_locale
      end

      class_methods do
        def localizable(available: nil, default: nil, param: :locale, header: true, response_headers: true)
          self.localizable_options = {
            available: available&.map(&:to_sym),
            default: default&.to_sym,
            param: param&.to_sym,
            header: header,
            response_headers: response_headers ? true : false
          }
        end
      end

      # Public so subclasses can override; writes the response headers, then
      # runs the action under the resolved locale.
      def switch_locale(&)
        locale = resolved_locale
        apply_locale_response_headers(locale)
        I18n.with_locale(locale, &)
      end

      # The locale chosen for this request — always one I18n can switch to.
      # Memoized per request (the wrapper plus any helpers may read it several
      # times; parsing the Accept-Language header repeatedly is waste).
      def resolved_locale
        @resolved_locale ||= begin
          opts = self.class.localizable_options
          allowed = opts[:available].presence || I18n.available_locales
          candidate = locale_from_param(opts, allowed) || locale_from_header(opts, allowed) || opts[:default]

          candidate && I18n.available_locales.include?(candidate.to_sym) ? candidate.to_sym : I18n.default_locale
        end
      end

      private

      # Content-Language always; Vary: Accept-Language only when the header can
      # influence the choice (a param-only setup already differs by URL).
      # Vary is appended and de-duplicated, never clobbered (Cacheable, the
      # paginators' Link header — same rule).
      def apply_locale_response_headers(locale)
        return unless locale_response_headers?

        response.set_header("Content-Language", locale.to_s.tr("_", "-"))
        append_vary_accept_language if self.class.localizable_options.fetch(:header, true)
      end

      def locale_response_headers?
        opts = self.class.localizable_options
        return false if opts.key?(:response_headers) && !opts[:response_headers]

        respond_to?(:response) && response.respond_to?(:set_header)
      end

      def append_vary_accept_language
        existing = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
        response.set_header("Vary", (existing + ["Accept-Language"]).uniq.join(", "))
      end

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
        ranked_accept_languages(header).each do |lang|
          # Full tag first (fr-CA matches an available :"fr-CA"), then the
          # primary subtag (fr). Pre-1.22 the region was discarded outright,
          # so a regional locale in available: could never match its own
          # Accept-Language tag.
          match = match_locale(lang, allowed) || match_locale(lang.split("-").first, allowed)
          return match if match
        end
        nil
      end

      # Language tags from an Accept-Language header (kept whole — see
      # parse_accept_language for region handling), q=0 dropped, highest-q
      # first (RFC 7231 preference order).
      def ranked_accept_languages(header)
        pairs = header.split(",").filter_map do |part|
          token, *params = part.split(";").map(&:strip)
          quality = accept_language_quality(params)
          next if quality <= 0.0

          lang = token.to_s.strip
          [lang, quality] if lang.present?
        end
        pairs.sort_by { |(_lang, quality)| -quality }.map(&:first)
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
