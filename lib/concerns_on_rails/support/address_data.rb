module ConcernsOnRails
  module Support
    # Reference data + lookups for Models::Addressable. Kept here (mirroring
    # ColumnGuard / RandomValue) so the concern itself stays lean and so the
    # large constant tables live as plain literals rather than RuboCop-flagged
    # blocks. All lookups are case-insensitive and string-safe.
    #
    # Scope is *format/structure* only — this validates shape (a well-formed
    # postal code, a real ISO country code), never real-world deliverability.
    module AddressData
      module_function

      # ISO 3166-1 alpha-2 country codes.
      ISO_COUNTRY_CODES = Set.new(%w[
                                    AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ
                                    BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ
                                    CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ
                                    DE DJ DK DM DO DZ
                                    EC EE EG EH ER ES ET
                                    FI FJ FK FM FO FR
                                    GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY
                                    HK HM HN HR HT HU
                                    ID IE IL IM IN IO IQ IR IS IT
                                    JE JM JO JP
                                    KE KG KH KI KM KN KP KR KW KY KZ
                                    LA LB LC LI LK LR LS LT LU LV LY
                                    MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ
                                    NA NC NE NF NG NI NL NO NP NR NU NZ
                                    OM
                                    PA PE PF PG PH PK PL PM PN PR PS PT PW PY
                                    QA
                                    RE RO RS RU RW
                                    SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ
                                    TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ
                                    UA UG UM US UY UZ
                                    VA VC VE VG VI VN VU
                                    WF WS
                                    YE YT
                                    ZA ZM ZW
                                  ]).freeze

      # Per-country postal-code patterns (matched against the *normalized*,
      # upcased value). `:default` is a permissive fallback for everything else.
      POSTAL_FORMATS = {
        "US" => /\A\d{5}(-\d{4})?\z/,
        "CA" => /\A[A-Z]\d[A-Z] ?\d[A-Z]\d\z/,
        "GB" => /\A[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2}\z/,
        "AU" => /\A\d{4}\z/,
        "DE" => /\A\d{5}\z/,
        "FR" => /\A\d{5}\z/,
        default: /\A[A-Z0-9][A-Z0-9 -]{1,8}[A-Z0-9]\z/
      }.freeze

      # USPS state / territory abbreviations.
      US_STATES = Set.new(%w[
                            AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS
                            MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV
                            WI WY DC AS GU MP PR VI
                          ]).freeze

      # Canadian province / territory codes.
      CA_PROVINCES = Set.new(%w[AB BC MB NB NL NS NT NU ON PE QC SK YT]).freeze

      # True when `code` is a known ISO 3166-1 alpha-2 country code.
      def valid_country?(code)
        return false unless code.is_a?(String)

        ISO_COUNTRY_CODES.include?(code.upcase)
      end

      # Regexp to validate a postal code for the given country (falls back to
      # the permissive `:default` pattern for unmapped countries).
      def postal_format_for(country)
        POSTAL_FORMATS[country.to_s.upcase] || POSTAL_FORMATS[:default]
      end

      # Validate a state/region against US / CA sets. Returns true for any other
      # country (we only know those two), so callers needn't special-case.
      def valid_state?(country, code)
        return true unless code.is_a?(String)

        case country.to_s.upcase
        when "US" then US_STATES.include?(code.upcase)
        when "CA" then CA_PROVINCES.include?(code.upcase)
        else true
        end
      end

      # Squish + upcase a postal code, adding canonical spacing for CA
      # (`A1A1A1` -> `A1A 1A1`). Non-strings pass through unchanged.
      def normalize_postal(country, value)
        return value unless value.is_a?(String)

        normalized = value.strip.squish.upcase
        return normalized unless country.to_s.upcase == "CA"

        compact = normalized.delete(" ")
        compact.match?(/\A[A-Z]\d[A-Z]\d[A-Z]\d\z/) ? "#{compact[0, 3]} #{compact[3, 3]}" : normalized
      end
    end
  end
end
