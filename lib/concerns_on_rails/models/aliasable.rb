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
    #   * Subclasses inherit aliases. If a subclass redefines the source
    #     association, re-declare the alias there (re-declaring an existing
    #     alias is allowed and idempotent) so the query side picks up the
    #     new reflection.
    module Aliasable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Aliasable".freeze

      # Method stems per reflection type; %s is the association name. The
      # reload_/reset_ stems vary across the supported Rails range and
      # build_/create_ are skipped by Rails for polymorphic belongs_to, so
      # each SOURCE method is existence-checked before its delegator is made.
      SINGULAR_STEMS = ["%s", "%s=", "build_%s", "create_%s", "create_%s!", "reload_%s", "reset_%s"].freeze
      COLLECTION_STEMS = ["%s", "%s="].freeze

      included do
        # Guarded so re-including the concern (e.g. ApplicationRecord and a
        # model both include it) cannot reset an inherited, populated hash —
        # that would desync the #association override from the inherited
        # delegators and split the loaded caches.
        class_attribute :aliasable_aliases, instance_accessor: false, default: {} unless respond_to?(:aliasable_aliases)
      end

      module ClassMethods
        # Register `new_name` as a full alias of the existing association
        # `source_name`. Argument order mirrors `alias_method new, old`.
        # Callable many times; aliases of aliases collapse to the terminal
        # source; re-declaring an existing alias (the STI subclass path)
        # refreshes its reflection in place instead of raising.
        def alias_association(new_name, source_name)
          new_name = new_name.to_sym
          source = aliasable_aliases[source_name.to_sym] || source_name.to_sym # collapse alias-of-alias
          reflection = aliasable_validate!(new_name, source)
          method_map = aliasable_method_map(new_name, source, reflection)
          aliasable_check_collisions!(new_name, method_map) unless aliasable_aliases.key?(new_name)

          self.aliasable_aliases = aliasable_aliases.merge(new_name => source)
          aliasable_register_reflection(new_name, source, reflection)
          aliasable_define_methods(method_map)
          new_name
        end

        private

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

        # Sweeps the FULL derived method map (reader, writer, build_/create_/
        # create_!/reload_/reset_, X_ids pair) against existing associations,
        # methods, columns, and declared attributes (virtual attributes).
        def aliasable_check_collisions!(new_name, method_map)
          raise ArgumentError, "#{LABEL}: '#{new_name}' is already an association on #{name}" if reflect_on_association(new_name)

          schema = aliasable_schema_reachable?
          method_map.each_key { |meth| aliasable_check_method_collision!(meth, schema) }
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

        # class_name uses the lazy string (NOT src.klass.name — calling klass
        # at macro time raises NameError while the target class is unloaded).
        # belongs_to derives its FK from the association name, so the copy
        # must pin the source's FK (and foreign_type when polymorphic).
        # class_name is also pinned for has_many :through copies, whose klass
        # would otherwise re-derive from the alias name.
        def aliasable_copy_options(src)
          opts = src.options.dup
          opts[:class_name] ||= src.class_name.to_s unless src.polymorphic?
          if src.belongs_to?
            opts[:foreign_key] ||= src.foreign_key
            opts[:foreign_type] ||= src.foreign_type if src.polymorphic?
          end
          opts
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

        def aliasable_method_map(new_name, source, reflection)
          stems = reflection.collection? ? COLLECTION_STEMS : SINGULAR_STEMS
          map = stems.to_h { |stem| [format(stem, new_name), format(stem, source)] }
          if reflection.collection?
            alias_ids = "#{new_name.to_s.singularize}_ids"
            source_ids = "#{source.to_s.singularize}_ids"
            map[alias_ids] = source_ids
            map["#{alias_ids}="] = "#{source_ids}="
          end
          map
        end

        def aliasable_define_methods(method_map)
          method_map.each do |alias_method_name, source_method_name|
            next unless method_defined?(source_method_name)

            aliasable_delegate(alias_method_name, source_method_name)
          end
        end

        # Delegators (not alias_method) so the alias honors model overrides
        # of the source method, finds sources declared on a superclass, and
        # tracks later redefinitions. They live in
        # generated_association_methods — the same module Rails puts its own
        # association methods in — so a model can override an alias and call
        # super.
        def aliasable_delegate(alias_method_name, source_method_name)
          generated_association_methods.define_method(alias_method_name) do |*args, **kwargs, &block|
            __send__(source_method_name, *args, **kwargs, &block)
          end
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
