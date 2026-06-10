require "bigdecimal"

module ConcernsOnRails
  module Support
    # Formats an integer subunit amount (e.g. cents) as a human-readable money
    # string. Pure and stateless; used by Models::Monetizable. Uses BigDecimal
    # throughout so there is no binary-float rounding drift.
    module Money
      module_function

      # format(199999) => "$1,999.99"
      # format(-500, unit: "£") => "-£5.00"
      # format(1234, unit: "¥", precision: 0, subunit_to_unit: 1) => "¥1,234"
      def format(cents, options = {})
        unit      = options.fetch(:unit, "$")
        precision = options.fetch(:precision, 2)
        delimiter = options.fetch(:delimiter, ",")
        separator = options.fetch(:separator, ".")
        subunit   = options.fetch(:subunit_to_unit, 100)

        decimal = BigDecimal(cents.to_s) / subunit
        # BigDecimal#round returns an Integer for precision <= 0, so re-wrap it
        # in a BigDecimal before #to_s("F") (Integer#to_s would read "F" as a radix).
        rounded = BigDecimal(decimal.abs.round(precision).to_s)
        whole, _, frac = rounded.to_s("F").partition(".")
        whole = delimit(whole, delimiter)
        number = precision.positive? ? "#{whole}#{separator}#{frac.ljust(precision, '0')[0, precision]}" : whole

        # Take the sign from the ROUNDED magnitude so a value that rounds to zero
        # (e.g. -0.001 at precision 2) never prints a spurious "-".
        sign = decimal.negative? && !rounded.zero? ? "-" : ""
        "#{sign}#{unit}#{number}"
      end

      # Insert the thousands delimiter into a non-negative integer string.
      def delimit(integer_string, delimiter)
        integer_string.reverse.gsub(/(\d{3})(?=\d)/, "\\1#{delimiter}").reverse
      end
    end
  end
end
