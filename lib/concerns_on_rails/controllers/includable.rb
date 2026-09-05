require "active_support/concern"
require "concerns_on_rails/support/include_tree"

module ConcernsOnRails
  module Controllers
    # Whitelisted association sideloading + sparse fieldsets for JSON APIs.
    # Same allow-list philosophy as Controllers::Sortable: a client can only ask
    # for associations/fields you've explicitly permitted, so `?include=` can
    # never trigger an arbitrary `.includes` (N+1 / data-exposure risk).
    #
    #   class ArticlesController < ApplicationController
    #     include ConcernsOnRails::Controllers::Includable
    #
    #     includable :author, comments: :author,        # nested paths: ?include=comments.author
    #                fields: { articles: %i[id title], authors: %i[id name] },
    #                default: :author,                  # eager-loaded when the client sends no ?include
    #                strategy: :preload                 # :includes (default) | :preload | :eager_load
    #
    #     def index
    #       render json: with_includes(Article.all),
    #              include: requested_includes(as: :json),
    #              fields: requested_fields
    #     end
    #   end
    #
    # URL params:
    #   ?include=author,comments.author  -> eager-loads only whitelisted paths
    #   ?fields[articles]=id,title       -> sanitized down to the allowed columns
    #
    # `requested_includes` returns the sanitized includes in the shape you need —
    # `as: :query` (default, what `includes`/`preload` take: `[:author,
    # { comments: :author }]`), `as: :paths` (dotted Strings for JSON:API
    # serializers) or `as: :json` (what `as_json(include:)` takes) — and
    # `requested_fields` the sanitized fieldsets; neither mutates the rendered
    # output itself.
    module Includable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::Includable".freeze
      STRATEGIES = %i[includes preload eager_load].freeze
      SHAPES = %i[query paths json].freeze
      TREE = ConcernsOnRails::Support::IncludeTree

      included do
        class_attribute :includable_associations, default: []
        class_attribute :includable_tree, default: {}
        class_attribute :includable_fields, default: {}
        class_attribute :includable_default_paths, default: []
        class_attribute :includable_strategy, default: :includes
      end

      module ClassMethods
        # Whitelist sideloadable associations — flat Symbols and/or nested
        # Hashes, exactly like `includes` arguments — and (optionally) the
        # columns exposable per resource via sparse fieldsets. `default:` names
        # the paths loaded when the client sends no `?include` at all (validated
        # against the allow-list); `strategy:` picks the eager-loading method.
        # Nested Hash entries arrive as **nested (Ruby 3 keyword rules) and are
        # folded back into the association tree.
        def includable(*associations, fields: {}, default: nil, strategy: :includes, **nested)
          tree = TREE.from(associations + [nested], label: LABEL).freeze
          self.includable_tree = tree
          self.includable_associations = tree.keys
          self.includable_fields = fields.each_with_object({}) do |(table, cols), memo|
            memo[table.to_sym] = Array(cols).map(&:to_sym)
          end
          self.includable_strategy = includable_strategy!(strategy)
          self.includable_default_paths = includable_default_paths!(default, tree)
        end

        private

        def includable_strategy!(strategy)
          strategy = strategy.to_sym
          return strategy if STRATEGIES.include?(strategy)

          raise ArgumentError, "#{LABEL}: strategy: must be one of #{STRATEGIES.join(', ')} (got #{strategy.inspect})"
        end

        def includable_default_paths!(default, tree)
          TREE.paths(TREE.from(default, label: LABEL)).each do |path|
            raise ArgumentError, "#{LABEL}: default: #{path} is not an includable path" unless TREE.allowed?(path, tree)
          end
        end
      end

      # Eager-load only the whitelisted paths requested via ?include= (or the
      # `default:` ones when the param is absent) with the configured strategy.
      # Returns the relation unchanged when nothing valid was requested.
      def with_includes(relation)
        includes = requested_includes
        includes.empty? ? relation : relation.public_send(self.class.includable_strategy, *includes)
      end

      # Sanitized includes in the shape you need:
      #   as: :query  (default) [:author, { comments: :author }]   — includes/preload/eager_load, most serializers
      #   as: :paths            ["author", "comments.author"]      — JSON:API serializers
      #   as: :json             [:author, { comments: { include: :author } }] — as_json / render json: include:
      def requested_includes(as: :query)
        paths = requested_include_paths
        case as
        when :query then TREE.query_shape(TREE.from_paths(paths))
        when :json then TREE.json_shape(TREE.from_paths(paths))
        when :paths then paths
        else raise ArgumentError, "#{LABEL}: as: must be :query, :paths or :json (got #{as.inspect})"
        end
      end

      # Allow-listed dotted paths from ?include= in request order (deduplicated).
      # An absent param yields the `default:` paths; a blank one yields none.
      def requested_include_paths
        raw = params[:include]
        return self.class.includable_default_paths if raw.nil?
        return [] if raw.respond_to?(:each_pair) # ?include[x]=y — not a list

        tree = self.class.includable_tree
        includable_tokens(raw).select { |path| TREE.valid_path?(path) && TREE.allowed?(path, tree) }.uniq
      end

      # Sanitized sparse fieldsets: { table => [cols] }, each intersected with
      # the allowed columns for that table. Unknown tables/columns are dropped.
      def requested_fields
        raw = params[:fields]
        return {} unless raw.respond_to?(:each_pair)

        allowed = self.class.includable_fields
        # Iterate via each_pair: in a real controller `raw` is an
        # ActionController::Parameters, which has each_pair but no Enumerable —
        # calling each_with_object directly on it was a guaranteed
        # NoMethodError 500 for every ?fields[...]= request.
        raw.each_pair.with_object({}) do |(table, cols), memo|
          key = table.to_sym
          next unless allowed.key?(key)

          permitted = split_field_list(cols) & allowed[key]
          memo[key] = permitted unless permitted.empty?
        end
      end

      private

      # ?include=a,b or ?include[]=a&include[]=b,c → ["a", "b", "c"]
      def includable_tokens(raw)
        (raw.is_a?(Array) ? raw : [raw]).flat_map { |value| value.to_s.split(",") }.map(&:strip)
      end

      def split_field_list(cols)
        list = cols.is_a?(Array) ? cols : cols.to_s.split(",")
        list.map { |col| col.to_s.strip.to_sym }
      end
    end
  end
end
