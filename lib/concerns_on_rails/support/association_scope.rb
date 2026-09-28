module ConcernsOnRails
  module Support
    # An association's rows with only the GEM'S OWN hiding predicates peeled
    # off — for the concern verbs that must reach every child a parent owns,
    # not just the ones the child's model shows by default (SoftDeletable's
    # cascade, Duplicable's deep copy).
    #
    # `record.association(name).scope` merges the target's default scopes
    # into the association's own conditions, so a child model declaring
    # `publishable_by ..., default_scope: true` hid its drafts: a cascade
    # soft-deleted only the published children, a deep copy silently dropped
    # the drafts. Only those predicates are removed — SoftDeletable's column
    # while its default scope is on, Publishable's while `default_scope: true`
    # is — with `unscope(where: column)`, the way SoftDeletable's own
    # `with_deleted` / `soft_delete_without_default_scope` peel theirs. Every
    # OTHER default scope still applies, exactly as it does for Rails' own
    # `dependent:`: an application's tenant scope or a discriminator scope on
    # a shared table (`default_scope { where(kind: "image") }`) is honoured,
    # so a copy or cascade never reaches another tenant's rows or a sibling
    # association's. (Dropping every default scope — building inside
    # `klass.unscoped { }` — did both.)
    #
    # `unscope(where:)` also strips the association's OWN predicates on those
    # columns (`has_many :live, -> { where(deleted_at: nil) }`), so they are
    # put back: they come from the association scope built inside
    # `klass.unscoped { }`, where no default scope is merged in. Everything
    # else — the foreign key, the polymorphic type, the STI type condition,
    # the declared `-> { ... }` scope, has_one's LIMIT 1, the default scopes'
    # ORDER — is the association's own relation, untouched.
    #
    # A LIMITed association (has_one, or a has_many declaring a limit) ranks
    # the rows its reader shows first: peeling a hiding predicate would
    # otherwise let the LIMIT pick a hidden draft (a lower id) over the child
    # `parent.cover` returns. A hidden row is picked only when the reader
    # returns fewer rows than the limit. (Not for a DISTINCT relation, whose
    # ORDER BY may only name selected expressions on PostgreSQL.)
    module AssociationScope
      module_function

      def unfiltered(record, name)
        association = record.association(name)
        relation = association.scope
        columns = hiding_columns(association.klass)
        return relation if columns.empty?

        own = on_columns(own_where_clause(association), columns)
        hidden = on_columns(relation.where_clause, columns) - own
        peeled = relation.unscope(where: columns)
        peeled.where_clause += own unless own.empty?
        rank_visible_first(peeled, hidden)
      end

      # The columns whose default-scope predicate is the gem's own: the
      # SoftDeletable stamp while its default scope is on, the Publishable
      # column while `default_scope: true` is.
      def hiding_columns(klass)
        columns = []
        columns << klass.soft_delete_field if klass.respond_to?(:soft_delete_field) && klass.soft_delete_default_scope
        columns << klass.publishable_field if klass.respond_to?(:publishable_field) && klass.publishable_default_scope
        columns.map(&:to_s).uniq
      end

      # The predicates of `where_clause` on `columns` (by name, as
      # `unscope(where:)` matches them).
      def on_columns(where_clause, columns)
        where_clause - where_clause.except(*columns)
      end

      # The association's own conditions, no default scope merged in. Rails
      # memoizes the association's own half of the scope (@association_scope),
      # and a declared lambda that reaches the target model
      # (`-> { merge(Child.where(...)) }`) picks up the default scope in force
      # when it is first built — so the memo is reset before building inside
      # `unscoped` (an earlier normal read must not leak its default scope in)
      # and after (ours must not leak into a later read).
      def own_where_clause(association)
        association.reset_scope
        association.klass.unscoped { association.scope }.where_clause
      ensure
        association.reset_scope
      end

      def rank_visible_first(relation, hidden)
        return relation if hidden.empty? || relation.limit_value.nil? || relation.distinct_value

        shown_first = Arel::Nodes::Case.new.when(hidden.ast).then(0).else(1)
        ranked = relation.spawn
        ranked.order_values = [shown_first, *relation.order_values]
        ranked
      end
    end
  end
end
