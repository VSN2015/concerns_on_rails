require "spec_helper"

# Audit 2026-10-10, TRANS-8. masked_attributes / sanitized_attributes read
# self[field] for every declared field, so a record loaded through a partial
# `select` raised ActiveModel::MissingAttributeError. Rails' own `attributes`,
# and as_json(masked:/sanitized:) beside them, return only the loaded columns.
describe "masked_attributes / sanitized_attributes on a partial select" do
  before do
    ActiveRecord::Schema.define do
      create_table :partial_select_posts, force: true do |t|
        t.string :title
        t.string :body
        t.string :website
        t.string :email
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:partial_select_posts, if_exists: true)
  end

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "partial_select_posts"
      include ConcernsOnRails::Models::Maskable
      include ConcernsOnRails::Models::Sanitizable

      maskable :website, with: :last4
      maskable :email, with: :email
      sanitizable :title, with: :strip
      sanitizable :body, with: :safe_list
    end
  end

  before do
    klass.create!(title: "<b>t</b>", body: "<i>b</i><script>x</script>", website: "https://example.com/secret",
                  email: "jane@example.com")
  end

  it "skips the columns the select did not load, keyed like attributes" do
    partial = klass.select(:id, :email, :body).first

    expect(partial.masked_attributes).to eq("email" => klass.first.masked_email)
    expect(partial.sanitized_attributes).to eq("body" => "<i>b</i>x")
    expect(partial.masked_attributes.keys - partial.attributes.keys).to be_empty
    expect(partial.sanitized_attributes.keys - partial.attributes.keys).to be_empty
  end

  it "returns an empty Hash when none of the declared columns was loaded" do
    partial = klass.select(:id).first

    expect(partial.masked_attributes).to eq({})
    expect(partial.sanitized_attributes).to eq({})
  end

  it "still covers every declared field on a full load" do
    record = klass.first

    expect(record.masked_attributes.keys).to contain_exactly("website", "email")
    expect(record.sanitized_attributes).to eq("title" => "t", "body" => "<i>b</i>x")
  end
end
