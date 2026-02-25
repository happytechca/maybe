# Parses QIF (Quicken Interchange Format) files.
#
# A QIF file is a plain-text format exported by Quicken. It is divided into
# sections, each introduced by a "!Type:<name>" header line.  Records within
# a section are terminated by a "^" line.  Each data line starts with a single
# letter field code followed immediately by the value.
#
# Sections handled:
#   !Type:Tag   – tag definitions (N=name, D=description)
#   !Type:Cat   – category definitions (N=name, D=description, I=income, E=expense)
#   !Type:CCard / !Type:Bank / !Type:Cash / !Type:Oth L  – transactions
#
# Transaction field codes:
#   D  date        M/ D'YY  or  MM/DD'YYYY
#   T  amount      may include commas, e.g. "-1,234.56"
#   U  amount      same as T (alternate field)
#   P  payee
#   M  memo
#   L  category    plain name or [TransferAccount]; /Tag suffix is supported
#   N  check/ref   (not a tag – the check number or reference)
#   C  cleared     X = cleared, * = reconciled
#   ^  end of record
module QifParser
  TRANSACTION_TYPES = %w[CCard Bank Cash Invst Oth\ L Oth\ A].freeze

  ParsedTransaction = Struct.new(
    :date, :amount, :payee, :memo, :category, :tags, :check_num, :cleared,
    keyword_init: true
  )

  ParsedCategory = Struct.new(:name, :description, :income, keyword_init: true)
  ParsedTag      = Struct.new(:name, :description, keyword_init: true)

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  # Transcodes raw file bytes to UTF-8.
  # Quicken typically writes QIF files in Windows-1252; falls back gracefully.
  def self.normalize_encoding(content)
    return content if content.nil?

    binary = content.b  # Force ASCII-8BIT; never raises on invalid bytes

    utf8_attempt = binary.dup.force_encoding("UTF-8")
    return utf8_attempt if utf8_attempt.valid_encoding?

    binary.encode("UTF-8", "Windows-1252", invalid: :replace, undef: :replace, replace: "")
  end

  # Returns true if the content looks like a valid QIF file.
  def self.valid?(content)
    return false if content.blank?

    binary = content.b
    binary.include?("!Type:")
  end

  # Returns the transaction account type string (e.g. "CCard", "Bank").
  # Skips Tag and Cat sections which are metadata, not transactions.
  def self.account_type(content)
    return nil if content.blank?

    content.scan(/^!Type:(.+)/i).flatten
           .map(&:strip)
           .reject { |t| %w[Tag Cat].include?(t) }
           .first
  end

  # Parses all transactions from the file, excluding the Opening Balance entry.
  # Returns an array of ParsedTransaction structs.
  def self.parse(content)
    return [] unless valid?(content)

    content = normalize_encoding(content)
    content = normalize_line_endings(content)

    type = account_type(content)
    return [] unless type

    section = extract_section(content, type)
    return [] unless section

    parse_records(section).filter_map { |record| build_transaction(record) }
  end

  # Returns the opening balance entry from the QIF file, if present.
  # In Quicken's QIF format, the first transaction of a bank/cash account is often
  # an "Opening Balance" record with payee "Opening Balance".  This entry is NOT a
  # real transaction – it is the account's starting balance.
  #
  # Returns a hash { date: Date, amount: BigDecimal } or nil.
  def self.parse_opening_balance(content)
    return nil unless valid?(content)

    content = normalize_encoding(content)
    content = normalize_line_endings(content)

    type = account_type(content)
    return nil unless type

    section = extract_section(content, type)
    return nil unless section

    record = parse_records(section).find { |r| r["P"]&.strip == "Opening Balance" }
    return nil unless record

    date   = parse_qif_date(record["D"])
    amount = parse_qif_amount(record["T"] || record["U"])
    return nil unless date && amount

    { date: Date.parse(date), amount: amount.to_d }
  end

  # Parses categories from the !Type:Cat section.
  # Returns an array of ParsedCategory structs.
  def self.parse_categories(content)
    return [] if content.blank?

    content = normalize_encoding(content)
    content = normalize_line_endings(content)

    section = extract_section(content, "Cat")
    return [] unless section

    parse_records(section).filter_map do |record|
      next unless record["N"].present?

      ParsedCategory.new(
        name:        record["N"],
        description: record["D"],
        income:      record.key?("I") && !record.key?("E")
      )
    end
  end

  # Parses tags from the !Type:Tag section.
  # Returns an array of ParsedTag structs.
  def self.parse_tags(content)
    return [] if content.blank?

    content = normalize_encoding(content)
    content = normalize_line_endings(content)

    section = extract_section(content, "Tag")
    return [] unless section

    parse_records(section).filter_map do |record|
      next unless record["N"].present?

      ParsedTag.new(
        name:        record["N"],
        description: record["D"]
      )
    end
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  def self.normalize_line_endings(content)
    content.gsub(/\r\n/, "\n").gsub(/\r/, "\n")
  end
  private_class_method :normalize_line_endings

  # Extracts the raw text of a named section (everything after its !Type: header
  # up to the next !Type: header or end-of-file).
  def self.extract_section(content, type_name)
    escaped = Regexp.escape(type_name)
    pattern = /^!Type:#{escaped}[^\n]*\n(.*?)(?=^!Type:|\z)/mi
    content.match(pattern)&.captures&.first
  end
  private_class_method :extract_section

  # Splits a section into an array of field-code => value hashes.
  # Single-letter codes with no value (e.g. "I", "E", "T") are stored with nil.
  def self.parse_records(section_content)
    records = []
    current = {}

    section_content.each_line do |line|
      line = line.chomp
      next if line.blank?

      if line == "^"
        records << current unless current.empty?
        current = {}
      else
        code  = line[0]
        value = line[1..]&.strip
        next unless code

        # Flag fields like "I" (income) and "E" (expense) have no meaningful value
        current[code] = value.presence
      end
    end

    records << current unless current.empty?
    records
  end
  private_class_method :parse_records

  def self.build_transaction(record)
    # "Opening Balance" is a Quicken convention for the account's starting balance –
    # it is not a real transaction and must not be imported as one.
    return nil if record["P"]&.strip == "Opening Balance"

    raw_date   = record["D"]
    raw_amount = record["T"] || record["U"]

    return nil unless raw_date.present? && raw_amount.present?

    date   = parse_qif_date(raw_date)
    amount = parse_qif_amount(raw_amount)

    return nil unless date && amount

    category, tags = parse_category_and_tags(record["L"])

    ParsedTransaction.new(
      date:      date,
      amount:    amount,
      payee:     record["P"],
      memo:      record["M"],
      category:  category,
      tags:      tags,
      check_num: record["N"],
      cleared:   record["C"]
    )
  end
  private_class_method :build_transaction

  # Separates the category name from any tag(s) appended with a "/" delimiter.
  # Transfer accounts are wrapped in brackets – treated as no category.
  #
  # Examples:
  #   "Food & Dining"              → ["Food & Dining", []]
  #   "Food & Dining/EUROPE2025"   → ["Food & Dining", ["EUROPE2025"]]
  #   "[TD - Chequing]"            → ["", []]
  def self.parse_category_and_tags(l_field)
    return [ "", [] ] if l_field.blank?

    # Transfer account reference
    if l_field.start_with?("[")
      return [ "", [] ]
    end

    parts    = l_field.split("/", 2)
    category = parts[0].strip
    tags     = parts[1].present? ? parts[1].split(":").map(&:strip).reject(&:blank?) : []

    [ category, tags ]
  end
  private_class_method :parse_category_and_tags

  # Parses a QIF date string into an ISO 8601 date string.
  #
  # Quicken uses several variants:
  #   M/D'YY        →  6/ 4'20  →  2020-06-04
  #   M/ D'YY       →  6/ 4'20  →  2020-06-04
  #   MM/DD/YYYY    →  06/04/2020 (less common)
  def self.parse_qif_date(date_str)
    return nil if date_str.blank?

    # Primary format: M/D'YY  or  M/ D'YY  (spaces around day are optional)
    if (m = date_str.match(%r{\A(\d{1,2})/\s*(\d{1,2})'(\d{2,4})\z}))
      month = m[1].to_i
      day   = m[2].to_i
      year  = m[3].length == 2 ? 2000 + m[3].to_i : m[3].to_i
      return Date.new(year, month, day).iso8601
    end

    # Fallback: MM/DD/YYYY
    if (m = date_str.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}))
      return Date.new(m[3].to_i, m[1].to_i, m[2].to_i).iso8601
    end

    nil
  rescue Date::Error, ArgumentError
    nil
  end
  private_class_method :parse_qif_date

  # Strips thousands-separator commas and returns a clean decimal string.
  def self.parse_qif_amount(amount_str)
    return nil if amount_str.blank?

    cleaned = amount_str.gsub(",", "").strip
    cleaned =~ /\A-?\d+\.?\d*\z/ ? cleaned : nil
  end
  private_class_method :parse_qif_amount
end
