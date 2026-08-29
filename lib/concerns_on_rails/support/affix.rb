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
    end
  end
end
