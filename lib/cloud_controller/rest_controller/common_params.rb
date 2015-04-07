require 'cgi'

module VCAP::CloudController::RestController
  class CommonParams
    def initialize(logger)
      @logger = logger
    end

    def parse(controller, params, query_string=nil)
      @logger.debug "parse_params: #{params} #{query_string}"
      # Sinatra squashes duplicate query parms into a single entry rather
      # than an array (which we might have for q)
      res = {}
      [
        ['inline-relations-depth', Integer],
        ['page',                   Integer],
        ['results-per-page',       Integer],
        ['q',                      String],
        ['order-direction',        String],
        ['orphan-relations',       Integer],
        ['exclude-relations',      String],
        ['include-relations',      String],
        ['order-by',               String],

      ].each do |key, klass|
        val = params[key]
        res[key.underscore.to_sym] = Object.send(klass.name, val) if val
      end

      if res[:q] && query_string && query_string.count('q=') > 1
        res[:q] = CGI.parse(query_string)['q']
      end

      # relationship names should be specified as a comma separated list
      if res[:exclude_relations]
        res[:exclude_relations] = res[:exclude_relations].split(',')
      end

      if res[:include_relations]
        res[:include_relations] = res[:include_relations].split(',')
      end

      if res[:order_by]
        attributes = res[:order_by].split(',')

        validate_query_parameter(controller, attributes)
        res[:order_by] = attributes
      end

      res
    end

    def validate_query_parameter(controller, attributes)
      attributes.each do |col|
        unless controller.class.query_parameters.to_a.include?(col)
          raise VCAP::Errors::ApiError.new_from_details(
                'BadQueryParameter',
                "invalid request parameter '#{col}' in order_by")
        end
      end
    end
  end
end
