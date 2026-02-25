class AddFitidAndMatchToImportRowsAndEntries < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :fitid, :string
    add_column :import_rows, :matched_entry_id, :uuid
    add_foreign_key :import_rows, :entries, column: :matched_entry_id

    add_column :entries, :fitid, :string
    add_index :entries, [ :account_id, :fitid ], where: "fitid IS NOT NULL"
  end
end
