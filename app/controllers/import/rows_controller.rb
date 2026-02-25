class Import::RowsController < ApplicationController
  before_action :set_import_row

  def update
    @row.update_and_sync(row_params)

    redirect_to import_row_path(@row.import, @row)
  end

  def unmatch
    @row.update_columns(matched_entry_id: nil)
    redirect_to import_clean_path(@import)
  end

  def show
  end

  private
    def row_params
      params.require(:import_row).permit(:type, :account, :date, :qty, :ticker, :price, :amount, :currency, :name, :category, :tags, :entity_type, :notes)
    end

    def set_import_row
      @import = Current.family.imports.find(params[:import_id])
      @row = @import.rows.find(params[:id])
    end
end
