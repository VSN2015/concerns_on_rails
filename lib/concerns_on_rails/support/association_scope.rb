module ConcernsOnRails
  module Support
    # An association's rows WITHOUT the target model's default scopes — for
    # the concern verbs that must reach every child a parent owns, not just
    # the ones the child's model shows by default (SoftDeletable's cascade,
    # Duplicable's deep copy).
    #
    # `record.association(name).scope` merges the target's default scopes
    # into the association's own conditions, so a child model declaring
    # `publishable_by ..., default_scope: true` hid its drafts: a cascade
    # soft-deleted only the published children, a deep copy silently dropped
    # the drafts. Peeling the default scope off afterwards is not possible —
    # its conditions are indistinguishable from the association's — so the
    # association scope is built inside `klass.unscoped { }`, where Rails
    # merges no default scope in the first place.
    #
    # What is kept: everything the association itself says — the foreign key,
    # the polymorphic type, the `-> { where ... }` scope on the declaration,
    # has_one's LIMIT 1 — and the STI type condition (part of the model's
    # base relation, not a default scope). The default scopes' ORDER is kept
    # too (only their filtering is dropped), so rows still come back in the
    # order the association would have returned them. For a :through
    # association only the TARGET's default scopes are dropped.
    module AssociationScope
      module_function

      def unfiltered(record, name)
        association = record.association(name)
        relation = association.klass.unscoped { association.scope }
        order = association.scope.order_values
        order.empty? || order == relation.order_values ? relation : relation.reorder(*order)
      end
    end
  end
end
