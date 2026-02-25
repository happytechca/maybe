require "test_helper"

class QifImportTest < ActiveSupport::TestCase
  # ── QifParser unit tests ────────────────────────────────────────────────────

  SAMPLE_QIF = <<~QIF
    !Type:Tag
    NEUROPE2025
    ^
    NNYC2023
    DVoyage NYC 2023
    ^
    !Type:Cat
    NFood & Dining
    DFood and dining expenses
    E
    ^
    NFood & Dining:Restaurants
    DRestaurants
    E
    ^
    NSalary
    DSalary Income
    I
    ^
    !Type:CCard
    D6/ 4'20
    U-99.00
    T-99.00
    C*
    NTXFR
    PFrais Eval
    LFees & Charges
    ^
    D3/29'21
    U-28,500.00
    T-28,500.00
    PVirement
    L[TD - Minimum chequing]
    ^
    D10/ 1'20
    U500.00
    T500.00
    PPayment received
    LFood & Dining/EUROPE2025
    ^
  QIF

  test "valid? returns true for QIF content" do
    assert QifParser.valid?(SAMPLE_QIF)
  end

  test "valid? returns false for non-QIF content" do
    refute QifParser.valid?("<OFX><STMTTRN></STMTTRN></OFX>")
    refute QifParser.valid?("date,amount,name\n2024-01-01,100,Coffee")
    refute QifParser.valid?(nil)
    refute QifParser.valid?("")
  end

  test "account_type extracts transaction section type" do
    assert_equal "CCard", QifParser.account_type(SAMPLE_QIF)
  end

  test "account_type ignores Tag and Cat sections" do
    qif = "!Type:Tag\nNMyTag\n^\n!Type:Cat\nNMycat\n^\n!Type:Bank\nD1/1'24\nT100.00\nPTest\n^\n"
    assert_equal "Bank", QifParser.account_type(qif)
  end

  test "parse returns correct number of transactions" do
    transactions = QifParser.parse(SAMPLE_QIF)
    assert_equal 3, transactions.length
  end

  test "parse extracts date correctly" do
    transactions = QifParser.parse(SAMPLE_QIF)
    assert_equal "2020-06-04", transactions[0].date
    assert_equal "2021-03-29", transactions[1].date
    assert_equal "2020-10-01", transactions[2].date
  end

  test "parse extracts negative amount with commas" do
    transactions = QifParser.parse(SAMPLE_QIF)
    assert_equal "-28500.00", transactions[1].amount
  end

  test "parse extracts simple negative amount" do
    transactions = QifParser.parse(SAMPLE_QIF)
    assert_equal "-99.00", transactions[0].amount
  end

  test "parse extracts payee" do
    transactions = QifParser.parse(SAMPLE_QIF)
    assert_equal "Frais Eval", transactions[0].payee
    assert_equal "Virement",   transactions[1].payee
  end

  test "parse extracts category and ignores transfer accounts" do
    transactions = QifParser.parse(SAMPLE_QIF)
    assert_equal "Fees & Charges", transactions[0].category
    assert_equal "",               transactions[1].category  # [TD - Minimum chequing] = transfer
    assert_equal "Food & Dining",  transactions[2].category
  end

  test "parse extracts tags from L field slash suffix" do
    transactions = QifParser.parse(SAMPLE_QIF)
    assert_equal [],               transactions[0].tags
    assert_equal [],               transactions[1].tags
    assert_equal [ "EUROPE2025" ], transactions[2].tags
  end

  test "parse_categories returns all categories" do
    categories = QifParser.parse_categories(SAMPLE_QIF)
    names = categories.map(&:name)
    assert_includes names, "Food & Dining"
    assert_includes names, "Food & Dining:Restaurants"
    assert_includes names, "Salary"
  end

  test "parse_categories marks income vs expense correctly" do
    categories = QifParser.parse_categories(SAMPLE_QIF)
    salary = categories.find { |c| c.name == "Salary" }
    food   = categories.find { |c| c.name == "Food & Dining" }
    assert salary.income
    refute food.income
  end

  test "parse_tags returns all tags" do
    tags = QifParser.parse_tags(SAMPLE_QIF)
    names = tags.map(&:name)
    assert_includes names, "EUROPE2025"
    assert_includes names, "NYC2023"
  end

  test "parse_tags captures description" do
    tags = QifParser.parse_tags(SAMPLE_QIF)
    nyc = tags.find { |t| t.name == "NYC2023" }
    assert_equal "Voyage NYC 2023", nyc.description
  end

  test "normalize_encoding returns content unchanged when already valid UTF-8" do
    result = QifParser.normalize_encoding("!Type:CCard\n")
    assert_equal "!Type:CCard\n", result
  end

  # ── QifImport model tests ───────────────────────────────────────────────────

  setup do
    @family  = families(:dylan_family)
    @account = accounts(:depository)
    @import  = QifImport.create!(
      family:  @family,
      account: @account
    )
  end

  test "generates rows from QIF content" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    assert_equal 3, @import.rows.count
  end

  test "generates row with correct date and amount" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    row = @import.rows.find_by(name: "Frais Eval")
    assert_equal "2020-06-04", row.date
    assert_equal "-99.00", row.amount
  end

  test "generates row with category" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    row = @import.rows.find_by(name: "Frais Eval")
    assert_equal "Fees & Charges", row.category
  end

  test "generates row with tags stored as pipe-separated string" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    row = @import.rows.find_by(name: "Payment received")
    assert_equal "EUROPE2025", row.tags
  end

  test "transfer rows have blank category" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    row = @import.rows.find_by(name: "Virement")
    assert row.category.blank?
  end

  test "skip_configuration? is true" do
    assert @import.skip_configuration?
  end

  test "qif_account_type returns CCard for sample" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    assert_equal "CCard", @import.qif_account_type
  end

  test "row_categories excludes blank categories" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    cats = @import.row_categories
    assert_includes cats, "Fees & Charges"
    assert_includes cats, "Food & Dining"
    refute_includes cats, ""
  end

  test "row_tags excludes blank tags" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    tags = @import.row_tags
    assert_includes tags, "EUROPE2025"
    refute_includes tags, ""
  end

  test "categories_selected? is false before sync_mappings" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv

    refute @import.categories_selected?
  end

  test "categories_selected? is true after sync_mappings" do
    @import.update!(raw_file_str: SAMPLE_QIF)
    @import.generate_rows_from_csv
    @import.sync_mappings

    assert @import.categories_selected?
  end
end
