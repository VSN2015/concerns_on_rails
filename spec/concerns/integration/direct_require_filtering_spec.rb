require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

# A concern file required ON ITS OWN (`gem "concerns_on_rails", require:
# false`) registered its sensitive fields into the filter registry, but only
# lib/concerns_on_rails.rb loaded the Railtie that makes Rails consult it — so
# the unlock token was logged in clear and #inspect showed decrypted
# plaintext. Each example boots a real Rails::Application in a fresh process,
# requiring the concern before initialize! (config/application.rb) or after it
# (the usual place: an autoloaded model file).
#
# SQLite only, like direct_require_spec: the child needs a private in-memory
# database, and the PG/MySQL CI bundles don't carry the sqlite3 gem.
RSpec.describe "filter_parameters when a concern file is required directly", :subprocess do
  before { skip "runs on the SQLite matrix cells only" unless TestDatabase.sqlite? }

  lib_dir = File.expand_path("../../../lib", __dir__)

  script = lambda do |concern, require_at|
    requirement = concern == :loader ? 'require "concerns_on_rails"' : %(require "concerns_on_rails/models/#{concern}")
    declaration = if concern == :encryptable
                    "include ConcernsOnRails::Models::Encryptable\nencryptable :ssn"
                  else
                    "include ConcernsOnRails::Models::Lockable\nlockable_by unlock_token: :unlock_token"
                  end
    <<~RUBY
      ENV["DATABASE_URL"] = "sqlite3::memory:"
      require "rails"
      require "active_record/railtie"
      require "action_controller/railtie"
      #{requirement if require_at == :before_boot}
      class App < Rails::Application
        config.eager_load = false
        config.logger = Logger.new(nil)
        config.secret_key_base = "x" * 64
      end
      App.initialize!
      #{requirement if require_at == :after_boot}
      ActiveRecord::Schema.verbose = false
      ActiveRecord::Schema.define do
        create_table(:users) do |t|
          t.integer :failed_attempts, default: 0
          t.datetime :locked_at
          t.string :unlock_token
          t.text :ssn
        end
      end
      ConcernsOnRails.configure_encryption { |c| c.key = "k" * 32 }
      class User < ActiveRecord::Base
        #{declaration}
      end
      filter = ActiveSupport::ParameterFilter.new(Rails.application.env_config["action_dispatch.parameter_filter"])
      logged = filter.filter("unlock_token" => "SECRET-TOKEN", "ssn" => "123-45-6789")
      print "__OUT__" + [logged["unlock_token"], logged["ssn"], User.new(ssn: "123-45-6789").inspect].join("|")
    RUBY
  end

  run = lambda do |concern, require_at|
    out, = Open3.capture2e(RbConfig.ruby, "-I", lib_dir, "-e", script.call(concern, require_at))
    marker = out.rindex("__OUT__")
    raise out unless marker

    out[(marker + 7)..].split("|", 3)
  end

  it "the gem's loader filters the unlock token (baseline)" do
    token, = run.call(:loader, :before_boot)
    expect(token).to eq("[FILTERED]")
  end

  %i[before_boot after_boot].each do |require_at|
    it "filters Lockable's unlock token from request params (required #{require_at.to_s.tr('_', ' ')})" do
      token, = run.call(:lockable, require_at)
      expect(token).to eq("[FILTERED]")
    end

    it "keeps Encryptable's plaintext out of params and #inspect (required #{require_at.to_s.tr('_', ' ')})" do
      _, ssn, inspected = run.call(:encryptable, require_at)
      expect(ssn).to eq("[FILTERED]")
      expect(inspected).not_to include("123-45-6789")
    end
  end

  # DURING initialize!: after Rails collected the initializers, before
  # `initialized?` — neither the initializer nor an "already booted" check
  # sees it. Production's eager_load does this for every model file.
  run_script = lambda do |source|
    out, = Open3.capture2e(RbConfig.ruby, "-I", lib_dir, "-e", source)
    marker = out.rindex("__OUT__")
    raise out unless marker

    out[(marker + 7)..]
  end

  # ApplicationRecord's own `self.filter_attributes += [...]` (the documented
  # way to extend the inspect filter) copies Base's list while it is
  # eager-loaded — before the install — so that copy must be extended too.
  it "filters when an eager-loaded model file requires the concern (production boot)" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app/models"))
      File.write(File.join(root, "app/models/application_record.rb"), <<~RUBY)
        class ApplicationRecord < ActiveRecord::Base
          self.abstract_class = true
          self.filter_attributes += [:cvv]
        end
      RUBY
      File.write(File.join(root, "app/models/user.rb"), <<~RUBY)
        require "concerns_on_rails/models/lockable"
        class User < ApplicationRecord
          include ConcernsOnRails::Models::Lockable
          lockable_by unlock_token: :unlock_token
        end
      RUBY
      filtered, inspected = run_script.call(<<~RUBY).split("|", 2)
        ENV["DATABASE_URL"] = "sqlite3::memory:"
        require "rails"
        require "active_record/railtie"
        require "action_controller/railtie"
        class App < Rails::Application
          config.root = #{root.inspect}
          config.eager_load = true
          config.logger = Logger.new(nil)
          config.secret_key_base = "x" * 64
        end
        App.initialize!
        ActiveRecord::Schema.verbose = false
        ActiveRecord::Schema.define do
          create_table(:users) do |t|
            t.integer :failed_attempts, default: 0
            t.datetime :locked_at
            t.string :unlock_token
          end
        end
        User.reset_column_information
        filter = ActiveSupport::ParameterFilter.new(Rails.application.env_config["action_dispatch.parameter_filter"])
        print "__OUT__" + [filter.filter("unlock_token" => "SECRET-TOKEN")["unlock_token"],
                           User.new(unlock_token: "SECRET-TOKEN").inspect].join("|")
      RUBY
      expect(filtered).to eq("[FILTERED]")
      expect(inspected).not_to include("SECRET-TOKEN")
    end
  end

  it "keeps #inspect filtered when a config/initializers file requires the concern" do
    inspected = run_script.call(<<~RUBY)
      ENV["DATABASE_URL"] = "sqlite3::memory:"
      require "rails"
      require "active_record/railtie"
      require "action_controller/railtie"
      class App < Rails::Application
        config.eager_load = false
        config.logger = Logger.new(nil)
        config.secret_key_base = "x" * 64
        initializer("host.concerns", after: :load_config_initializers) do
          require "concerns_on_rails/models/encryptable"
          ConcernsOnRails.configure_encryption { |c| c.key = "k" * 32 }
        end
      end
      App.initialize!
      ActiveRecord::Schema.verbose = false
      ActiveRecord::Schema.define { create_table(:people) { |t| t.text :ssn } }
      class Person < ActiveRecord::Base
        include ConcernsOnRails::Models::Encryptable
        encryptable :ssn
      end
      print "__OUT__" + Person.new(ssn: "123-45-6789").inspect
    RUBY
    expect(inspected).not_to include("123-45-6789")
  end

  # core requires the railtie and the railtie requires core; either one
  # loaded first must not be a circular require.
  it "requires the railtie and core in either order without a circular-require warning" do
    %w[concerns_on_rails/railtie concerns_on_rails/core concerns_on_rails/models/lockable].each do |entry|
      out, = Open3.capture2e(RbConfig.ruby, "-w", "-I", lib_dir, "-e", %(require "rails"; require "#{entry}"))
      expect(out).not_to include("circular require"), "#{entry}: #{out}"
    end
  end
end
