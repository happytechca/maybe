# Development-only rake tasks for cleaning up test data.
# These tasks are DESTRUCTIVE and guarded to only run in development or test environments.
#
# Usage:
#   bin/rails dev:cleanup:transactions   # Remove all entries/transactions, keep accounts & users
#   bin/rails dev:cleanup:accounts       # Remove all accounts + their data, keep users & families
#   bin/rails dev:cleanup:full           # Remove all financial data, keep only users & families

namespace :dev do
  namespace :cleanup do
    desc "Remove all transaction/entry data from all accounts, keeping accounts and users intact"
    task transactions: :environment do
      guard_environment!

      counts = {}

      ActiveRecord::Base.transaction do
        # Transfers link pairs of entries — delete first to avoid FK violations
        counts[:transfers]         = Transfer.delete_all
        counts[:rejected_transfers] = RejectedTransfer.delete_all

        # Entries cascade-destroy their entryable (Transaction / Valuation / Trade)
        counts[:entries]           = Entry.delete_all

        # Computed tables that reference accounts but are built from entries
        counts[:balances]          = Balance.delete_all
        counts[:holdings]          = Holding.delete_all

        # Import history (rows + mappings hang off imports; mappings can also hang off accounts)
        counts[:import_mappings]   = Import::Mapping.where.not(mappable_type: "Account").delete_all
        counts[:import_rows]       = Import::Row.delete_all
        counts[:imports]           = Import.delete_all

        # Reset cached balance on each account to 0 so the UI doesn't show stale numbers
        Account.update_all(balance: 0, cash_balance: 0)
      end

      puts "Cleaned up transaction data:"
      counts.each { |table, n| puts "  #{table}: #{n} rows deleted" }
      puts "Accounts and users are untouched."
    end

    desc "Remove all accounts (and their data) from all families, keeping users and families intact"
    task accounts: :environment do
      guard_environment!

      counts = {}

      ActiveRecord::Base.transaction do
        counts[:transfers]          = Transfer.delete_all
        counts[:rejected_transfers] = RejectedTransfer.delete_all
        counts[:entries]            = Entry.delete_all
        counts[:balances]           = Balance.delete_all
        counts[:holdings]           = Holding.delete_all
        counts[:import_mappings]    = Import::Mapping.delete_all
        counts[:import_rows]        = Import::Row.delete_all
        counts[:imports]            = Import.delete_all
        counts[:syncs]              = Sync.delete_all
        counts[:plaid_accounts]     = PlaidAccount.delete_all
        counts[:plaid_items]        = PlaidItem.delete_all

        # Destroying accounts also destroys their accountable records
        # (Depository, CreditCard, Loan, Investment, etc.) via dependent: :destroy
        counts[:accounts] = 0
        Account.find_each { |a| a.destroy; counts[:accounts] += 1 }
      end

      puts "Cleaned up account data:"
      counts.each { |table, n| puts "  #{table}: #{n} rows deleted" }
      puts "Families and users are untouched."
    end

    desc "Remove ALL financial data, keeping only users and families (full fresh-start reset)"
    task full: :environment do
      guard_environment!

      counts = {}

      ActiveRecord::Base.transaction do
        counts[:transfers]          = Transfer.delete_all
        counts[:rejected_transfers] = RejectedTransfer.delete_all
        counts[:entries]            = Entry.delete_all
        counts[:balances]           = Balance.delete_all
        counts[:holdings]           = Holding.delete_all
        counts[:import_mappings]    = Import::Mapping.delete_all
        counts[:import_rows]        = Import::Row.delete_all
        counts[:imports]            = Import.delete_all
        counts[:syncs]              = Sync.delete_all
        counts[:plaid_accounts]     = PlaidAccount.delete_all
        counts[:plaid_items]        = PlaidItem.delete_all
        counts[:chats]              = Chat.delete_all
        counts[:categories]         = Category.delete_all
        counts[:tags]               = Tag.delete_all
        counts[:merchants]          = Merchant.delete_all
        counts[:rules]              = Rule.delete_all

        counts[:accounts] = 0
        Account.find_each { |a| a.destroy; counts[:accounts] += 1 }
      end

      puts "Full financial data cleanup complete:"
      counts.each { |table, n| puts "  #{table}: #{n} rows deleted" }
      puts "Users and families are untouched."
    end
  end

  # ---------------------------------------------------------------------------
  private

  def guard_environment!
    unless Rails.env.development? || Rails.env.test?
      abort "ERROR: dev:cleanup tasks can only run in development or test environments. Aborting."
    end
  end
end
