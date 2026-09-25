require "spec_helper"

RSpec.describe ConcernsOnRails::Models::Duplicable do
  before do
    ActiveRecord::Schema.define do
      create_table :dup_invoices, force: true do |t|
        t.string :title
        t.string :slug
        t.integer :sequence
        t.string :number
        t.string :token
        t.datetime :token_expires_at
        t.datetime :issued_at
        t.datetime :deleted_at
        t.text :audit_log
        t.integer :failed_attempts
        t.datetime :locked_at
        t.string :unlock_token
        t.timestamps null: true
      end
      create_table :dup_line_items, force: true do |t|
        t.integer :dup_invoice_id
        t.string :description
        t.integer :quantity
        t.string :batch_code
        t.timestamps null: true
      end
      create_table :dup_notes, force: true do |t|
        t.integer :dup_invoice_id
        t.string :body
      end
      create_table :dup_tags, force: true do |t|
        t.string :name
      end
      create_table :dup_invoices_dup_tags, id: false, force: true do |t|
        t.integer :dup_invoice_id
        t.integer :dup_tag_id
      end
    end

    line_item = Class.new(TestModel) do
      self.table_name = "dup_line_items"
      include ConcernsOnRails::Models::Duplicable

      duplicable_by reset: %i[batch_code]
    end
    Object.const_set(:DupLineItem, line_item)

    Object.const_set(:DupNote, Class.new(TestModel) { self.table_name = "dup_notes" })
    Object.const_set(:DupTag, Class.new(TestModel) { self.table_name = "dup_tags" })

    # Named BEFORE the associations are declared: has_and_belongs_to_many
    # derives its internals from the model's class name, so it cannot be
    # declared on a still-anonymous class.
    invoice = Class.new(TestModel) { self.table_name = "dup_invoices" }
    Object.const_set(:DupInvoice, invoice)
    invoice.class_eval do
      include ConcernsOnRails::Models::Duplicable

      has_many :dup_line_items, class_name: "DupLineItem", foreign_key: :dup_invoice_id
      has_one :dup_note, class_name: "DupNote", foreign_key: :dup_invoice_id
      has_and_belongs_to_many :dup_tags, class_name: "DupTag",
                                         join_table: "dup_invoices_dup_tags",
                                         foreign_key: :dup_invoice_id,
                                         association_foreign_key: :dup_tag_id

      duplicable_by associations: %i[dup_line_items dup_note dup_tags],
                    reset: %i[issued_at],
                    suffix: { title: " (copy)" }
    end
  end

  after do
    %i[DupInvoice DupLineItem DupNote DupTag].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
    %i[dup_invoices dup_line_items dup_notes dup_tags dup_invoices_dup_tags].each do |table|
      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  describe "#duplicate" do
    it "returns an unsaved copy with attributes, no id, and blank timestamps" do
      original = DupInvoice.create!(title: "Q1", issued_at: 2.days.ago)
      copy = original.duplicate

      expect(copy).to be_new_record
      expect(copy.id).to be_nil
      expect(copy.created_at).to be_nil
      expect(copy.updated_at).to be_nil
      expect(copy.title).to eq("Q1 (copy)")
    end

    it "blanks reset: columns and applies suffix: only to present values" do
      original = DupInvoice.create!(title: nil, issued_at: Time.zone.now)
      copy = original.duplicate

      expect(copy.issued_at).to be_nil
      expect(copy.title).to be_nil # no suffix appended to a blank value
    end

    it "applies overrides through the writers" do
      original = DupInvoice.create!(title: "Q1")
      copy = original.duplicate(title: "Q2 rebill")
      expect(copy.title).to eq("Q2 rebill")
    end

    it "works with a bare include (no duplicable_by call)" do
      klass = Class.new(TestModel) do
        self.table_name = "dup_notes"
        include ConcernsOnRails::Models::Duplicable
      end
      original = klass.create!(body: "hello")
      copy = original.duplicate
      expect(copy.body).to eq("hello")
      expect(copy).to be_new_record
    end

    it "runs the on_duplicate hook with the unsaved copy" do
      klass = Class.new(TestModel) do
        self.table_name = "dup_notes"
        include ConcernsOnRails::Models::Duplicable

        def on_duplicate(copy)
          copy.body = "#{copy.body} [hooked]"
        end
      end
      copy = klass.create!(body: "note").duplicate
      expect(copy.body).to eq("note [hooked]")
    end
  end

  describe "#duplicate! and associations" do
    it "persists the copy with deep-copied has_many children" do
      original = DupInvoice.create!(title: "Q1")
      original.dup_line_items.create!(description: "Widget", quantity: 2, batch_code: "B-1")
      original.dup_line_items.create!(description: "Gadget", quantity: 5, batch_code: "B-2")

      copy = original.duplicate!

      expect(copy).to be_persisted
      expect(copy.dup_line_items.count).to eq(2)
      expect(copy.dup_line_items.pluck(:description)).to match_array(%w[Widget Gadget])
      expect(copy.dup_line_items.pluck(:id) & original.dup_line_items.pluck(:id)).to be_empty
      expect(original.reload.dup_line_items.count).to eq(2)
    end

    it "copies children through THEIR OWN Duplicable rules (nested resets)" do
      original = DupInvoice.create!(title: "Q1")
      original.dup_line_items.create!(description: "Widget", quantity: 2, batch_code: "B-1")

      copy = original.duplicate!
      expect(copy.dup_line_items.first.batch_code).to be_nil
      expect(original.dup_line_items.first.batch_code).to eq("B-1")
    end

    it "deep-copies a has_one child and tolerates its absence" do
      with_note = DupInvoice.create!(title: "A")
      DupNote.create!(dup_invoice_id: with_note.id, body: "attached")
      without_note = DupInvoice.create!(title: "B")

      copy = with_note.duplicate!
      expect(copy.dup_note.body).to eq("attached")
      expect(copy.dup_note.id).not_to eq(with_note.dup_note.id)

      expect(without_note.duplicate!.dup_note).to be_nil
    end

    it "shares (not copies) has_and_belongs_to_many records" do
      original = DupInvoice.create!(title: "Q1")
      tag = DupTag.create!(name: "urgent")
      original.dup_tags << tag

      copy = original.duplicate!

      expect(copy.dup_tags).to contain_exactly(tag)
      expect(DupTag.count).to eq(1)
    end
  end

  describe "macro validation" do
    it "raises for an undeclared association" do
      expect do
        Class.new(TestModel) do
          self.table_name = "dup_invoices"
          include ConcernsOnRails::Models::Duplicable

          duplicable_by associations: %i[nonexistent]
        end
      end.to raise_error(ArgumentError, /no association `nonexistent`/)
    end

    it "raises for a belongs_to association" do
      expect do
        Class.new(TestModel) do
          self.table_name = "dup_line_items"
          include ConcernsOnRails::Models::Duplicable

          belongs_to :dup_invoice, class_name: "DupInvoice", optional: true
          duplicable_by associations: %i[dup_invoice]
        end
      end.to raise_error(ArgumentError, /belongs_to/)
    end

    it "raises for a has_many :through association" do
      expect do
        Class.new(TestModel) do
          self.table_name = "dup_invoices"
          include ConcernsOnRails::Models::Duplicable

          has_many :dup_line_items, class_name: "DupLineItem", foreign_key: :dup_invoice_id
          has_many :sibling_invoices, through: :dup_line_items, source: :dup_invoice
          duplicable_by associations: %i[sibling_invoices]
        end
      end.to raise_error(ArgumentError, /:through/)
    end

    it "raises for a missing reset: column" do
      expect do
        Class.new(TestModel) do
          self.table_name = "dup_invoices"
          include ConcernsOnRails::Models::Duplicable

          duplicable_by reset: %i[nope]
        end
      end.to raise_error(ArgumentError, /does not exist/)
    end
  end

  describe "concern-aware identity resets" do
    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "dup_invoices"
        include ConcernsOnRails::Models::Duplicable
        include ConcernsOnRails::Models::Tokenizable
        include ConcernsOnRails::Models::Sequenceable
        include ConcernsOnRails::Models::Auditable
        include ConcernsOnRails::Models::SoftDeletable
        include ConcernsOnRails::Models::Lockable

        tokenizable_by :token, type: :hex, length: 12, expires_in: 1.hour
        sequenceable_by :sequence, into: :number, prefix: "INV-"
        auditable_by :title, into: :audit_log
        soft_deletable_by :deleted_at, default_scope: false
        lockable_by attempts: :failed_attempts, locked_at: :locked_at, unlock_token: :unlock_token
      end
    end

    it "regenerates tokens, sequence numbers, and formatted numbers on the copy" do
      original = klass.create!(title: "Q1")
      copy = original.duplicate!

      expect(copy.token).to be_present
      expect(copy.token).not_to eq(original.token)
      expect(copy.sequence).to eq(original.sequence + 1)
      expect(copy.number).to eq("INV-#{copy.sequence}")
    end

    it "gives the copy's token a fresh expiry instead of inheriting the original's" do
      original = travel_to(Time.utc(2026, 1, 1, 10)) { klass.create!(title: "Q1") }
      expect(original.token_expires_at).to eq(Time.utc(2026, 1, 1, 11))

      # Without clearing the stamp alongside the token, the copy would carry a
      # brand-new secret that expired five months ago.
      travel_to(Time.utc(2026, 6, 1, 10)) do
        copy = original.duplicate!
        expect(copy.token_expires_at).to eq(Time.utc(2026, 6, 1, 11))
        expect(copy.token_expired?).to be(false)
      end
    end

    it "does not inherit the original's audit history (only the copy's own creation entry)" do
      original = klass.create!(title: "Q1")
      original.update!(title: "Q1 revised")
      expect(original.audit_trail.length).to eq(2)

      copy = original.duplicate!
      expect(copy.audit_trail.length).to eq(1)
      expect(copy.audit_trail.first).to include("field" => "title", "from" => nil, "to" => "Q1 revised")
    end

    it "copies a soft-deleted record as a live one" do
      original = klass.create!(title: "Q1")
      original.soft_delete!

      copy = original.duplicate!
      expect(copy.deleted_at).to be_nil
      expect(copy.deleted?).to be(false)
    end

    it "resets the lockout state on the copy" do
      original = klass.create!(title: "Q1")
      original.lock_access!

      copy = original.reload.duplicate!
      expect(copy.failed_attempts).to eq(0)
      expect(copy.locked_at).to be_nil
      # A copy is born unlocked, so it must not inherit a live unlock link —
      # and two rows must never carry the same token.
      expect(original.reload.unlock_token).to be_present
      expect(copy.unlock_token).to be_nil
    end

    it "gives the copy fresh timestamps" do
      original = klass.create!(title: "Q1")
      original.update_columns(created_at: 2.years.ago)

      copy = original.reload.duplicate!
      expect(copy.created_at).to be > 1.minute.ago
    end
  end

  describe "children the child model hides or identifies" do
    before do
      ActiveRecord::Schema.define do
        create_table :dup_children, force: true do |t|
          t.integer :dup_invoice_id
          t.string :body
          t.datetime :published_at
          t.datetime :deleted_at
          t.string :token
          t.integer :sequence
          t.string :number
          t.text :audit_log
          t.timestamps null: true
        end
        add_index :dup_children, :token, unique: true
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:dup_children) }

    def parent_with(association, child_class)
      stub_const("DupChild", child_class)
      parent = Class.new(TestModel) { self.table_name = "dup_invoices" }
      stub_const("DupParent", parent)
      parent.class_eval do
        include ConcernsOnRails::Models::Duplicable

        public_send(association, :dup_children, class_name: "DupChild", foreign_key: :dup_invoice_id)
        duplicable_by associations: %i[dup_children]
      end
      parent
    end

    def child_class(&body)
      Class.new(TestModel) do
        self.table_name = "dup_children"
        class_eval(&body)
      end
    end

    def copied_bodies(copy)
      DupChild.unscoped.where(dup_invoice_id: copy.id).order(:id).pluck(:body)
    end

    # The deep copy iterated the association reader, which carries the
    # child's default scopes — drafts were silently not copied.
    describe "a child hidden by its own default scope" do
      let(:publishable_child) do
        child_class do
          include ConcernsOnRails::Models::Publishable

          publishable_by :published_at, default_scope: true
        end
      end

      it "copies the drafts along with the published children" do
        parent = parent_with(:has_many, publishable_child)
        original = parent.create!(title: "course")
        DupChild.create!(dup_invoice_id: original.id, body: "live", published_at: 1.day.ago)
        DupChild.create!(dup_invoice_id: original.id, body: "draft", published_at: nil)

        expect(copied_bodies(original.duplicate!)).to eq(%w[live draft])
      end

      it "copies a has_one draft" do
        parent = parent_with(:has_one, publishable_child)
        original = parent.create!(title: "course")
        DupChild.create!(dup_invoice_id: original.id, body: "draft", published_at: nil)

        expect(copied_bodies(original.duplicate!)).to eq(%w[draft])
      end

      it "still carries in-memory edits of an already-loaded association" do
        parent = parent_with(:has_many, publishable_child)
        original = parent.create!(title: "course")
        DupChild.create!(dup_invoice_id: original.id, body: "live", published_at: 1.day.ago)
        DupChild.create!(dup_invoice_id: original.id, body: "draft", published_at: nil)
        original.dup_children.load.first.body = "edited"

        expect(copied_bodies(original.duplicate!)).to eq(%w[edited draft])
      end

      it "re-links has_and_belongs_to_many records the associated model hides" do
        DupTag.class_eval { default_scope { where.not(name: "hidden") } }
        original = DupInvoice.create!(title: "Q1")
        shown = DupTag.create!(name: "shown")
        hidden = DupTag.unscoped.create!(name: "hidden")
        ActiveRecord::Base.connection.execute(
          "INSERT INTO dup_invoices_dup_tags (dup_invoice_id, dup_tag_id) VALUES " \
          "(#{original.id}, #{shown.id}), (#{original.id}, #{hidden.id})"
        )

        copy = original.duplicate!
        linked = ActiveRecord::Base.connection.select_values(
          "SELECT dup_tag_id FROM dup_invoices_dup_tags WHERE dup_invoice_id = #{copy.id}"
        )
        expect(linked.map(&:to_i)).to contain_exactly(shown.id, hidden.id)
      end

      # A trashed child is not part of the record: the SoftDeletable default
      # scope (when on) keeps excluding it, exactly as before.
      it "still leaves out children hidden by a SoftDeletable default scope" do
        soft = child_class do
          include ConcernsOnRails::Models::SoftDeletable

          soft_deletable_by :deleted_at
        end
        parent = parent_with(:has_many, soft)
        original = parent.create!(title: "course")
        DupChild.create!(dup_invoice_id: original.id, body: "kept")
        DupChild.create!(dup_invoice_id: original.id, body: "trashed").soft_delete!

        expect(copied_bodies(original.duplicate!)).to eq(%w[kept])
      end
    end

    # A child without Duplicable only had its timestamps (and counters)
    # blanked: its token was copied onto the new row — a shared credential,
    # or RecordNotUnique on the unique index — and likewise its sequence
    # number and audit trail.
    it "resets a plain (non-Duplicable) child's identity columns" do
      plain = child_class do
        include ConcernsOnRails::Models::Tokenizable
        include ConcernsOnRails::Models::Sequenceable
        include ConcernsOnRails::Models::Auditable

        tokenizable_by :token
        sequenceable_by :sequence, into: :number, prefix: "N-"
        auditable_by :body, into: :audit_log
      end
      parent = parent_with(:has_many, plain)
      original = parent.create!(title: "p")
      child = DupChild.create!(dup_invoice_id: original.id, body: "a")
      child.update!(body: "b")

      copy = nil
      expect { copy = original.duplicate! }.not_to raise_error
      copied = copy.dup_children.first
      expect(copied.token).to be_present
      expect(copied.token).not_to eq(child.token)
      expect(copied.number).not_to eq(child.reload.number)
      expect(copied.audit_trail.length).to eq(1)
    end
  end

  describe "Sluggable interaction" do
    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "dup_invoices"
        include ConcernsOnRails::Models::Duplicable
        include ConcernsOnRails::Models::Sluggable

        sluggable_by :title
      end
    end

    it "regenerates a unique slug for the copy" do
      original = klass.create!(title: "Hello World")
      expect(original.slug).to eq("hello-world")

      copy = original.duplicate!
      expect(copy.slug).to be_present
      expect(copy.slug).not_to eq(original.slug)
    end
  end

  describe "per-call association selection (only: / except:)" do
    let(:original) do
      invoice = DupInvoice.create!(title: "Q1")
      invoice.dup_line_items.create!(description: "Widget", quantity: 2)
      invoice.dup_line_items.create!(description: "Gadget", quantity: 5)
      DupNote.create!(dup_invoice_id: invoice.id, body: "attached")
      invoice.dup_tags << DupTag.create!(name: "urgent")
      invoice.reload
    end

    it "except: skips the named associations for this copy only" do
      copy = original.duplicate!(except: :dup_line_items)
      expect(copy.dup_line_items.count).to eq(0)
      expect(copy.dup_note.body).to eq("attached")
      expect(copy.dup_tags.pluck(:name)).to eq(["urgent"])

      expect(original.duplicate!.dup_line_items.count).to eq(2) # the macro's list is untouched
    end

    it "only: copies just the named associations; only: [] is a shallow copy" do
      copy = original.duplicate!(only: [:dup_tags])
      expect(copy.dup_tags.pluck(:name)).to eq(["urgent"])
      expect(copy.dup_line_items.count).to eq(0)
      expect(copy.dup_note).to be_nil

      shallow = original.duplicate!(only: [])
      expect(shallow.dup_line_items.count).to eq(0)
      expect(shallow.dup_note).to be_nil
      expect(shallow.dup_tags).to be_empty
      expect(shallow.title).to eq("Q1 (copy)")
    end

    it "treats an explicit nil as passed, not as absent" do
      # A UI checkbox list sends nil when nothing is ticked; that must copy no
      # associations, never fall through to a full deep copy.
      shallow = original.duplicate!(only: nil)
      expect(shallow.dup_line_items.count).to eq(0)
      expect(shallow.dup_note).to be_nil
      expect(shallow.dup_tags).to be_empty

      full = original.duplicate!(except: nil)
      expect(full.dup_line_items.count).to eq(2)
      expect(full.dup_note.body).to eq("attached")
      expect(full.dup_tags.pluck(:name)).to eq(["urgent"])
    end

    it "mixes with braceless overrides and validates the selection" do
      copy = original.duplicate!(title: "Q3", except: :dup_note)
      expect(copy.title).to eq("Q3")
      expect(copy.dup_note).to be_nil
      expect(copy.dup_line_items.count).to eq(2)

      expect(original.duplicate({ title: "Q4" }, only: :dup_tags).title).to eq("Q4") # positional Hash form too

      expect { original.duplicate(only: :dup_note, except: :dup_tags) }
        .to raise_error(ArgumentError, /pass either :only or :except, not both/)
      expect { original.duplicate(only: :bogus) }
        .to raise_error(ArgumentError, /bogus is not a duplicable association \(declared: dup_line_items, dup_note, dup_tags\)/)
    end
  end

  describe "counter-cache columns (1.29 audit)" do
    before do
      ActiveRecord::Schema.define do
        create_table :cc_posts, force: true do |t|
          t.string :title
          t.integer :comments_count, default: 0
          t.integer :approved_comments_count, default: 0
          t.integer :reviews_count, default: 0
          t.integer :cc_pings_count, default: 0
        end
        create_table :cc_comments, force: true do |t|
          t.integer :cc_post_id
          t.boolean :approved, default: false
          t.integer :replies_count, default: 0
        end
        create_table :cc_replies, force: true do |t|
          t.integer :cc_comment_id
        end
        create_table :cc_reviews, force: true do |t|
          t.integer :cc_post_id
        end
        create_table :cc_pings, force: true do |t|
          t.integer :target_id
          t.string :target_type
        end
      end

      Object.const_set(:CcPost, Class.new(TestModel) { self.table_name = "cc_posts" })
      Object.const_set(:CcComment, Class.new(TestModel) { self.table_name = "cc_comments" })
      Object.const_set(:CcReply, Class.new(TestModel) { self.table_name = "cc_replies" })
      Object.const_set(:CcReview, Class.new(TestModel) { self.table_name = "cc_reviews" })
      Object.const_set(:CcPing, Class.new(TestModel) { self.table_name = "cc_pings" })

      CcReply.belongs_to :cc_comment, counter_cache: :replies_count
      CcReview.belongs_to :cc_post, counter_cache: :reviews_count
      CcPing.belongs_to :target, polymorphic: true, counter_cache: true

      CcComment.class_eval do
        include ConcernsOnRails::Models::CounterCacheable

        belongs_to :cc_post
        has_many :cc_replies
        counter_cacheable_by :cc_post, count: :comments_count
        counter_cacheable_by :cc_post, count: :approved_comments_count, if: -> { approved? }
      end

      CcPost.class_eval do
        include ConcernsOnRails::Models::Duplicable

        has_many :cc_comments
        has_many :cc_reviews
        has_many :cc_pings, as: :target
        # An association whose class can't be loaded must not break duplicate.
        has_many :ghosts, class_name: "NoSuchGhostClass"
        duplicable_by associations: %i[cc_comments cc_reviews cc_pings]
      end
    end

    after do
      %i[CcPost CcComment CcReply CcReview CcPing].each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name)
      end
      %i[cc_posts cc_comments cc_replies cc_reviews cc_pings].each do |table|
        ActiveRecord::Base.connection.drop_table(table)
      end
    end

    let(:original) do
      post = CcPost.create!(title: "A")
      CcComment.create!(cc_post: post, approved: true)
      CcComment.create!(cc_post: post, approved: false)
      CcReview.create!(cc_post: post)
      CcPing.create!(target: post)
      post.reload
    end

    def counts(post)
      fresh = CcPost.find(post.id)
      [fresh.comments_count, fresh.approved_comments_count, fresh.reviews_count, fresh.cc_pings_count]
    end

    it "sets up the original's counters (sanity)" do
      expect(counts(original)).to eq([2, 1, 1, 1])
    end

    it "zeroes counter columns on the unsaved copy" do
      copy = original.duplicate(only: [])
      expect([copy.comments_count, copy.approved_comments_count, copy.reviews_count, copy.cc_pings_count])
        .to eq([0, 0, 0, 0])
    end

    it "a deep copy counts exactly the children it copied (CounterCacheable, native and polymorphic native)" do
      copy = original.duplicate!
      expect(counts(copy)).to eq([2, 1, 1, 1])
      expect(counts(original)).to eq([2, 1, 1, 1])
    end

    it "a shallow copy starts every counter at zero" do
      copy = original.duplicate!(only: [])
      expect(counts(copy)).to eq([0, 0, 0, 0])
    end

    it "a partial copy counts only the association it carried" do
      copy = original.duplicate!(only: :cc_reviews)
      expect(counts(copy)).to eq([0, 0, 1, 0])
    end

    it "zeroes a plain (non-Duplicable) child's own counters — its children are not copied" do
      comment = original.cc_comments.first
      CcReply.create!(cc_comment: comment)
      expect(comment.reload.replies_count).to eq(1)

      copy = original.duplicate!
      expect(copy.cc_comments.map { |c| c.reload.replies_count }).to eq([0, 0])
    end
  end

  describe "native counter_cache on a scoped has_many, partial inserts off (review of #111)" do
    # A scoped has_many has no automatic inverse, so Rails' has_many bumps the
    # OWNER's in-memory counter as children are added (and clears the change);
    # with partial inserts off that in-memory value was INSERTed and then the
    # children incremented it again.
    before do
      ActiveRecord::Schema.define do
        create_table :pi_posts, force: true do |t|
          t.integer :pi_reviews_count, default: 0
        end
        create_table :pi_reviews, force: true do |t|
          t.integer :pi_post_id
        end
      end

      Object.const_set(:PiPost, Class.new(TestModel) { self.table_name = "pi_posts" })
      Object.const_set(:PiReview, Class.new(TestModel) { self.table_name = "pi_reviews" })
      PiReview.belongs_to :pi_post, counter_cache: true
      PiPost.class_eval do
        include ConcernsOnRails::Models::Duplicable

        has_many :pi_reviews, -> { order(:id) }
        duplicable_by associations: %i[pi_reviews]
      end
    end

    after do
      %i[PiPost PiReview].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
      %i[pi_posts pi_reviews].each { |table| ActiveRecord::Base.connection.drop_table(table) }
    end

    def partial_inserts!(model, value)
      if model.respond_to?(:partial_inserts=)
        model.partial_inserts = value
      else
        model.partial_writes = value # Rails 6.x
      end
    end

    [false, true].each do |partial|
      it "ends with the counter equal to the children copied (partial inserts #{partial ? 'on' : 'off'})" do
        partial_inserts!(PiPost, partial)
        post = PiPost.create!
        2.times { PiReview.create!(pi_post: post) }
        post.reload

        copy = post.duplicate!
        expect(PiPost.find(copy.id).pi_reviews_count).to eq(2)
        expect(copy.pi_reviews_count).to eq(2) # in memory too, after duplicate!

        shallow = post.duplicate!(only: [])
        expect(PiPost.find(shallow.id).pi_reviews_count).to eq(0)

        unsaved = post.duplicate
        unsaved.save!
        expect(PiPost.find(unsaved.id).pi_reviews_count).to eq(2)
      end
    end

    it "leaves an explicit counter override alone" do
      post = PiPost.create!
      copy = post.duplicate(pi_reviews_count: 7)
      expect(copy.pi_reviews_count).to eq(7)
    end
  end
end
