module ConcernsOnRails
  module Support
    # Strips Unicode whitespace (and NUL, which String#strip also removed) from
    # both ends of a String — String#strip is ASCII-only, so a pasted no-break
    # or ideographic space survived it. Shared by Normalizable, Searchable,
    # Taggable and Money.
    #
    # The one-regex form (`gsub(/\A[[:space:]\0]+|[[:space:]\0]+\z/, "")`) had
    # to start a `[[:space:]]+\z` attempt at every position of an interior run
    # of spaces. Ruby 3.2's match cache keeps that from going quadratic, but
    # at about a microsecond per character: a 1 MB `"a" + " " * N + "b"` query
    # parameter cost ~1 s of CPU, and 3 MB of `"a b" * N` over 2 s. Two
    # anchored `\A` runs (the end is reached by reversing the String, whose
    # whitespace characters are all single code points) match each edge in one
    # pass and stop at the first non-space character.
    module EdgeSpace
      LEADING = /\A[[:space:]\0]+/
      LEADING_NO_NUL = /\A[[:space:]]+/

      module_function

      # A new String, like gsub returned. Raises ArgumentError on invalid byte
      # sequences, as the regex form did. `nul: false` leaves NUL alone
      # (Money's reader never stripped it).
      def strip(string, nul: true)
        edge = nul ? LEADING : LEADING_NO_NUL
        string.sub(edge, "").reverse.sub(edge, "").reverse
      end
    end
  end
end
