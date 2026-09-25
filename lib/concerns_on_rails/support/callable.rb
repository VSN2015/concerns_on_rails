module ConcernsOnRails
  module Support
    # Invokes a user-supplied option that the macro accepted because it
    # `respond_to?(:call)` — Throttleable's `by:`, WebhookVerifiable's
    # `secret:`, Deprecatable's `notify:` (receiver: the controller) and
    # CounterCacheable's `if:` (receiver: the record). The call sites used to
    # `instance_exec(&option)`, which only a Proc survives: any other callable
    # object passed validation at boot and then raised TypeError ("wrong
    # argument type ... (expected Proc)") on every request / save.
    #
    # Dispatch follows Throttleable's `if:` (and Rails' own before_action
    # conditionals), keyed on the Proc's arity:
    #
    #   * a zero-arity lambda (`-> { request.remote_ip }`) is instance_exec'd
    #     on the receiver, so its methods resolve inside it;
    #   * a block-style (non-lambda) Proc is instance_exec'd too, AND handed
    #     the receiver as its argument (`proc { |c| ... }`: self and c are both
    #     the receiver; a proc ignores arguments it does not declare);
    #   * a lambda that takes arguments (`->(c) { c.tenant }`) or a symbol proc
    #     (`:tenant_secret.to_proc`, a lambda of arity -2) is called with the
    #     receiver, keeping its own self;
    #   * any other callable (an object with #call, a Method) is called with
    #     the receiver, unless its #call takes no arguments, in which case it
    #     is called bare (`secret: SecretStore.method(:current)`).
    module Callable
      module_function

      def invoke(receiver, callable)
        return invoke_proc(receiver, callable) if callable.is_a?(Proc)

        arity(callable).zero? ? callable.call : callable.call(receiver)
      end

      def invoke_proc(receiver, callable)
        return receiver.instance_exec(receiver, &callable) unless callable.lambda?
        return receiver.instance_exec(&callable) if callable.arity.zero?

        callable.call(receiver)
      end

      # The arity of any callable: a Proc/Method answers directly (a Method's
      # own #call is variadic, arity -1), anything else through its #call;
      # -1 ("takes the receiver") when #call is answered via method_missing.
      def arity(callable)
        return callable.arity if callable.is_a?(Proc) || callable.is_a?(Method)

        callable.method(:call).arity
      rescue NameError
        -1
      end
    end
  end
end
