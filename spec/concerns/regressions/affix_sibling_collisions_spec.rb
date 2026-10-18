require "spec_helper"

# Audit 2026-10-10 (STATE-5): two halves.
#   * The batch verbs chose their rows through PUBLIC scope names a sibling
#     concern can replace. With Expirable + Activatable unaffixed, the macro
#     called last owns `.active`, so `expire_all` iterated Activatable's
#     `active = TRUE` rows — overwriting the stored expiry of rows that had
#     expired long ago and skipping live rows whose flag was off — and
#     `deactivate_all` iterated Expirable's "not expired" rows. The verbs now
#     build their row predicates inline.
#   * Two concerns given the SAME affix (`prefix: :term` on both) silently
#     replaced each other's `term_active?` and `.term_active`. A generated
#     affixed name another gem concern already generates is now refused.
describe "affixed names and batch rows across sibling concerns" do
  before do
    ActiveRecord::Schema.define do
      create_table :asc_subs, force: true do |t|
        t.boolean :active, default: false
        t.datetime :expires_at
        t.datetime :starts_at
        t.datetime :ends_at
        t.datetime :published_at
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:asc_subs, if_exists: true)
  end

  def sub_model(&)
    Class.new(TestModel) do
      self.table_name = "asc_subs"
      class_eval(&)
    end
  end

  describe "batch verbs select their own rows, whatever owns the public scope" do
    it "expire_all expires every live row and leaves already-expired rows alone when Activatable owns .active" do
      model = sub_model do
        include ConcernsOnRails::Expirable
        include ConcernsOnRails::Activatable

        expirable_by :expires_at
        activatable_by :active
      end
      past = Time.zone.parse("2026-01-01 00:00:00")
      old = model.create!(active: true, expires_at: past)
      live_inactive = model.create!(active: false, expires_at: nil)

      expect(model.expire_all).to eq(1)
      expect(old.reload.expires_at).to eq(past)
      expect(live_inactive.reload.expires_at).not_to be_nil
    end

    it "deactivate_all deactivates every active row when Expirable owns .active" do
      model = sub_model do
        include ConcernsOnRails::Activatable
        include ConcernsOnRails::Expirable

        activatable_by :active
        expirable_by :expires_at
      end
      expired_but_on = model.create!(active: true, expires_at: 1.day.ago)
      live_and_off = model.create!(active: false, expires_at: nil)

      expect(model.deactivate_all).to eq(1)
      expect(expired_but_on.reload.active).to be(false)
      expect(live_and_off.reload.active).to be(false)
    end

    it "activate_all and expire_all take the per-record path with the same rows" do
      model = sub_model do
        include ConcernsOnRails::Expirable
        include ConcernsOnRails::Activatable

        expirable_by :expires_at
        activatable_by :active
        validates :active, inclusion: { in: [true, false] } # forces the per-record path
      end
      past = Time.zone.parse("2026-01-01 00:00:00")
      old = model.create!(active: true, expires_at: past)
      model.create!(active: false, expires_at: nil)

      expect(model.expire_all).to eq(1)
      expect(old.reload.expires_at).to eq(past)
      expect(model.activate_all).to eq(1)
    end

    it "unpublish_all unpublishes the published rows even when the model replaced .published" do
      model = sub_model do
        include ConcernsOnRails::Publishable

        publishable_by :published_at
        scope :published, -> { where(active: true) } # an app's own redefinition
      end
      live = model.create!(published_at: 1.day.ago, active: false)

      expect(model.unpublish_all).to eq(1)
      expect(live.reload.published_at).to be_nil
    end
  end

  describe "the same affix on two concerns" do
    it "refuses Activatable's term_active? / .term_active after Expirable generated them" do
      model = sub_model do
        include ConcernsOnRails::Expirable
        include ConcernsOnRails::Activatable

        expirable_by :expires_at, prefix: :term
      end

      expect { model.activatable_by :active, prefix: :term }
        .to raise_error(ArgumentError, /term_active\?.*ConcernsOnRails::Models::Expirable/)
      expect(model.term_active.to_sql).to include(TestDatabase.quoted_column("expires_at"))
    end

    it "refuses the reverse order too" do
      model = sub_model do
        include ConcernsOnRails::Expirable
        include ConcernsOnRails::Activatable

        activatable_by :active, prefix: :term
      end

      expect { model.expirable_by :expires_at, prefix: :term }
        .to raise_error(ArgumentError, /term_active\?.*ConcernsOnRails::Models::Activatable/)
    end

    it "refuses Schedulable and Expirable sharing an affixed expired? / .expired" do
      model = sub_model do
        include ConcernsOnRails::Schedulable
        include ConcernsOnRails::Expirable

        schedulable_by prefix: :window
      end

      expect { model.expirable_by :expires_at, prefix: :window }.to raise_error(ArgumentError, /window_expired/)
    end

    it "refuses an affixed scope name another concern generates by default" do
      model = sub_model do
        include ConcernsOnRails::Schedulable
        include ConcernsOnRails::Activatable

        schedulable_by
      end

      expect { model.activatable_by :active, suffix: :at }.to raise_error(ArgumentError, /active_at/)
    end

    it "lets different affixes coexist" do
      model = sub_model do
        include ConcernsOnRails::Expirable
        include ConcernsOnRails::Activatable

        expirable_by :expires_at, prefix: :term
        activatable_by :active, prefix: :flag
      end
      row = model.create!(active: true, expires_at: 1.day.ago)

      expect(row).to be_flag_active
      expect(row).not_to be_term_active
    end

    it "still lets unaffixed concerns share the plain names (the concern declared last wins)" do
      model = sub_model do
        include ConcernsOnRails::Expirable
        include ConcernsOnRails::Activatable

        expirable_by :expires_at
        activatable_by :active
      end
      row = model.create!(active: true, expires_at: 1.day.ago)

      expect(row).to be_active # Activatable included last
      expect(model.active.to_a).to eq([row])
    end

    it "still lets a concern re-declare its own affix, on the class or an STI-style subclass" do
      model = sub_model do
        include ConcernsOnRails::Expirable

        expirable_by :expires_at, prefix: :term
      end

      expect { model.expirable_by :expires_at, prefix: :term }.not_to raise_error
      expect { Class.new(model) { expirable_by :expires_at, prefix: :term } }.not_to raise_error
    end
  end
end
