class QifImport < Import
  after_create :set_default_config

  validates :account, presence: true, on: :publish

  # Parses the stored QIF content and creates Import::Row records.
  def generate_rows_from_csv
    rows.destroy_all

    transactions = QifParser.parse(raw_file_str)

    mapped_rows = transactions.map do |trn|
      {
        date:                   trn.date.to_s,
        amount:                 trn.amount.to_s,
        currency:               default_currency.to_s,
        name:                   (trn.payee.presence || default_row_name).to_s,
        notes:                  trn.memo.to_s,
        category:               trn.category.to_s,
        tags:                   trn.tags.join("|"),
        account:                "",
        qty:                    "",
        ticker:                 "",
        price:                  "",
        exchange_operating_mic: "",
        entity_type:            ""
      }
    end

    if mapped_rows.any?
      rows.insert_all!(mapped_rows)
      rows.reset  # insert_all! bypasses AR cache; reset so callers see the new rows
    end
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      transactions = rows.map do |row|
        category = mappings.categories.mappable_for(row.category)
        tags     = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        Transaction.new(
          category: category,
          tags:     tags,
          entry:    Entry.new(
            account:  account,
            date:     row.date_iso,
            amount:   row.signed_amount,
            name:     row.name,
            currency: row.currency,
            notes:    row.notes,
            import:   self
          )
        )
      end

      Transaction.import!(transactions, recursive: true)

      # If the QIF file contains an "Opening Balance" entry, use it to anchor the
      # account's opening balance so the ForwardCalculator has the correct starting
      # point.  Without this, the auto-anchor created at account creation time
      # (defaulting to 2 years ago) would exclude all historical transactions.
      if (ob = QifParser.parse_opening_balance(raw_file_str))
        Account::OpeningBalanceManager.new(account).set_opening_balance(
          balance: ob[:amount],
          date:    ob[:date]
        )
      else
        # No "Opening Balance" in the QIF — move the anchor back automatically if
        # any imported transactions predate it, so the ForwardCalculator covers the
        # full history rather than silently dropping older entries.
        adjust_opening_anchor_if_needed!
      end
    end

    # Trigger a direct account sync after the transaction commits so the balance
    # is recalculated promptly, without waiting for the full family→account sync chain.
    account.sync_later
  end

  # Returns true if import! will move the opening anchor back to cover transactions
  # that predate the current anchor date. Used to show a notice in the confirm step.
  def will_adjust_opening_anchor?
    return false if QifParser.parse_opening_balance(raw_file_str).present?
    return false unless account.present?

    manager = Account::OpeningBalanceManager.new(account)
    return false unless manager.has_opening_anchor?

    earliest = earliest_row_date
    earliest.present? && earliest < manager.opening_date
  end

  # The date the opening anchor will be moved to when will_adjust_opening_anchor? is true.
  def adjusted_opening_anchor_date
    earliest = earliest_row_date
    (earliest - 1.day) if earliest.present?
  end

  # The account type declared in the QIF file (e.g. "CCard", "Bank").
  def qif_account_type
    return nil unless raw_file_str.present?

    QifParser.account_type(raw_file_str)
  end

  # Unique categories used across all rows (blank entries excluded).
  def row_categories
    rows.distinct.pluck(:category).reject(&:blank?).sort
  end

  # Unique tags used across all rows (blank entries excluded).
  def row_tags
    rows.flat_map(&:tags_list).uniq.reject(&:blank?).sort
  end

  # True once the category/tag selection step has been completed
  # (sync_mappings has been called, which always produces at least one mapping).
  def categories_selected?
    mappings.any?
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

  # QIF has a fixed format so the configuration step is not needed.
  def skip_configuration?
    true
  end

  private

    def adjust_opening_anchor_if_needed!
      manager = Account::OpeningBalanceManager.new(account)
      return unless manager.has_opening_anchor?

      earliest = earliest_row_date
      return unless earliest.present? && earliest < manager.opening_date

      Account::OpeningBalanceManager.new(account).set_opening_balance(
        balance: manager.opening_balance,
        date:    earliest - 1.day
      )
    end

    def earliest_row_date
      str = rows.minimum(:date)
      Date.parse(str) if str.present?
    end

    def set_default_config
      self.signage_convention = "inflows_positive"
      self.date_format        = "%Y-%m-%d"
      self.number_format      = "1,234.56"
      save!
    end
end
