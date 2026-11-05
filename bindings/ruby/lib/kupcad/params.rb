# frozen_string_literal: true

require 'json'

module Kupcad
  # The parameters' values as the JSON libkupcad takes them (`kupcad build -p`'s), each checked
  # first: JSON.generate writes a value it has no type for as its to_s, so a Rational became the
  # String "5/2", which a number parameter refused and a string parameter took.
  module Params
    # What a value, or a key of a Hash among them, may be besides an Array or a Hash: the values
    # JSON has a type for
    SCALARS = [String, Symbol, Integer, Float, TrueClass, FalseClass, NilClass].freeze

    # How deep JSON.generate nests values before it refuses them: the check stops there
    DEPTH = JSON::State.new.max_nesting

    module_function

    # `params` as JSON, '' for none (nil, or empty). Raises TypeError for a value JSON has no
    # type for, saying where, and ArgumentError for one it can't hold (NaN) or nested too deep.
    def json(params)
      check(params, 'params')
      params.nil? || (params.respond_to?(:empty?) && params.empty?) ? '' : JSON.generate(params)
    rescue JSON::GeneratorError, JSON::NestingError => e
      raise ArgumentError, "parameters: #{e.message}"
    end

    # Raises TypeError for a value in `value`, or a key of a Hash among them, that JSON has no type
    # for, saying where (`where`, as Ruby reads it: params[:holes][1]). Past DEPTH it stops:
    # JSON.generate refuses what is that deep, and going on would only use up the stack.
    def check(value, where, depth = 0)
      return if depth > DEPTH

      case value
      when Hash
        value.each do |key, item|
          check_scalar(key, "a key of #{where}")
          check(item, "#{where}[#{key.inspect}]", depth + 1)
        end
      when Array then value.each_with_index { |item, index| check(item, "#{where}[#{index}]", depth + 1) }
      else check_scalar(value, where)
      end
    end

    def check_scalar(value, where)
      return if SCALARS.any? { |type| value.is_a?(type) }

      raise TypeError, "#{where} is #{value.class}, which JSON has no type for (it has Strings, Symbols, Integers, " \
                       'Floats, true, false, nil, Arrays and Hashes)'
    end
    private_class_method :check, :check_scalar
  end
  private_constant :Params
end
