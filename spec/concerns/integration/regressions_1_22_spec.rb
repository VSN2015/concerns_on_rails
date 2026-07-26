require "spec_helper"
require "support/integration_harness"

# End-to-end proofs through the REAL ActionController stack for the 1.22
# fixes that the FakeController harness structurally could not catch.
RSpec.describe "1.22 regressions through real ActionController dispatch" do
  BoomIntegrationError = Class.new(StandardError)

  def dispatch(controller, action, **options)
    IntegrationHarness.dispatch(controller, action, **options)
  end

  describe "Includable sparse fieldsets arrive as ActionController::Parameters" do
    let(:controller) do
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Includable
        includable :author, fields: { articles: %i[id title] }

        def show
          render json: requested_fields
        end
      end
    end

    it "sanitizes ?fields[articles]=... instead of 500ing (pre-1.22 NoMethodError)" do
      result = dispatch(controller, :show, query: "fields[articles]=id,title,secret")
      expect(result.status).to eq(200)
      expect(JSON.parse(result.body)).to eq("articles" => %w[id title])
    end
  end

  describe "Paginatable param type confusion" do
    let(:controller) do
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Paginatable

        def show
          render json: { page: send(:pagination_page), per_page: send(:pagination_per_page) }
        end
      end
    end

    it "falls back to defaults for ?page[]=1&per_page[x]=5 instead of 500ing" do
      result = dispatch(controller, :show, query: "page[]=1&per_page[x]=5")
      expect(result.status).to eq(200)
      expect(JSON.parse(result.body)).to eq("page" => 1, "per_page" => 25)
    end
  end

  describe "SecureHeadable on rescue_from-rendered errors" do
    let(:controller) do
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::SecureHeadable
        secure_headers :nosniff, :deny_frame

        rescue_from BoomIntegrationError do
          render json: { error: "handled" }, status: :unprocessable_entity
        end

        def show
          raise BoomIntegrationError
        end

        def ok
          render json: { ok: true }
        end
      end
    end

    it "emits the headers on the rescued error (after_action is skipped by rescue_from)" do
      result = dispatch(controller, :show)
      expect(result.status).to eq(422)
      expect(result.header("X-Content-Type-Options")).to eq("nosniff")
      expect(result.header("X-Frame-Options")).to eq("DENY")
    end

    it "still emits the headers on normal responses" do
      result = dispatch(controller, :ok)
      expect(result.status).to eq(200)
      expect(result.header("X-Content-Type-Options")).to eq("nosniff")
    end
  end

  describe "Cacheable no_store on rescue_from-rendered errors" do
    let(:no_store_controller) do
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Cacheable
        http_cache_actions no_store: true

        rescue_from BoomIntegrationError do
          render json: { error: "handled" }, status: :unprocessable_entity
        end

        def show
          raise BoomIntegrationError
        end
      end
    end

    let(:public_controller) do
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Cacheable
        http_cache_actions visibility: :public, max_age: 300

        rescue_from BoomIntegrationError do
          render json: { error: "handled" }, status: :unprocessable_entity
        end

        def show
          raise BoomIntegrationError
        end
      end
    end

    it "carries Cache-Control: no-store on the rescued error" do
      result = dispatch(no_store_controller, :show)
      expect(result.status).to eq(422)
      expect(result.header("Cache-Control")).to eq("no-store")
    end

    it "never emits the positive freshness policy on a rescued error" do
      result = dispatch(public_controller, :show)
      expect(result.status).to eq(422)
      expect(result.header("Cache-Control").to_s).not_to include("public")
    end
  end

  describe "Authorizable array-valued roles" do
    def role_controller(roles)
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Authorizable
        require_role :admin, role_method: :roles

        define_method(:current_user) { Struct.new(:roles).new(roles) }
        private :current_user

        def show
          render json: { ok: true }
        end
      end
    end

    it "allows an actor whose roles method returns an Array (pre-1.22: always denied)" do
      expect(dispatch(role_controller(%w[admin editor]), :show).status).to eq(200)
    end

    it "still denies an actor without the wanted role" do
      expect(dispatch(role_controller(%w[viewer]), :show).status).to eq(403)
    end
  end
end
