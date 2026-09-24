require "active_support/concern"

begin
  require "rails-html-sanitizer"
rescue LoadError
  # rails-html-sanitizer ships transitively via actionview in every Rails app
  # (actionview -> rails-html-sanitizer -> loofah), so this require is purely
  # defensive for the rare host that pins an unusually old actionview. If the
  # library is genuinely absent, referencing a sanitizer below raises a clear
  # NameError at first use rather than at gem load.
end

module ConcernsOnRails
  module Support
    # Memoized, feature-detected HTML sanitizer instances shared by the
    # sanitizing concerns (currently Models::Sanitizable).
    #
    # Picks the HTML5 parser (Rails::HTML5::*, the default since Rails 7.1, so
    # it matches the host app's own ActionView sanitize/strip_tags output) when
    # the platform supports it, and otherwise falls back to HTML4 (libgumbo /
    # HTML5 is unavailable on JRuby) — mirroring Rails core.
    #
    # The namespace decision and each sanitizer are built lazily on first use,
    # so libgumbo / ActionView is never probed at file-load time, and the
    # instances are reused (they are thread-safe for #sanitize) rather than
    # re-allocated per attribute access.
    #
    # We reference Rails::HTML5 / Rails::HTML4 explicitly: the bare
    # Rails::HTML::* aliases silently resolve to the HTML4 implementation.
    module HtmlSanitizers
      module_function

      def namespace
        @namespace ||=
          if defined?(Rails::HTML::Sanitizer) &&
             Rails::HTML::Sanitizer.respond_to?(:html5_support?) &&
             Rails::HTML::Sanitizer.html5_support?
            Rails::HTML5
          else
            Rails::HTML4
          end
      end

      # Removes every tag, keeping the inner text. The safe default and the
      # only sanitizer appropriate for a destructive write (it cannot
      # reintroduce markup).
      def full
        @full ||= namespace::FullSanitizer.new
      end

      # Rails' curated allow-list: keeps formatting tags (em / strong / a / p…),
      # drops <script> / <iframe>, and neutralizes javascript: URLs.
      def safe
        @safe ||= namespace::SafeListSanitizer.new
      end

      # Strips only <a> tags, keeping their visible text and other markup.
      def link
        @link ||= namespace::LinkSanitizer.new
      end

      # The entities FullSanitizer's text serializer emits, besides &lt; / &gt;
      # (HTML5 emits &amp; and &nbsp;; the quote forms cover the HTML4 path).
      PLAIN_TEXT_DECODED = { "nbsp" => " ", "quot" => '"', "#34" => '"', "apos" => "'", "#39" => "'" }.freeze

      # The HTML5 named references a parser decodes WITHOUT a trailing ";"
      # (WHATWG's legacy list): "&copyright" reads back as "©right".
      LEGACY_REFERENCES = %w[
        AElig AMP Aacute Acirc Agrave Aring Atilde Auml COPY Ccedil ETH Eacute Ecirc Egrave Euml GT Iacute Icirc
        Igrave Iuml LT Ntilde Oacute Ocirc Ograve Oslash Otilde Ouml QUOT REG THORN Uacute Ucirc Ugrave Uuml Yacute
        aacute acirc acute aelig agrave amp aring atilde auml brvbar ccedil cedil cent copy curren deg divide eacute
        ecirc egrave eth euml frac12 frac14 frac34 gt iacute icirc iexcl igrave iquest iuml laquo lt macr micro middot
        nbsp not ntilde oacute ocirc ograve ordf ordm oslash otilde ouml para plusmn pound quot raquo reg sect shy
        sup1 sup2 sup3 szlig thorn times uacute ucirc ugrave uml uuml yacute yen yuml
      ].freeze

      # What, after a bare "&", a parser may read back as a character
      # reference: anything numeric-looking ("#" — the HTML4/libxml2 parser
      # swallows even a digitless "&#"), any well-formed named one (the
      # longest HTML5 name is 31 characters), or a legacy semicolon-less
      # name. A static, bounded lookahead and deliberately an
      # over-approximation: calling a literal "&" a reference only keeps its
      # "&amp;" encoded, which is still stable, whereas the reverse would let
      # the stored value change on the next save.
      CHARACTER_REFERENCE = /#|[A-Za-z][A-Za-z0-9]{1,31};|#{Regexp.union(LEGACY_REFERENCES).source}/

      # One linear pass: the decodable entities, plus an "&amp;" only when
      # what follows could not turn the bare "&" back into a reference.
      PLAIN_TEXT_ENTITY = /&(nbsp|quot|apos|#39|#34);|&amp;(?!#{CHARACTER_REFERENCE.source})/

      # Removes every tag like #full, but returns PLAIN TEXT to store rather
      # than HTML-escaped text: "<b>Tom</b> & Jerry" => "Tom & Jerry", where
      # #full gives "Tom &amp; Jerry" (which output escaping would show as
      # "Tom &amp;amp; Jerry"). &lt; and &gt; are deliberately KEPT encoded,
      # so the value can never turn into markup, even when rendered with raw.
      #
      # The result re-sanitizes to itself (idempotent on re-save and in
      # sanitize_all!): an "&amp;" is only decoded when the bare "&" could not
      # be read back as a character reference — "R&amp;D" => "R&D", but a
      # literal "&amp;copy" stays encoded rather than becoming "©" next save.
      # Linear time: one parse, then one regex pass with a bounded lookahead
      # (this used to re-parse per ampersand, a DoS on "&a" * N). A carriage
      # return (only reachable through "&#13;") is normalized to "\n" up front,
      # as the parser would do to it on the next save.
      def plain_text(value)
        full.sanitize(value).to_s.gsub(PLAIN_TEXT_ENTITY) do
          entity = Regexp.last_match(1)
          entity ? PLAIN_TEXT_DECODED.fetch(entity) : "&"
        end.gsub(/\r\n?/, "\n")
      end
    end
  end
end
