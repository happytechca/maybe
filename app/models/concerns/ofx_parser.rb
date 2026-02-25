# Parses OFX and QFX files (both SGML and XML variants).
#
# OFX/QFX files come in two formats:
#   - SGML (older): leaf elements have no closing tags, e.g. <TRNAMT>-45.00
#   - XML  (newer): standard XML, e.g. <TRNAMT>-45.00</TRNAMT>
#
# Both formats use closing tags for aggregate elements (<STMTTRN>...</STMTTRN>),
# which makes regex-based extraction reliable for both variants.
module OfxParser
  ParsedTransaction = Struct.new(:date, :amount, :name, :memo, :currency, :fitid, keyword_init: true)

  # Transcodes the raw file bytes to UTF-8.
  #
  # QFX files frequently declare CHARSET:1252 (Windows-1252) in their SGML header
  # and contain non-ASCII characters (e.g. accented merchant names).  PostgreSQL
  # requires valid UTF-8, so we must transcode before storing.
  #
  # Strategy:
  #   1. Force the string to binary so Ruby stops caring about encoding validity.
  #   2. Inspect the OFX header for a CHARSET declaration.
  #   3. Transcode from the declared encoding (default Windows-1252) to UTF-8,
  #      replacing any bytes that cannot be represented.
  def self.normalize_encoding(content)
    return content if content.nil?

    binary = content.b  # Force to ASCII-8BIT (binary); never raises on invalid bytes

    # If the bytes are already valid UTF-8, use them as-is.
    # Some banks declare CHARSET:1252 in the header but export UTF-8 anyway.
    utf8_attempt = binary.dup.force_encoding("UTF-8")
    return utf8_attempt if utf8_attempt.valid_encoding?

    # Not valid UTF-8 — transcode from the encoding declared in the OFX header.
    declared_charset = binary.match(/\bCHARSET:(\S+)/i)&.captures&.first

    source_encoding = case declared_charset
    when "1252"                      then "Windows-1252"
    when /\A(8859-1|iso-8859-1)\z/i  then "ISO-8859-1"
    else "Windows-1252"  # safest fallback for OFX SGML files
    end

    binary.encode("UTF-8", source_encoding, invalid: :replace, undef: :replace, replace: "")
  end

  # Returns true if the content looks like a valid OFX/QFX file with transactions.
  def self.valid?(content)
    return false if content.blank?

    # Treat as binary for the check so misencoded bytes don't raise.
    binary = content.b
    binary.match?(/<OFX>/i) && binary.match?(/<STMTTRN>/i)
  end

  # Extracts the account ID (<ACCTID>) from the file's BANKACCTFROM or CCACCTFROM block.
  # Returns nil if not found.
  def self.extract_account_id(content)
    return nil if content.blank?

    content = normalize_line_endings(normalize_encoding(content))
    ofx_body = extract_ofx_body(content)
    return nil unless ofx_body

    extract_field(ofx_body, "ACCTID")
  end

  # Extracts the bank/institution name from the <FI><ORG> field, falling back to <BANKID>.
  # Used for display purposes when prompting the user to link a new QFX account.
  def self.extract_bank_name(content)
    return nil if content.blank?

    content = normalize_line_endings(normalize_encoding(content))
    ofx_body = extract_ofx_body(content)
    return nil unless ofx_body

    extract_field(ofx_body, "ORG") || extract_field(ofx_body, "BANKID")
  end

  # Parses the OFX/QFX content and returns an array of ParsedTransaction structs.
  def self.parse(content)
    return [] unless valid?(content)

    content = normalize_line_endings(content)
    ofx_body = extract_ofx_body(content)
    return [] unless ofx_body

    currency = extract_field(ofx_body, "CURDEF") || "USD"

    transactions = []
    ofx_body.scan(/<STMTTRN>(.*?)<\/STMTTRN>/mi) do |match|
      trn = parse_transaction(match[0], currency)
      transactions << trn if trn
    end

    transactions
  end

  private

    def self.normalize_line_endings(content)
      content.gsub(/\r\n/, "\n").gsub(/\r/, "\n")
    end

    # Drops the SGML header block that precedes <OFX> in older QFX files.
    def self.extract_ofx_body(content)
      start = content.index(/<OFX>/i)
      start ? content[start..] : nil
    end

    def self.parse_transaction(trn_content, currency)
      date   = parse_date(extract_field(trn_content, "DTPOSTED"))
      amount = extract_field(trn_content, "TRNAMT")

      return nil unless date && amount

      name   = extract_field(trn_content, "NAME") ||
                extract_field(trn_content, "MEMO") ||
                "Imported transaction"
      memo   = extract_field(trn_content, "MEMO")
      fitid  = extract_field(trn_content, "FITID")

      ParsedTransaction.new(
        date:     date,
        amount:   amount,
        name:     name,
        memo:     memo,
        currency: currency,
        fitid:    fitid
      )
    end

    # Extracts the first text value for a given tag name.
    # Works for both SGML (<TAG>value) and XML (<TAG>value</TAG>).
    def self.extract_field(content, field)
      match = content.match(/<#{Regexp.escape(field)}[^>]*>\s*([^<\r\n]+)/i)
      match ? match[1].strip : nil
    end

    # Parses OFX date strings: YYYYMMDD, YYYYMMDDHHMMSS, or YYYYMMDDHHMMSS.XXX[-offset:Name]
    # Returns an ISO 8601 date string (YYYY-MM-DD).
    def self.parse_date(date_str)
      return nil unless date_str.present?

      Date.strptime(date_str[0, 8], "%Y%m%d").iso8601
    rescue Date::Error, ArgumentError
      nil
    end
end
