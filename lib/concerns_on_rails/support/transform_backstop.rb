module ConcernsOnRails
  module Support
    # The ONE prepended before_save shared by the field-transform concerns
    # (Normalizable, Sanitizable, Taggable, Addressable) to transform the
    # saves that skip validation (update_attribute, save(validate: false)).
    #
    # Each concern used to prepend its own backstop. Every prepend goes to
    # the FRONT of the chain, so the backstops ran in REVERSE include order
    # while the before_validation passes run in include order: with two
    # transforms on one column, a validation-skipping save stored a value a
    # validated save never would. Now each concern hands its backstop method
    # to .install when it registers its before_validation pass, and one
    # prepended dispatcher runs the list in that order. The dispatcher itself
    # is prepended, so a sibling's earlier before_save (Encryptable's blind
    # index, Auditable's entry, Addressable's fingerprint) still sees the
    # value that gets stored.
    #
    # A `settle:` method runs after EVERY backstop, in the same order. It is
    # for Normalizable's last look at a field NO transform handled (a slug
    # friendly_id builds in a validate step, after Normalizable's pass), and it
    # has to come after the other backstops' checks, or they would see its
    # rewrite as a change of their own and run again.
    #
    # Every transform records what it WROTE into a field (`.wrote`), so a
    # later look can tell a sibling transform's output — never to be
    # transformed again by another concern: titleize turned Sanitizable's
    # "&lt;" into "&Lt;" — from a rewrite by code that is no transform. The
    # record belongs to one save: dropped once it succeeded (after_save) and
    # on reload, kept across a failed or halted one so a retry on the same
    # record finds it.
    module TransformBackstop
      # The inheritable class_attributes holding the method names.
      LIST = :concerns_on_rails_transform_backstops
      SETTLES = :concerns_on_rails_transform_settles
      # The before_save callback that runs them.
      DISPATCHER = :concerns_on_rails_run_transform_backstops
      OUTPUTS = :@concerns_on_rails_transform_outputs
      # The per-save records the transforms keep (what each produced, what
      # validation left): dropped once a save has run, restored if its
      # transaction then rolls back.
      SAVE_RECORDS = [
        :@normalizable_applied, :@normalizable_validated, :@sanitizable_applied, OUTPUTS
      ].freeze
      STASH = :@concerns_on_rails_transform_stash
      private_constant :OUTPUTS, :SAVE_RECORDS, :STASH

      # Records that a transform just left `record[field]` holding its output.
      def self.wrote(record, field)
        outputs = record.instance_variable_get(OUTPUTS) || {}
        record.instance_variable_set(OUTPUTS, outputs.merge(field.to_s => record[field].dup))
      end

      # Is `value` exactly what a transform last wrote into `field`?
      def self.wrote?(record, field, value)
        outputs = record.instance_variable_get(OUTPUTS)
        !outputs.nil? && outputs.key?(field.to_s) && outputs[field.to_s] == value
      end

      # Appends `backstop` (a private instance method) — and `settle`, when
      # given — to klass's lists, registering the dispatcher on the first call
      # in a class hierarchy. A subclass's writer gives it its own copy, so
      # the parent's lists are never touched. Calling again moves the name to
      # the end, just as re-registering a before_validation moves that
      # callback (Rails drops the duplicate and appends), so the two orders
      # stay the same.
      def self.install(klass, backstop, settle: nil)
        register(klass) unless klass.respond_to?(LIST)
        append(klass, LIST, backstop)
        append(klass, SETTLES, settle) if settle
      end

      def self.register(klass)
        [LIST, SETTLES].each do |name|
          klass.class_attribute name, instance_accessor: false, instance_predicate: false, default: [].freeze
        end
        klass.include(Dispatcher)
        klass.before_save DISPATCHER, prepend: true
        klass.after_save :concerns_on_rails_stash_transform_records
        # Rails 6.0 enrolls a record in the transaction (so `rolledback!` runs
        # at all) only when its class has a transactional callback.
        klass.after_rollback :concerns_on_rails_transform_enrolled if ActiveRecord.version < Gem::Version.new("6.1")
      end

      def self.append(klass, list, name)
        names = klass.public_send(list)
        klass.public_send(:"#{list}=", ((names - [name]) + [name]).freeze)
      end
      private_class_method :register, :append

      # Instance side: the callback itself.
      module Dispatcher
        # A reload throws the unsaved state away, the transforms' record of it
        # included.
        def reload(*)
          SAVE_RECORDS.each { |name| remove_instance_variable(name) if instance_variable_defined?(name) }
          remove_instance_variable(STASH) if instance_variable_defined?(STASH)
          super
        end

        # What the transaction's end decides: a commit makes the stash
        # pointless; a rollback restores attributes' dirty state but keeps the
        # values the transforms wrote, so their record has to come back too —
        # or a retry of the same record would transform its own output again.
        # The keywords differ across Rails 6.0-8.1: everything goes to super.
        def committed!(*, **, &)
          super
        ensure
          remove_instance_variable(STASH) if instance_variable_defined?(STASH)
        end

        def rolledback!(*, **, &)
          super
        ensure
          concerns_on_rails_restore_transform_records
        end

        # A copy starts from its own copy of the records (a shallow `dup` or
        # `clone` would share the Hashes the original keeps updating).
        def initialize_dup(other)
          super
          concerns_on_rails_own_transform_records
        end

        def initialize_clone(*, **)
          super
          concerns_on_rails_own_transform_records
        end

        private

        def concerns_on_rails_own_transform_records
          SAVE_RECORDS.each do |name|
            instance_variable_set(name, instance_variable_get(name).dup) if instance_variable_defined?(name)
          end
          remove_instance_variable(STASH) if instance_variable_defined?(STASH)
        end

        def concerns_on_rails_transform_enrolled; end

        # after_save: the save went through, so the next save cycle starts
        # afresh — but the records are kept aside until the transaction is
        # known to have committed.
        def concerns_on_rails_stash_transform_records
          stash = {}
          SAVE_RECORDS.each do |name|
            next unless instance_variable_defined?(name)

            stash[name] = instance_variable_get(name)
            remove_instance_variable(name)
          end
          instance_variable_set(STASH, stash)
        end

        def concerns_on_rails_restore_transform_records
          stash = instance_variable_defined?(STASH) ? remove_instance_variable(STASH) : nil
          stash&.each { |name, value| instance_variable_set(name, value) unless instance_variable_defined?(name) }
        end

        def concerns_on_rails_run_transform_backstops
          klass = self.class
          klass.public_send(TransformBackstop::LIST).each { |backstop| send(backstop) }
          klass.public_send(TransformBackstop::SETTLES).each { |settle| send(settle) }
        end
      end
    end
  end
end
