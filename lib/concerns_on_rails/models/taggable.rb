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
    #
    # Notes:
    #   * Matching is boundary-safe ("rail" does not match "rails").
    #   * A tag cannot contain the delimiter (default ",") — input containing
    #     it is split into multiple tags on the spot (`add_tags("a,b")` adds
    #     "a" and "b"), everywhere, so what you read back always matches what
    #     a save would have produced.
    #   * Reach for acts-as-taggable-on when you need tag contexts, ownership,
    #     tag counts/clouds, or polymorphic tags shared across models.
    module Taggable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Taggable".freeze
      DEFAULT_FIELD = :tags
      DEFAULT_DELIMITER = ",".freeze

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

          clauses = tags.map { |t| taggable_clause(t) }
          sql = clauses.map(&:first).join(any ? " OR " : " AND ")
          where(sql, *clauses.flat_map(&:last))
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

        # Boundary-safe match for one tag against the delimiter-joined column.
        # Returns [sql_fragment, [bind_params...]]. An explicit ESCAPE clause makes
        # the backslash escaping below work on every adapter (SQLite has no default
        # LIKE escape), so a tag containing `_` or `%` matches literally.
        def taggable_clause(tag)
          column = "#{connection.quote_table_name(table_name)}.#{connection.quote_column_name(taggable_field)}"
          # Escape the delimiter too (not just the tag): a delimiter that is a LIKE
          # wildcard (% or _) must match literally. Use LIKE for the whole-column
          # branch as well, so casing is uniform across all four branches — the
          # previous `= ?` was case-sensitive while LIKE is not.
          delim = taggable_escape_like(taggable_delimiter)
          escaped = taggable_escape_like(tag)
          esc = " ESCAPE '\\'"
          ["(#{column} LIKE ?#{esc} OR #{column} LIKE ?#{esc} OR #{column} LIKE ?#{esc} OR #{column} LIKE ?#{esc})",
           [escaped, "#{escaped}#{delim}%", "%#{delim}#{escaped}", "%#{delim}#{escaped}#{delim}%"]]
        end

        # Treat the user's tag as a LIKE literal: %, _ and \ are not wildcards.
        def taggable_escape_like(str)
          str.gsub(/[\\%_]/) { |char| "\\#{char}" }
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
