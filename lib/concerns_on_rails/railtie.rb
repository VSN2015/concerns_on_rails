require "rails/railtie"
# core.rb requires this file at its end, so skip the require while core is
# the one loading us (a circular require only warns, but it does warn).
require "concerns_on_rails/core" unless defined?(ConcernsOnRails) && ConcernsOnRails.respond_to?(:filter_parameter_registry)

module ConcernsOnRails
  # Boot-time integration, loaded only when Rails is present — by
  # concerns_on_rails/core, so a host that requires a single concern file
  # (`gem "concerns_on_rails", require: false`) gets it too, not just one that
  # goes through lib/concerns_on_rails.rb.
  class Railtie < Rails::Railtie
    # Append the filter-parameter proc before ActiveRecord copies
    # `config.filter_parameters` into `filter_attributes` (a `+=` snapshot), so
    # encrypted fields are redacted from both request logs and #inspect. When
    # ActiveRecord is absent the `before:` reference simply doesn't constrain
    # ordering (railties matches before/after by name only).
    initializer "concerns_on_rails.filter_parameters",
                before: "active_record.set_filter_attributes" do |app|
      Railtie.install_filter_parameters(app.config)
    end

    # Idempotent: the registry's proc is one object, appended once.
    def self.install_filter_parameters(config)
      filter = ConcernsOnRails.filter_parameter_registry.to_proc
      config.filter_parameters << filter unless config.filter_parameters.include?(filter)
      filter
    end

    # Loaded after boot — a concern file required from an autoloaded model —
    # the initializer above never runs, so install directly. The request
    # filter reads config.filter_parameters itself (the same Array, replaced
    # in place when precompiled), but ActiveRecord copied it into
    # filter_attributes at boot, so that copy is extended too.
    def self.install_after_boot(app)
      filter = install_filter_parameters(app.config)
      ActiveSupport.on_load(:active_record) do
        self.filter_attributes += [filter] unless filter_attributes.include?(filter)
      end
    end
  end
end

ConcernsOnRails::Railtie.install_after_boot(Rails.application) if Rails.respond_to?(:application) && Rails.application&.initialized?
