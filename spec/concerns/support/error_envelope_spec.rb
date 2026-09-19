# frozen_string_literal: true

require "spec_helper"

describe ConcernsOnRails::Support::ErrorEnvelope do
  # Minimal stand-ins: the envelope only ever calls #render_error or #render.
  def controller_class(&body)
    Class.new do
      attr_reader :rendered, :delegated

      def render(options)
        @rendered = options
      end

      class_eval(&body) if body
    end
  end

  def render_on(controller, details: nil)
    described_class.render(controller, message: "nope", status: :forbidden,
                                       code: "forbidden", details: details)
  end

  context "with no render_error at all" do
    it "renders the inline envelope" do
      c = controller_class.new

      render_on(c)

      expect(c.rendered).to eq(
        json: { success: false, error: { message: "nope", code: "forbidden" } },
        status: :forbidden
      )
    end

    it "includes details when given" do
      c = controller_class.new

      render_on(c, details: { field: ["bad"] })

      expect(c.rendered[:json][:error][:details]).to eq(field: ["bad"])
    end
  end

  context "with a public render_error" do
    it "delegates to it" do
      c = controller_class do
        def render_error(**kwargs)
          @delegated = kwargs
        end
      end.new

      render_on(c)

      expect(c.delegated).to eq(message: "nope", code: "forbidden", status: :forbidden)
      expect(c.rendered).to be_nil
    end
  end

  # `private def render_error` is the idiomatic way to keep a controller helper
  # from becoming a routable action, and helper_method has the same effect on
  # respond_to?. The public-only check missed both and silently fell back to the
  # gem's own body — so an app rendering RFC 9457 problem+json got a
  # non-conforming shape for every 401/403/429/400 the concerns emit.
  context "with a PRIVATE render_error" do
    let(:controller) do
      controller_class do
        private

        def render_error(**kwargs)
          @delegated = kwargs
        end
      end.new
    end

    it "still delegates to it" do
      render_on(controller)

      expect(controller.delegated).to eq(message: "nope", code: "forbidden", status: :forbidden)
    end

    it "does not fall back to the inline envelope" do
      render_on(controller)

      expect(controller.rendered).to be_nil
    end

    it "passes errors: through when details are given" do
      render_on(controller, details: { field: ["bad"] })

      expect(controller.delegated[:errors]).to eq(field: ["bad"])
    end
  end

  context "with a protected render_error" do
    it "still delegates to it" do
      c = controller_class do
        protected

        def render_error(**kwargs)
          @delegated = kwargs
        end
      end.new

      render_on(c)

      expect(c.delegated).to include(code: "forbidden")
    end
  end

  it "omits errors: entirely when there are no details" do
    c = controller_class do
      # The documented three-kwarg contract: an unconditional errors: would
      # raise ArgumentError against implementations shaped like this.
      def render_error(message:, status:, code: nil)
        @delegated = { message: message, status: status, code: code }
      end
    end.new

    expect { render_on(c) }.not_to raise_error
    expect(c.delegated).to eq(message: "nope", status: :forbidden, code: "forbidden")
  end
end
