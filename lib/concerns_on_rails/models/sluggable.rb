require "active_support/concern"
require "concerns_on_rails/core"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/slug_sources"

# Loaded here — with the concern, on first use — rather than at gem boot, so
# apps that never include Sluggable never load friendly_id.
begin
  require "friendly_id"
rescue LoadError
  raise ConcernsOnRails::MissingDependency,
        "ConcernsOnRails::Models::Sluggable requires the friendly_id gem. " \
        'Add `gem "friendly_id", "~> 5.4"` to your Gemfile to use it.'
end

module ConcernsOnRails
  module Models
    module Sluggable
      extend ActiveSupport::Concern

      # instance methods
      LABEL = "ConcernsOnRails::Models::Sluggable".freeze

      included do # rubocop:disable Metrics/BlockLength
        # Checked here rather than in sluggable_by: friendly_id's to_param lands
        # on the class at include time, so this is the first moment the clash
        # exists — and it catches a model that includes Sluggable without ever
        # calling the macro.
        sluggable_guard_hashable_to_param!

        # declare class attributes and set default values
        class_attribute :sluggable_field, instance_accessor: false
        self.sluggable_field ||= :name
        # `candidates:` — friendly_id slug candidates tried in order before the
        # uuid fallback; `max_length:` — word-boundary truncation of the slug.
        class_attribute :sluggable_candidates, instance_accessor: false, default: nil
        class_attribute :sluggable_max_length, instance_accessor: false, default: nil
        # Whether sluggable_by has run (the :name default above is only a
        # fallback) — Encryptable's guard checks declared sources only.
        class_attribute :sluggable_declared, instance_accessor: false, default: false

        extend FriendlyId

        # we need use a lambda to access the instance variable
        # instead of friendly_id :slug_source, use: :slugged
        friendly_id :slug_source, use: :slugged
        # friendly_id ->(record) { record.slug_source }, use: :slugged

        # we must override should_generate_new_friendly_id? to support update slug
        # if we don't override this method, friendly_id will not generate the new slug when update
        define_method :should_generate_new_friendly_id? do # rubocop:disable Metrics/CyclomaticComplexity
          return true if @sluggable_force_regenerate # regenerate_slug!

          field = self.class.sluggable_field
          slug_column = self.class.friendly_id_config.slug_column

          # A missing slug is built whenever there is a source to build it
          # from: legacy/imported rows with a NULL slug self-heal, and a blank
          # slug ASSIGNED in this save — "" from an optional form field, or
          # nil, friendly_id's way to ask for a fresh one — is not stored as
          # is (a second "" would trip the slug's unique index).
          return true if send(slug_column).blank? && slug_source.present?

          # An explicitly-assigned slug wins — don't overwrite it with a generated
          # one when the slug column itself is being changed in this save. The
          # exception is a slug friendly_id BUILT earlier in this save whose
          # source has changed since (see #sluggable_built_slug_stale?).
          changing_slug = respond_to?("will_save_change_to_#{slug_column}?") &&
                          send("will_save_change_to_#{slug_column}?")
          return sluggable_built_slug_stale? if changing_slug

          source_changed = respond_to?("will_save_change_to_#{field}?") &&
                           send("will_save_change_to_#{field}?")

          source_changed || sluggable_scope_changed?
        end

        # Defined on the class (like the method above) so it sits ABOVE
        # FriendlyId::Slugged in the ancestor chain — a module-level override
        # here would be shadowed by friendly_id's own. Truncates each candidate
        # at a word (separator) boundary; the uniqueness suffix friendly_id
        # appends on a conflict is added AFTER, on purpose — friendly_id's own
        # `slug_limit` hard-cuts characters and squeezes the uuid inside the
        # limit, which is rarely what a URL wants.
        define_method :normalize_friendly_id do |value|
          normalized = super(value)
          limit = self.class.sluggable_max_length
          return normalized unless limit && normalized.respond_to?(:truncate)

          normalized.truncate(limit, omission: "", separator: friendly_id_config.sequence_separator)
        end

        # friendly_id's (private) set_slug, wrapped to remember the slug it
        # built and the candidates it built it from. That is what lets a later
        # phase tell "our slug, built before its source settled" apart from a
        # slug the caller assigned — both are a pending change to the column.
        # A slug handed in pre-normalized (friendly_id's own set_friendly_id)
        # is not ours to rebuild.
        define_method :set_slug do |normalized_slug = nil|
          column = friendly_id_config.slug_column
          before = send(column)
          result = super(normalized_slug)
          built = send(column)
          @sluggable_built = { slug: built, from: sluggable_candidate_key } if normalized_slug.nil? && built != before
          result
        end
        private :set_slug

        # friendly_id builds the slug in a before_validation registered HERE,
        # at include time, so a sibling included later — Sanitizable's
        # `on: :write`, Normalizable, the host's own before_validation — used
        # to transform the source only after the slug was built from the raw
        # value. Every before_validation has run by the time validations do,
        # so a stale slug is rebuilt here: order-independent, and before any
        # sibling's before_save reads it. PREPENDED so every validator sees
        # the final slug — friendly_id's reserved-words exclusion is
        # registered at `extend FriendlyId` above (its default `use :reserved`).
        validate :sluggable_rebuild_stale_slug, prepend: true

        # The memo describes ONE save. Once it is written, a later explicit
        # slug that happens to equal an old built one must read as explicit.
        # A failed save never gets here, so a slug it left pending can still
        # be rebuilt when the source changes before the retry.
        after_save :sluggable_forget_built_slug
      end

      # class methods
      # A real module (not `class_methods do`) so the macro and its private
      # helpers aren't constrained by Metrics/BlockLength (the Stateable
      # precedent). ActiveSupport::Concern auto-extends ClassMethods.
      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Define sluggable field, with optional friendly_id features.
        # Example:
        #   sluggable_by :wonderful_name
        #   sluggable_by :title, history: true            # old slugs keep resolving (needs a friendly_id_slugs table)
        #   sluggable_by :title, scope: :account_id       # slugs unique per scope column
        #   sluggable_by :title, reserved_words: %w[new]  # block these slugs (a UUID is appended instead)
        #   sluggable_by :title, finders: true            # Model.find accepts a slug directly
        #   sluggable_by :title, candidates: [:title, %i[title city]]   # try "title", then "title-city", then a uuid
        #   sluggable_by :title, max_length: 60                        # truncate at a word boundary
        def sluggable_by(field, history: false, scope: nil, reserved_words: nil, finders: false,
                         candidates: nil, max_length: nil)
          # Validated before anything is assigned: a refused declaration must
          # not leave the class slugging from the field it was refused for.
          field = field.to_sym
          candidates = sluggable_validate_candidates!(candidates)
          max_length = sluggable_validate_max_length!(max_length)
          sluggable_guard_encryptable!(sluggable_source_fields(field, candidates))
          # Validate the slug column too (a missing one used to fail at first save
          # with an opaque friendly_id error); an association scope: is exempt.
          scope_column = scope && reflect_on_association(scope.to_sym) ? nil : scope
          ensure_columns!("ConcernsOnRails::Models::Sluggable",
                          [field, friendly_id_config.slug_column, scope_column].compact,
                          types: { friendly_id_config.slug_column.to_sym => "string:uniq" })
          self.sluggable_field = field
          self.sluggable_candidates = candidates
          self.sluggable_max_length = max_length
          self.sluggable_declared = true
          return unless history || scope || reserved_words || finders

          reconfigure_friendly_id(history: history, scope: scope,
                                  reserved_words: reserved_words, finders: finders)
        end

        # The attribute names the slug is built from: the `candidates:` entries
        # that are Symbols/Strings (nested arrays flattened) when given — they
        # replace the sluggable field — else the sluggable field. Procs are
        # opaque and left out; attribute aliases resolve to their column.
        def sluggable_source_fields(field = sluggable_field, candidates = sluggable_candidates)
          sources = ConcernsOnRails::Support::SlugSources
          sources.resolve_aliases(self, sources.symbolize(sources.declared(field, candidates)))
        end

        private

        # A slug is a PLAINTEXT derivative of its source ("123-45-6789"), so an
        # encrypted field must never feed one. Mirror of Encryptable's guard,
        # covering the reverse order (sluggable_by declared AFTER encryptable).
        # A method or Proc candidate that reads an encrypted field cannot be
        # seen from here — keep encrypted values out of those yourself.
        # Encryptable also re-checks at save time (the implicit :name default
        # and later declarations included).
        def sluggable_guard_encryptable!(sources)
          return unless respond_to?(:encryptable_rules)

          overlap = sources & encryptable_rules.keys
          return if overlap.empty?

          raise ArgumentError,
                "#{LABEL}: #{overlap.map { |f| ":#{f}" }.join(', ')} declared with both Encryptable and " \
                "Sluggable; the slug would store the decrypted plaintext in the slug column. " \
                "Slug from a non-sensitive field instead."
        end

        # Mirror of Hashable's macro-time guard, covering the reverse
        # declaration order (Hashable declared BEFORE Sluggable) — friendly_id's
        # to_param would land above Hashable's and silently win.
        def sluggable_guard_hashable_to_param!
          return unless respond_to?(:hashable_to_param) && hashable_to_param

          raise ArgumentError,
                "#{LABEL}: Sluggable/friendly_id overrides to_param, which conflicts with " \
                "Hashable's `to_param: true` on ':#{hashable_field}' (the winner would depend on include order). " \
                "Drop one, or override to_param on the model yourself."
        end

        # friendly_id's candidate shapes: a Symbol/String (method), a Proc, or an
        # Array of those (joined with the separator).
        def sluggable_validate_candidates!(candidates)
          return nil if candidates.nil?
          unless candidates.is_a?(Array) && candidates.any?
            raise ArgumentError,
                  "#{LABEL}: candidates: must be an Array of Symbols/Procs/Arrays (got #{candidates.inspect})"
          end

          candidates
        end

        def sluggable_validate_max_length!(max_length)
          return nil if max_length.nil?
          unless max_length.is_a?(Integer) && max_length.positive?
            raise ArgumentError,
                  "#{LABEL}: max_length: must be a positive Integer (got #{max_length.inspect})"
          end

          max_length
        end

        # Re-runs friendly_id with the extra modules. friendly_id merges config
        # across calls, so this layers :history / :scoped / :finders / :reserved onto :slugged.
        def reconfigure_friendly_id(history:, scope:, reserved_words: nil, finders: false)
          modules = [:slugged]
          modules << :history if history
          modules << :scoped if scope
          modules << :finders if finders
          modules << :reserved if reserved_words
          # friendly_id's second argument is a positional options hash (not kwargs),
          # so pass it positionally to stay correct on both Ruby 2.7 and 3.x.
          friendly_id(:slug_source, friendly_id_options(modules, scope, reserved_words))
        end

        # Build friendly_id's positional options hash from the resolved modules.
        def friendly_id_options(modules, scope, reserved_words)
          options = { use: modules }
          options[:scope] = scope if scope
          options[:reserved_words] = Array(reserved_words).map(&:to_s) if reserved_words
          options
        end
      end

      # Instance methods
      # Returns the source for the slug
      # we are calling the class attribute, so we can use it in the lambda
      # Example:
      #   record.slug_source
      def slug_source
        candidates = self.class.sluggable_candidates
        return candidates if candidates

        field = self.class.sluggable_field
        respond_to?(field) ? send(field) : to_s
      end

      # Rebuild the slug from the current source (candidates included) and
      # save — even over a slug that was assigned by hand, which a normal save
      # deliberately leaves alone. Conflicts still get friendly_id's suffix.
      def regenerate_slug!
        @sluggable_force_regenerate = true
        save!
      ensure
        @sluggable_force_regenerate = false
      end

      private

      # True when the pending slug is the one set_slug built (not reassigned
      # since) and its candidates no longer normalize to what they were then.
      # A transform that leaves the normalized candidates unchanged ("Hello
      # World" squished) costs no rebuild and no query.
      #
      # "The one set_slug built" includes that slug as the slug column's own
      # write-time transforms left it (a Normalizable rule on :slug runs in
      # before_validation too, possibly right after friendly_id).
      def sluggable_built_slug_stale?
        built = @sluggable_built
        return false unless built

        current = send(friendly_id_config.slug_column)
        return false unless current == built[:slug] || current == sluggable_transform_slug(built[:slug])

        sluggable_candidate_key != built[:from]
      end

      def sluggable_forget_built_slug
        @sluggable_built = nil
      end

      # friendly_id's own :scoped rule, which the should_generate_new_friendly_id?
      # override above replaced without ever consulting: a record moved to
      # another scope (`scope: :account_id` changed) whose slug the NEW scope
      # already holds rebuilds it from the source against that scope —
      # friendly_id's uuid suffix when the plain slug is taken there too —
      # instead of duplicating it. A slug that is free there is kept: it may
      # have been assigned by hand, and its URLs must survive the move. A slug
      # assigned in the same save still wins (the guard above). Persisted
      # records only: a new record's slug follows the source rules.
      def sluggable_scope_changed?
        config = friendly_id_config
        return false unless persisted? && config.uses?(:scoped)
        return false unless config.scope_columns.any? { |column| will_save_change_to_attribute?(column) }

        sluggable_slug_taken_in_scope?(config)
      end

      def sluggable_slug_taken_in_scope?(config)
        slug = send(config.slug_column)
        return false if slug.blank?

        scope = config.scope_columns.to_h { |column| [column, self[column]] }
        self.class.base_class.unscoped.where(scope).where(config.slug_column => slug)
            .where.not(self.class.primary_key => id).exists?
      end

      # The slug column's own write-time transforms — a write-mode Sanitizable
      # rule, then a Normalizable rule — as their before_validation callbacks
      # would apply them. A slug built in before_create comes after both.
      def sluggable_transform_slug(slug)
        return slug if slug.nil?

        column = friendly_id_config.slug_column.to_sym
        klass = self.class
        rule = klass.respond_to?(:sanitizable_rules) ? klass.sanitizable_rules[column] : nil
        slug = rule[:writer].call(slug) if rule && rule[:on] == :write
        return slug unless klass.respond_to?(:normalizable_rules) && klass.normalizable_rules.key?(column)

        klass.normalize(column, slug)
      end

      # The normalized candidate strings the slug is built from — friendly_id's
      # own Candidates, so reserved-word filtering and max_length: apply. No
      # query: availability is only checked when a slug is actually built.
      def sluggable_candidate_key
        FriendlyId::Candidates.new(self, send(friendly_id_config.base)).to_a
      end

      def sluggable_rebuild_stale_slug
        set_slug if sluggable_built_slug_stale?
      end

      # Support::GeneratedValues consumer. A column generated in before_create
      # (a Sequenceable number, a Hashable code) — after friendly_id's
      # before_validation built the slug, or found nothing to build it from —
      # may be the slug's source. set_slug's usual rules decide: a missing or
      # stale slug is built, an explicitly assigned one is kept, a conflict
      # gets friendly_id's uuid suffix.
      #
      # Every before_validation/before_save has already run, so what they
      # would have done to a new slug is done here: the reserved_words:
      # validator never sees it (a reserved slug is resolved the way
      # friendly_id resolves a taken one), and the slug column's own
      # Sanitizable/Normalizable rules are applied.
      def sluggable_generated_values_assigned(_columns)
        column = friendly_id_config.slug_column
        before = send(column)
        set_slug
        slug = send(column)
        return if slug == before

        slug = resolve_friendly_id_conflict([slug]) if sluggable_reserved_slug?(slug)
        transformed = sluggable_transform_slug(slug)
        send("#{column}=", transformed) unless transformed == send(column)
      end

      def sluggable_reserved_slug?(slug)
        config = friendly_id_config
        config.uses?(:reserved) && Array(config.reserved_words).include?(slug)
      end
    end
  end
end
