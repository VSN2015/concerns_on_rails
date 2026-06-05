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

      # Source of truth for ISO 3166-1: alpha-2 => [English name, alpha-3].
      # ISO_COUNTRY_CODES and the name/alpha-3 lookups below are all derived
      # from this, so the three never drift apart.
      # Each value is a [name, alpha-3] pair (a tuple), not a list of words.
      # rubocop:disable Style/WordArray
      COUNTRY_DATA = {
        "AD" => ["Andorra", "AND"],
        "AE" => ["United Arab Emirates", "ARE"],
        "AF" => ["Afghanistan", "AFG"],
        "AG" => ["Antigua and Barbuda", "ATG"],
        "AI" => ["Anguilla", "AIA"],
        "AL" => ["Albania", "ALB"],
        "AM" => ["Armenia", "ARM"],
        "AO" => ["Angola", "AGO"],
        "AQ" => ["Antarctica", "ATA"],
        "AR" => ["Argentina", "ARG"],
        "AS" => ["American Samoa", "ASM"],
        "AT" => ["Austria", "AUT"],
        "AU" => ["Australia", "AUS"],
        "AW" => ["Aruba", "ABW"],
        "AX" => ["Åland Islands", "ALA"],
        "AZ" => ["Azerbaijan", "AZE"],
        "BA" => ["Bosnia and Herzegovina", "BIH"],
        "BB" => ["Barbados", "BRB"],
        "BD" => ["Bangladesh", "BGD"],
        "BE" => ["Belgium", "BEL"],
        "BF" => ["Burkina Faso", "BFA"],
        "BG" => ["Bulgaria", "BGR"],
        "BH" => ["Bahrain", "BHR"],
        "BI" => ["Burundi", "BDI"],
        "BJ" => ["Benin", "BEN"],
        "BL" => ["Saint Barthélemy", "BLM"],
        "BM" => ["Bermuda", "BMU"],
        "BN" => ["Brunei", "BRN"],
        "BO" => ["Bolivia", "BOL"],
        "BQ" => ["Caribbean Netherlands", "BES"],
        "BR" => ["Brazil", "BRA"],
        "BS" => ["Bahamas", "BHS"],
        "BT" => ["Bhutan", "BTN"],
        "BV" => ["Bouvet Island", "BVT"],
        "BW" => ["Botswana", "BWA"],
        "BY" => ["Belarus", "BLR"],
        "BZ" => ["Belize", "BLZ"],
        "CA" => ["Canada", "CAN"],
        "CC" => ["Cocos (Keeling) Islands", "CCK"],
        "CD" => ["Democratic Republic of the Congo", "COD"],
        "CF" => ["Central African Republic", "CAF"],
        "CG" => ["Republic of the Congo", "COG"],
        "CH" => ["Switzerland", "CHE"],
        "CI" => ["Côte d'Ivoire", "CIV"],
        "CK" => ["Cook Islands", "COK"],
        "CL" => ["Chile", "CHL"],
        "CM" => ["Cameroon", "CMR"],
        "CN" => ["China", "CHN"],
        "CO" => ["Colombia", "COL"],
        "CR" => ["Costa Rica", "CRI"],
        "CU" => ["Cuba", "CUB"],
        "CV" => ["Cape Verde", "CPV"],
        "CW" => ["Curaçao", "CUW"],
        "CX" => ["Christmas Island", "CXR"],
        "CY" => ["Cyprus", "CYP"],
        "CZ" => ["Czechia", "CZE"],
        "DE" => ["Germany", "DEU"],
        "DJ" => ["Djibouti", "DJI"],
        "DK" => ["Denmark", "DNK"],
        "DM" => ["Dominica", "DMA"],
        "DO" => ["Dominican Republic", "DOM"],
        "DZ" => ["Algeria", "DZA"],
        "EC" => ["Ecuador", "ECU"],
        "EE" => ["Estonia", "EST"],
        "EG" => ["Egypt", "EGY"],
        "EH" => ["Western Sahara", "ESH"],
        "ER" => ["Eritrea", "ERI"],
        "ES" => ["Spain", "ESP"],
        "ET" => ["Ethiopia", "ETH"],
        "FI" => ["Finland", "FIN"],
        "FJ" => ["Fiji", "FJI"],
        "FK" => ["Falkland Islands", "FLK"],
        "FM" => ["Micronesia", "FSM"],
        "FO" => ["Faroe Islands", "FRO"],
        "FR" => ["France", "FRA"],
        "GA" => ["Gabon", "GAB"],
        "GB" => ["United Kingdom", "GBR"],
        "GD" => ["Grenada", "GRD"],
        "GE" => ["Georgia", "GEO"],
        "GF" => ["French Guiana", "GUF"],
        "GG" => ["Guernsey", "GGY"],
        "GH" => ["Ghana", "GHA"],
        "GI" => ["Gibraltar", "GIB"],
        "GL" => ["Greenland", "GRL"],
        "GM" => ["Gambia", "GMB"],
        "GN" => ["Guinea", "GIN"],
        "GP" => ["Guadeloupe", "GLP"],
        "GQ" => ["Equatorial Guinea", "GNQ"],
        "GR" => ["Greece", "GRC"],
        "GS" => ["South Georgia and the South Sandwich Islands", "SGS"],
        "GT" => ["Guatemala", "GTM"],
        "GU" => ["Guam", "GUM"],
        "GW" => ["Guinea-Bissau", "GNB"],
        "GY" => ["Guyana", "GUY"],
        "HK" => ["Hong Kong", "HKG"],
        "HM" => ["Heard Island and McDonald Islands", "HMD"],
        "HN" => ["Honduras", "HND"],
        "HR" => ["Croatia", "HRV"],
        "HT" => ["Haiti", "HTI"],
        "HU" => ["Hungary", "HUN"],
        "ID" => ["Indonesia", "IDN"],
        "IE" => ["Ireland", "IRL"],
        "IL" => ["Israel", "ISR"],
        "IM" => ["Isle of Man", "IMN"],
        "IN" => ["India", "IND"],
        "IO" => ["British Indian Ocean Territory", "IOT"],
        "IQ" => ["Iraq", "IRQ"],
        "IR" => ["Iran", "IRN"],
        "IS" => ["Iceland", "ISL"],
        "IT" => ["Italy", "ITA"],
        "JE" => ["Jersey", "JEY"],
        "JM" => ["Jamaica", "JAM"],
        "JO" => ["Jordan", "JOR"],
        "JP" => ["Japan", "JPN"],
        "KE" => ["Kenya", "KEN"],
        "KG" => ["Kyrgyzstan", "KGZ"],
        "KH" => ["Cambodia", "KHM"],
        "KI" => ["Kiribati", "KIR"],
        "KM" => ["Comoros", "COM"],
        "KN" => ["Saint Kitts and Nevis", "KNA"],
        "KP" => ["North Korea", "PRK"],
        "KR" => ["South Korea", "KOR"],
        "KW" => ["Kuwait", "KWT"],
        "KY" => ["Cayman Islands", "CYM"],
        "KZ" => ["Kazakhstan", "KAZ"],
        "LA" => ["Laos", "LAO"],
        "LB" => ["Lebanon", "LBN"],
        "LC" => ["Saint Lucia", "LCA"],
        "LI" => ["Liechtenstein", "LIE"],
        "LK" => ["Sri Lanka", "LKA"],
        "LR" => ["Liberia", "LBR"],
        "LS" => ["Lesotho", "LSO"],
        "LT" => ["Lithuania", "LTU"],
        "LU" => ["Luxembourg", "LUX"],
        "LV" => ["Latvia", "LVA"],
        "LY" => ["Libya", "LBY"],
        "MA" => ["Morocco", "MAR"],
        "MC" => ["Monaco", "MCO"],
        "MD" => ["Moldova", "MDA"],
        "ME" => ["Montenegro", "MNE"],
        "MF" => ["Saint Martin", "MAF"],
        "MG" => ["Madagascar", "MDG"],
        "MH" => ["Marshall Islands", "MHL"],
        "MK" => ["North Macedonia", "MKD"],
        "ML" => ["Mali", "MLI"],
        "MM" => ["Myanmar", "MMR"],
        "MN" => ["Mongolia", "MNG"],
        "MO" => ["Macao", "MAC"],
        "MP" => ["Northern Mariana Islands", "MNP"],
        "MQ" => ["Martinique", "MTQ"],
        "MR" => ["Mauritania", "MRT"],
        "MS" => ["Montserrat", "MSR"],
        "MT" => ["Malta", "MLT"],
        "MU" => ["Mauritius", "MUS"],
        "MV" => ["Maldives", "MDV"],
        "MW" => ["Malawi", "MWI"],
        "MX" => ["Mexico", "MEX"],
        "MY" => ["Malaysia", "MYS"],
        "MZ" => ["Mozambique", "MOZ"],
        "NA" => ["Namibia", "NAM"],
        "NC" => ["New Caledonia", "NCL"],
        "NE" => ["Niger", "NER"],
        "NF" => ["Norfolk Island", "NFK"],
        "NG" => ["Nigeria", "NGA"],
        "NI" => ["Nicaragua", "NIC"],
        "NL" => ["Netherlands", "NLD"],
        "NO" => ["Norway", "NOR"],
        "NP" => ["Nepal", "NPL"],
        "NR" => ["Nauru", "NRU"],
        "NU" => ["Niue", "NIU"],
        "NZ" => ["New Zealand", "NZL"],
        "OM" => ["Oman", "OMN"],
        "PA" => ["Panama", "PAN"],
        "PE" => ["Peru", "PER"],
        "PF" => ["French Polynesia", "PYF"],
        "PG" => ["Papua New Guinea", "PNG"],
        "PH" => ["Philippines", "PHL"],
        "PK" => ["Pakistan", "PAK"],
        "PL" => ["Poland", "POL"],
        "PM" => ["Saint Pierre and Miquelon", "SPM"],
        "PN" => ["Pitcairn Islands", "PCN"],
        "PR" => ["Puerto Rico", "PRI"],
        "PS" => ["Palestine", "PSE"],
        "PT" => ["Portugal", "PRT"],
        "PW" => ["Palau", "PLW"],
        "PY" => ["Paraguay", "PRY"],
        "QA" => ["Qatar", "QAT"],
        "RE" => ["Réunion", "REU"],
        "RO" => ["Romania", "ROU"],
        "RS" => ["Serbia", "SRB"],
        "RU" => ["Russia", "RUS"],
        "RW" => ["Rwanda", "RWA"],
        "SA" => ["Saudi Arabia", "SAU"],
        "SB" => ["Solomon Islands", "SLB"],
        "SC" => ["Seychelles", "SYC"],
        "SD" => ["Sudan", "SDN"],
        "SE" => ["Sweden", "SWE"],
        "SG" => ["Singapore", "SGP"],
        "SH" => ["Saint Helena", "SHN"],
        "SI" => ["Slovenia", "SVN"],
        "SJ" => ["Svalbard and Jan Mayen", "SJM"],
        "SK" => ["Slovakia", "SVK"],
        "SL" => ["Sierra Leone", "SLE"],
        "SM" => ["San Marino", "SMR"],
        "SN" => ["Senegal", "SEN"],
        "SO" => ["Somalia", "SOM"],
        "SR" => ["Suriname", "SUR"],
        "SS" => ["South Sudan", "SSD"],
        "ST" => ["São Tomé and Príncipe", "STP"],
        "SV" => ["El Salvador", "SLV"],
        "SX" => ["Sint Maarten", "SXM"],
        "SY" => ["Syria", "SYR"],
        "SZ" => ["Eswatini", "SWZ"],
        "TC" => ["Turks and Caicos Islands", "TCA"],
        "TD" => ["Chad", "TCD"],
        "TF" => ["French Southern Territories", "ATF"],
        "TG" => ["Togo", "TGO"],
        "TH" => ["Thailand", "THA"],
        "TJ" => ["Tajikistan", "TJK"],
        "TK" => ["Tokelau", "TKL"],
        "TL" => ["Timor-Leste", "TLS"],
        "TM" => ["Turkmenistan", "TKM"],
        "TN" => ["Tunisia", "TUN"],
        "TO" => ["Tonga", "TON"],
        "TR" => ["Turkey", "TUR"],
        "TT" => ["Trinidad and Tobago", "TTO"],
        "TV" => ["Tuvalu", "TUV"],
        "TW" => ["Taiwan", "TWN"],
        "TZ" => ["Tanzania", "TZA"],
        "UA" => ["Ukraine", "UKR"],
        "UG" => ["Uganda", "UGA"],
        "UM" => ["United States Minor Outlying Islands", "UMI"],
        "US" => ["United States", "USA"],
        "UY" => ["Uruguay", "URY"],
        "UZ" => ["Uzbekistan", "UZB"],
        "VA" => ["Vatican City", "VAT"],
        "VC" => ["Saint Vincent and the Grenadines", "VCT"],
        "VE" => ["Venezuela", "VEN"],
        "VG" => ["British Virgin Islands", "VGB"],
        "VI" => ["U.S. Virgin Islands", "VIR"],
        "VN" => ["Vietnam", "VNM"],
        "VU" => ["Vanuatu", "VUT"],
        "WF" => ["Wallis and Futuna", "WLF"],
        "WS" => ["Samoa", "WSM"],
        "YE" => ["Yemen", "YEM"],
        "YT" => ["Mayotte", "MYT"],
        "ZA" => ["South Africa", "ZAF"],
        "ZM" => ["Zambia", "ZMB"],
        "ZW" => ["Zimbabwe", "ZWE"]
      }.freeze
      # rubocop:enable Style/WordArray

      # ISO 3166-1 alpha-2 country codes (derived from COUNTRY_DATA).
      ISO_COUNTRY_CODES = Set.new(COUNTRY_DATA.keys).freeze

      # Downcased English country name => alpha-2, and alpha-3 => alpha-2.
      NAME_TO_ALPHA2 = COUNTRY_DATA.to_h { |code, (name, _a3)| [name.downcase, code] }.freeze
      ALPHA3_TO_ALPHA2 = COUNTRY_DATA.to_h { |code, (_name, a3)| [a3, code] }.freeze

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

      # Canonicalize a country value to its ISO 3166-1 alpha-2 code: an existing
      # alpha-2 is upcased; a 3-letter alpha-3 (e.g. "USA") and a recognized
      # English name (e.g. "Canada") map to the alpha-2. Unrecognized values are
      # returned unchanged, and non-strings pass through.
      def normalize_country_code(value)
        return value unless value.is_a?(String)

        trimmed = value.strip.squish
        return value if trimmed.empty?

        upper = trimmed.upcase
        return upper if ISO_COUNTRY_CODES.include?(upper)
        return ALPHA3_TO_ALPHA2[upper] if ALPHA3_TO_ALPHA2.key?(upper)

        NAME_TO_ALPHA2[trimmed.downcase] || value
      end
    end
  end
end
