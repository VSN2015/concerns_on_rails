require "spec_helper"

# PARAMS-2: `paginate_by` / `includable` gave every keyword a literal default, so
# re-declaring them in a subclass reset every omitted option to the gem default
# (a parent's `max_per_page: 20` became 200). Omitted options now inherit, as
# CursorPaginatable's UNSET sentinel does.
describe "re-declaring paginate_by / includable in a subclass" do
  describe "paginate_by" do
    let(:parent) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Paginatable

        paginate_by per_page: 10, max_per_page: 20, style: :jsonapi, link_header: false, window: 2
      end
    end

    it "keeps every omitted option and changes only the passed one" do
      child = Class.new(parent) { paginate_by per_page: 5 }

      expect(child.paginatable_per_page).to eq(5)
      expect(child.paginatable_max_per_page).to eq(20)
      expect(child.paginatable_link_header).to be(false)
      expect(child.paginatable_window).to eq(2)
      expect(child.paginatable_page_param).to eq(%w[page number])
      expect(child.paginatable_per_page_param).to eq(%w[page size])
      expect(parent.paginatable_per_page).to eq(10)
    end

    it "still enforces the inherited cap on a request" do
      child = Class.new(parent) { paginate_by per_page: 5 }
      controller = child.new(params: { page: { size: "200" } })
      controller.paginated((1..500).to_a)
      expect(controller.response.headers["X-Per-Page"]).to eq("20")
    end

    it "an explicit option still overrides the inherited one" do
      child = Class.new(parent) { paginate_by max_per_page: 0, link_header: true, window: nil }

      expect(child.paginatable_max_per_page).to eq(0)
      expect(child.paginatable_link_header).to be(true)
      expect(child.paginatable_window).to be_nil
      expect(child.paginatable_per_page).to eq(10)
    end

    it "an explicit style re-derives both paths, and a path passed with it wins" do
      flat = Class.new(parent) { paginate_by style: :flat }
      expect([flat.paginatable_page_param, flat.paginatable_per_page_param]).to eq([%w[page], %w[per_page]])

      custom = Class.new(parent) { paginate_by style: :flat, page_param: :p }
      expect([custom.paginatable_page_param, custom.paginatable_per_page_param]).to eq([%w[p], %w[per_page]])
    end

    it "a lone page_param changes only the page path" do
      child = Class.new(parent) { paginate_by page_param: :p }
      expect([child.paginatable_page_param, child.paginatable_per_page_param]).to eq([%w[p], %w[page size]])
    end

    it "a bare first declaration still gets the gem defaults" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Paginatable

        paginate_by per_page: 7
      end

      expect(klass.paginatable_max_per_page).to eq(200)
      expect(klass.paginatable_link_header).to be(true)
      expect(klass.paginatable_page_param).to eq(%w[page])
    end

    it "a bad option leaves the class unchanged" do
      expect { parent.paginate_by(per_page: 3, max_per_page: 5, style: :bogus) }.to raise_error(ArgumentError, /style/)
      expect(parent.paginatable_per_page).to eq(10)
    end
  end

  describe "includable" do
    let(:parent) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Includable

        includable :author, :tags, fields: { articles: %i[id title] }, default: :author, strategy: :preload
      end
    end

    it "replaces the association list but keeps fields, default and strategy" do
      child = Class.new(parent) { includable :author, :comments }

      expect(child.includable_associations).to eq(%i[author comments])
      expect(child.includable_fields).to eq(articles: %i[id title])
      expect(child.includable_default_paths).to eq(%w[author])
      expect(child.includable_strategy).to eq(:preload)
      expect(parent.includable_associations).to eq(%i[author tags])
    end

    it "drops an inherited default the new allow-list no longer holds, and says so on stderr" do
      child = nil
      expect { child = Class.new(parent) { includable :comments } }
        .to output(/anonymous controller.*default include path\(s\) author/).to_stderr

      expect(child.includable_default_paths).to eq([])
      expect(child.includable_strategy).to eq(:preload)
    end

    it "stays quiet while every inherited default is still allowed, or when a default: is passed" do
      expect { Class.new(parent) { includable :author, :comments } }.not_to output(/default include path/).to_stderr
      expect { Class.new(parent) { includable :comments, default: nil } }.not_to output(/default include path/).to_stderr
    end

    it "explicit options override, and nil / {} clear" do
      child = Class.new(parent) { includable :author, strategy: :eager_load, default: nil, fields: {} }

      expect(child.includable_strategy).to eq(:eager_load)
      expect(child.includable_default_paths).to eq([])
      expect(child.includable_fields).to eq({})
    end

    it "still validates a passed default" do
      expect { Class.new(parent) { includable :author, default: :nope } }.to raise_error(ArgumentError, /not an includable path/)
    end

    it "a first declaration keeps the gem defaults" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Includable

        includable :author
      end

      expect([klass.includable_strategy, klass.includable_fields, klass.includable_default_paths]).to eq([:includes, {}, []])
    end
  end
end
