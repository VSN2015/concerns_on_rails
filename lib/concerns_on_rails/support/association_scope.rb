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
    # the drafts. Only the gem's own hiding predicates are removed: those on
    # the CHILD'S OWN TABLE's SoftDeletable column while its default scope is
    # on, and its Publishable column while `default_scope: true` is. Every
    # other predicate still applies, exactly as it does for Rails' own
    # `dependent:` — an application's tenant scope, a discriminator scope on
    # a shared table (`default_scope { where(kind: "image") }`), and a
    # same-named column of a JOINED table (`default_scope {
    # joins(:author).where(authors: { deleted_at: nil }) }`) — so a copy or
    # cascade never reaches another tenant's rows, a sibling association's,
    # or the comments of a deleted author. (Dropping every default scope —
    # building inside `klass.unscoped { }` — reached the first two;
    # `unscope(where: column)`, which matches a column by NAME on any table,
    # the third. Rails 6.0 cannot unscope by Arel attribute, so the where
    # clause is filtered here, with the attribute lookup unscope uses.)
    #
    # The association's OWN predicates on those columns (`has_many :live,
    # -> { where(deleted_at: nil) }`) are indistinguishable from the default
    # scope's in the merged relation, so they are put back: they come from
    # the association scope built inside `klass.unscoped { }`, where no
    # default scope is merged in. Everything else — the foreign key, the
    # polymorphic type, the STI type condition, the declared `-> { ... }`
    # scope, has_one's LIMIT 1, the default scopes' ORDER — is the
    # association's own relation, untouched.
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

        table = association.klass.arel_table
        own = predicates(own_where_clause(association)).select { |node| hiding?(node, table, columns) }
        hiding = predicates(relation.where_clause).select { |node| hiding?(node, table, columns) }
        peeled = without(relation, columns)
        peeled.where_clause += ActiveRecord::Relation::WhereClause.new(own) unless own.empty?
        rank_visible_first(peeled, hiding - own)
      end

      # `relation` minus its predicates on `columns` of its OWN table — the
      # table-qualified form of `unscope(where: columns)`, which also strips a
      # joined table's same-named column (see hiding?).
      def without(relation, columns)
        table = relation.klass.arel_table
        columns = Array(columns).map(&:to_s)
        peeled = relation.spawn
        peeled.where_clause = ActiveRecord::Relation::WhereClause.new(
          predicates(relation.where_clause).reject { |node| hiding?(node, table, columns) }
        )
        peeled
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

      # WhereClause keeps its predicate list protected (Rails 6.0 through 8.1).
      def predicates(where_clause)
        where_clause.send(:predicates)
      end

      # A predicate on one of `columns` of the child's own `table` — found the
      # way `unscope(where:)` finds a predicate's column (Arel.fetch_attribute:
      # comparisons, IN, IS NULL, and on Rails 6.1+ Groupings and OR/AND of
      # them), but matched on the attribute's TABLE as well as its name, so a
      # joined table's same-named column (or an aliased self-join) is kept.
      def hiding?(node, table, columns)
        Arel.fetch_attribute(node) { |attribute| attribute.relation == table && columns.include?(attribute.name.to_s) }
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

        shown = ActiveRecord::Relation::WhereClause.new(hidden).ast
        shown_first = Arel::Nodes::Case.new.when(shown).then(0).else(1)
        ranked = relation.spawn
        ranked.order_values = [shown_first, *relation.order_values]
        ranked
      end
    end
  end
end
