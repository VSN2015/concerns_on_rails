module ConcernsOnRails
  module Support
    # A relation the caller already LIMITed and/or OFFSET (`Player.order(:score).limit(10)`)
    # is a window: Paginatable pages INSIDE it (PARAMS-S2) instead of replacing
    # its LIMIT with the page's own. The two windows are combined arithmetically
    # on the caller's own relation, so ORDER, eager loading, STI, readonly and
    # identifier quoting stay exactly as Rails builds them.
    module CallerWindow
      module_function

      # True for a relation carrying a limit or a non-zero offset. A model
      # class, an Array and a duck-typed source have no window.
      def window?(relation)
        return false unless %i[limit_value offset_value].all? { |reader| relation.respond_to?(reader) }

        !relation.limit_value.nil? || offset_of(relation).positive?
      end

      def offset_of(relation)
        relation.offset_value.to_i
      end

      # Rows inside the window, given the unwindowed row count: max(0, min(L, N - O)).
      def rows_in(total, relation)
        rows = total - offset_of(relation)
        rows = [rows, relation.limit_value.to_i].min unless relation.limit_value.nil?
        [rows, 0].max
      end

      # [offset, limit] for the page starting `page_offset` rows into the
      # window. A limit of 0 is a page past the window's end.
      def page_window(relation, page_offset, per_page)
        limit = per_page
        limit = (relation.limit_value.to_i - page_offset).clamp(0, per_page) unless relation.limit_value.nil?
        [offset_of(relation) + page_offset, limit]
      end
    end
  end
end
