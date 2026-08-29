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
      private_class_method :retire_guard_owner!
    end
  end
end
