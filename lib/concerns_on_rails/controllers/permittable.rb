require "permittable"

module ConcernsOnRails
  module Controllers
    # Permittable lives in the standalone `permittable` gem (a runtime
    # dependency — it was developed here and extracted). This alias keeps the
    # concerns_on_rails include path, and everything documented for it,
    # working unchanged:
    #
    #   include ConcernsOnRails::Controllers::Permittable
    #
    # is the same module as `include Permittable`. Full docs: the permittable
    # gem README / docs/concerns/permittable.md. Note the instrumentation
    # event is the gem's: "invalid_parameters.permittable".
    Permittable = ::Permittable
  end
end

# One registry for the whole process: route the gem's `sensitive:` field
# registrations into the registry ConcernsOnRails::Railtie already appends to
# config.filter_parameters, so Permittable params and Encryptable attributes
# share one filter. (Contracts declared through ::Permittable before this
# bridge loads registered on the gem's default registry — that one stays
# appended by Permittable::Railtie, so nothing is un-filtered.)
::Permittable.filter_parameter_registry = ConcernsOnRails.filter_parameter_registry
