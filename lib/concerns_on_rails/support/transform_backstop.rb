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
      private_constant :OUTPUTS

      # Records that a transform just left `record[field]` holding its output.
      def self.wrote(record, field)
        outputs = record.instance_variable_get(OUTPUTS) || record.instance_variable_set(OUTPUTS, {})
        outputs[field.to_s] = record[field].dup
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
        klass.after_save :concerns_on_rails_forget_transform_outputs
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
          concerns_on_rails_forget_transform_outputs
          super
        end

        private

        def concerns_on_rails_forget_transform_outputs
          remove_instance_variable(OUTPUTS) if instance_variable_defined?(OUTPUTS)
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
