module ConcernsOnRails
  module Support
    # Guards against query-param type confusion. A client can make any params
    # value an Array (`?page[]=1`) or a nested hash (`?page[x]=1`, which Rails
    # exposes as ActionController::Parameters); calling `.to_i` on those — or
    # passing them to `.where` — raises and surfaces as a 500. Controller
    # concerns route untrusted param reads through here instead.
    module ScalarParam
      # Absolute upper bound on a resolved per_page, whatever the paginator's
      # configured cap says. per_page is untrusted input that becomes LIMIT;
      # `max_per_page: 0` is documented as "no cap", and with no cap
      # `?per_page=99999999999999999999` overflowed LIMIT — an unauthenticated
      # 500. "No cap" means no CONFIGURED cap, not an unbounded LIMIT; a page
      # of a million records is already far past what any client can render.
      MAX_PER_PAGE = 1_000_000

      module_function

      # The per_page resolver shared by Paginatable and CursorPaginatable, so
      # the two cannot drift again (the cursor paginator's private copy never
      # got the ceiling above). A positive integer request wins; anything else
      # — missing, non-positive, garbage, Array/Parameters — falls back to
      # `default`. A positive `cap` then applies (0 or negative = no configured
      # cap), and the absolute MAX_PER_PAGE ceiling applies last, even when a
      # cap IS configured: `max_per_page: 10**30` is its own way of asking for
      # the overflow back.
      def per_page(value, default:, cap:)
        requested = to_i(value, default: 0)
        requested = default if requested < 1
        requested = [requested, cap].min if cap.positive?
        [requested, MAX_PER_PAGE].min
      end

      # A single scalar value, safe for `.to_i` / string coercion.
      def scalar?(value)
        value.is_a?(String) || value.is_a?(Numeric)
      end

      # Safe to pass to `.where(column: value)`: scalars and nil are fine, and
      # Arrays become `IN (...)` — but only when every member is itself
      # where-safe (`?status[][x]=1` yields `[Parameters]`, which AR cannot
      # quote). Hash-likes (Hash / ActionController::Parameters) are not safe.
      def where_safe?(value)
        return value.all? { |member| where_safe?(member) } if value.is_a?(Array)
        return false if value.is_a?(Hash)
        return false if defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters)

        true
      end

      # Coerce an untrusted param to Integer, falling back to `default` for
      # anything non-scalar (Array/Parameters/nil).
      def to_i(value, default: 0)
        scalar?(value) ? value.to_i : default
      end
    end
  end
end
