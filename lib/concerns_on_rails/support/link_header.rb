require "rack/utils"

module ConcernsOnRails
  module Support
    # RFC 8288 `Link` response header for the paginators: rebuilds the current
    # request URL with a few query params changed (`page=3`, `cursor=…`) and
    # appends `<url>; rel="next"` entries to the response — never clobbering a
    # Link header something else already set (Deprecatable's rel="deprecation",
    # CDN preload hints). Shared by Paginatable and CursorPaginatable.
    module LinkHeader
      module_function

      # True when the controller has a request the URLs can be rebuilt from.
      # The dependency-free FakeController has none, so emission is skipped.
      def available?(controller)
        return false unless controller.respond_to?(:request)

        request = controller.request
        %i[base_url path query_parameters].all? { |reader| request.respond_to?(reader) }
      end

      # The request's URL with `overrides` merged into its query string (a nil
      # value or a key in `drop:` removes that param). Existing params keep
      # their order; nested params survive via Rack's nested-query encoding.
      def url_for(request, drop: [], **overrides)
        query = request.query_parameters.to_h.transform_keys(&:to_s)
        overrides.each { |key, value| value.nil? ? query.delete(key.to_s) : query[key.to_s] = value.to_s }
        Array(drop).each { |key| query.delete(key.to_s) }

        base = "#{request.base_url}#{request.path}"
        query.empty? ? base : "#{base}?#{Rack::Utils.build_nested_query(query)}"
      end

      # `links` is { rel => url }; nil urls are skipped and nothing is set when
      # none remain. Appends to an existing Link header, comma-separated.
      def append(response, links)
        entries = links.filter_map { |rel, url| %(<#{url}>; rel="#{rel}") if url }
        return if entries.empty?

        existing = response.headers["Link"]
        response.set_header("Link", [existing, entries.join(", ")].reject { |part| part.nil? || part.empty? }.join(", "))
      end
    end
  end
end
