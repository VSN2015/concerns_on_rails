require "spec_helper"

# PARAMS-1: cursor_paginate_by stored per_page with a bare to_i, so -1 made
# every request without ?per_page raise "negative array size" and 0 served
# empty pages forever. Paginatable's macro raises; so does this one now.
describe "CursorPaginatable per_page: validation (PARAMS-1)" do
  let(:klass) { Class.new(FakeController) { include ConcernsOnRails::Controllers::CursorPaginatable } }

  [-1, 0, "abc", nil].each do |bad|
    it "raises ArgumentError at the macro for per_page: #{bad.inspect}" do
      expect { klass.cursor_paginate_by(order: { id: :asc }, per_page: bad) }
        .to raise_error(ArgumentError, /per_page/)
      expect(klass.cursor_paginatable_per_page).to eq(ConcernsOnRails::Controllers::CursorPaginatable::DEFAULT_PER_PAGE)
    end
  end

  it "still accepts a positive per_page" do
    klass.cursor_paginate_by(order: { id: :asc }, per_page: "7")
    expect(klass.cursor_paginatable_per_page).to eq(7)
  end

  describe "per-call override" do
    before do
      ActiveRecord::Schema.define(verbose: false) { create_table(:params_cursor_rows, force: true) { |t| t.integer :a } }
    end
    after { ActiveRecord::Base.connection.drop_table(:params_cursor_rows) }

    it "falls back to the configured per_page for a non-positive override" do
      model = Class.new(TestModel) { self.table_name = "params_cursor_rows" }
      3.times { |i| model.create!(a: i) }
      klass.cursor_paginate_by(order: { a: :asc }, per_page: 2)
      expect(klass.new(params: {}).cursor_paginated(model.all, per_page: -1).size).to eq(2)
    end
  end
end
