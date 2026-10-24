import Foundation

@main
struct CorrespondenceNavigationTests {
    static func main() {
        let local = URL(string: "http://localhost:4040/correspondence")!
        let loopback = URL(string: "http://127.0.0.1:4040/writing")!
        let wrongPort = URL(string: "http://localhost:4041/correspondence")!
        let lookalike = URL(string: "http://localhost.evil.example:4040/correspondence")!
        let insecureScheme = URL(string: "file:///tmp/poem.txt")!
        let javascript = URL(string: "javascript:alert(1)")!
        let external = URL(string: "https://journal.example/submit")!
        let remoteHTTP = URL(string: "http://journal.example/submit")!
        let export = URL(string: "http://localhost:4040/correspondence/packets/123/export/docx")!
        let exportText = URL(string: "http://localhost:4040/correspondence/packets/123/export/txt")!

        precondition(CorrespondenceNavigationPolicy.decide(local, localPort: 4040, userInitiated: false) == .allowInApp)
        precondition(CorrespondenceNavigationPolicy.decide(loopback, localPort: 4040, userInitiated: true) == .allowInApp)
        precondition(CorrespondenceNavigationPolicy.decide(wrongPort, localPort: 4040, userInitiated: true) == .cancel)
        precondition(CorrespondenceNavigationPolicy.decide(lookalike, localPort: 4040, userInitiated: true) == .openExternal)
        precondition(CorrespondenceNavigationPolicy.decide(insecureScheme, localPort: 4040, userInitiated: true) == .cancel)
        precondition(CorrespondenceNavigationPolicy.decide(javascript, localPort: 4040, userInitiated: true) == .cancel)
        precondition(CorrespondenceNavigationPolicy.decide(external, localPort: 4040, userInitiated: true) == .openExternal)
        precondition(CorrespondenceNavigationPolicy.decide(remoteHTTP, localPort: 4040, userInitiated: false) == .cancel)
        precondition(CorrespondenceNavigationPolicy.decide(export, localPort: 4040, userInitiated: true) == .allowInApp)
        precondition(CorrespondenceNavigationPolicy.decide(exportText, localPort: 4040, userInitiated: false) == .allowInApp)
        precondition(CorrespondenceNavigationPolicy.decide(nil, localPort: 4040, userInitiated: true) == .cancel)
        precondition(CorrespondenceNavigationPolicy.shouldDownloadResponse(url: export, localPort: 4040,
            statusCode: 200, contentDisposition: "attachment; filename=manuscript.docx"))
        precondition(!CorrespondenceNavigationPolicy.shouldDownloadResponse(url: export, localPort: 4040,
            statusCode: 422, contentDisposition: "attachment; filename=manuscript.docx"))
        precondition(!CorrespondenceNavigationPolicy.shouldDownloadResponse(url: export, localPort: 4040,
            statusCode: 200, contentDisposition: "inline"))
        precondition(!CorrespondenceNavigationPolicy.shouldDownloadResponse(url: external, localPort: 4040,
            statusCode: 200, contentDisposition: "attachment"))
        print("Correspondence navigation checks passed: local routes, deliberate web links, successful attachment responses, and blocked schemes/redirects.")
    }
}
