class AddQuickToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :quick, :boolean, default: false, null: false
  end
end
