class AddOfxAccountIdToAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :ofx_account_id, :string
    add_index :accounts, [ :family_id, :ofx_account_id ], unique: true, where: "ofx_account_id IS NOT NULL"
  end
end
