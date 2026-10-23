import Foundation

@main
struct BackupCloseTests {
    static func main() {
        precondition(ClosePolicy.resolve(changed: false) == .close)
        precondition(ClosePolicy.resolve(changed: false, editorReady: false) == .askForChoice)
        precondition(ClosePolicy.resolve(changed: true) == .askForChoice)
        precondition(ClosePolicy.resolve(changed: true, choice: .cancel) == .cancel)
        precondition(ClosePolicy.resolve(changed: true, choice: .closeWithoutBackingUp) == .close)
        precondition(ClosePolicy.resolve(changed: true, choice: .backUpAndClose) == .backUp)
        precondition(ClosePolicy.resolve(changed: true, choice: .backUpAndClose, hasBackupFolder: false) == .chooseBackupFolder)
        precondition(ClosePolicy.resolve(changed: false, editorReady: false,
            choice: .backUpAndClose) == .backUp)
        precondition(ClosePolicy.backupResult(editorReady: false, backupConfirmed: true, stillChanged: false) == .keepOpenForUnsavedWords)
        precondition(ClosePolicy.backupResult(editorReady: true, backupConfirmed: false, stillChanged: false) == .keepOpenAfterFailure)
        precondition(ClosePolicy.backupResult(editorReady: true, backupConfirmed: true, stillChanged: true) == .keepOpenForNewerChanges)
        precondition(ClosePolicy.backupResult(editorReady: true, backupConfirmed: true, stillChanged: false) == .close)
        print("Backup close policy checks passed: clean close, all choices, missing folder, unsaved words, failure, and write race.")
    }
}
