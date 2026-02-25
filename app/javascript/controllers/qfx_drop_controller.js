import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Enables drag-and-drop QFX/OFX import from anywhere in the app.
//
// Drop a .qfx or .ofx file onto the window; the controller posts it to the
// quick-import endpoint and navigates to the appropriate next step:
//   - Known account  → clean/review step (auto-matched via ACCTID)
//   - Unknown account → link-account step (one-time setup)
//
// Usage: add data-controller="qfx-drop" data-qfx-drop-url-value="..." to <body>.
export default class extends Controller {
  static values = { url: String }

  // Counter tracks nested dragenter/dragleave pairs so the overlay
  // doesn't flicker when the pointer moves between child elements.
  _dragCounter = 0
  _overlay = null

  connect() {
    this._onDragEnter = this._handleDragEnter.bind(this)
    this._onDragOver  = this._handleDragOver.bind(this)
    this._onDragLeave = this._handleDragLeave.bind(this)
    this._onDrop      = this._handleDrop.bind(this)

    window.addEventListener("dragenter", this._onDragEnter)
    window.addEventListener("dragover",  this._onDragOver)
    window.addEventListener("dragleave", this._onDragLeave)
    window.addEventListener("drop",      this._onDrop)
  }

  disconnect() {
    window.removeEventListener("dragenter", this._onDragEnter)
    window.removeEventListener("dragover",  this._onDragOver)
    window.removeEventListener("dragleave", this._onDragLeave)
    window.removeEventListener("drop",      this._onDrop)
    this._overlay?.remove()
    this._overlay = null
  }

  // ─── drag event handlers ──────────────────────────────────────────────────

  _handleDragEnter(e) {
    if (!this._hasFiles(e)) return
    this._dragCounter++
    if (this._dragCounter === 1) this._showOverlay()
  }

  _handleDragOver(e) {
    if (!this._hasFiles(e)) return
    e.preventDefault()
    e.dataTransfer.dropEffect = "copy"
  }

  _handleDragLeave(e) {
    if (!this._hasFiles(e) && this._dragCounter === 0) return
    this._dragCounter = Math.max(0, this._dragCounter - 1)
    if (this._dragCounter === 0) this._hideOverlay()
  }

  _handleDrop(e) {
    e.preventDefault()
    this._dragCounter = 0
    this._hideOverlay()

    if (!this.hasUrlValue || !this.urlValue) return

    const file = e.dataTransfer?.files?.[0]
    if (!file) return

    const ext = file.name.split(".").pop().toLowerCase()
    if (ext !== "qfx" && ext !== "ofx") {
      this._showNotification("Please drop a .qfx or .ofx file", "error")
      return
    }

    this._upload(file)
  }

  // ─── upload ───────────────────────────────────────────────────────────────

  async _upload(file) {
    const loadingOverlay = this._buildLoadingOverlay(file.name)
    document.body.appendChild(loadingOverlay)

    try {
      const formData = new FormData()
      formData.append("import[qfx_file]", file)

      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: formData
      })

      const data = await response.json()

      loadingOverlay.remove()

      if (data.redirect) {
        Turbo.visit(data.redirect)
      } else {
        this._showNotification(data.error || "Import failed. Please try again.", "error")
      }
    } catch (_err) {
      loadingOverlay.remove()
      this._showNotification("Upload failed. Please check your connection and try again.", "error")
    }
  }

  // ─── overlay helpers ──────────────────────────────────────────────────────

  _showOverlay() {
    if (this._overlay) return

    this._overlay = document.createElement("div")
    this._overlay.setAttribute("aria-hidden", "true")
    this._overlay.className = [
      "fixed inset-0 z-50 flex items-center justify-center",
      "bg-black/40 backdrop-blur-sm pointer-events-none"
    ].join(" ")

    this._overlay.innerHTML = `
      <div class="flex flex-col items-center gap-4 p-10 rounded-2xl border-2 border-dashed border-white/60 bg-black/30 text-white text-center max-w-sm mx-4">
        <svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 24 24"
             fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"
             class="opacity-90">
          <path d="M14.5 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7.5L14.5 2z"/>
          <polyline points="14 2 14 8 20 8"/>
          <line x1="12" y1="18" x2="12" y2="12"/>
          <line x1="9" y1="15" x2="12" y2="12"/>
          <line x1="15" y1="15" x2="12" y2="12"/>
        </svg>
        <div>
          <p class="text-lg font-semibold">Drop to import QFX / OFX</p>
          <p class="text-sm opacity-75 mt-1">Release to start your import</p>
        </div>
      </div>
    `

    document.body.appendChild(this._overlay)
  }

  _hideOverlay() {
    this._overlay?.remove()
    this._overlay = null
  }

  _buildLoadingOverlay(filename) {
    const el = document.createElement("div")
    el.setAttribute("aria-live", "polite")
    el.className = [
      "fixed inset-0 z-50 flex items-center justify-center",
      "bg-black/40 backdrop-blur-sm"
    ].join(" ")

    el.innerHTML = `
      <div class="flex flex-col items-center gap-4 p-10 rounded-2xl bg-black/40 text-white text-center max-w-sm mx-4">
        <svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 24 24"
             fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
             class="animate-spin">
          <path d="M21 12a9 9 0 1 1-6.219-8.56"/>
        </svg>
        <div>
          <p class="text-lg font-semibold">Importing ${this._escapeHtml(filename)}</p>
          <p class="text-sm opacity-75 mt-1">Parsing transactions…</p>
        </div>
      </div>
    `

    return el
  }

  _showNotification(message, type = "info") {
    // Insert a flash-style notification into the existing notification tray
    const tray = document.getElementById("notification-tray")
    if (!tray) return

    const colorClass = type === "error" ? "bg-destructive text-white" : "bg-container text-primary"

    const el = document.createElement("div")
    el.className = `${colorClass} rounded-xl px-4 py-3 text-sm shadow-lg`
    el.textContent = message
    tray.prepend(el)

    setTimeout(() => el.remove(), 5000)
  }

  // ─── utilities ────────────────────────────────────────────────────────────

  _hasFiles(e) {
    return e.dataTransfer?.types?.includes("Files")
  }

  _escapeHtml(str) {
    return str.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
  }
}
