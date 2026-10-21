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
    # for a concern that compares against what IT produced rather than what
    # validation accepted (Normalizable): in a validated save it re-runs at
    # before_save when a later transform rewrote its field, and that re-run
    # has to come after the other backstops' checks, or they would see its
    # rewrite as a change of their own and run again.
    module TransformBackstop
      # The inheritable class_attributes holding the method names.
      LIST = :concerns_on_rails_transform_backstops
      SETTLES = :concerns_on_rails_transform_settles
      # The before_save callback that runs them.
      DISPATCHER = :concerns_on_rails_run_transform_backstops

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
      end

      def self.append(klass, list, name)
        names = klass.public_send(list)
        klass.public_send(:"#{list}=", ((names - [name]) + [name]).freeze)
      end
      private_class_method :register, :append

      # Instance side: the callback itself.
      module Dispatcher
        private

        def concerns_on_rails_run_transform_backstops
          klass = self.class
          klass.public_send(TransformBackstop::LIST).each { |backstop| send(backstop) }
          klass.public_send(TransformBackstop::SETTLES).each { |settle| send(settle) }
        end
      end
    end
  end
end
