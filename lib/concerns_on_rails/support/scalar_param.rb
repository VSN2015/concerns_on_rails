module ConcernsOnRails
  module Support
    # Guards against query-param type confusion. A client can make any params
    # value an Array (`?page[]=1`) or a nested hash (`?page[x]=1`, which Rails
    # exposes as ActionController::Parameters); calling `.to_i` on those — or
    # passing them to `.where` — raises and surfaces as a 500. Controller
    # concerns route untrusted param reads through here instead.
    module ScalarParam
      module_function

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
