class QfxImport < Import
  after_create :set_default_config

  validates :account, presence: true, on: :publish

  # Parses the stored QFX content and creates Import::Row records.
  # Overrides the CSV-based implementation in the base class.
  def generate_rows_from_csv
    rows.destroy_all

    transactions = OfxParser.parse(raw_file_str)

    mapped_rows = transactions.map do |trn|
      {
        date:     trn.date.to_s,
        amount:   trn.amount.to_s,
        currency: (trn.currency.presence || default_currency).to_s,
        name:     (trn.name.presence || default_row_name).to_s,
        notes:    trn.memo.to_s,
        account:  "",
        category: "",
        tags:     "",
        qty:      "",
        ticker:   "",
        price:    "",
        exchange_operating_mic: "",
        entity_type: ""
      }
    end

    rows.insert_all!(mapped_rows) if mapped_rows.any?
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      transactions = rows.map do |row|
        category = mappings.categories.mappable_for(row.category)
        tags = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        Transaction.new(
          category: category,
          tags: tags,
          entry: Entry.new(
            account: account,
            date: row.date_iso,
            amount: row.signed_amount,
            name: row.name,
            currency: row.currency,
            notes: row.notes,
            import: self
          )
        )
      end

      Transaction.import!(transactions, recursive: true)
    end
  end

  # The ACCTID value embedded in the QFX file, used for automatic account matching.
  def ofx_acct_id
    return nil unless raw_file_str.present?
    OfxParser.extract_account_id(raw_file_str)
  end

  def ofx_bank_name
    return nil unless raw_file_str.present?
    OfxParser.extract_bank_name(raw_file_str)
  end

  def mapping_steps
    [ Import::CategoryMapping, Import::TagMapping ]
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    %i[date amount name currency category tags notes]
  end

  # QFX has a fixed format so the configuration step is not needed.
  def skip_configuration?
    true
  end

  private

    def set_default_config
      self.signage_convention = "inflows_positive"
      self.date_format = "%Y-%m-%d"
      self.number_format = "1,234.56"
      save!
    end
end
