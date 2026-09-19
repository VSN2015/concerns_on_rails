require "active_support/concern"
require "concerns_on_rails/support/column_guard"

module ConcernsOnRails
  module Models
    # Lightweight, dependency-free tagging over a single string column.
    # Tags are stored delimiter-joined in one column — no join tables, no
    # tagging engine — so it works on any database, including SQLite.
    #
    #   class Article < ApplicationRecord
    #     include ConcernsOnRails::Taggable
    #
    #     taggable_by :tags                       # default column :tags
    #     # taggable_by :skills, downcase: true   # custom column, case-folded
    #   end
    #
    #   a = Article.new
    #   a.tag_list = "Ruby, Rails, Ruby"          # accepts a String or an Array
    #   a.tag_list                                 # => ["Ruby", "Rails"]  (stripped + de-duped)
    #   a.add_tags("api"); a.remove_tags("Rails")
    #   a.tagged_with?("ruby")                     # membership predicate
    #   a.save!
    #
    #   Article.tagged_with("ruby", "rails")          # records carrying BOTH tags
    #   Article.tagged_with("ruby", "go", any: true)  # records carrying ANY tag
    #   Article.all_tags                               # sorted unique tags in use
    #   Article.published.tag_counts(limit: 20)        # { "ruby" => 12, "rails" => 7, ... } for a tag cloud
    #
    # Notes:
    #   * Matching is boundary-safe ("rail" does not match "rails").
    #   * `tagged_with` matches case-INsensitively on every adapter — LIKE on
    #     SQLite and MySQL, ILIKE on PostgreSQL — so one call means one thing
    #     everywhere (how non-ASCII characters fold is still the database
    #     collation's business). The Ruby-side helpers (`tagged_with?`,
    #     `all_tags`, `tag_counts`) compare exactly, so `downcase: true`, which
    #     folds on write, is what makes the scope and the helpers agree.
    #   * A tag cannot contain the delimiter (default ",") — input containing
    #     it is split into multiple tags on the spot (`add_tags("a,b")` adds
    #     "a" and "b"), everywhere, so what you read back always matches what
    #     a save would have produced.
    #   * Reach for acts-as-taggable-on when you need tag contexts, ownership,
    #     or polymorphic tags shared across models.
    module Taggable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Taggable".freeze
      DEFAULT_FIELD = :tags
      DEFAULT_DELIMITER = ",".freeze
      # Same LIKE-escaping contract as Models::Searchable: the adapter quotes
      # the escape character for us, so a backslash is portable here.
      LIKE_ESCAPE = "\\".freeze
      LIKE_SPECIAL = /[\\%_]/

      included do
        class_attribute :taggable_field, instance_accessor: false, default: DEFAULT_FIELD
        class_attribute :taggable_delimiter, instance_accessor: false, default: DEFAULT_DELIMITER
        class_attribute :taggable_downcase, instance_accessor: false, default: false
      end

      # Real module (not `class_methods do`) so the private query helpers live
      # under a single `private`. ActiveSupport::Concern auto-extends ClassMethods.
      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Configure the tag column. See the module docs for the DSL.
        def taggable_by(field = DEFAULT_FIELD, delimiter: DEFAULT_DELIMITER, downcase: false)
          self.taggable_field = field.to_sym
          self.taggable_delimiter = delimiter.to_s
          self.taggable_downcase = downcase
          ensure_columns!(LABEL, taggable_field, types: :string)

          before_validation :taggable_normalize!
        end

        # Records carrying the given tags. `any: true` matches ANY tag (OR);
        # the default requires ALL tags (AND). Returns a chainable relation.
        def tagged_with(*names, any: false)
          tags = taggable_clean_all(names)
          return all if tags.empty?

          predicates = tags.map { |tag| taggable_predicate(tag) }
          return where(predicates.reduce { |memo, node| memo.or(node) }) if any

          predicates.reduce(all) { |memo, node| memo.where(node) }
        end

        # All distinct tags currently stored across the table, sorted.
        # distinct + NULL filter dedupe DB-side, so identical tag strings ship
        # over the wire once instead of once per row.
        #
        # reorder(nil) drops any inherited ORDER BY: PostgreSQL rejects
        # SELECT DISTINCT ordered by a column outside the select list ("for
        # SELECT DISTINCT, ORDER BY expressions must appear in select list"),
        # and Models::Sortable installs exactly such a default_scope — so
        # Taggable + Sortable raised on Postgres while passing on SQLite,
        # which permits it. The ordering is meaningless here anyway: the
        # result is sorted in Ruby below.
        def all_tags
          where.not(taggable_field => nil)
               .reorder(nil)
               .distinct
               .pluck(taggable_field)
               .flat_map { |raw| taggable_split(raw) }
               .uniq.sort
        end

        # Tag => number of records carrying it, ordered by count desc then tag
        # asc (a Hash keeps insertion order, so `.first(n)` / `.keys` are the
        # cloud). Relation-aware: `Article.published.tag_counts`. One GROUP BY
        # query on the raw column — identical tag strings ship once with their
        # row count and are split in Ruby, so the cost scales with DISTINCT tag
        # strings, not rows. `limit:` keeps the top N.
        def tag_counts(limit: nil)
          counts = Hash.new(0)
          taggable_count_scope.where.not(taggable_field => nil)
                              .group(taggable_field).count.each do |raw, rows|
            taggable_split(raw).each { |tag| counts[tag] += rows }
          end
          ordered = counts.sort_by { |tag, count| [-count, tag] }
          ordered = ordered.first([limit.to_i, 0].max) if limit
          ordered.to_h
        end

        # The rows to tally. A caller's select/group/order cannot survive the
        # GROUP BY (COUNT(a, b) is invalid SQL, an array group key is
        # meaningless, and a trailing ORDER BY breaks Postgres), so they are
        # stripped. limit/offset genuinely pick rows, so they are honoured by
        # resolving the window to ids first -- MySQL rejects LIMIT inside an
        # IN subquery, so the ids come back through Ruby. The window is
        # bounded by definition, so that stays cheap.
        def taggable_count_scope
          relation = all
          base = relation.except(:select, :group)
          return base.except(:order) unless (relation.limit_value || relation.offset_value) && primary_key

          unscoped.where(primary_key => base.pluck(primary_key))
        end

        # Split a raw stored column value into a normalized tag array.
        def taggable_split(raw)
          taggable_clean_all(raw.to_s.split(taggable_delimiter))
        end

        # Normalize a single tag (strip + optional downcase).
        def taggable_clean(tag)
          tag = tag.to_s.strip
          taggable_downcase ? tag.downcase : tag
        end

        private

        # Splits each entry on the delimiter before cleaning: a tag can never
        # contain the delimiter (the column format has no way to escape it),
        # so "a,b" was ALWAYS going to read back as two tags after the next
        # normalize pass — splitting here makes that immediate and uniform
        # instead of a silent later surprise.
        def taggable_clean_all(names)
          names.flatten
               .flat_map { |t| t.to_s.split(taggable_delimiter) }
               .map { |t| taggable_clean(t) }
               .reject(&:blank?).uniq
        end

        # Boundary-safe match for one tag against the delimiter-joined column:
        # the tag alone, first, last, or somewhere in the middle. Built from
        # Arel's `matches` rather than a hand-written LIKE string for two
        # reasons.
        #
        # 1. The ESCAPE character is then quoted by the adapter. An inlined
        #    `ESCAPE '\'` is a syntax error on MySQL, where a backslash escapes
        #    its own closing quote inside a string literal, even though the very
        #    same text is fine on SQLite and on PostgreSQL.
        # 2. `case_sensitive: false` emits ILIKE on PostgreSQL, whose LIKE —
        #    unlike SQLite's, and unlike MySQL's under a default _ci collation —
        #    is case-sensitive, so `tagged_with` used to mean something
        #    different there.
        #
        # An explicit ESCAPE is still what makes a tag containing `_` or `%`
        # match literally (SQLite has no default LIKE escape).
        def taggable_predicate(tag)
          column = arel_table[taggable_field]
          # Escape the delimiter too (not just the tag): a delimiter that is a
          # LIKE wildcard (% or _) must match literally.
          delim = taggable_escape_like(taggable_delimiter)
          escaped = taggable_escape_like(tag)
          [escaped, "#{escaped}#{delim}%", "%#{delim}#{escaped}", "%#{delim}#{escaped}#{delim}%"]
            .map { |pattern| column.matches(pattern, LIKE_ESCAPE, false) }
            .reduce { |memo, node| memo.or(node) }
        end

        # Treat the user's tag as a LIKE literal: %, _ and \ are not wildcards.
        def taggable_escape_like(str)
          str.gsub(LIKE_SPECIAL) { |char| "#{LIKE_ESCAPE}#{char}" }
        end
      end

      # ---- instance methods ----

      def tag_list
        self.class.taggable_split(self[self.class.taggable_field])
      end

      def tag_list=(value)
        tags = taggable_coerce(value)
        self[self.class.taggable_field] = tags.empty? ? nil : tags.join(self.class.taggable_delimiter)
      end

      def add_tags(*names)
        self.tag_list = tag_list + names.flatten
        tag_list
      end
      alias add_tag add_tags

      def remove_tags(*names)
        drop = taggable_coerce(names.flatten)
        self.tag_list = tag_list.reject { |t| drop.include?(t) }
        tag_list
      end
      alias remove_tag remove_tags

      # AND semantics for delimiter-containing input, mirroring the class-level
      # tagged_with default: tagged_with?("a,b") is true when BOTH tags are set.
      def tagged_with?(tag)
        parts = self.class.taggable_split(tag.to_s)
        parts.any? && (parts - tag_list).empty?
      end
      alias has_tag? tagged_with?

      private

      # before_validation hook — re-normalize whatever sits in the column, covering
      # direct `record.tags = "..."` assignment, not just the tag_list= setter.
      def taggable_normalize!
        field = self.class.taggable_field
        raw = self[field]
        return if raw.nil?

        tags = self.class.taggable_split(raw)
        self[field] = tags.empty? ? nil : tags.join(self.class.taggable_delimiter)
      end

      # Funnel every input shape through taggable_split so Strings and Arrays
      # (and Array items that themselves contain the delimiter) normalize
      # identically.
      def taggable_coerce(value)
        raw = value.is_a?(Array) ? value.join(self.class.taggable_delimiter) : value.to_s
        self.class.taggable_split(raw)
      end
    end
  end
end
