require "rails/railtie"

module ConcernsOnRails
  # Boot-time integration, loaded only when Rails is present — by
  # concerns_on_rails/core, so a host that requires a single concern file
  # (`gem "concerns_on_rails", require: false`) gets it too, not just one that
  # goes through lib/concerns_on_rails.rb.
  class Railtie < Rails::Railtie
    # core requires this file unless this class already exists — and it does
    # from here on — so neither load order is a circular require.
    require "concerns_on_rails/core" unless ConcernsOnRails.respond_to?(:filter_parameter_registry)

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

    # Loaded once initialize! is under way — a concern file required from an
    # eager-loaded model or a config/initializers file — or after it (an
    # autoloaded model), the initializer above never runs: the app collected
    # its initializers already. So install again once boot has finished. The
    # request filter reads config.filter_parameters itself (the same Array,
    # replaced in place when precompiled), but ActiveRecord copied it into
    # filter_attributes at boot, so that copy is extended too.
    def self.install_after_boot(app)
      filter = install_filter_parameters(app.config)
      ActiveSupport.on_load(:active_record) do
        self.filter_attributes += [filter] unless filter_attributes.include?(filter)
      end
    end
  end
end

# Runs at the end of initialize! — or at once when boot is already over. A
# no-op repeat when the initializer ran too (both installs are idempotent).
ActiveSupport.on_load(:after_initialize) { ConcernsOnRails::Railtie.install_after_boot(self) }
