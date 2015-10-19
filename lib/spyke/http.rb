require 'connection_pool'
require 'faraday'
require 'faraday_middleware'
require 'spyke/config'
require 'spyke/path'
require 'spyke/result'

module Spyke
  module Http
    extend ActiveSupport::Concern
    METHODS = %i{ get post put patch delete }

    included do
      class_attribute :connection_pool, instance_accessor: false
    end

    module ClassMethods
      METHODS.each do |method|
        define_method(method) do
          new_instance_or_collection_from_result scoped_request(method)
        end
      end

      def connection=(connection)
        self.connection_pool = ConnectionPool.new(size: 1) { connection }
      end

      def request(method, path, params = {})
        ActiveSupport::Notifications.instrument('request.spyke', method: method) do |payload|
          connection_pool.with do |connection|
            response = connection.send(method) do |request|
              if method == :get
                request.url path.to_s, params
              else
                request.url path.to_s
                request.body = params
              end
            end
            payload[:url], payload[:status] = response.env.url, response.status
            Result.new_from_response(response)
          end
        end
      end

      def new_instance_from_result(result)
        new_or_return result.data if result.data
      end

      def new_collection_from_result(result)
        Collection.new Array(result.data).map { |record| new_or_return(record) }, result.metadata
      end

      def uri(uri_template = nil)
        @uri ||= uri_template || default_uri
      end

      private

        def scoped_request(method)
          uri = new.uri
          params = current_scope.params.except(*uri.variables)
          request(method, uri, params)
        end

        def new_instance_or_collection_from_result(result)
          if result.data.is_a?(Array)
            new_collection_from_result(result)
          else
            new_instance_from_result(result)
          end
        end

        def new_or_return(attributes_or_object)
          if attributes_or_object.is_a?(Spyke::Base)
            attributes_or_object
          else
            new attributes_or_object
          end
        end

        def default_uri
          "#{model_name.element.pluralize}/(:id)"
        end
    end

    METHODS.each do |method|
      define_method(method) do |action = nil, params = {}|
        params = action if action.is_a?(Hash)
        path = resolve_path_from_action(action)

        result = self.class.request(method, path, params)

        add_errors_to_model(result.errors)
        self.attributes = result.data
      end
    end

    def uri
      Path.new(@uri_template, attributes) if @uri_template
    end

    private

      def add_errors_to_model(errors_hash)
        errors_hash.each do |field, field_errors|
          field_errors.each do |attributes|
            error_name = attributes.delete(:error).to_sym
            errors.add(field.to_sym, error_name, attributes.symbolize_keys)
          end
        end
      end

      def resolve_path_from_action(action)
        case action
        when Symbol then uri.join(action)
        when String then Path.new(action, attributes)
        else uri
        end
      end
  end
end
