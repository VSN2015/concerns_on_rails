module ConcernsOnRails
  module Support
    # Bounded retry for writes guarded by a database unique index. The in-Ruby
    # `exists?` prechecks in Hashable/Tokenizable/Sequenceable are best-effort:
    # two processes can both pass the check and race to the INSERT/UPDATE, and
    # the documented "add a unique index" guarantee then surfaces as
    # ActiveRecord::RecordNotUnique. Wrapping the write here converts that race
    # back into a fresh attempt.
    #
    # The block MUST generate a fresh candidate value on every attempt —
    # retrying the same value would just fail `limit` times.
    #
    # Note: RecordNotUnique carries no column information portably, so a
    # violation on an *unrelated* unique index (e.g. a unique email) also
    # triggers retries; they are wasted but bounded by `limit`.
    #
    # Create-time usage (a before_create can't retry its own save; on Postgres
    # the failed INSERT poisons the surrounding transaction, so retry the whole
    # create from outside any transaction):
    #
    #   ConcernsOnRails::Support::UniqueRetry.with_retries { Invoice.create!(attrs) }
    module UniqueRetry
      module_function

      def with_retries(limit: 3)
        attempts = 0
        begin
          yield
        rescue ActiveRecord::RecordNotUnique
          attempts += 1
          raise if attempts >= limit

          retry
        end
      end
    end
  end
end
