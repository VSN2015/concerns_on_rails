module ConcernsOnRails
  module Support
    # Invokes a user-supplied option that the macro accepted because it
    # `respond_to?(:call)` — Throttleable's `by:`, WebhookVerifiable's
    # `secret:`, Deprecatable's `notify:` (receiver: the controller),
    # CounterCacheable's `if:` and Auditable's `actor:` (receiver: the
    # record). The call sites used to `instance_exec(&option)`, which only a
    # Proc survives: any other callable object passed validation at boot and
    # then raised TypeError ("wrong argument type ... (expected Proc)") on
    # every request / save, and a `->(c)` lambda raised ArgumentError.
    #
    # Dispatch is arity-aware like Throttleable's `if:` (and Rails' own
    # before_action conditionals) but NOT identical to it: `if:` instance_execs
    # only an arity-0 Proc and passes the controller to everything else
    # (`->(*)`, `proc { |c| }` and every callable object included). Here every
    # Proc the old instance_exec could already run keeps running on the
    # receiver, and only what it could not run is called instead:
    #
    #   * a lambda with no REQUIRED parameter (`-> { request.remote_ip }`,
    #     `->(*) { ... }`, `->(c = nil) { ... }`) is instance_exec'd on the
    #     receiver, so its methods resolve inside it — as every Proc was
    #     before this dispatch existed;
    #   * a block-style (non-lambda) Proc is instance_exec'd too, AND handed
    #     the receiver as its argument (`proc { |c| ... }`: self and c are both
    #     the receiver; a proc ignores arguments it does not declare);
    #   * a lambda with a required parameter (`->(c) { c.tenant }`) or a
    #     symbol proc (`:tenant_secret.to_proc`, parameters [[:req], [:rest]])
    #     is called with the receiver, keeping its own self;
    #   * any other callable (an object with #call, a Method) is called with
    #     the receiver only when its #call REQUIRES an argument, like the
    #     lambda rule above; otherwise it is called bare — no parameters
    #     (`secret: SecretStore.method(:current)`) or only optional/forwarded
    #     ones (`def call(*)`, `def call(...)`, a delegate-generated Method,
    #     a #call answered by method_missing), which is how Auditable always
    #     called a non-Proc actor.
    module Callable
      module_function

      def invoke(receiver, callable)
        return invoke_proc(receiver, callable) if callable.is_a?(Proc)

        requires_argument?(arity(callable)) ? callable.call(receiver) : callable.call
      end

      # Method#arity: n > 0 required, or -(n + 1) for n required before a
      # splat — so -1 (optional/variadic only) requires nothing.
      def requires_argument?(arity)
        arity.positive? || arity < -1
      end

      def invoke_proc(receiver, callable)
        return receiver.instance_exec(receiver, &callable) unless callable.lambda?
        return receiver.instance_exec(&callable) if callable.parameters.none? { |kind, _name| kind == :req }

        callable.call(receiver)
      end

      # The arity of any callable: a Proc/Method answers directly (a Method's
      # own #call is variadic, arity -1), anything else through its #call;
      # -1 (called bare) when #call is answered via method_missing.
      def arity(callable)
        return callable.arity if callable.is_a?(Proc) || callable.is_a?(Method)

        callable.method(:call).arity
      rescue NameError
        -1
      end
    end
  end
end
