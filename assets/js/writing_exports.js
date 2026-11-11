// Explicit exports remain available while the same page switches to reading.
export const WritingExports = {
  mounted() {
    this.onPDFResult = ({detail}) => {
      this.pushEvent(detail.error ? "pdf_export_failed" : "pdf_export_finished",
        detail.error ? {message: detail.error, request_id: detail.request_id} : {path: detail.path, request_id: detail.request_id})
    }
    window.addEventListener("still:pdf-export-result", this.onPDFResult)
    this.handleEvent("writing-pdf-request", payload => {
      const handler = window.webkit?.messageHandlers?.stillPDFExport
      if (handler) handler.postMessage(payload)
      else this.pushEvent("pdf_export_failed", {message: "PDF export is available in the Mac app.", request_id: payload.request_id})
    })
    this.handleEvent("reveal-writing-export", ({path}) => {
      window.webkit?.messageHandlers?.stillRevealExport?.postMessage({path})
    })
  },
  destroyed() { window.removeEventListener("still:pdf-export-result", this.onPDFResult) },
}
