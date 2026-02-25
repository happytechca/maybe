class Import::LinkAccountsController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
    @accounts = Current.family.accounts.visible.alphabetically
  end

  def update
    account = Current.family.accounts.find(params[:account_id])

    acct_id = @import.ofx_acct_id
    account.update!(ofx_account_id: acct_id) if acct_id.present?

    @import.account = account
    @import.save!(validate: false)
    @import.generate_rows_from_csv
    @import.reload.sync_mappings

    redirect_to import_clean_path(@import), notice: "Account linked and file imported successfully."
  rescue ActiveRecord::RecordNotFound
    flash.now[:alert] = "Please select a valid account"
    @accounts = Current.family.accounts.visible.alphabetically
    render :show, status: :unprocessable_entity
  end

  private

    def set_import
      @import = Current.family.imports.find(params[:import_id])

      unless @import.is_a?(QfxImport) && @import.raw_file_str.present?
        redirect_to imports_path, alert: "Import not found or file missing"
      end
    end
end
