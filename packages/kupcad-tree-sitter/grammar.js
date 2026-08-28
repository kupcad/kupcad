module.exports = grammar({
  name: 'kupcad',

  extras: $ => [
    $.comment,
    $.docstring,
    /[\s\n]/,
  ],

  rules: {
    source_file: $ => repeat($._statement),

    _statement: $ => choice(
      $.class_declaration,
      $.module_declaration,
      $.method_declaration,
      $.import_statement,
      $.export_statement,
      $.assignment,
      $._expression
    ),

    // --- Declarations ---
    class_declaration: $ => seq(
      'class',
      field('name', $.constant),
      optional(seq('<', field('superclass', $.constant))),
      repeat($._statement),
      'end'
    ),

    module_declaration: $ => seq(
      'module',
      field('name', $.constant),
      repeat($._statement),
      'end'
    ),

    method_declaration: $ => seq(
      'def',
      field('name', $.identifier),
      optional($.parameters),
      repeat($._statement),
      'end'
    ),

    parameters: $ => seq(
      '(',
      commaSep($._parameter),
      ')'
    ),

    _parameter: $ => choice(
      $.identifier,
      $.keyword_parameter,
      $.splat_parameter
    ),

    keyword_parameter: $ => seq($.identifier, ':', optional($._expression)),
    splat_parameter: $ => seq(choice('*', '**', '&'), $.identifier),

    // --- Imports / Exports ---
    import_statement: $ => seq(
      'import',
      choice(
        $.string,
        $.constant,
        seq('{', commaSep(choice($.identifier, $.constant)), '}')
      ),
      optional(seq('from', $.string))
    ),

    export_statement: $ => seq(
      'export',
      choice(
        $.constant,
        seq('{', commaSep(choice($.identifier, $.constant)), '}')
      )
    ),

    // --- Expressions ---
    _expression: $ => choice(
      $.method_call,
      $.command_call,
      $.binary_expression,
      $.array,
      $.hash,
      $.identifier,
      $.constant,
      $.number,
      $.string,
      $.symbol,
      $.boolean
    ),

    method_call: $ => prec.left(2, seq(
      optional(seq(field('receiver', $._expression), choice('.', '&.'))),
      field('method', $.identifier),
      optional($.arguments),
      optional($.block)
    )),

    command_call: $ => prec.left(1, seq(
      field('method', $.identifier),
      commaSep1($._argument),
      optional($.block)
    )),

    arguments: $ => seq('(', commaSep($._argument), ')'),

    _argument: $ => choice(
      $._expression,
      $.keyword_argument
    ),

    keyword_argument: $ => seq(
      field('key', choice($.identifier, $.symbol)),
      ':',
      field('value', $._expression)
    ),

    block: $ => seq(
      'do',
      optional($.block_parameters),
      repeat($._statement),
      'end'
    ),

    block_parameters: $ => seq(
      '|',
      commaSep(choice($.identifier, $.array)), // Supports spatial destructuring |(x, y)|
      '|'
    ),

    binary_expression: $ => prec.left(1, seq(
      field('left', $._expression),
      field('operator', choice('+', '-', '*', '/', '%', '**', '==', '!=', '>', '<', '>=', '<=', '&&', '||', '&', '|', '^', '<<', '>>')),
      field('right', $._expression)
    )),

    assignment: $ => seq(
      field('left', choice($.identifier, $.constant, $.instance_variable, $.array)),
      choice('=', '+=', '-=', '*=', '/='),
      field('right', $._expression)
    ),

    // --- Literals ---
    array: $ => seq('[', commaSep($._expression), ']'),
    hash: $ => seq('{', commaSep($.keyword_argument), '}'),

    identifier: $ => /[a-z_][a-zA-Z0-9_]*[!?]?/,
    constant: $ => /[A-Z][a-zA-Z0-9_]*/,
    instance_variable: $ => /@[a-zA-Z_][a-zA-Z0-9_]*/,
    symbol: $ => /:[a-zA-Z_][a-zA-Z0-9_]*/,
    number: $ => /-?[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?/,
    string: $ => /"[^"]*"/,
    boolean: $ => choice('true', 'false', 'nil'),

    comment: $ => /#.*/,
    docstring: $ => /#\s*@[a-zA-Z_]+.*/,
  }
});

function commaSep(rule) {
  return optional(commaSep1(rule));
}

function commaSep1(rule) {
  return seq(rule, repeat(seq(',', rule)));
}
