module ConcernsOnRails
  module Support
    # `Vary` response header maintenance for the per-request negotiation
    # concerns: Localizable (`Accept-Language`) and Timezoneable (`Time-Zone`).
    # Both write Vary BEFORE the action runs, so a rescued error still carries
    # it, and both must append to whatever Vary the response already has rather
    # than clobber it (Cacheable, the paginators' Link header — same rule).
    module VaryHeader
      module_function

      # Appends `dimensions` to the controller's Vary, de-duplicated
      # case-insensitively. Callers have already established that the response
      # can take a header.
      def append(controller, *dimensions)
        response = controller.response
        existing = dimensions_in(response.headers["Vary"])
        # `Vary: *` already means "never reuse this response for another
        # request" — it outranks every named dimension, so leave it as it is.
        return if existing.include?("*")

        merged = existing + rails_accept_dimension(controller) + dimensions.map(&:to_s)
        response.set_header("Vary", dedupe(merged).join(", "))
      end

      # The dimensions a Vary header value already advertises.
      def dimensions_in(value)
        value.to_s.split(",").map(&:strip).reject(&:empty?)
      end

      # Header names are case-insensitive; the first spelling seen wins, so an
      # existing `vary: accept` is never duplicated as `Accept`.
      def dedupe(values)
        values.each_with_object([]) do |value, list|
          list << value unless list.any? { |seen| seen.casecmp?(value) }
        end
      end

      # Rails adds its own `Vary: Accept` during render, but ONLY while the
      # header is still blank (ActionController::Rendering#_set_vary_header).
      # Writing ours first would therefore SUPPRESS it and cost a content-
      # negotiating action a cache dimension — a shared cache would then hand a
      # JSON body to an HTML request — so seed Accept ourselves whenever Rails
      # would have. No request at all (the FakeController harness): nothing to
      # seed. `#request` is looked up privately for the same reason `#cookies`
      # is: a controller may well declare it that way.
      def rails_accept_dimension(controller)
        return [] unless controller.respond_to?(:request, true) && (request = controller.send(:request))
        return [] unless request.respond_to?(:should_apply_vary_header?) && request.should_apply_vary_header?

        ["Accept"]
      end
    end
  end
end
