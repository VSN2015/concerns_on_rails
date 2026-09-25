module ConcernsOnRails
  module Support
    # What a friendly_id `:slugged` model builds its slug from — shared by
    # Anonymizable (does erasing these fields have to rewrite the slug?) and
    # the Encryptable/Sluggable guards (a slug is the PLAINTEXT of its source,
    # so an encrypted field must never feed one).
    #
    # The gem's Sluggable: its `candidates:` (nested arrays flattened) when
    # given — they replace the sluggable field — else the sluggable field.
    # A bare friendly_id model: its base.
    module SlugSources
      module_function

      # Every declared source — Symbols/Strings (attribute or method names)
      # and opaque Procs alike. [] unless the model is friendly_id-slugged.
      def sources(klass)
        return [] unless slugged?(klass)
        return declared(klass.sluggable_field, klass.sluggable_candidates) if klass.respond_to?(:sluggable_field)

        Array(klass.friendly_id_config.base).flatten
      end

      # The source NAMES (Symbols) — Procs are opaque and left out.
      def names(klass)
        symbolize(sources(klass))
      end

      # Sluggable's source list for a given field + candidates, before either
      # is assigned (so a refused declaration never sticks).
      def declared(field, candidates)
        candidates ? Array(candidates).flatten : [field]
      end

      def symbolize(list)
        list.filter_map { |source| source.to_sym if source.is_a?(Symbol) || source.is_a?(String) }
      end

      def slugged?(klass)
        klass.respond_to?(:friendly_id_config) && klass.friendly_id_config.uses?(:slugged)
      end
    end
  end
end
