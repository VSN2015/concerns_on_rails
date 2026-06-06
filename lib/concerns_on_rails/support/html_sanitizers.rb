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
    end
  end
end
