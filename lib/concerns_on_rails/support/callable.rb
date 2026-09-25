module ConcernsOnRails
  module Support
    # Invokes a controller-concern option that the macro accepted because it
    # `respond_to?(:call)` — Throttleable's `by:`, WebhookVerifiable's
    # `secret:`, Deprecatable's `notify:`. The call sites used to
    # `instance_exec(&option)`, which only a Proc survives: any other callable
    # object passed validation at boot and then raised TypeError ("wrong
    # argument type ... (expected Proc)") on every matching request.
    #
    #   * a Proc (block, proc, lambda) is instance_exec'd on the controller,
    #     unchanged — `request` / `params` / `current_user` resolve inside it;
    #   * any other callable (an object with #call, a Method) is handed the
    #     controller — the receiver the Proc form sees as `self` — unless its
    #     #call takes no arguments, in which case it is called bare
    #     (`secret: SecretStore.method(:current)`).
    module Callable
      module_function

      def invoke(controller, callable)
        return controller.instance_exec(&callable) if callable.is_a?(Proc)

        takes_no_arguments?(callable) ? callable.call : callable.call(controller)
      end

      # A Method's own #call is variadic (arity -1), so ask the Method itself.
      def takes_no_arguments?(callable)
        (callable.is_a?(Method) ? callable : callable.method(:call)).arity.zero?
      rescue NameError # #call answered via method_missing only — hand it the controller
        false
      end
    end
  end
end
