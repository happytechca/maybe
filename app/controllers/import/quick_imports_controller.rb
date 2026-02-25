class Import::QuickImportsController < ApplicationController
  # Receives a QFX/OFX file dropped anywhere in the app and either:
  #   a) auto-assigns it to the linked account and routes to the clean step, or
  #   b) routes to the link_account step so the user can link the ACCTID once.
  #
  # Always responds with JSON { redirect: url } so the Stimulus drop controller
  # can use Turbo.visit() to navigate without a full-page reload.
  def create
    raw_bytes    = params.dig(:import, :qfx_file)&.read
    file_content = OfxParser.normalize_encoding(raw_bytes)

    unless file_content.present? && OfxParser.valid?(file_content)
      return render json: { error: "Must be a valid QFX or OFX file with at least one transaction" }, status: :unprocessable_entity
    end

    import = Current.family.imports.create!(
      type: "QfxImport",
      date_format: Current.family.date_format,
      quick: true
    )

    import.update!(raw_file_str: file_content)

    acct_id = import.ofx_acct_id
    account = acct_id.present? ? Current.family.accounts.find_by(ofx_account_id: acct_id) : nil

    if account
      import.account = account
      import.save!(validate: false)
      import.generate_rows_from_csv
      import.reload.sync_mappings

      render json: { redirect: import_clean_path(import) }
    else
      render json: { redirect: import_link_account_path(import) }
    end
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
