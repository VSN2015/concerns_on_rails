module ConcernsOnRails
  module Support
    # Nested association allow-lists for Controllers::Includable. A tree is a
    # Hash of Symbol => child tree — `{ writer: {}, remarks: { story: {} } }` —
    # built from ActiveRecord-style includes arguments or dotted request paths
    # ("remarks.story"), and rendered back into the shapes `includes`/`preload`
    # (`[:writer, { remarks: :story }]`) and `as_json(include:)`
    # (`[:writer, { remarks: { include: :story } }]`) expect.
    module IncludeTree
      module_function

      PATH = /\A[^.\s,]+(\.[^.\s,]+)*\z/

      # AR-style includes arguments — Symbols, Strings (dotted allowed), Arrays,
      # Hashes, nested freely — to a tree. Anything else raises.
      def from(spec, label:)
        case spec
        when nil then {}
        when Symbol, String then from_path(spec.to_s)
        when Array then spec.each_with_object({}) { |entry, memo| merge!(memo, from(entry, label: label)) }
        when Hash then spec.each_with_object({}) { |(key, children), memo| merge!(memo, key.to_sym => from(children, label: label)) }
        else raise ArgumentError, "#{label}: associations must be Symbols, Strings, Arrays or Hashes (got #{spec.class})"
        end
      end

      # "remarks.story" → { remarks: { story: {} } }
      def from_path(path)
        path.split(".").reverse.reduce({}) { |children, segment| { segment.strip.to_sym => children } }
      end

      def from_paths(paths)
        paths.each_with_object({}) { |path, memo| merge!(memo, from_path(path)) }
      end

      def merge!(target, addition)
        addition.each { |key, children| target[key] = merge!(target[key] || {}, children) }
        target
      end

      # Leaf paths: { writer: {}, remarks: { story: {} } } → ["writer", "remarks.story"]
      def paths(tree, prefix = nil)
        tree.flat_map do |key, children|
          path = [prefix, key].compact.join(".")
          children.empty? ? [path] : paths(children, path)
        end
      end

      # Well-formed dotted path: no blank segments, no stray dots/spaces.
      def valid_path?(path)
        path.match?(PATH)
      end

      # Does every segment of the path exist in the tree, in order?
      def allowed?(path, tree)
        node = path.split(".").reduce(tree) { |current, segment| current && current[segment.to_sym] }
        !node.nil?
      end

      # Tree → `includes`/`preload`/`eager_load` arguments: [:writer, { remarks: :story }]
      def query_shape(tree)
        tree.map { |key, children| children.empty? ? key : { key => collapse(query_shape(children)) } }
      end

      # Tree → `as_json(include:)` arguments: [:writer, { remarks: { include: :story } }]
      def json_shape(tree)
        tree.map { |key, children| children.empty? ? key : { key => { include: collapse(json_shape(children)) } } }
      end

      def collapse(list)
        list.size == 1 ? list.first : list
      end
    end
  end
end
