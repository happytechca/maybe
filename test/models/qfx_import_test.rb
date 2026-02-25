require "test_helper"

class QfxImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper, ImportInterfaceTest

  # A minimal SGML-format QFX file with one debit and one credit transaction.
  SGML_QFX = <<~QFX
    OFXHEADER:100
    DATA:OFXSGML
    VERSION:151
    SECURITY:NONE
    ENCODING:USASCII
    CHARSET:1252
    COMPRESSION:NONE
    OLDFILEUID:NONE
    NEWFILEUID:NONE

    <OFX>
    <SIGNONMSGSRSV1>
    <SONRS>
    <STATUS>
    <CODE>0
    <SEVERITY>INFO
    </STATUS>
    <DTSERVER>20240101000000
    <LANGUAGE>ENG
    </SONRS>
    </SIGNONMSGSRSV1>
    <BANKMSGSRSV1>
    <STMTTRNRS>
    <TRNUID>0
    <STATUS>
    <CODE>0
    <SEVERITY>INFO
    </STATUS>
    <STMTRS>
    <CURDEF>USD
    <BANKACCTFROM>
    <BANKID>123456789
    <ACCTID>987654321
    <ACCTTYPE>CHECKING
    </BANKACCTFROM>
    <BANKTRANLIST>
    <DTSTART>20240101000000
    <DTEND>20240131000000
    <STMTTRN>
    <TRNTYPE>DEBIT
    <DTPOSTED>20240115000000
    <TRNAMT>-45.00
    <FITID>20240115001
    <NAME>Grocery Store
    <MEMO>Weekly groceries
    </STMTTRN>
    <STMTTRN>
    <TRNTYPE>CREDIT
    <DTPOSTED>20240120000000
    <TRNAMT>2500.00
    <FITID>20240120001
    <MEMO>Paycheck deposit
    </STMTTRN>
    </BANKTRANLIST>
    </STMTRS>
    </STMTTRNRS>
    </BANKMSGSRSV1>
    </OFX>
  QFX

  # An XML-format OFX file (newer format, valid XML with closing tags on leaf elements).
  XML_OFX = <<~OFX
    <?xml version="1.0" encoding="UTF-8"?>
    <OFX>
    <SIGNONMSGSRSV1>
    <SONRS>
    <STATUS><CODE>0</CODE><SEVERITY>INFO</SEVERITY></STATUS>
    <DTSERVER>20240101000000</DTSERVER>
    <LANGUAGE>ENG</LANGUAGE>
    </SONRS>
    </SIGNONMSGSRSV1>
    <BANKMSGSRSV1>
    <STMTTRNRS>
    <STMTRS>
    <CURDEF>EUR</CURDEF>
    <BANKTRANLIST>
    <STMTTRN>
    <TRNTYPE>DEBIT</TRNTYPE>
    <DTPOSTED>20240310000000</DTPOSTED>
    <TRNAMT>-12.50</TRNAMT>
    <FITID>20240310001</FITID>
    <NAME>Coffee Shop</NAME>
    </STMTTRN>
    </BANKTRANLIST>
    </STMTRS>
    </STMTTRNRS>
    </BANKMSGSRSV1>
    </OFX>
  OFX

  setup do
    @subject = @import = imports(:qfx)
    @import.update!(account: accounts(:depository))
  end

  # -- OfxParser unit tests --

  test "parser detects valid QFX content" do
    assert OfxParser.valid?(SGML_QFX)
    assert OfxParser.valid?(XML_OFX)
  end

  test "parser rejects invalid content" do
    assert_not OfxParser.valid?(nil)
    assert_not OfxParser.valid?("")
    assert_not OfxParser.valid?("date,amount\n01/01/2024,100")
    assert_not OfxParser.valid?("<OFX>no transactions here</OFX>")
  end

  test "normalize_encoding transcodes Windows-1252 bytes to UTF-8" do
    # Build a minimal QFX string with a Windows-1252 byte (0xC9 = É in cp1252)
    # embedded in a payee name, preceded by the CHARSET:1252 header declaration.
    windows_1252_content = "CHARSET:1252\n<OFX><STMTTRN><NAME>Caf\xC9 Bistro</NAME></STMTTRN></OFX>"
    windows_1252_content.force_encoding("ASCII-8BIT")

    normalized = OfxParser.normalize_encoding(windows_1252_content)

    assert_equal Encoding::UTF_8, normalized.encoding
    assert normalized.valid_encoding?
    assert_includes normalized, "CafÉ Bistro"
  end

  test "normalize_encoding preserves valid UTF-8 content unchanged" do
    # Some banks declare CHARSET:1252 but export UTF-8 bytes. We detect valid
    # UTF-8 first and skip transcoding so multi-byte characters aren't corrupted.
    utf8_content = "CHARSET:1252\n<OFX><STMTTRN><NAME>Caf\u00E9 Bistro</NAME></STMTTRN></OFX>"

    result = OfxParser.normalize_encoding(utf8_content)

    assert_equal Encoding::UTF_8, result.encoding
    assert result.valid_encoding?
    assert_includes result, "Café Bistro"
  end

  test "parser extracts transactions from SGML format" do
    transactions = OfxParser.parse(SGML_QFX)

    assert_equal 2, transactions.length

    debit = transactions[0]
    assert_equal "2024-01-15", debit.date
    assert_equal "-45.00", debit.amount
    assert_equal "Grocery Store", debit.name
    assert_equal "Weekly groceries", debit.memo
    assert_equal "USD", debit.currency

    credit = transactions[1]
    assert_equal "2024-01-20", credit.date
    assert_equal "2500.00", credit.amount
    assert_equal "USD", credit.currency
  end

  test "parser extracts transactions from XML format" do
    transactions = OfxParser.parse(XML_OFX)

    assert_equal 1, transactions.length

    trn = transactions[0]
    assert_equal "2024-03-10", trn.date
    assert_equal "-12.50", trn.amount
    assert_equal "Coffee Shop", trn.name
    assert_equal "EUR", trn.currency
  end

  test "parser uses MEMO as name when NAME is absent" do
    transactions = OfxParser.parse(SGML_QFX)
    credit = transactions[1]  # No NAME, only MEMO

    assert_equal "Paycheck deposit", credit.name
  end

  test "parser returns empty array for content with no transactions" do
    assert_equal [], OfxParser.parse("<OFX></OFX>")
  end

  # -- QfxImport model tests --

  test "skips configuration step" do
    assert @import.skip_configuration?
  end

  test "mapping steps include categories and tags only" do
    assert_equal [ Import::CategoryMapping, Import::TagMapping ], @import.mapping_steps
  end

  test "generates rows from QFX content" do
    @import.update!(raw_file_str: SGML_QFX)

    assert_difference "@import.rows.count", 2 do
      @import.generate_rows_from_csv
    end

    @import.reload
    rows = @import.rows.order(:date)

    debit_row = rows[0]
    assert_equal "2024-01-15", debit_row.date
    assert_equal "-45.00", debit_row.amount
    assert_equal "USD", debit_row.currency
    assert_equal "Grocery Store", debit_row.name
    assert_equal "Weekly groceries", debit_row.notes

    credit_row = rows[1]
    assert_equal "2024-01-20", credit_row.date
    assert_equal "2500.00", credit_row.amount
  end

  test "generates rows with correct signage convention" do
    @import.update!(raw_file_str: SGML_QFX)
    @import.generate_rows_from_csv
    @import.reload

    debit_row, credit_row = @import.rows.order(:date).first(2)

    # In Maybe, positive = outflow (expense), negative = inflow (income).
    # QFX uses inflows_positive, so -45 debit becomes +45 (expense).
    assert_equal 45.00, debit_row.signed_amount
    # And +2500 credit becomes -2500 (income).
    assert_equal(-2500.00, credit_row.signed_amount)
  end

  test "imports transactions from QFX file" do
    @import.update!(raw_file_str: SGML_QFX)
    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.reload

    assert_difference -> { Entry.count } => 2,
                      -> { Transaction.count } => 2 do
      @import.publish
    end

    assert_equal "complete", @import.reload.status
  end

  test "sets default config on create" do
    import = QfxImport.create!(family: families(:dylan_family))

    assert_equal "inflows_positive", import.signage_convention
    assert_equal "%Y-%m-%d", import.date_format
    assert_equal "1,234.56", import.number_format
  end

  test "generates rows with fitid stored" do
    @import.update!(raw_file_str: SGML_QFX)
    @import.generate_rows_from_csv
    @import.reload

    rows = @import.rows.order(:date)
    assert_equal "20240115001", rows[0].fitid
    assert_equal "20240120001", rows[1].fitid
  end

  # -- auto_match_rows! tests --

  test "auto_match_rows! matches row by FITID to existing entry" do
    existing_entry = Entry.create!(
      account: accounts(:depository),
      date: "2024-01-15",
      amount: 45.00,
      currency: "USD",
      name: "Grocery Store",
      fitid: "20240115001",
      entryable: Transaction.create!
    )

    @import.update!(raw_file_str: SGML_QFX)
    @import.generate_rows_from_csv
    @import.reload

    matched_row = @import.rows.find_by(fitid: "20240115001")
    assert matched_row.matched?, "Expected row with matching FITID to be matched"
    assert_equal existing_entry.id, matched_row.matched_entry_id
  end

  test "auto_match_rows! falls back to date+amount match when no FITID on existing entry" do
    existing_entry = Entry.create!(
      account: accounts(:depository),
      date: "2024-01-15",
      amount: 45.00,
      currency: "USD",
      name: "Grocery Store",
      fitid: nil,
      entryable: Transaction.create!
    )

    @import.update!(raw_file_str: SGML_QFX)
    @import.generate_rows_from_csv
    @import.reload

    matched_row = @import.rows.find_by(date: "2024-01-15")
    assert matched_row.matched?, "Expected row to be matched by date+amount fallback"
    assert_equal existing_entry.id, matched_row.matched_entry_id
  end

  test "auto_match_rows! does not match entry from a different account" do
    Entry.create!(
      account: accounts(:credit_card),
      date: "2024-01-15",
      amount: 45.00,
      currency: "USD",
      name: "Grocery Store",
      fitid: "20240115001",
      entryable: Transaction.create!
    )

    @import.update!(raw_file_str: SGML_QFX)
    @import.generate_rows_from_csv
    @import.reload

    matched_row = @import.rows.find_by(fitid: "20240115001")
    assert_not matched_row.matched?, "Should not match entry from a different account"
  end

  test "import! skips matched rows to prevent duplicates" do
    Entry.create!(
      account: accounts(:depository),
      date: "2024-01-15",
      amount: 45.00,
      currency: "USD",
      name: "Grocery Store",
      fitid: "20240115001",
      entryable: Transaction.create!
    )

    @import.update!(raw_file_str: SGML_QFX)
    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.reload

    # Only the credit row (unmatched) should be imported as a new entry
    assert_difference -> { Entry.count }, 1 do
      @import.publish
    end
  end

  test "import! stores fitid on newly created entries" do
    @import.update!(raw_file_str: SGML_QFX)
    @import.generate_rows_from_csv
    @import.sync_mappings
    @import.reload

    @import.publish

    fitids = @import.entries.pluck(:fitid).compact
    assert_includes fitids, "20240115001"
    assert_includes fitids, "20240120001"
  end
end
