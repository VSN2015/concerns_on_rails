require "spec_helper"

describe ConcernsOnRails::Controllers::Authorizable do
  # FakeController has no callback machinery, so stub before_action and exercise
  # enforce_authorization directly (the before_action wiring itself is an
  # ActionController responsibility — mirrors secure_headable_spec).
  AuthzActor = Struct.new(:role) unless defined?(AuthzActor)

  let(:base_class) do
    Class.new(FakeController) do
      def self.before_action(*); end
    end
  end

  # Build a controller with the given declaration; `user` becomes current_user
  # and `action` becomes action_name.
  def controller(action: "index", user: nil, &declaration)
    klass = Class.new(base_class) do
      include ConcernsOnRails::Controllers::Authorizable

      class_eval(&declaration) if declaration
    end
    c = klass.new
    c.define_singleton_method(:action_name) { action }
    c.define_singleton_method(:current_user) { user }
    c
  end

  describe "#enforce_authorization" do
    it "does nothing when no rules are declared" do
      c = controller
      expect(c.enforce_authorization).to be_nil
      expect(c.rendered).to be_nil
    end

    it "allows the request when the predicate is truthy" do
      c = controller(user: AuthzActor.new("admin")) { authorize_by { current_user.present? } }
      c.enforce_authorization
      expect(c.rendered).to be_nil
    end

    it "denies with 403 when the predicate is falsey" do
      c = controller(user: nil) { authorize_by { current_user.present? } }
      c.enforce_authorization
      expect(c.rendered[:status]).to eq(:forbidden)
      expect(c.rendered[:json][:success]).to be false
      expect(c.rendered[:json][:error][:code]).to eq("forbidden")
    end

    it "passes the action name and actor to a two-arg block" do
      seen = []
      c = controller(action: "destroy", user: AuthzActor.new("editor")) do
        authorize_by do |action, user|
          seen << [action, user.role]
          user.role == "admin"
        end
      end
      c.enforce_authorization
      expect(seen).to eq([%w[destroy editor]])
      expect(c.rendered[:status]).to eq(:forbidden)
    end

    it "invokes a one-arg block with the action name" do
      c = controller(action: "edit") { authorize_by { |action| action == "edit" } }
      c.enforce_authorization
      expect(c.rendered).to be_nil
    end

    it "only enforces a rule for the listed actions (only:)" do
      decl = proc { authorize_by(only: %i[update destroy]) { false } }

      allowed = controller(action: "index", &decl)
      allowed.enforce_authorization
      expect(allowed.rendered).to be_nil

      blocked = controller(action: "update", &decl)
      blocked.enforce_authorization
      expect(blocked.rendered[:status]).to eq(:forbidden)
    end

    it "skips a rule for excluded actions (except:)" do
      c = controller(action: "index") { authorize_by(except: %i[index]) { false } }
      c.enforce_authorization
      expect(c.rendered).to be_nil
    end

    it "uses a custom status and message" do
      c = controller(user: nil) do
        authorize_by(status: :unauthorized, message: "Log in first") { current_user.present? }
      end
      c.enforce_authorization
      expect(c.rendered[:status]).to eq(:unauthorized)
      expect(c.rendered[:json][:error][:message]).to eq("Log in first")
    end
  end

  describe ".require_role" do
    it "allows an actor whose role is in the list" do
      c = controller(user: AuthzActor.new("editor")) { require_role :admin, :editor }
      c.enforce_authorization
      expect(c.rendered).to be_nil
    end

    it "denies an actor whose role is not in the list" do
      c = controller(user: AuthzActor.new("viewer")) { require_role :admin, :editor }
      c.enforce_authorization
      expect(c.rendered[:status]).to eq(:forbidden)
    end

    it "denies when there is no current actor" do
      c = controller(user: nil) { require_role :admin }
      c.enforce_authorization
      expect(c.rendered[:status]).to eq(:forbidden)
    end

    it "resolves a private/helper_method current_user instead of denying" do
      klass = Class.new(base_class) do
        include ConcernsOnRails::Controllers::Authorizable

        require_role :admin

        private

        def current_user
          AuthzActor.new("admin")
        end
      end
      c = klass.new
      c.define_singleton_method(:action_name) { "index" }
      c.enforce_authorization
      expect(c.rendered).to be_nil
    end
  end

  describe "delegation to Respondable" do
    it "renders the Respondable envelope when render_error is available" do
      klass = Class.new(base_class) do
        include ConcernsOnRails::Controllers::Respondable
        include ConcernsOnRails::Controllers::Authorizable

        authorize_by { false }
      end
      c = klass.new
      c.define_singleton_method(:action_name) { "index" }
      c.enforce_authorization

      expect(c.rendered[:status]).to eq(:forbidden)
      expect(c.rendered[:json][:success]).to be false
      expect(c.rendered[:json][:error][:code]).to eq("forbidden")
    end
  end

  describe "argument validation" do
    it "raises without a block" do
      expect { controller { authorize_by } }.to raise_error(ArgumentError, /a block is required/)
    end

    it "raises when both :only and :except are passed" do
      expect do
        controller { authorize_by(only: :a, except: :b) { true } }
      end.to raise_error(ArgumentError, /:only or :except/)
    end

    it "raises require_role without roles" do
      expect { controller { require_role } }.to raise_error(ArgumentError, /at least one role/)
    end
  end

  describe "#authorization_denied" do
    it "no-ops cleanly when there is no response object" do
      c = controller(user: nil) { authorize_by { false } }
      c.response = nil
      expect { c.enforce_authorization }.not_to raise_error
    end
  end
end
