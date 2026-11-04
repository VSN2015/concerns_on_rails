require "spec_helper"

# Regression (audit 2026-10-29, STATE-6): an event named `transition` passed the collision
# guard, and its per-event hook `before_transition` resolved to the generic 3-argument
# before_transition(event, from, to), so every `transition!` raised ArgumentError (wrong
# number of arguments). Such a declaration is refused at the macro.
RSpec.describe "Stateable event named :transition" do
  before do
    ActiveRecord::Schema.define do
      create_table :ten_posts, force: true do |t|
        t.string :status
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:ten_posts, if_exists: true) }

  def model(**options)
    transitions = options.delete(:transitions)
    Class.new(TestModel) do
      self.table_name = "ten_posts"
      include ConcernsOnRails::Models::Stateable

      stateable_by :status, states: %i[draft moved], default: :draft, transitions: transitions, **options
    end
  end

  it "is refused at the macro with an ArgumentError naming the event" do
    expect { model(transitions: { transition: { from: :draft, to: :moved } }) }
      .to raise_error(ArgumentError, /transition 'transition' would generate `transition!`/)
  end

  it "accepts an event whose affixed name is not `transition`" do
    klass = model(transitions: { transition: { from: :draft, to: :moved } }, prefix: :do)
    post = klass.create!
    expect { post.do_transition! }.not_to raise_error
    expect(post.reload.status).to eq("moved")
  end

  it "still lets an ordinary event such as `move` work, with its per-event hooks" do
    klass = model(transitions: { move: { from: :draft, to: :moved } })
    klass.class_eval do
      attr_reader :seen

      def before_move
        (@seen ||= []) << :before_move
      end

      def before_transition(event, from, to)
        (@seen ||= []) << [event, from, to]
      end
    end
    post = klass.create!

    post.move!

    expect(post.reload.status).to eq("moved")
    expect(post.seen).to eq([[:move, "draft", "moved"], :before_move])
  end
end
