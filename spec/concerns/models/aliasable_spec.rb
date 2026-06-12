require "spec_helper"

# NOTE: association-bearing test models must be NAMED classes — anonymous
# classes with associations crash in compute_type on the lockfile Rails.
# Anonymous subclasses OF named models are fine (used in the inheritance
# specs below).
describe ConcernsOnRails::Aliasable do
  before(:each) do
    ActiveRecord::Schema.define do
      create_table :authors, force: true do |t|
        t.string :name
        t.timestamps
      end

      create_table :books, force: true do |t|
        t.string :title
        t.integer :author_id
        t.timestamps
      end
    end

    class Author < TestModel
      include ConcernsOnRails::Aliasable

      has_many :books, foreign_key: :author_id
      alias_association :works, :books
      validates :name, presence: true # powers the create_writer! spec
    end

    class Book < TestModel
      include ConcernsOnRails::Aliasable

      belongs_to :author # optional: bare-AR specs never set belongs_to_required_by_default
      alias_association :writer, :author
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
    %i[Author Book SoloAuthor ShelfAuthor GhostBook VirtualBook HabtmAuthor Label
       PhantomBook TrackedBook DestroyAuthor FancyAuthor Note Review LazyAuthor
       LazyBook].each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
  end

  def create_author_with_books(name: "Jane", titles: %w[Intro Body])
    author = Author.create!(name: name)
    titles.each { |t| Book.create!(title: t, author_id: author.id) }
    author
  end

  describe ".alias_association validation" do
    it "raises when the source association does not exist" do
      expect do
        Author.alias_association(:everything, :nothing)
      end.to raise_error(ArgumentError, /association 'nothing' does not exist/)
    end

    it "raises when declared before the source association (ordering requirement)" do
      klass = Class.new(TestModel) do
        self.table_name = "books"
        include ConcernsOnRails::Aliasable
      end

      expect do
        klass.alias_association(:writer, :author)
      end.to raise_error(ArgumentError, /association 'author' does not exist/)
    end

    it "raises when the alias name is already an association" do
      class ShelfAuthor < TestModel
        self.table_name = "authors"
        include ConcernsOnRails::Aliasable

        has_many :books, foreign_key: :author_id
        has_many :tomes, class_name: "Book", foreign_key: :author_id
      end

      expect do
        ShelfAuthor.alias_association(:tomes, :books)
      end.to raise_error(ArgumentError, /'tomes' is already an association/)
    end

    it "raises when the alias name is a column" do
      expect do
        Book.alias_association(:title, :author)
      end.to raise_error(ArgumentError, /'title' is already a column or attribute/)
    end

    it "raises when the alias name is an existing method" do
      expect do
        Book.alias_association(:destroy, :author)
      end.to raise_error(ArgumentError, /'destroy' is already defined as a method/)
    end

    it "raises when the alias equals the source, including after alias-of-alias collapse" do
      expect do
        Author.alias_association(:books, :books)
      end.to raise_error(ArgumentError, /must differ from the source/)

      # :works collapses to :books, so this is books -> books in disguise
      expect do
        Author.alias_association(:books, :works)
      end.to raise_error(ArgumentError, /must differ from the source/)
    end

    it "raises when a derived ids method collides with a column" do
      ActiveRecord::Schema.define do
        create_table :shelf_authors, force: true do |t|
          t.string :name
          t.integer :work_ids
        end
      end

      class ShelfAuthor < TestModel
        include ConcernsOnRails::Aliasable

        has_many :books, foreign_key: :author_id
      end

      expect do
        ShelfAuthor.alias_association(:works, :books)
      end.to raise_error(ArgumentError, /'work_ids' is already a column or attribute/)
    end

    it "raises when a derived build_/create_ method collides with an existing method" do
      class GhostBook < TestModel
        self.table_name = "books"
        include ConcernsOnRails::Aliasable

        belongs_to :author

        def build_penman; end
      end

      expect do
        GhostBook.alias_association(:penman, :author)
      end.to raise_error(ArgumentError, /'build_penman' is already defined as a method/)
    end

    it "raises when the alias collides with a declared virtual attribute" do
      class VirtualBook < TestModel
        self.table_name = "books"
        include ConcernsOnRails::Aliasable

        belongs_to :author
        attribute :penman, :string
      end

      expect do
        VirtualBook.alias_association(:penman, :author)
      end.to raise_error(ArgumentError, /'penman' is already a column or attribute/)
    end

    it "rejects has_and_belongs_to_many sources" do
      ActiveRecord::Schema.define do
        create_table :labels, force: true do |t|
          t.string :name
        end
        create_table :authors_labels, id: false, force: true do |t|
          t.integer :author_id
          t.integer :label_id
        end
      end

      class Label < TestModel; end

      class HabtmAuthor < TestModel
        self.table_name = "authors"
        include ConcernsOnRails::Aliasable

        has_and_belongs_to_many :labels, join_table: "authors_labels", foreign_key: :author_id
      end

      expect do
        HabtmAuthor.alias_association(:tags, :labels)
      end.to raise_error(ArgumentError, /has_and_belongs_to_many/)
    end

    it "returns the alias name and records the mapping" do
      expect(Author.alias_association(:publications, :books)).to eq(:publications)
      expect(Author.aliasable_aliases[:works]).to eq(:books)
      expect(Author.aliasable_aliases[:publications]).to eq(:books)
    end

    it "raises when repointing an existing alias at a different source" do
      Author.has_many :tomes, class_name: "Book", foreign_key: :author_id

      expect do
        Author.alias_association(:works, :tomes)
      end.to raise_error(ArgumentError, /'works' is already aliased to 'books'/)
    end

    it "allows re-declaring an alias with the same source (idempotent)" do
      expect { Author.alias_association(:works, :books) }.not_to raise_error
      expect(Author.aliasable_aliases[:works]).to eq(:books)
    end

    it "does not raise when no table exists (column sweep is best-effort)" do
      class PhantomBook < TestModel
        self.table_name = "missing_table"
        include ConcernsOnRails::Aliasable

        belongs_to :author
      end

      expect do
        PhantomBook.alias_association(:writer, :author)
      end.not_to raise_error
    end
  end

  describe "collection alias — read/write/ids" do
    it "reads the same records as the source" do
      author = create_author_with_books
      expect(author.works).to eq(author.books)
      expect(author.works.map(&:title)).to contain_exactly("Intro", "Body")
    end

    it "returns the very same CollectionProxy as the source" do
      author = create_author_with_books
      expect(author.works).to equal(author.books)
    end

    it "persists assignment through the alias writer" do
      author = Author.create!(name: "Jane")
      book = Book.create!(title: "Solo")

      author.works = [book]

      expect(author.reload.books).to eq([book])
    end

    it "makes << through the alias immediately visible via the source" do
      author = Author.create!(name: "Jane")
      book = Book.create!(title: "Solo")

      author.works << book

      expect(author.books).to include(book)
    end

    it "supports the ids reader and writer" do
      author = create_author_with_books
      other = Book.create!(title: "Other")

      expect(author.work_ids).to eq(author.book_ids)

      author.work_ids = [other.id]
      expect(author.reload.books).to eq([other])
    end

    it "shares the loaded cache — loading the source loads the alias without a second query" do
      author = create_author_with_books
      author.books.to_a

      expect(author.works.loaded?).to be(true)
    end
  end

  describe "query side" do
    it "joins(:alias) joins the source table, aliased when the where-hash references the alias" do
      expect(Author.joins(:works).to_sql).to include('INNER JOIN "books"')
      expect(Author.joins(:works).where(works: { title: "X" }).to_sql)
        .to include('INNER JOIN "books" "works"')
    end

    it "joins(:alias).where(alias: {...}) finds matching rows" do
      author = create_author_with_books(titles: ["Intro"])
      create_author_with_books(name: "Other", titles: ["Misc"])

      expect(Author.joins(:works).where(works: { title: "Intro" })).to eq([author])
    end

    it "resolves a singular alias in joins + where" do
      author = Author.create!(name: "Jane")
      book = Book.create!(title: "Solo", author_id: author.id)

      expect(Book.joins(:writer).where(writer: { name: "Jane" })).to eq([book])
    end

    it "includes(:alias) fills the shared cache for both names" do
      create_author_with_books

      loaded = Author.includes(:works).first
      expect(loaded.works.loaded?).to be(true)
      expect(loaded.books.loaded?).to be(true)
    end

    it "supports preload and eager_load through the alias" do
      author = create_author_with_books(titles: ["Intro"])

      preloaded = Author.preload(:works).first
      expect(preloaded.works.loaded?).to be(true)

      expect(Author.eager_load(:works).where(works: { title: "Intro" })).to eq([author])
    end

    it "exposes the alias through reflect_on_association as a renamed copy" do
      reflection = Author.reflect_on_association(:works)

      expect(reflection).not_to be_nil
      expect(reflection.name).to eq(:works)
      expect(reflection.macro).to eq(:has_many)
      expect(reflection.klass).to eq(Book)
      expect(reflection.table_name).to eq("books")
    end

    it "routes record.association(:alias) to the source association object" do
      author = create_author_with_books
      expect(author.association(:works)).to equal(author.association(:books))
    end

    it "requires the where-hash key to match the joined name (stock Rails rule)" do
      create_author_with_books(titles: ["Intro"])

      expect do
        Author.joins(:books).where(works: { title: "Intro" }).to_a
      end.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "stays coherent when both names are included at once" do
      create_author_with_books

      loaded = Author.includes(:works, :books).first
      expect(loaded.works.loaded?).to be(true)
      expect(loaded.works).to eq(loaded.books)
    end
  end

  describe "singular alias — belongs_to" do
    it "reads the same record as the source" do
      author = Author.create!(name: "Jane")
      book = Book.create!(title: "Solo", author_id: author.id)

      expect(book.writer).to eq(book.author)
      expect(book.writer).to eq(author)
    end

    it "writes the foreign key through the alias writer" do
      author = Author.create!(name: "Jane")
      book = Book.create!(title: "Solo")

      book.writer = author
      book.save!

      expect(book.reload.author).to eq(author)
    end

    it "wires build_<alias> into the shared association target" do
      book = Book.new(title: "Solo")
      built = book.build_writer(name: "Jane")

      expect(book.author).to equal(built)
      expect(book.writer).to equal(built)
    end

    it "persists create_<alias> and raises from create_<alias>! on invalid targets" do
      book = Book.create!(title: "Solo")

      writer = book.create_writer(name: "Jane")
      expect(writer).to be_persisted
      expect(book.author).to eq(writer)

      expect do
        book.create_writer!(name: nil)
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "re-fetches through reload_<alias>" do
      author = Author.create!(name: "Jane")
      book = Book.create!(title: "Solo", author_id: author.id)
      book.writer # load the cache

      author.update_columns(name: "Zoe")

      expect(book.reload_writer.name).to eq("Zoe")
      expect(book.writer.name).to eq("Zoe")
    end
  end

  describe "singular alias — has_one" do
    before do
      class SoloAuthor < TestModel
        self.table_name = "authors"
        include ConcernsOnRails::Aliasable

        has_one :book, foreign_key: :author_id
        alias_association :masterpiece, :book
      end
    end

    it "reads, writes, builds and creates through the alias" do
      solo = SoloAuthor.create!(name: "Jane")
      book = Book.create!(title: "Solo")

      solo.masterpiece = book
      expect(book.reload.author_id).to eq(solo.id)
      expect(solo.masterpiece).to eq(solo.book)

      other = SoloAuthor.create!(name: "Ann")
      built = other.build_masterpiece(title: "Draft")
      expect(other.book).to equal(built)

      third = SoloAuthor.create!(name: "Eve")
      created = third.create_masterpiece(title: "Done")
      expect(created).to be_persisted
      expect(third.reload.book).to eq(created)
    end
  end

  describe "polymorphic belongs_to alias" do
    before do
      ActiveRecord::Schema.define do
        create_table :notes, force: true do |t|
          t.string :body
          t.string :notable_type
          t.integer :notable_id
        end
      end

      class Note < TestModel
        include ConcernsOnRails::Aliasable

        belongs_to :notable, polymorphic: true
        alias_association :subject, :notable
      end
    end

    it "aliases reader/writer; build_/create_ stay absent (Rails defines none for polymorphic)" do
      author = Author.create!(name: "Jane")
      note = Note.new(body: "memo")

      note.subject = author
      note.save!

      expect(note.reload.notable).to eq(author)
      expect(note.subject).to eq(author)
      expect(note.notable_type).to eq("Author")
      expect(note).not_to respond_to(:build_subject)
      expect(note).not_to respond_to(:create_subject)
    end

    it "aliases the foreign key and type attributes with alias_foreign_key:" do
      Note.alias_association(:topic, :notable, alias_foreign_key: true)

      author = Author.create!(name: "Jane")
      note = Note.new(body: "memo")
      note.topic = author

      expect(note.topic_id).to eq(author.id)
      expect(note.topic_type).to eq("Author")
    end
  end

  describe "has_many :through aliases" do
    before do
      ActiveRecord::Schema.define do
        create_table :reviews, force: true do |t|
          t.string :body
          t.integer :book_id
          t.integer :author_id
        end
      end

      class Review < TestModel
        belongs_to :book
        belongs_to :author
      end

      Book.has_many :reviews, foreign_key: :book_id
      Author.has_many :reviews, through: :books
      Author.alias_association :critiques, :reviews
    end

    def create_reviewed_author
      author = Author.create!(name: "Jane")
      book = Book.create!(title: "Intro", author_id: author.id)
      Review.create!(body: "great", book_id: book.id, author_id: author.id)
      author
    end

    it "reads the same through proxy and registers a source-pinned reflection copy" do
      author = create_reviewed_author

      expect(author.critiques.map(&:body)).to eq(["great"])
      expect(author.critiques).to equal(author.reviews)

      reflection = Author.reflect_on_association(:critiques)
      expect(reflection.klass).to eq(Review)
      expect(reflection.options[:source]).to eq(:reviews)
    end

    it "joins, filters, and includes through the alias" do
      author = create_reviewed_author

      expect(Author.joins(:critiques).where(critiques: { body: "great" })).to eq([author])

      loaded = Author.includes(:critiques).first
      expect(loaded.critiques.loaded?).to be(true)
    end

    it "declares safely in a class body before the through model's class is loaded" do
      class LazyAuthor < TestModel
        self.table_name = "authors"
        include ConcernsOnRails::Aliasable

        has_many :lazy_books, class_name: "LazyBook", foreign_key: :author_id
        has_many :reviews, through: :lazy_books
        alias_association :critiques, :reviews # LazyBook is not defined yet
      end

      class LazyBook < TestModel
        self.table_name = "books"

        has_many :reviews, foreign_key: :book_id
      end

      author = LazyAuthor.create!(name: "Jane")
      book = LazyBook.create!(title: "Intro", author_id: author.id)
      Review.create!(body: "deep", book_id: book.id)

      expect(author.critiques.map(&:body)).to eq(["deep"])
      expect(LazyAuthor.joins(:critiques).where(critiques: { body: "deep" })).to eq([author])
    end

    it "pins a singular-form source resolved from the loaded through model" do
      Book.has_many :authors, through: :reviews
      Book.alias_association(:reviewers, :authors)

      author = create_reviewed_author
      book = Book.find_by!(title: "Intro")

      expect(Book.reflect_on_association(:reviewers).options[:source]).to eq(:author)
      expect(book.reviewers).to eq([author])
      expect(Book.joins(:reviewers).where(reviewers: { name: "Jane" })).to eq([book])
    end

    it "copies an explicit source: option verbatim" do
      Author.has_many :remarks, through: :books, source: :reviews
      Author.alias_association(:commentary, :remarks)

      author = create_reviewed_author

      expect(Author.reflect_on_association(:commentary).options[:source]).to eq(:reviews)
      expect(author.commentary.map(&:body)).to eq(["great"])
    end
  end

  describe "inheritance" do
    it "works from an anonymous subclass of a named model" do
      subclass = Class.new(Author)
      author = subclass.create!(name: "Jane")
      book = Book.create!(title: "Intro", author_id: author.id)

      expect(author.works).to eq([book])
      author.works = []
      expect(author.reload.books).to be_empty
      expect(subclass.joins(:works).to_sql).to include('INNER JOIN "books"')
    end

    it "allows declaring an alias in a subclass for a parent-defined association" do
      # Named subclass: the query side resolves the copy's klass through its
      # owning class, and anonymous classes cannot resolve class names
      # (stock Rails compute_type limitation, same as any association
      # declared on an anonymous class).
      class FancyAuthor < Author; end
      FancyAuthor.alias_association(:tomes, :books)

      author = FancyAuthor.create!(name: "Jane")
      Book.create!(title: "Intro", author_id: author.id)

      expect(author.tomes.map(&:title)).to eq(["Intro"])
      expect(FancyAuthor.joins(:tomes).where(tomes: { title: "Intro" })).to eq([author])
      expect(Author.reflect_on_association(:tomes)).to be_nil
    end

    it "lets a subclass redefine the source and re-declare the alias idempotently" do
      subclass = Class.new(Author)
      subclass.has_many :books, -> { where.not(title: nil) }, class_name: "Book", foreign_key: :author_id

      expect do
        subclass.alias_association(:works, :books)
      end.not_to raise_error

      expect(subclass.reflect_on_association(:works).scope).not_to be_nil
      expect(Author.reflect_on_association(:works).scope).to be_nil
    end

    it "keeps inherited aliases routing when the concern is re-included" do
      subclass = Class.new(Author) { include ConcernsOnRails::Aliasable }

      expect(subclass.aliasable_aliases[:works]).to eq(:books)

      author = subclass.create!(name: "Jane")
      expect(author.association(:works)).to equal(author.association(:books))
    end
  end

  describe "misc behavior" do
    it "supports multiple aliases for one source" do
      Author.alias_association(:publications, :books)
      author = create_author_with_books(titles: ["Intro"])

      expect(author.works).to eq(author.books)
      expect(author.publications).to eq(author.books)
    end

    it "collapses aliases of aliases to the terminal source" do
      Author.alias_association(:catalog, :works)

      expect(Author.aliasable_aliases[:catalog]).to eq(:books)

      author = create_author_with_books
      expect(author.catalog).to equal(author.books)
    end

    it "runs dependent: :destroy callbacks exactly once per record" do
      class TrackedBook < TestModel
        self.table_name = "books"

        belongs_to :author
        cattr_accessor :destroyed_count, default: 0
        after_destroy { self.class.destroyed_count += 1 }
      end

      class DestroyAuthor < TestModel
        self.table_name = "authors"
        include ConcernsOnRails::Aliasable

        has_many :tracked_books, class_name: "TrackedBook", foreign_key: :author_id, dependent: :destroy
        alias_association :works, :tracked_books
      end

      author = DestroyAuthor.create!(name: "Jane")
      2.times { |i| TrackedBook.create!(title: "B#{i}", author_id: author.id) }
      TrackedBook.destroyed_count = 0

      author.destroy

      expect(TrackedBook.destroyed_count).to eq(2)
      expect(TrackedBook.count).to eq(0)
    end

    it "autosaves children added through the alias on a new parent" do
      author = Author.new(name: "Jane")
      author.works << Book.new(title: "Intro")

      author.save!

      expect(author.reload.books.map(&:title)).to eq(["Intro"])
    end

    it "supports accepts_nested_attributes_for on the alias name" do
      Author.accepts_nested_attributes_for :works

      author = Author.new(name: "Jane")
      author.works_attributes = [{ title: "Nested" }]
      author.save!

      expect(author.reload.books.map(&:title)).to eq(["Nested"])
    end
  end

  describe "method-map options (only:/except:)" do
    it "only: :reader generates just the reader, query side intact" do
      Book.alias_association(:penman, :author, only: :reader)
      author = Author.create!(name: "Jane")
      book = Book.create!(title: "Solo", author_id: author.id)

      expect(book.penman).to eq(author)
      expect(book).not_to respond_to(:penman=)
      expect(book).not_to respond_to(:build_penman)
      expect(book).not_to respond_to(:reload_penman)
      expect(Book.joins(:penman).where(penman: { name: "Jane" })).to eq([book])
    end

    it "except: :ids skips the ids pair on collections" do
      Author.alias_association(:publications, :books, except: :ids)
      author = create_author_with_books

      expect(author.publications).to eq(author.books)
      expect(author).not_to respond_to(:publication_ids)
      expect(author).not_to respond_to(:publication_ids=)
    end

    it "ignores groups that do not apply to the reflection type" do
      Author.alias_association(:publications, :books, only: %i[reader build])
      author = create_author_with_books

      expect(author.publications).to eq(author.books)
      expect(author).not_to respond_to(:publications=)
    end

    it "raises when only: and except: are combined" do
      expect do
        Book.alias_association(:penman, :author, only: :reader, except: :writer)
      end.to raise_error(ArgumentError, /not both/)
    end

    it "raises on unknown method groups" do
      expect do
        Book.alias_association(:penman, :author, only: :everything)
      end.to raise_error(ArgumentError, /unknown method group/)
    end

    it "re-declaring with narrower options prunes the stale delegators" do
      Book.alias_association(:penman, :author)
      expect(Book.new).to respond_to(:penman=)

      Book.alias_association(:penman, :author, only: :reader)
      book = Book.new

      expect(book).to respond_to(:penman)
      expect(book).not_to respond_to(:penman=)
      expect(book).not_to respond_to(:build_penman)
    end
  end

  describe "deprecated: option" do
    it "warns on use and still delegates" do
      Book.alias_association(:penman, :author, deprecated: true)
      author = Author.create!(name: "Jane")
      book = Book.create!(title: "Solo", author_id: author.id)

      expect { expect(book.penman).to eq(author) }
        .to output(/Book#penman is a deprecated alias of #author/).to_stderr
    end

    it "appends a custom message" do
      Book.alias_association(:penman, :author, deprecated: "use #author; removed in 2.0")
      book = Book.create!(title: "Solo")

      expect { book.penman }.to output(/use #author; removed in 2\.0/).to_stderr
    end

    it "does not warn for plain aliases" do
      book = Book.create!(title: "Solo")

      expect { book.writer }.not_to output.to_stderr
    end
  end

  describe "alias_foreign_key: option" do
    it "aliases the foreign-key attribute for belongs_to" do
      Book.alias_association(:penman, :author, alias_foreign_key: true)
      author = Author.create!(name: "Jane")

      book = Book.new(title: "Solo")
      book.penman_id = author.id
      book.save!

      expect(book.reload.author).to eq(author)
      expect(book.penman_id).to eq(author.id)
    end

    it "raises for non-belongs_to associations" do
      expect do
        Author.alias_association(:library, :books, alias_foreign_key: true)
      end.to raise_error(ArgumentError, /only supported for belongs_to/)
    end

    it "raises when the aliased FK collides with a column" do
      ActiveRecord::Schema.define do
        create_table :ghost_books, force: true do |t|
          t.string :title
          t.integer :author_id
          t.integer :penman_id
        end
      end

      class GhostBook < TestModel
        include ConcernsOnRails::Aliasable

        belongs_to :author
      end

      expect do
        GhostBook.alias_association(:penman, :author, alias_foreign_key: true)
      end.to raise_error(ArgumentError, /'penman_id' is already a column/)
    end
  end
end
