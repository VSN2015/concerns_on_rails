require "spec_helper"

# Audit 2026-10-29 PARAMS-S2. `paginated(rel.limit(n))` replaced the caller's
# LIMIT with the page's own (`source.limit(per_page).offset(offset)`) and the
# COUNT stripped it, so a "top 5, 2 per page" leaderboard reported
# X-Total-Count = the whole table and page 4+ served rows beyond the top 5.
# A relation carrying a limit and/or offset is now paginated OVER that window
# (a derived table), so the count and the pages are the window's.
describe ConcernsOnRails::Controllers::Paginatable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :ranked_players, force: true do |t|
        t.string :name
        t.integer :score
        t.integer :team_id
      end
      create_table :ranked_teams, force: true do |t|
        t.string :title
      end
      create_table :ranked_items, force: true do |t|
        t.integer :ranked_player_id
        t.string :kind
      end
      create_table :ranked_staff, force: true do |t|
        t.string :type
        t.string :name
        t.integer :score
      end
    end
    stub_const("RankedItem", Class.new(TestModel) { self.table_name = "ranked_items" })
    stub_const("RankedStaff", Class.new(TestModel) { self.table_name = "ranked_staff" })
    stub_const("RankedCoach", Class.new(RankedStaff))
    stub_const("RankedTeam", Class.new(TestModel) { self.table_name = "ranked_teams" })
    stub_const("RankedPlayer", Class.new(TestModel) do
      self.table_name = "ranked_players"
      belongs_to :team, class_name: "RankedTeam", optional: true
      has_many :items, class_name: "RankedItem", foreign_key: :ranked_player_id
    end)
    teams = [RankedTeam.create!(title: "red"), RankedTeam.create!(title: "blue")]
    (1..10).each do |i|
      player = RankedPlayer.create!(name: "p#{i}", score: i, team_id: teams[i % 2].id)
      %w[a b c].each { |kind| RankedItem.create!(ranked_player_id: player.id, kind: kind) }
      RankedCoach.create!(name: "c#{i}", score: i)
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def controller_for(page, per_page: 2)
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Paginatable

      paginate_by per_page: per_page
    end.new(params: { page: page })
  end

  def page_of(relation, page, per_page: 2)
    controller = controller_for(page, per_page: per_page)
    names = controller.paginated(relation).map(&:name)
    [names, controller.response.headers["X-Total-Count"], controller]
  end

  it "pages a top-5 leaderboard inside its limit" do
    top5 = -> { RankedPlayer.order(score: :desc).limit(5) }

    expect(page_of(top5.call, 1).first).to eq(%w[p10 p9])
    expect(page_of(top5.call, 2).first).to eq(%w[p8 p7])
    expect(page_of(top5.call, 3).first).to eq(%w[p6])
    names, total, = page_of(top5.call, 4)
    expect(names).to eq([])
    expect(total).to eq("5")
  end

  it "reports the window's total, total pages and meta" do
    _, total, controller = page_of(RankedPlayer.order(:score).limit(5), 1)
    expect(total).to eq("5")
    expect(controller.response.headers["X-Total-Pages"]).to eq("3")
    expect(controller.pagination_meta[:total_pages]).to eq(3)
    expect(controller.pagination_meta[:total_count] || controller.pagination_meta[:total]).to eq(5)
    expect(controller.pagination_meta(RankedPlayer.order(:score).limit(5))[:total_pages]).to eq(3)
  end

  it "paginates an offset + limit window" do
    window = -> { RankedPlayer.order(:score).offset(3).limit(4) }

    expect(page_of(window.call, 1).first).to eq(%w[p4 p5])
    expect(page_of(window.call, 2).first).to eq(%w[p6 p7])
    names, total, = page_of(window.call, 3)
    expect(names).to eq([])
    expect(total).to eq("4")
  end

  it "paginates an offset-only window" do
    names, total, = page_of(RankedPlayer.order(:score).offset(7), 2)
    expect(names).to eq(%w[p10])
    expect(total).to eq("3")
  end

  it "keeps a limit larger than the table, a where and an empty window honest" do
    expect(page_of(RankedPlayer.order(:score).limit(500), 5).second).to eq("10")
    expect(page_of(RankedPlayer.where("score > 6").order(:score).limit(5), 2).first).to eq(%w[p9 p10])
    expect(page_of(RankedPlayer.where("score > 6").order(:score).limit(5), 1).second).to eq("4")
    expect(page_of(RankedPlayer.order(:score).offset(50).limit(3), 1)[0, 2]).to eq([[], "0"])
    expect(page_of(RankedPlayer.none.limit(3), 1)[0, 2]).to eq([[], "0"])
  end

  it "keeps a partial select list and preloads on a limited relation" do
    relation = RankedPlayer.select(:id, :name, :team_id).order(:score).limit(3).preload(:team)
    names, total, = page_of(relation, 2)
    expect(names).to eq(%w[p3])
    expect(total).to eq("3")

    rows = controller_for(1).paginated(relation).to_a
    expect(rows.first.attributes.keys).to match_array(%w[id name team_id])
    expect(rows.first.association(:team)).to be_loaded
  end

  it "paginates a limited joined relation (ordered by a joined column too)" do
    joined = RankedPlayer.joins(:team).where(ranked_teams: { title: "red" }).order(score: :desc).limit(4)
    names, total, = page_of(joined, 2)
    expect(names).to eq(%w[p6 p4])
    expect(total).to eq("4")

    by_joined = RankedPlayer.joins(:team).order("ranked_teams.title, ranked_players.score").limit(6)
    names, total, = page_of(by_joined, 3)
    expect(total).to eq("6")
    expect(names.size).to eq(2)
  end

  it "paginates a limited computed-select relation" do
    relation = RankedPlayer.select("name, score * 2 AS doubled").order(:score).limit(3)
    rows = controller_for(2).paginated(relation).to_a
    expect(rows.map(&:doubled)).to eq([6])
  end

  it "paginates a limited association scope" do
    team = RankedTeam.find_by!(title: "red")
    team.update!(title: "red")
    association = RankedPlayer.where(team_id: team.id).order(:score).limit(3)
    names, total, = page_of(association, 2)
    expect(total).to eq("3")
    expect(names.size).to eq(1)
  end

  it "pages a has_many eager_load window as 3 players, not 9 joined rows" do
    relation = RankedPlayer.eager_load(:items).order(:score).limit(3)
    controller = controller_for(1)
    rows = controller.paginated(relation).to_a
    expect(rows.map(&:name)).to eq(%w[p1 p2])
    expect(rows.map { |row| row.items.size }).to eq([3, 3])
    expect(rows.all? { |row| row.association(:items).loaded? }).to be(true)
    expect(controller.response.headers["X-Total-Count"]).to eq("3")

    names, total, = page_of(relation, 2)
    expect([names, total]).to eq([%w[p3], "3"])
  end

  it "pages an includes + where on the association window" do
    relation = RankedPlayer.includes(:items).where(ranked_items: { kind: "a" }).order(:score).limit(3)
    names, total, = page_of(relation, 2)
    expect([names, total]).to eq([%w[p3], "3"])
  end

  it "keeps a belongs_to eager_load loaded on the page's records" do
    rows = controller_for(1).paginated(RankedPlayer.eager_load(:team).order(:score).limit(3)).to_a
    expect(rows.map { |row| row.association(:team).loaded? }).to eq([true, true])
  end

  it "pages an STI subclass with a partial select" do
    relation = RankedCoach.select(:id, :name).order(:score).limit(3)
    names, total, = page_of(relation, 2)
    expect([names, total]).to eq([%w[c3], "3"])
  end

  it "keeps readonly, a String order and a joined computed select" do
    rows = controller_for(1).paginated(RankedPlayer.readonly.order(:score).limit(3)).to_a
    expect(rows.map(&:readonly?)).to eq([true, true])

    expect(page_of(RankedPlayer.order("score DESC").limit(5), 2).first).to eq(%w[p8 p7])

    joined = RankedPlayer.joins(:team).select("ranked_players.*, ranked_teams.title AS team_title").order(:score).limit(4)
    rows = controller_for(2).paginated(joined).to_a
    expect(rows.map(&:name)).to eq(%w[p3 p4])
    expect(rows.map(&:team_title)).to all(be_a(String))
    expect(page_of(joined, 1).second).to eq("4")
  end

  it "reports total_pages for the window and serves nothing past it, without a query" do
    controller = controller_for(4)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/ranked_players/) && payload[:sql] !~ /COUNT/ }
    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      controller.paginated(RankedPlayer.order(:score).limit(5)).to_a
    end
    expect(result).to eq([])
    expect(queries).to be_empty
    expect(controller.response.headers.values_at("X-Total-Count", "X-Total-Pages")).to eq(%w[5 3])
    expect(controller.pagination_meta[:total_pages]).to eq(3)
  end

  it "keeps the pre-existing unlimited behaviour, counts included" do
    names, total, = page_of(RankedPlayer.order(:score), 5)
    expect(names).to eq(%w[p9 p10])
    expect(total).to eq("10")

    expect(page_of(RankedPlayer.all, 1)[1]).to eq("10")
    expect(page_of(RankedPlayer, 1)[1]).to eq("10")
    [RankedPlayer.select(:team_id).distinct, RankedPlayer.group(:team_id)].each do |relation|
      controller = controller_for(1)
      controller.paginated(relation).to_a
      expect(controller.response.headers["X-Total-Count"]).to eq("2")
    end
  end
end
