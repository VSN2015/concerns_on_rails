module ConcernsOnRails
  module Support
    # Shared naming for concerns that generate affixable scopes or accessors.
    #
    # Two concerns that each define `.active` (SoftDeletable, Activatable,
    # Expirable) can coexist on one model only if their generated names can be
    # renamed, so every such concern takes `prefix:`/`suffix:` and routes the
    # name through here rather than re-implementing the join.
    module Affix
      module_function

      # `[prefix, base, suffix]`, underscore-joined, as a Symbol.
      def name(base, prefix: nil, suffix: nil)
        [prefix, base, suffix].compact.join("_").to_sym
      end

      # Normalize an affix option: `true` means "use the configured field
      # name" (Stateable's semantics, generalized to every affixing concern),
      # a String/Symbol is used literally, and nil/false means no affix.
      def normalize(option, default:)
        return nil unless option

        option == true ? default.to_s : option.to_s
      end

      # Define affixed twins of a concern's instance predicates on `klass`:
      # `{ active: :expirable_live? }` with `prefix: "term"` defines
      # `term_active?`, which calls the concern's private `expirable_live?`
      # (never the public plain predicate, which another concern included
      # later may have replaced). A no-op without an affix. The methods live
      # in a fresh module included into `klass` — the way Rails generates
      # attribute methods — so a predicate the model defines itself still
      # wins. Returns the defined names.
      #
      # Because that module sits ABOVE Rails' generated attribute methods, a
      # predicate named like a column's query method (`flag_active?` for a
      # boolean `flag_active` column) would silently shadow it; that raises
      # ArgumentError at macro time instead. Re-declaring the macro retires
      # the predicates of the previous declaration (keyed by `label`, one
      # set per concern): the class's own earlier ones are removed, and a
      # subclass hides the ones it inherited without touching its parent.
      def define_predicates(klass, mapping, prefix:, suffix:, label:)
        predicates = affixed_predicates(mapping, prefix, suffix)
        check_predicate_collisions!(klass, predicates.keys, label)

        registry = predicate_registry(klass)
        inherited = retire_predicates!(klass, registry[label], label)
        stale = inherited ? inherited[:names] - predicates.keys : []
        if predicates.empty? && stale.empty?
          registry.delete(label)
          return []
        end

        registry[label] = { module: predicate_module(predicates, inherited, stale), names: predicates.keys }
        klass.include(registry[label][:module])
        predicates.keys
      end

      # { affixed_name? => private target }, or {} without an affix.
      def affixed_predicates(mapping, prefix, suffix)
        return {} unless prefix || suffix

        mapping.to_h { |base, target| [:"#{name(base, prefix: prefix, suffix: suffix)}?", target] }
      end

      # A fresh module defining `predicates` and hiding the `stale` names a
      # subclass inherited. undef_method needs the name reachable from the
      # module itself, so it includes the ancestor's module before hiding.
      def predicate_module(predicates, inherited, stale)
        mod = Module.new
        predicates.each { |predicate, target| mod.send(:define_method, predicate) { |*args| send(target, *args) } }
        mod.include(inherited[:module]) if stale.any?
        stale.each { |predicate| mod.send(:undef_method, predicate) }
        mod
      end

      # The class's OWN registry of affixed-predicate modules (an ivar, so
      # subclasses never share it).
      def predicate_registry(klass)
        klass.instance_variable_get(:@concerns_on_rails_affixed_predicates) ||
          klass.instance_variable_set(:@concerns_on_rails_affixed_predicates, {})
      end

      # Removes this class's own earlier predicates (returning nil), or
      # returns the nearest ancestor's registry entry — the predicates a new
      # declaration on this subclass must hide.
      def retire_predicates!(klass, own, label)
        if own
          own[:names].each do |predicate|
            own[:module].send(:remove_method, predicate) if own[:module].method_defined?(predicate, false)
          end
          return nil
        end

        klass.ancestors.drop(1).grep(Class).each do |ancestor|
          entry = ancestor.instance_variable_get(:@concerns_on_rails_affixed_predicates)&.[](label)
          return entry if entry
        end
        nil
      end

      def check_predicate_collisions!(klass, predicates, label)
        return if predicates.empty? || !predicate_schema_reachable?(klass)

        predicates.each do |predicate|
          attribute = predicate.to_s.chomp("?")
          next unless klass.attribute_names.include?(attribute) || klass.attribute_alias?(attribute)

          raise ArgumentError,
                "#{label}: the affix would define #{predicate}, which shadows the query method of the " \
                "'#{attribute}' column on #{klass.name || klass}. Choose a different prefix:/suffix:."
        end
      end

      # Mirrors ColumnGuard#schema_reachable?: skip the check (never raise)
      # while the schema cannot be inspected, e.g. during db:create.
      def predicate_schema_reachable?(klass)
        klass.table_exists?
      rescue ActiveRecord::ActiveRecordError
        false
      end

      # Snapshot the scopes a concern just defined on `klass`: a
      # name => UnboundMethod map, captured immediately after definition.
      # Names that aren't defined are skipped (a concern may generate a scope
      # only under some configurations).
      def capture(klass, names)
        singleton = klass.singleton_class
        names.each_with_object({}) do |base, acc|
          name = base.to_sym
          next unless singleton.method_defined?(name)

          acc[name] = singleton.instance_method(name)
        end
      end

      # Remove the default-named scopes recorded by `capture` so their affixed
      # replacements are the only ones left. Returns the names removed.
      #
      # Three guards, all of which must pass before a name is removed:
      #   1. it is in the captured map (never a name the concern did not create);
      #   2. it is owned by THIS class's own singleton (never inherited);
      #   3. it is still the exact method captured (never a model's override).
      #
      # Guard 2 failing means the concern was configured on a parent and the
      # affix is being declared on a subclass — retiring nothing would hand
      # back an escape hatch that doesn't work, because the parent's colliding
      # scopes would survive. That raises instead.
      def retire!(klass, captured, label:)
        singleton = klass.singleton_class
        captured.each_with_object([]) do |(name, recorded), removed|
          next unless singleton.method_defined?(name)

          current = singleton.instance_method(name)
          retire_guard_owner!(current, singleton, klass, name, label)
          next unless current == recorded

          singleton.send(:remove_method, name)
          removed << name
        end
      end

      # Postfix private: keeps the public module_function methods above
      # callable as `Affix.foo` while hiding the helper.
      def retire_guard_owner!(current, singleton, klass, name, label)
        return if current.owner == singleton

        owner = current.owner.attached_object
        raise ArgumentError,
              "#{label}: cannot affix scopes on #{klass} because '#{name}' is defined on #{owner}. " \
              "Declare the prefix:/suffix: option on #{owner} itself — affixing here would leave " \
              "#{owner}'s unaffixed scopes in place and the collision unresolved."
      end
      private_class_method :retire_guard_owner!, :predicate_registry, :retire_predicates!,
                           :check_predicate_collisions!, :predicate_schema_reachable?,
                           :affixed_predicates, :predicate_module
    end
  end
end
