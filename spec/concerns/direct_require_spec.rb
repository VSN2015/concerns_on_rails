require "spec_helper"
require "json"
require "open3"
require "rbconfig"
require "tempfile"

# Every concern file must work when required ON ITS OWN — without the gem's
# `lib/concerns_on_rails.rb` loader — because the loader documents that a
# direct `require "concerns_on_rails/models/lockable"` keeps working. The spec
# process has already loaded the whole gem, so each file is checked in a
# fresh process that has loaded ONLY what a host necessarily has: model files
# get `active_record` (no action_controller, no extra core_ext), controller
# files get `action_controller` (no active_record). Then the one concern file,
# and a trivial declaration that reaches whatever gem-level singleton
# (`ConcernsOnRails.encryption/config/deprecator/filter_parameter_registry`)
# or ActiveSupport extension the concern touches.
#
# Cost: one boot per KIND, not per file — the runner boots once and forks a
# child per file (spawning a fresh Ruby per file where fork is unsupported).
# Tagged :subprocess so it can be skipped locally: `rspec --tag ~subprocess`.
#
# The regression this pins: ten files called those singletons, which were
# defined only in the loader, so a direct require raised NoMethodError — or,
# worse, Encryptable/Lockable swallowed it and silently skipped registering
# the sensitive field with filter_parameters.
#
# SQLite only: the model runner needs a private in-memory database (on
# PostgreSQL/MySQL it would share the suite's database and its table names),
# and the PG/MySQL CI bundles don't carry the sqlite3 gem. Loading a file is
# adapter-independent, so the SQLite cells of the matrix cover it.
RSpec.describe "requiring a single concern file directly", :subprocess do
  before { skip "runs on the SQLite matrix cells only" unless TestDatabase.sqlite? }

  lib_dir = File.expand_path("../../lib", __dir__)

  # Boots `ARGV[0]`, then runs every job of the JSON file `ARGV[1]` (name =>
  # code) in its own forked child, 8 at a time, and prints
  # "__RESULTS__" + JSON { name => [output, success] }.
  runner = <<~'RUBY'
        require "json"
        require "rbconfig"
        require "open3"
        boot, jobs_path = ARGV
        boot.split(",").each { |lib| require lib }
        # What every host has already loaded before a model / controller file:
        # the base classes (both autoloaded, and ~1s each to load per child).
        ActiveRecord::Base if defined?(ActiveRecord)
        ActiveRecord::Schema if defined?(ActiveRecord) # the prelude's, not a concern's
        ActionController::Base if defined?(ActionController)
        jobs = JSON.parse(File.read(jobs_path))
        forkable = Process.respond_to?(:fork) && RUBY_ENGINE == "ruby" && !Gem.win_platform?

        run_forked = lambda do |code|
          reader, writer = IO.pipe
          pid = fork do
            reader.close
            $stdout.reopen(writer)
            $stderr.reopen(writer)
            status = begin
              TOPLEVEL_BINDING.eval(code)
              print "LOADED-OK"
              0
            rescue Exception => e # rubocop:disable Lint/RescueException
              $stderr.print "#{e.class}: #{e.message}
    #{Array(e.backtrace).first(8).join("
    ")}"
              1
            end
            $stdout.flush
            $stderr.flush
            exit!(status)
          end
          writer.close
          output = reader.read
          reader.close
          [output, Process.wait2(pid).last.success? && output.end_with?("LOADED-OK")]
        end

        run_spawned = lambda do |code|
          preload = boot.split(",").map { |lib| "require #{lib.inspect}
    " }.join
          output, status = Open3.capture2e(RbConfig.ruby, *$LOAD_PATH.first(1).flat_map { |d| ["-I", d] },
                                           "-e", "#{preload}#{code}
    print 'LOADED-OK'")
          [output, status.success? && output.end_with?("LOADED-OK")]
        end

        queue = Queue.new
        jobs.each { |job| queue << job }
        results = {}
        lock = Mutex.new
        Array.new(8) do
          Thread.new do
            loop do
              name, code = queue.pop(true)
              outcome = forkable ? run_forked.call(code) : run_spawned.call(code)
              lock.synchronize { results[name] = outcome }
            end
          rescue ThreadError
            nil # queue drained
          end
        end.each(&:join)
        print "
    __RESULTS__#{JSON.generate(results)}"
  RUBY

  model_prelude = <<~RUBY
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    Time.zone = "UTC" # host setup; loading ActiveRecord::Base brings the zone extension
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :widgets do |t|
        t.string :name
        t.string :slug
        t.integer :position
        t.datetime :published_at
        t.datetime :deleted_at
        t.datetime :starts_at
        t.datetime :ends_at
        t.datetime :expires_at
        t.boolean :active, default: false
        t.string :status
        t.string :tags
        t.text :bio
        t.string :email
        t.integer :price_cents
        t.string :line1
        t.string :city
        t.string :postal_code
        t.string :country
        t.text :audit_log
        t.integer :failed_attempts, default: 0
        t.datetime :locked_at
        t.string :unlock_token
        t.text :settings
        t.text :ssn
        t.datetime :anonymized_at
        t.string :number
        t.string :identifier
        t.string :token
        t.integer :widgets_count, default: 0
        t.integer :parent_id
        t.timestamps null: true
      end
    end
  RUBY

  # file basename => [module constant, class body, exercise]. The exercise
  # runs after the class is defined and must raise on failure.
  models = {
    "activatable" => ["Activatable", "activatable_by :active", "Widget.create!.activate!"],
    "addressable" => ["Addressable", "addressable_by",
                      'Widget.new(line1: "1 Main", city: "X", postal_code: "12345", country: "US").valid? || raise("invalid")'],
    "aliasable" => ["Aliasable",
                    "belongs_to :parent, class_name: 'Widget', optional: true\n" \
                    "alias_association :owner, :parent, deprecated: true",
                    "ConcernsOnRails.deprecator.silence { Widget.new.owner }"],
    "anonymizable" => ["Anonymizable", "anonymizable :name, with: :redact",
                       'w = Widget.create!(name: "Jane"); w.anonymize!; w.name == "[REDACTED]" || raise("not erased")'],
    "auditable" => ["Auditable", "auditable_by :name",
                    'w = Widget.create!(name: "a"); w.update!(name: "b"); w.audit_trail.any? || raise("no trail")'],
    "counter_cacheable" => ["CounterCacheable",
                            "belongs_to :parent, class_name: 'Widget', optional: true\n" \
                            "counter_cacheable_by :parent, count: :widgets_count",
                            "p = Widget.create!; Widget.create!(parent: p); p.reload.widgets_count == 1 || raise('count')"],
    "duplicable" => ["Duplicable", "duplicable_by", "Widget.create!(name: 'a').duplicate!"],
    "encryptable" => ["Encryptable", "encryptable :ssn",
                      'ConcernsOnRails.configure_encryption { |c| c.key = "k" * 32 }' \
                      "\nWidget.create!(ssn: '1').reload.ssn == '1' || raise('roundtrip')" \
                      "\nConcernsOnRails.filter_parameter_registry.include?('ssn') || raise('not filtered')"],
    "expirable" => ["Expirable", "expirable_by", "Widget.create!(expires_at: Time.now - 86_400); Widget.expired.count == 1 || raise"],
    "hashable" => ["Hashable", "hashable_by :identifier", "Widget.create!.identifier.present? || raise"],
    "lockable" => ["Lockable", "lockable_by max_attempts: 1, unlock_token: :unlock_token",
                   "Widget.create!.register_failed_attempt!" \
                   "\nConcernsOnRails.filter_parameter_registry.include?('unlock_token') || raise('not filtered')"],
    "maskable" => ["Maskable", "maskable :email, with: :email",
                   'Widget.new(email: "jo@x.io").masked_email == "j*@x.io" || raise'],
    "monetizable" => ["Monetizable", "monetizable :price_cents", 'Widget.new(price: "1.50").price_cents == 150 || raise'],
    "normalizable" => ["Normalizable", "normalizable :email, with: :email",
                       'w = Widget.new(email: " A@B.C "); w.valid?; w.email == "a@b.c" || raise'],
    "publishable" => ["Publishable", "publishable_by", "Widget.create!.publish!; Widget.published.count == 1 || raise"],
    "sanitizable" => ["Sanitizable", "sanitizable :bio", 'Widget.new(bio: "<b>x</b>").sanitized_bio == "x" || raise'],
    "schedulable" => ["Schedulable", "schedulable_by", "Widget.current.to_a"],
    "searchable" => ["Searchable", "searchable_by :name", 'Widget.create!(name: "abc"); Widget.search("b").count == 1 || raise'],
    "sequenceable" => ["Sequenceable", "sequenceable_by :number", "Widget.create!.number.present? || raise"],
    "sluggable" => ["Sluggable", "sluggable_by :name", 'Widget.create!(name: "A b").slug == "a-b" || raise'],
    "soft_deletable" => ["SoftDeletable", "soft_deletable_by", "Widget.create!.soft_delete!; Widget.count.zero? || raise"],
    "sortable" => ["Sortable", "sortable_by :position", "Widget.create!.position == 1 || raise"],
    "stateable" => ["Stateable",
                    "stateable_by :status, states: %i[draft live], default: :draft, " \
                    "transitions: { go: { from: :draft, to: :live } }",
                    "w = Widget.create!; w.go!; w.status == 'live' || raise"],
    "storable" => ["Storable", "storable_by :settings, theme: { type: :string, default: 'light' }",
                   "Widget.new.theme == 'light' || raise"],
    "taggable" => ["Taggable", "taggable_by :tags", 'Widget.create!(tags: "a,b"); Widget.tagged_with("a").count == 1 || raise'],
    "tokenizable" => ["Tokenizable", "tokenizable_by :token", "Widget.create!.token.present? || raise"]
  }

  # file basename => [module constant, class body, exercise]. The class body
  # always defines `index`, rendering 200.
  controllers = {
    "authorizable" => ["Authorizable", "authorize_by { true }", "dispatch(C, :index) == 200 || raise"],
    "cacheable" => ["Cacheable", "http_cache_actions :index, max_age: 60", "dispatch(C, :index) == 200 || raise"],
    "cursor_paginatable" => ["CursorPaginatable", "cursor_paginate_by order: { id: :asc }", "C.new"],
    "deprecatable" => ["Deprecatable", "deprecate_actions :index, deprecated_at: '2020-01-01'",
                       "dispatch(C, :index) == 200 || raise"],
    "error_handleable" => ["ErrorHandleable", "", "dispatch(C, :index) == 200 || raise"],
    "filterable" => ["Filterable", "filter_by :name", "C.new"],
    "idempotentable" => ["Idempotentable", "idempotent_actions :index",
                         "require 'active_support/cache'\n" \
                         "ConcernsOnRails.setup { |c| c.cache_store = ActiveSupport::Cache::MemoryStore.new }\n" \
                         "dispatch(C, :index, method: 'POST', headers: { 'Idempotency-Key' => 'k1' }) == 200 || raise"],
    "includable" => ["Includable", "includable :author", "C.new"],
    "localizable" => ["Localizable", "localizable available: %i[en]", "dispatch(C, :index) == 200 || raise"],
    "paginatable" => ["Paginatable", "paginate_by per_page: 10", "C.new"],
    "permittable" => ["Permittable", "", "ConcernsOnRails.filter_parameter_registry"],
    "respondable" => ["Respondable", "", "dispatch(C, :index) == 200 || raise"],
    "secure_headable" => ["SecureHeadable", "secure_headers", "dispatch(C, :index) == 200 || raise"],
    "sortable" => ["Sortable", "sortable_by :name", "C.new"],
    "throttleable" => ["Throttleable", "throttle_by limit: 5, period: 60, by: -> { 'client' }",
                       "require 'active_support/cache'\n" \
                       "ConcernsOnRails.setup { |c| c.cache_store = ActiveSupport::Cache::MemoryStore.new }\n" \
                       "dispatch(C, :index) == 200 || raise"],
    "timezoneable" => ["Timezoneable", "timezoneable cookie: true", "dispatch(C, :index) == 200 || raise"],
    "webhook_verifiable" => ["WebhookVerifiable", "verify_webhook :index, secret: 's', header: 'X-Signature', replay: true",
                             "require 'active_support/cache'\n" \
                             "ConcernsOnRails.setup { |c| c.cache_store = ActiveSupport::Cache::MemoryStore.new }\n" \
                             "dispatch(C, :index) == 401 || raise"]
  }

  controller_prelude = <<~RUBY
    require "rack/mock"
    def dispatch(klass, action, method: "GET", headers: {})
      env = Rack::MockRequest.env_for("/", method: method)
      headers.each { |k, v| env["HTTP_\#{k.tr('-', '_').upcase}"] = v }
      status, = klass.action(action).call(env)
      status
    end
  RUBY

  model_jobs = models.to_h do |file, (const, body, exercise)|
    ["models/#{file}", <<~RUBY]
      #{model_prelude}
      require "concerns_on_rails/models/#{file}"
      class Widget < ActiveRecord::Base
        include ConcernsOnRails::Models::#{const}
        #{body}
      end
      #{exercise}
    RUBY
  end

  # Sluggable/Sortable raise MissingDependency when their gem is absent; a
  # direct require used to hit NameError instead, because the constant lived
  # only in the top-level loader. (The runner never loads either gem.)
  model_jobs["missing_dependency"] = <<~RUBY
    module Kernel
      alias_method :__direct_require_spec_require, :require
      def require(name)
        raise LoadError, "cannot load such file -- \#{name}" if %w[friendly_id acts_as_list].include?(name)

        __direct_require_spec_require(name)
      end
    end
    missing = %w[sluggable sortable].map do |file|
      require "concerns_on_rails/models/\#{file}"
      raise "\#{file} loaded without its gem"
    rescue ConcernsOnRails::MissingDependency
      file
    end
    missing == %w[sluggable sortable] || raise(missing.inspect)
  RUBY

  controller_jobs = controllers.to_h do |file, (const, body, exercise)|
    ["controllers/#{file}", <<~RUBY]
      #{controller_prelude}
      require "concerns_on_rails/controllers/#{file}"
      class C < ActionController::Base
        include ConcernsOnRails::Controllers::#{const}
        #{body}
        def index = head(:ok)
      end
      #{exercise}
    RUBY
  end

  run_runner = lambda do |boot, jobs|
    Tempfile.create(["direct_require_jobs", ".json"]) do |file|
      file.write(JSON.generate(jobs))
      file.flush
      output, = Open3.capture2e(RbConfig.ruby, "-I", lib_dir, "-e", runner, boot, file.path)
      marker = output.rindex("__RESULTS__")
      raise "direct-require runner (#{boot}) crashed:\n#{output}" unless marker

      JSON.parse(output[(marker + "__RESULTS__".length)..])
    end
  end

  # Both runners at once, on first use; each example reads its own entry.
  results = nil
  results_mutex = Mutex.new
  result_for = lambda do |name|
    results_mutex.synchronize do
      results ||= [
        Thread.new { run_runner.call("active_record,active_record/connection_adapters/sqlite3_adapter", model_jobs) },
        Thread.new { run_runner.call("action_controller", controller_jobs) }
      ].map(&:value).reduce(:merge)
    end
    results.fetch(name)
  end

  it "covers every model and controller concern file" do
    on_disk = ->(kind) { Dir[File.join(lib_dir, "concerns_on_rails", kind, "*.rb")].map { |f| File.basename(f, ".rb") }.sort }
    expect(models.keys.sort).to eq(on_disk.call("models"))
    expect(controllers.keys.sort).to eq(on_disk.call("controllers"))
  end

  it "raises MissingDependency (not NameError) for an absent friendly_id / acts_as_list" do
    output, success = result_for.call("missing_dependency")
    expect(success).to be(true), output
  end

  (model_jobs.keys - ["missing_dependency"] + controller_jobs.keys).each do |name|
    it "#{name}.rb loads and declares on its own" do
      output, success = result_for.call(name)
      expect(success).to be(true), output
    end
  end
end
