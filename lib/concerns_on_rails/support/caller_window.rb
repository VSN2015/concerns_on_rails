module ConcernsOnRails
  module Support
    # A relation the caller already LIMITed and/or OFFSET (`Player.order(:score).limit(10)`)
    # is a window: the paginators work INSIDE it (PARAMS-S2) instead of
    # replacing its LIMIT with their own. The window becomes a derived table
    # aliased as the model's own table, so every column reference the
    # paginator builds keeps resolving, and the paginator's own WHERE / ORDER /
    # LIMIT go on the outer query. Shared by Paginatable and CursorPaginatable.
    module CallerWindow
      module_function

      # True for a relation carrying a limit or a non-zero offset. A model
      # class, an Array and a duck-typed source have no window.
      def window?(relation)
        return false unless %i[limit_value offset_value].all? { |reader| relation.respond_to?(reader) }

        !relation.limit_value.nil? || !(relation.offset_value.nil? || relation.offset_value.to_s == "0")
      end

      # An unwindowed row count bounded by what the window can hold.
      def clamp(count, relation)
        count -= relation.offset_value.to_i
        count = [count, relation.limit_value.to_i].min unless relation.limit_value.nil?
        [count, 0].max
      end

      # `FROM (<relation>) <table>` as an unscoped relation of the same model
      # (the inner one already applied every scope). Eager loading stays inside
      # (its JOINs shape the rows); a plain includes/preload and `extending`
      # move outside so the page's records get them. No ORDER: the caller
      # decides what to repeat outside.
      def derive(relation)
        eager = relation.eager_loading?
        inner = eager ? relation : relation.except(:includes, :preload)
        outer = relation.klass.unscoped.from(inner, relation.klass.table_name)
        outer = outer.preload(*relation.preload_values) if relation.preload_values.any?
        outer = outer.includes(*relation.includes_values) if !eager && relation.includes_values.any?
        outer = outer.extending(*relation.extending_values) if relation.extending_values.any?
        outer
      end
    end
  end
end
