module ConcernsOnRails
  module Support
    # The `where` condition that addresses ONE row by its primary key, for the
    # concerns' hand-built SQL (update_all, pluck, a row lock). A composite
    # primary key (Rails 7.1+ `primary_key: [:shop_id, :id]`) is an Array of
    # columns whose id is an Array of values, and `where(["shop_id", "id"] =>
    # [2, 1])` raises ("Expected corresponding value ... to be an Array"), so
    # the columns and values are paired up instead:
    #
    #   PrimaryKey.condition(Post, 1)         # => { "id" => 1 }
    #   PrimaryKey.condition(Order, [2, 1])   # => { "shop_id" => 2, "id" => 1 }
    module PrimaryKey
      module_function

      def condition(klass, value)
        key = klass.primary_key
        return { key => value } unless key.is_a?(Array)

        key.zip(Array(value)).to_h
      end

      # The primary key's column names, one for a simple key.
      def columns(klass)
        Array(klass.primary_key)
      end
    end
  end
end
