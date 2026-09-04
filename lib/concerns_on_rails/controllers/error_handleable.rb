require "active_support/concern"
require "concerns_on_rails/support/error_envelope"

module ConcernsOnRails
  module Controllers
    # Installs `rescue_from` handlers for the controller exceptions a JSON API
    # meets in practice and renders each as the error envelope Respondable uses.
    #
    #   class Api::BaseController < ApplicationController
    #     include ConcernsOnRails::Controllers::Respondable      # optional, but recommended
    #     include ConcernsOnRails::Controllers::ErrorHandleable
    #
    #     handle_errors except: :stale_object    # optional: let some propagate
    #   end
    #
    # Handled (key → exception → status):
    #   * :not_found                  ActiveRecord::RecordNotFound                 404
    #   * :parameter_missing          ActionController::ParameterMissing           400
    #   * :record_invalid             ActiveRecord::RecordInvalid                  422 (+ field errors)
    #   * :validation_error           ActiveModel::ValidationError                 422 (+ field errors)
    #   * :record_not_saved           ActiveRecord::RecordNotSaved                 422 (+ field errors, if any)
    #   * :record_not_destroyed       ActiveRecord::RecordNotDestroyed             422 (+ field errors, if any)
    #   * :stale_object               ActiveRecord::StaleObjectError               409
    #   * :record_not_unique          ActiveRecord::RecordNotUnique                409
    #   * :foreign_key_violation      ActiveRecord::InvalidForeignKey              409
    #   * :unpermitted_parameters     ActionController::UnpermittedParameters      400 (+ the param names)
    #   * :invalid_authenticity_token ActionController::InvalidAuthenticityToken   422
    #   * :bad_request                ActionController::BadRequest                 400
    #   * :parse_error                ActionDispatch::Http::Parameters::ParseError 400
    #   * :unknown_format             ActionController::UnknownFormat              406
    #
    # Statuses follow Rails' own `rescue_responses` wherever Rails has an
    # opinion; the two database-constraint races Rails leaves as 500s
    # (RecordNotUnique, InvalidForeignKey) get the REST-conventional 409.
    # Messages for database- and parser-level errors are deliberately generic:
    # the raw messages carry SQL fragments, table/column names, model class
    # names or the offending input, none of which belongs in an API response.
    #
    # If Respondable is also included on the controller, the handlers delegate
    # to `render_error` so the envelope shape stays in one place. Otherwise the
    # handlers render the same envelope inline.
    #
    # Each handler is a public instance method, so subclasses can override the
    # message wording or response shape without re-declaring the `rescue_from`.
    module ErrorHandleable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::ErrorHandleable".freeze

      # The envelope `code` is the key; the status is what the handler renders.
      # Exception names are strings so registration never forces a constant to
      # load (and a name absent from the host's Rails version is simply never
      # matched — `rescue_from` safe_constantizes at rescue time).
      HANDLERS = {
        not_found: { exception: "ActiveRecord::RecordNotFound",
                     handler: :handle_record_not_found, status: :not_found },
        parameter_missing: { exception: "ActionController::ParameterMissing",
                             handler: :handle_parameter_missing, status: :bad_request },
        record_invalid: { exception: "ActiveRecord::RecordInvalid",
                          handler: :handle_record_invalid, status: :unprocessable_entity },
        validation_error: { exception: "ActiveModel::ValidationError",
                            handler: :handle_validation_error, status: :unprocessable_entity },
        record_not_saved: { exception: "ActiveRecord::RecordNotSaved",
                            handler: :handle_record_not_saved, status: :unprocessable_entity },
        record_not_destroyed: { exception: "ActiveRecord::RecordNotDestroyed",
                                handler: :handle_record_not_destroyed, status: :unprocessable_entity },
        stale_object: { exception: "ActiveRecord::StaleObjectError",
                        handler: :handle_stale_object, status: :conflict },
        record_not_unique: { exception: "ActiveRecord::RecordNotUnique",
                             handler: :handle_record_not_unique, status: :conflict },
        foreign_key_violation: { exception: "ActiveRecord::InvalidForeignKey",
                                 handler: :handle_invalid_foreign_key, status: :conflict },
        unpermitted_parameters: { exception: "ActionController::UnpermittedParameters",
                                  handler: :handle_unpermitted_parameters, status: :bad_request },
        invalid_authenticity_token: { exception: "ActionController::InvalidAuthenticityToken",
                                      handler: :handle_invalid_authenticity_token, status: :unprocessable_entity },
        bad_request: { exception: "ActionController::BadRequest",
                       handler: :handle_bad_request, status: :bad_request },
        parse_error: { exception: "ActionDispatch::Http::Parameters::ParseError",
                       handler: :handle_parse_error, status: :bad_request },
        unknown_format: { exception: "ActionController::UnknownFormat",
                          handler: :handle_unknown_format, status: :not_acceptable }
      }.freeze

      included do
        # The keys still handled on this controller (trimmed by `handle_errors`).
        class_attribute :error_handleable_keys, instance_accessor: false, default: HANDLERS.keys

        HANDLERS.each_value do |spec|
          rescue_from spec[:exception], with: spec[:handler]
        end
      end

      class_methods do
        # Trim the default map: `only:` keeps just those keys, `except:` drops
        # them. Accepts a symbol or a list; calls accumulate. Removes only the
        # concern's OWN registrations (matched on exception name AND handler
        # method), so a `rescue_from` the host declared for the same exception
        # is untouched — and nothing is ever re-added, so the host's later
        # declarations keep their precedence. Returns the keys still active.
        #
        #   handle_errors except: :stale_object                 # let lock conflicts reach the error tracker
        #   handle_errors only: %i[not_found parameter_missing record_invalid]
        def handle_errors(only: nil, except: nil)
          keep = error_handleable_selection(only: only, except: except)
          dropped = HANDLERS.filter_map { |key, spec| [spec[:exception], spec[:handler]] unless keep.include?(key) }
          self.rescue_handlers = rescue_handlers.reject { |entry| dropped.include?(entry) }
          self.error_handleable_keys = error_handleable_keys & keep
        end

        # Validates only:/except: and returns the HANDLERS keys to keep.
        def error_handleable_selection(only:, except:)
          raise ArgumentError, "#{LABEL}: pass only: or except:, not both" if only && except

          keys = error_handleable_known_keys(Array(only || except))
          only ? keys : HANDLERS.keys - keys
        end

        def error_handleable_known_keys(list)
          keys = list.map(&:to_sym)
          unknown = keys - HANDLERS.keys
          return keys if unknown.empty?

          raise ArgumentError,
                "#{LABEL}: unknown handler key(s) #{unknown.map(&:inspect).join(', ')} — " \
                "valid keys: #{HANDLERS.keys.map(&:inspect).join(', ')}"
        end
        private :error_handleable_selection, :error_handleable_known_keys
      end

      def handle_record_not_found(_error)
        # Use a generic message: the raw RecordNotFound message leaks the model
        # class name and the queried attribute/value to API clients. Subclasses
        # can override this method to surface detail in non-production envs.
        render_handled_error(:not_found, message: "Resource not found")
      end

      def handle_parameter_missing(error)
        render_handled_error(:parameter_missing, message: "Parameter missing: #{error.param}")
      end

      def handle_record_invalid(error)
        render_handled_error(:record_invalid, message: error.message, errors: record_error_details(error))
      end

      # `validate!` on a plain ActiveModel::Model (form objects, service inputs).
      def handle_validation_error(error)
        model = error.respond_to?(:model) ? error.model : nil
        render_handled_error(:validation_error, message: error.message, errors: error_messages_of(model))
      end

      # `save!` refused by a callback abort (`throw :abort`) — the record may or
      # may not carry errors, so details are attached only when it does.
      def handle_record_not_saved(error)
        render_handled_error(:record_not_saved, message: error.message, errors: record_error_details(error))
      end

      def handle_record_not_destroyed(error)
        render_handled_error(:record_not_destroyed, message: error.message, errors: record_error_details(error))
      end

      # Optimistic locking (`lock_version`) lost the race. The raw message names
      # the model class; the client only needs to know to reload and retry.
      def handle_stale_object(_error)
        render_handled_error(:stale_object, message: "Resource was modified by another request; reload and retry")
      end

      # A unique index caught what a uniqueness validation raced past. The raw
      # message is the adapter's SQL error — table and column included.
      def handle_record_not_unique(_error)
        render_handled_error(:record_not_unique, message: "Resource already exists")
      end

      def handle_invalid_foreign_key(_error)
        render_handled_error(:foreign_key_violation, message: "Resource is referenced by other records")
      end

      # Only raised with `config.action_controller.action_on_unpermitted_parameters = :raise`.
      def handle_unpermitted_parameters(error)
        names = error.respond_to?(:params) ? Array(error.params).map(&:to_s) : []
        render_handled_error(:unpermitted_parameters,
                             message: "Unpermitted parameters: #{names.join(', ')}",
                             errors: names.empty? ? nil : names)
      end

      def handle_invalid_authenticity_token(_error)
        render_handled_error(:invalid_authenticity_token, message: "Invalid authenticity token")
      end

      # Malformed query string / form body (bad %-encoding, invalid UTF-8). The
      # raw message echoes the offending input — never reflect it back.
      def handle_bad_request(_error)
        render_handled_error(:bad_request, message: "Bad request")
      end

      # Unparseable JSON/XML request body. The raw message carries the parser's
      # excerpt of the body.
      def handle_parse_error(_error)
        render_handled_error(:parse_error, message: "Malformed request body")
      end

      # `respond_to` had no block for the requested format.
      def handle_unknown_format(_error)
        render_handled_error(:unknown_format, message: "Requested format is not supported")
      end

      private

      # Renders the envelope for a HANDLERS key: code = key, status from the table.
      def render_handled_error(key, message:, errors: nil)
        render_error_envelope(message: message, code: key.to_s, status: HANDLERS.fetch(key)[:status], errors: errors)
      end

      # Kept for subclasses that call it from a handler override.
      def render_error_envelope(message:, code:, status:, errors: nil)
        ConcernsOnRails::Support::ErrorEnvelope.render(
          self, message: message, code: code, status: status, details: errors
        )
      end

      def record_error_details(error)
        error_messages_of(error.respond_to?(:record) ? error.record : nil)
      end

      # `errors.full_messages` when the object has any, else nil so the
      # envelope omits `details` rather than emitting an empty array.
      def error_messages_of(object)
        return nil unless object.respond_to?(:errors)

        messages = object.errors.full_messages
        messages.empty? ? nil : messages
      end
    end
  end
end
