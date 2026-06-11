require "active_support/concern"

module ConcernsOnRails
  module Models
    # Alias an existing ActiveRecord association under a second name with
    # FULL support — read, write/assign, build/create, and the query side
    # (joins / includes / preload / eager_load / where hash conditions) —
    # not just a delegated reader. Rails' alias_attribute covers columns
    # only; there is no built-in way to alias an association.
    #
    #   class Book < ApplicationRecord
    #     include ConcernsOnRails::Aliasable
    #
    #     belongs_to :author
    #     has_many :chapters
    #
    #     alias_association :writer,   :author     # alias_method order: new, old
    #     alias_association :sections, :chapters
    #
    #     # Options:
    #     alias_association :penman, :author, only: :reader            # no writer/build_/create_
    #     alias_association :parts,  :chapters, except: :ids           # skip part_ids/part_ids=
    #     alias_association :owner,  :author, deprecated: "use #author"  # warns on use
    #     alias_association :maker,  :author, alias_foreign_key: true    # maker_id -> author_id
    #   end
    #
    #   book.writer                  # same cached object as book.author
    #   book.writer = user           # assigns through the original association
    #   book.build_writer(...)       # build_/create_/create_!/reload_ (singular)
    #   book.sections << chapter     # the same CollectionProxy as book.chapters
    #   book.section_ids             # ids reader/writer (collection)
    #   Book.joins(:writer)          # INNER JOIN "authors"
    #   Book.joins(:sections).where(sections: { title: "Intro" })
    #
    # Notes:
    #   * Declare alias_association AFTER the source association — it raises
    #     "does not exist" when the source has not been defined yet.
    #   * One loaded cache under two names: record.association(:alias) IS
    #     record.association(:source), and only the source macro installs
    #     callbacks — dependent:, counter_cache, autosave and validations
    #     run exactly once.
    #   * Query SQL: a bare joins(:sections) joins "chapters" directly; when
    #     paired with where(sections: {...}) Rails aliases the join as
    #     "sections" (INNER JOIN "chapters" "sections"). A where-hash key
    #     must match the name you joined under (same rule as stock Rails):
    #     joins(:sections).where(sections: {...}) works,
    #     joins(:chapters).where(sections: {...}) does not.
    #   * The belongs_to foreign-key attribute is NOT aliased — pair with
    #     Rails' alias_attribute (e.g. :writer_id, :author_id) if needed.
    #   * has_and_belongs_to_many cannot be aliased — use has_many :through.
    #   * has_many/has_one :through CAN be aliased (the copy pins `source:`
    #     so it is not re-derived from the alias name). One caveat: when the
    #     alias is declared before the through model's class has loaded AND
    #     the through model defines the source under a different name (e.g.
    #     belongs_to :author behind has_many :authors), declare `source:`
    #     explicitly on the original association.
    #   * Subclasses inherit aliases. If a subclass redefines the source
    #     association, re-declare the alias there (re-declaring with the SAME
    #     source is allowed and idempotent) so the query side picks up the
    #     new reflection. Repointing an existing alias at a DIFFERENT source
    #     raises.
    #   * only:/except: narrow the generated methods by group — :reader,
    #     :writer, :build, :reload (singular), :ids (collection). Groups that
    #     do not apply to the reflection type are ignored; the query side
    #     (joins/includes/where-hash) is always registered.
    #   * deprecated: true (or a String hint) makes every generated delegator
    #     warn through ConcernsOnRails.deprecator before delegating — the
    #     gradual-rename story: point the OLD name at the new association and
    #     deprecate it. The query side and alias_foreign_key attribute
    #     aliases do not warn.
    #   * alias_foreign_key: true (belongs_to only) also aliases the FK
    #     attribute via Rails' alias_attribute (<alias>_id, plus <alias>_type
    #     when polymorphic).
    module Aliasable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Aliasable".freeze

      # Method stems per reflection type, keyed by the only:/except: group
      # names; %s is the association name. The reload_/reset_ stems vary
      # across the supported Rails range and build_/create_ are skipped by
      # Rails for polymorphic belongs_to, so each SOURCE method is
      # existence-checked before its delegator is made. The :ids pair is
      # handled separately (it singularizes the association name).
      SINGULAR_STEM_GROUPS = {
        reader: ["%s"].freeze,
        writer: ["%s="].freeze,
        build: ["build_%s", "create_%s", "create_%s!"].freeze,
        reload: ["reload_%s", "reset_%s"].freeze
      }.freeze
      COLLECTION_STEM_GROUPS = {
        reader: ["%s"].freeze,
        writer: ["%s="].freeze
      }.freeze
      METHOD_GROUPS = %i[reader writer build reload ids].freeze

      included do
        # Guarded so re-including the concern (e.g. ApplicationRecord and a
        # model both include it) cannot reset an inherited, populated hash —
        # that would desync the #association override from the inherited
        # delegators and split the loaded caches. aliasable_alias_methods
        # records which delegators each alias defined, so a re-declare with
        # narrower only:/except: prunes the ones no longer wanted.
        unless respond_to?(:aliasable_aliases)
          class_attribute :aliasable_aliases, instance_accessor: false, default: {}
          class_attribute :aliasable_alias_methods, instance_accessor: false, default: {}
        end
      end

      module ClassMethods
        # Register `new_name` as a full alias of the existing association
        # `source_name`. Argument order mirrors `alias_method new, old`.
        # Callable many times; aliases of aliases collapse to the terminal
        # source; re-declaring an existing alias WITH THE SAME SOURCE (the
        # STI subclass path) refreshes its reflection in place instead of
        # raising, while repointing it at a different source raises — that is
        # almost always an accident, and the generated methods/reflection
        # would silently change meaning.
        # Options:
        #   only:/except: — narrow the generated method map by group
        #     (:reader, :writer, :build, :reload, :ids); inapplicable groups
        #     are ignored, unknown ones raise.
        #   deprecated: — true or a String hint; delegators warn through
        #     ConcernsOnRails.deprecator before delegating.
        #   alias_foreign_key: — belongs_to only; alias_attribute the FK
        #     (<alias>_id, plus <alias>_type when polymorphic).
        def alias_association(new_name, source_name, only: nil, except: nil, deprecated: nil, alias_foreign_key: false)
          new_name = new_name.to_sym
          source = aliasable_aliases[source_name.to_sym] || source_name.to_sym # collapse alias-of-alias
          aliasable_guard_repoint!(new_name, source)
          reflection = aliasable_validate!(new_name, source)
          aliasable_validate_foreign_key!(new_name, reflection) if alias_foreign_key
          aliasable_install(new_name, source, reflection,
                            groups: aliasable_method_groups(only, except),
                            deprecated: deprecated, alias_foreign_key: alias_foreign_key)
          new_name
        end

        private

        def aliasable_guard_repoint!(new_name, source)
          existing = aliasable_aliases[new_name]
          return unless existing && existing != source

          raise ArgumentError,
                "#{LABEL}: '#{new_name}' is already aliased to '#{existing}' (model: #{name}) — " \
                "repointing an alias is not allowed; remove the original declaration first"
        end

        def aliasable_install(new_name, source, reflection, groups:, deprecated:, alias_foreign_key:)
          method_map = aliasable_method_map(new_name, source, reflection, groups)
          unless aliasable_aliases.key?(new_name)
            sweep = method_map.keys
            sweep += aliasable_foreign_key_names(new_name, reflection) if alias_foreign_key
            aliasable_check_collisions!(new_name, sweep)
          end

          self.aliasable_aliases = aliasable_aliases.merge(new_name => source)
          aliasable_register_reflection(new_name, source, reflection)
          aliasable_define_methods(new_name, method_map, aliasable_deprecation_message(new_name, source, deprecated))
          aliasable_define_foreign_key_aliases(new_name, reflection) if alias_foreign_key
        end

        def aliasable_validate!(new_name, source)
          raise ArgumentError, "#{LABEL}: alias '#{new_name}' must differ from the source association" if new_name == source

          reflection = reflect_on_association(source)
          unless reflection
            raise ArgumentError,
                  "#{LABEL}: association '#{source}' does not exist (model: #{name}) — " \
                  "declare alias_association after the association"
          end
          # HABTM: Reflection.create cannot build habtm copies and the public
          # reflections rebuild drops parent_reflection children — reject.
          if reflection.macro == :has_and_belongs_to_many ||
             (reflection.respond_to?(:parent_reflection) && reflection.parent_reflection)
            raise ArgumentError, "#{LABEL}: has_and_belongs_to_many associations cannot be aliased — use has_many :through"
          end

          reflection
        end

        # only:/except: narrow generation by named group. Unknown names
        # raise; names that don't apply to the reflection type (e.g. :build
        # on a collection) are ignored so one declaration can serve both
        # shapes.
        def aliasable_method_groups(only, except)
          raise ArgumentError, "#{LABEL}: pass only: or except:, not both" if only && except

          requested = (Array(only) + Array(except)).map(&:to_sym)
          unknown = requested - METHOD_GROUPS
          if unknown.any?
            raise ArgumentError,
                  "#{LABEL}: unknown method group(s): #{unknown.join(', ')} (valid: #{METHOD_GROUPS.join(', ')})"
          end
          return METHOD_GROUPS - requested if except

          only ? requested : METHOD_GROUPS
        end

        def aliasable_validate_foreign_key!(new_name, reflection)
          return if reflection.belongs_to?

          raise ArgumentError,
                "#{LABEL}: alias_foreign_key: is only supported for belongs_to associations " \
                "('#{new_name}' aliases a #{reflection.macro})"
        end

        # Sweeps every name the declaration would generate (the configured
        # method map plus the alias_foreign_key attribute pair) against
        # existing associations, methods, columns, and declared attributes
        # (virtual attributes).
        def aliasable_check_collisions!(new_name, method_names)
          raise ArgumentError, "#{LABEL}: '#{new_name}' is already an association on #{name}" if reflect_on_association(new_name)

          schema = aliasable_schema_reachable?
          method_names.each { |meth| aliasable_check_method_collision!(meth, schema) }
        end

        def aliasable_check_method_collision!(meth, schema)
          attr_name = meth.to_s.delete_suffix("!").delete_suffix("=")
          if schema && (column_names.include?(attr_name) || attribute_types.key?(attr_name))
            raise ArgumentError, "#{LABEL}: '#{attr_name}' is already a column or attribute on #{name} (table: #{table_name})"
          end
          return unless method_defined?(meth) || private_method_defined?(meth)

          raise ArgumentError, "#{LABEL}: '#{meth}' is already defined as a method on #{name}"
        end

        # Column collisions can only be checked against a live schema. Class
        # loading without a database (rake db:create, assets:precompile) must
        # not crash, so the column/attribute sweep is best-effort. The rescue
        # is scoped to AR's own error hierarchy (no connection, no database,
        # statement errors) — a NameError/NoMethodError from a real bug must
        # still surface.
        def aliasable_schema_reachable?
          table_exists?
        rescue ActiveRecord::ActiveRecordError
          false
        end

        # Register a RENAMED COPY of the source reflection under the alias.
        # Registering the same object does NOT work: PredicateBuilder aliases
        # the arel table to the where-hash key while JoinDependency names the
        # JOIN after reflection.name, so a shared object yields `JOIN "books"`
        # + `WHERE "works"...` — invalid SQL. With the renamed copy the two
        # agree (`INNER JOIN "books" "works"` when the where-hash references
        # the alias), and the #association override below keeps the copy on
        # the source's loaded cache. Reflection.create builds metadata only —
        # it installs no callbacks, autosave, or validations, so side effects
        # never run twice.
        def aliasable_register_reflection(new_name, source, src)
          renamed = ActiveRecord::Reflection.create(src.macro, new_name, src.scope, aliasable_copy_options(src), self)
          # _reflections is String-keyed on Rails <= 7.x and Symbol-keyed on
          # newer releases — probe the source's own entry, never hardcode.
          key = _reflections.key?(source.to_s) ? new_name.to_s : new_name
          # class_attribute writer: a subclass call never mutates the parent.
          self._reflections = _reflections.merge(key => renamed)
          aliasable_clear_reflection_caches
        end

        # Every option a reflection copy would re-derive from the ALIAS name
        # must be pinned to what the source derived.
        #   * through: pin :source (Rails derives it from the association
        #     name — the copy would look for the alias on the through model).
        #     class_name is NOT touched: ThroughReflection#class_name resolves
        #     the source-reflection chain eagerly, raising NameError at macro
        #     time while the through/target classes are still unloaded, and
        #     with :source pinned the copy derives its klass correctly anyway.
        #   * direct: pin class_name via the lazy string (NOT src.klass.name —
        #     calling klass at macro time raises NameError while the target
        #     class is unloaded). belongs_to also derives its FK from the
        #     association name, so pin foreign_key (and foreign_type when
        #     polymorphic).
        def aliasable_copy_options(src)
          opts = src.options.dup
          if opts[:through]
            opts[:source] ||= aliasable_through_source_name(src)
          else
            aliasable_pin_direct_options!(opts, src)
          end
          opts
        end

        def aliasable_pin_direct_options!(opts, src)
          opts[:class_name] ||= src.class_name.to_s unless src.polymorphic?
          return unless src.belongs_to?

          opts[:foreign_key] ||= src.foreign_key
          opts[:foreign_type] ||= src.foreign_type if src.polymorphic?
        end

        # Exact resolution (src.source_reflection.name) handles sources the
        # through model defines under a different form (e.g. belongs_to
        # :author behind has_many :authors), but it loads the through class —
        # impossible while classes are still loading. Fall back to the source
        # association's own name, Rails' derivation anchor; a lazily-loading
        # app whose source lives under a different name must declare `source:`
        # on the original association (standard Rails practice).
        def aliasable_through_source_name(src)
          src.source_reflection&.name || src.name
        rescue NameError, ActiveRecord::ActiveRecordError
          src.name
        end

        # The memoized reflections cache is per-class; descendants that have
        # already memoized would otherwise stay stale (this matters on the
        # re-declare-in-a-subclass path). respond_to? guard: private method,
        # presence varies across the supported range.
        def aliasable_clear_reflection_caches
          ([self] + descendants).each do |klass|
            klass.send(:clear_reflections_cache) if klass.respond_to?(:clear_reflections_cache, true)
          end
        end

        def aliasable_method_map(new_name, source, reflection, groups)
          stem_groups = reflection.collection? ? COLLECTION_STEM_GROUPS : SINGULAR_STEM_GROUPS
          map = {}
          stem_groups.each do |group, stems|
            next unless groups.include?(group)

            stems.each { |stem| map[format(stem, new_name)] = format(stem, source) }
          end
          aliasable_add_ids_pair(map, new_name, source) if reflection.collection? && groups.include?(:ids)
          map
        end

        def aliasable_add_ids_pair(map, new_name, source)
          alias_ids = "#{new_name.to_s.singularize}_ids"
          source_ids = "#{source.to_s.singularize}_ids"
          map[alias_ids] = source_ids
          map["#{alias_ids}="] = "#{source_ids}="
        end

        # Defines the configured delegators and prunes ones a previous,
        # broader declaration of this alias created (a re-declare narrowing
        # only:/except: must not leave stale methods behind). Only methods
        # this class's OWN generated_association_methods defined are pruned —
        # a parent's declaration is never touched from a subclass.
        def aliasable_define_methods(new_name, method_map, deprecation)
          aliasable_prune_stale_delegators(new_name, method_map)
          defined = method_map.filter_map do |alias_method_name, source_method_name|
            next unless method_defined?(source_method_name)

            aliasable_delegate(alias_method_name, source_method_name, deprecation)
            alias_method_name
          end
          self.aliasable_alias_methods = aliasable_alias_methods.merge(new_name => defined)
        end

        def aliasable_prune_stale_delegators(new_name, method_map)
          stale = (aliasable_alias_methods[new_name] || []) - method_map.keys
          mod = generated_association_methods
          stale.each { |meth| mod.send(:remove_method, meth) if mod.method_defined?(meth, false) }
        end

        # Delegators (not alias_method) so the alias honors model overrides
        # of the source method, finds sources declared on a superclass, and
        # tracks later redefinitions. They live in
        # generated_association_methods — the same module Rails puts its own
        # association methods in — so a model can override an alias and call
        # super. A deprecated alias warns once per call, BEFORE delegating,
        # so the warning fires even when the source raises.
        def aliasable_delegate(alias_method_name, source_method_name, deprecation)
          generated_association_methods.define_method(alias_method_name) do |*args, **kwargs, &block|
            ConcernsOnRails.deprecator.warn(deprecation) if deprecation
            __send__(source_method_name, *args, **kwargs, &block)
          end
        end

        # Computed once at macro time; true gives the generic message and a
        # String is appended as the migration hint. Query-side use and the
        # alias_foreign_key attribute aliases do not warn — only delegators.
        def aliasable_deprecation_message(new_name, source, deprecated)
          return nil if deprecated.nil? || deprecated == false

          base = "#{name}##{new_name} is a deprecated alias of ##{source}"
          deprecated.is_a?(String) ? "#{base} — #{deprecated}" : base
        end

        def aliasable_foreign_key_names(new_name, reflection)
          names = ["#{new_name}_id", "#{new_name}_id="]
          names.push("#{new_name}_type", "#{new_name}_type=") if reflection.polymorphic?
          names
        end

        # alias_attribute, not delegators: the FK is a real column, and Rails
        # resolves attribute aliases in attribute APIs and where-hashes.
        def aliasable_define_foreign_key_aliases(new_name, reflection)
          alias_attribute :"#{new_name}_id", reflection.foreign_key.to_sym
          alias_attribute :"#{new_name}_type", reflection.foreign_type.to_sym if reflection.polymorphic?
        end
      end

      # Route the alias to the source association proxy so
      # record.association(:alias) IS record.association(:source) — one
      # loaded cache. Load-bearing for the preloader, which assigns loaded
      # records via record.association(reflection.name) using the alias's
      # renamed reflection.
      def association(name)
        super(self.class.aliasable_aliases[name.to_sym] || name)
      end
    end
  end
end
