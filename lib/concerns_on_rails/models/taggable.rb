require "active_support/concern"

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
    #   * A tag must not contain the delimiter (default ",").
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
          ensure_columns!(LABEL, taggable_field)

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
        def all_tags
          pluck(taggable_field).flat_map { |raw| taggable_split(raw) }.uniq.sort
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

        def taggable_clean_all(names)
          names.flatten.map { |t| taggable_clean(t) }.reject(&:blank?).uniq
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
        self.tag_list = tag_list + names.flatten.map { |t| self.class.taggable_clean(t) }
        tag_list
      end
      alias add_tag add_tags

      def remove_tags(*names)
        drop = names.flatten.map { |t| self.class.taggable_clean(t) }
        self.tag_list = tag_list.reject { |t| drop.include?(t) }
        tag_list
      end
      alias remove_tag remove_tags

      def tagged_with?(tag)
        tag_list.include?(self.class.taggable_clean(tag))
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

      def taggable_coerce(value)
        items = value.is_a?(Array) ? value : value.to_s.split(self.class.taggable_delimiter)
        items.map { |t| self.class.taggable_clean(t) }.reject(&:blank?).uniq
      end
    end
  end
end
