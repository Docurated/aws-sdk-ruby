# Copyright 2011-2013 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You
# may not use this file except in compliance with the License. A copy of
# the License is located at
#
#     http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF
# ANY KIND, either express or implied. See the License for the specific
# language governing permissions and limitations under the License.

module Aws

  # @api private
  class Translator

    include Util

    DEFAULT_OPTIONS = {
      documentation: true,
      timestamp_format: 'iso8601',
    }

    def initialize(src, options)
      @properties = {}
      @options = options
      DEFAULT_OPTIONS.each do |option, default|
        @options[option] = default unless @options.key?(option)
      end
      src.each_pair do |property, value|
        self.send("set_#{property}", value)
      end
    end

    def set_timestamp_format(format)
      @options = @options.merge(timestamp_format: format.sub(/Timestamp/, ''))
    end

    def set_documentation(docs)
      if docs && @options[:documentation]
        docs = docs.gsub(/<!--.*?-->/m, '')
        docs = docs.gsub(/<a>(.+?)<\/a>/m, '\1')
        docs = docs.gsub(/<examples?>.+?<\/examples?>/m, '')
        docs = docs.gsub(/<\/?note>/m, '')
        docs = docs.gsub(/\{(\S+)\}/, '`{\1}`')
        docs = docs.gsub(/\s+/, ' ').strip
        @properties['documentation'] = docs unless docs.empty?
      end
    end

    def translated
      raise NotImplementedError
    end

    class << self

      def translate(src, options)
        new(src, options).translated if src
      end

      def property(name, options = {})
        method_name = "set_#{options[:from] || name}"
        define_method(method_name) do |value|
          @properties[name.to_s] = value
        end
      end

      def metadata(name, options = {})
        define_method("set_#{name}") do |value|
          @properties['metadata'] ||= {}
          @properties['metadata'][options[:as] || name.to_s] = value
        end
      end

      def ignore(property)
        define_method("set_#{property}") { |value| }
      end

    end

  end

  # This tool translates APIs from the raw AWS format into a
  # `Seahorse::Model::Api`.  The formats are similar, but not fully
  # compatible.
  # @api private
  class ApiTranslator < Translator

    def self.translate(src, options = {})
      super(src, options)
    end

    def translated
      if @global_endpoint
        @properties['plugins'].delete('Aws::Plugins::RegionalEndpoint') if
        @properties['endpoint'] = @global_endpoint
      end
      api = Seahorse::Model::Api.from_hash(@properties)
      api.metadata = Hash[api.metadata.sort]
      @operations.values.each do |src|
        operation = OperationTranslator.translate(src, @options)
        api.operations[method_name(underscore(operation.name))] = operation
      end
      api
    end

    def method_name(operation_name)
      underscore(operation_name).sub(/_?\d{4}_\d{2}_\d{2}$/, '')
    end

    property :version, from: :api_version

    metadata :signing_name
    metadata :checksum_format
    metadata :json_version, as: 'json_version'
    metadata :target_prefix, as: 'json_target_prefix'
    metadata :service_full_name
    metadata :service_abbreviation
    metadata :result_wrapped
    metadata :xmlnamespace

    def set_type(type)
      plugins = @properties['plugins'] ||= []
      plugins << 'Aws::Plugins::GlobalConfiguration'
      plugins << 'Aws::Plugins::RegionalEndpoint'
      plugins << 'Aws::Plugins::EnvironmentCredentials'
      plugins << 'Aws::Plugins::ContentLength'
      plugins << 'Aws::Plugins::RestProtocol'
      plugins <<
        case type
        when 'query' then 'Aws::Plugins::QuerySerializer'
        when /json/ then 'Aws::Plugins::JsonSerializer'
        when /xml/ then 'Aws::Plugins::XmlSerializer'
        end if type
      plugins << 'Aws::Plugins::Signer'
    end

    def set_signature_version(version)
      return unless version
      signer = case version
      when 'v4' then 'Version4'
      when 'v3' then 'Version3'
      when 'v3https' then 'Version3Https'
      when 'cloudfront' then 'CloudFront'
      when 's3' then 'S3'
      when 'v2' then 'Version2'
      else raise "unhandled signer version `#{version}'"
      end
      @properties['metadata'] ||= {}
      @properties['metadata']['signer'] = signer
    end

    def set_global_endpoint(endpoint)
      @global_endpoint = endpoint
    end

    def set_endpoint_prefix(prefix)
      @properties['endpoint'] = "#{prefix}.%s.amazonaws.com"
    end

    def set_operations(operations)
      @operations = operations
    end

  end

  # @api private
  class OperationTranslator < Translator

    def translated
      @properties['http_method'] ||= 'POST'
      @properties['http_path'] ||= '/'

      if @input
        @input.members.each_pair do |member_name, member_shape|
          if member_shape.location == 'uri'
            placeholder = member_shape.serialized_name
            @properties['http_path'].sub!("{#{placeholder}}", "{#{member_name}}")
            member_shape.serialized_name = nil
          end
        end
      end

      operation = Seahorse::Model::Operation.from_hash(@properties)
      operation.input = @input if @input
      operation.output = @output if @output
      operation.errors = @errors if @errors
      operation
    end

    property :name
    ignore :documentation_url
    ignore :alias

    def set_http(http)
      @properties['http_method'] = http['method']
      @properties['http_path'] = http['uri']
    end

    def set_input(src)
      if src
        src = src.merge('type' => 'input')
        @input = InputShapeTranslator.translate(src, @options)
      end
    end

    def set_output(src)
      if src
        src = src.merge('type' => 'output')
        @output = OutputShapeTranslator.translate(src, @options)
      end
    end

    def set_errors(errors)
      @errors = errors.map { |src| OutputShapeTranslator.translate(src, @options) }
      @errors = nil if @errors.empty?
    end

  end

  # @api private
  class ShapeTranslator < Translator

    CONVERT_TYPES = {
      'long' => 'integer',
      'double' => 'float',
    }

    def translated

      if @properties['type'] == 'timestamp'
        @type_prefix = @options[:timestamp_format]
      end

      if @type_prefix
        @properties['type'] = "#{@type_prefix}_#{@properties['type']}"
      end

      shape = Seahorse::Model::Shapes::Shape.from_hash(@properties)
      shape.members = @members unless @members.nil?
      shape.keys = @keys if @keys
      shape
    end

    property :location
    property :serialized_name, from: :xmlname
    property :serialized_name, from: :location_name
    property :enum

    metadata :xmlnamespace
    metadata :xmlattribute
    metadata :payload
    metadata :wrapper

    ignore :shape_name
    ignore :member_order
    ignore :box
    ignore :streaming

    # validation properties
    ignore :pattern
    ignore :min_length
    ignore :max_length

    def set_xmlnamespace(xmlns)
      metadata = @properties['metadata'] ||= {}
      metadata['xmlns_uri'] = xmlns['uri']
      metadata['xmlns_prefix'] = xmlns['prefix'] if xmlns['prefix']
    end

    def set_type(type)
      @properties['type'] = CONVERT_TYPES[type] || type
    end

    def set_flattened(state)
      @type_prefix = 'flat' if state
    end

    def set_keys(member)
      @keys = self.class.translate(member, @options)
    end

    # Structure shapes have a hash of members.  Lists and maps have a
    # single member (with a type).
    def set_members(members)
      if members['type'].is_a?(String)
        @members = self.class.translate(members, @options)
      else
        @members = Seahorse::Model::Shapes::MemberHash.new
        members.each do |name, src|
          shape = self.class.translate(src, @options)
          shape.serialized_name ||= name
          @members[underscore(name)] = shape
        end
      end
    end

  end

  # @api private
  class InputShapeTranslator < ShapeTranslator
    property :required
  end

  # @api private
  class OutputShapeTranslator < ShapeTranslator
    ignore :required
  end

end