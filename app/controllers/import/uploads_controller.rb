class Import::UploadsController < ApplicationController
  layout "imports"

  before_action :set_import

  def show
  end

  def sample_csv
    send_data @import.csv_template.to_csv,
      filename: "#{@import.type.underscore.split('_').first}_sample.csv",
      type: "text/csv",
      disposition: "attachment"
  end

  def update
    if @import.is_a?(QfxImport)
      handle_qfx_upload
    elsif @import.is_a?(QifImport)
      handle_qif_upload
    else
      handle_csv_upload
    end
  end

  private
    def set_import
      @import = Current.family.imports.find(params[:import_id])
    end

    def handle_qfx_upload
      raw_bytes    = upload_params[:qfx_file]&.read
      file_content = OfxParser.normalize_encoding(raw_bytes)

      unless file_content.present? && OfxParser.valid?(file_content)
        flash.now[:alert] = "Must be a valid QFX or OFX file with at least one transaction"
        return render :show, status: :unprocessable_entity
      end

      @import.account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))

      unless @import.account
        flash.now[:alert] = "Please select an account for this import"
        return render :show, status: :unprocessable_entity
      end

      @import.update!(raw_file_str: file_content)
      @import.generate_rows_from_csv
      @import.reload.sync_mappings

      redirect_to import_clean_path(@import), notice: "QFX file uploaded and parsed successfully."
    end

    def handle_csv_upload
      if csv_valid?(csv_str)
        @import.account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))
        @import.assign_attributes(raw_file_str: csv_str, col_sep: upload_params[:col_sep])
        @import.save!(validate: false)

        redirect_to import_configuration_path(@import, template_hint: true), notice: "CSV uploaded successfully."
      else
        flash.now[:alert] = "Must be valid CSV with headers and at least one row of data"

        render :show, status: :unprocessable_entity
      end
    end

    def csv_str
      @csv_str ||= upload_params[:csv_file]&.read || upload_params[:raw_file_str]
    end

    def csv_valid?(str)
      begin
        csv = Import.parse_csv_str(str, col_sep: upload_params[:col_sep])
        return false if csv.headers.empty?
        return false if csv.count == 0
        true
      rescue CSV::MalformedCSVError
        false
      end
    end

    def handle_qif_upload
      raw_bytes    = upload_params[:qif_file]&.read
      file_content = QifParser.normalize_encoding(raw_bytes)

      unless file_content.present? && QifParser.valid?(file_content)
        flash.now[:alert] = "Must be a valid QIF file with at least one transaction"
        return render :show, status: :unprocessable_entity
      end

      @import.account = Current.family.accounts.find_by(id: params.dig(:import, :account_id))

      unless @import.account
        flash.now[:alert] = "Please select an account for this import"
        return render :show, status: :unprocessable_entity
      end

      @import.update!(raw_file_str: file_content)
      @import.generate_rows_from_csv

      redirect_to import_qif_category_selection_path(@import)
    end

    def upload_params
      params.require(:import).permit(:raw_file_str, :csv_file, :qfx_file, :qif_file, :col_sep, :account_id)
    end
end
