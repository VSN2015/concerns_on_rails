require "spec_helper"
require "support/integration_harness"

# Audit 2026-10-29, HTTP-2. `require_role %i[admin editor]` (or a role-list
# constant) reached the rule as roles = [[:admin, :editor]], which was never
# flattened: wanted became ["[:admin, :editor]"], no actor role equals that, and
# the endpoint answered 403 to everyone. `require_role []` also passed the "at
# least one role" guard because [[]] is non-empty.
describe "Authorizable require_role with an Array of roles" do
  def status_for(role, &declare)
    klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Authorizable

      instance_exec(&declare)
      define_method(:current_user) { Struct.new(:role).new(role) }
      private :current_user
      define_method(:show) { render json: { ok: true } }
    end
    IntegrationHarness.dispatch(klass, :show).status
  end

  it "admits an actor whose role is in an Array argument" do
    expect(status_for("admin") { require_role %i[admin editor] }).to eq(200)
    expect(status_for("editor") { require_role %i[admin editor] }).to eq(200)
  end

  it "still denies an actor whose role is not in the Array" do
    expect(status_for("viewer") { require_role %i[admin editor] }).to eq(403)
  end

  it "accepts a role-list constant mixed with loose roles and nested arrays" do
    expect(status_for("owner") { require_role [:admin, [:editor]], :owner }).to eq(200)
    expect(status_for("editor") { require_role [:admin, [:editor]], :owner }).to eq(200)
  end

  it "keeps the splat form working" do
    expect(status_for("admin") { require_role :admin, :editor }).to eq(200)
    expect(status_for("viewer") { require_role :admin, :editor }).to eq(403)
  end

  it "raises at class load for an empty Array or an Array of empty Arrays" do
    [[[]], [[[]]], [[], []]].each do |args|
      expect do
        IntegrationHarness.build_controller do
          include ConcernsOnRails::Controllers::Authorizable

          require_role(*args)
        end
      end.to raise_error(ArgumentError, /at least one role is required/)
    end
  end

  it "still raises for no roles at all" do
    expect do
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Authorizable

        require_role
      end
    end.to raise_error(ArgumentError, /at least one role is required/)
  end

  it "raises at class load for a nil or blank role (an unset ENV lookup) instead of admitting role-less actors" do
    [[nil], [""], ["  "], [:admin, nil], [[:admin, ""]]].each do |args|
      expect do
        IntegrationHarness.build_controller do
          include ConcernsOnRails::Controllers::Authorizable

          require_role(*args)
        end
      end.to raise_error(ArgumentError, /roles must not be nil or blank/)
    end
  end

  it "does not admit an actor with an empty role when the role list was built from an unset value" do
    expect do
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Authorizable

        require_role ENV.fetch("COR_UNSET_ROLE_FOR_SPEC", nil)&.to_sym
      end
    end.to raise_error(ArgumentError)
  end
end
