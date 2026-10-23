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
        precondition(FileLeavePolicy.allowsLeaving(hasFile: false, authoritative: false, unsaved: true, hasContent: true, recoverySafe: false))
        precondition(FileLeavePolicy.allowsLeaving(hasFile: true, authoritative: true, unsaved: false, hasContent: true, recoverySafe: false))
        precondition(FileLeavePolicy.allowsLeaving(hasFile: true, authoritative: false, unsaved: false, hasContent: false, recoverySafe: false))
        precondition(FileLeavePolicy.allowsLeaving(hasFile: true, authoritative: false, unsaved: true, hasContent: true, recoverySafe: true))
        precondition(!FileLeavePolicy.allowsLeaving(hasFile: true, authoritative: false, unsaved: true, hasContent: true, recoverySafe: false))
        precondition(!FileLeavePolicy.allowsLeaving(hasFile: true, authoritative: true, unsaved: true, hasContent: true, recoverySafe: false))
        print("File writing leave checks passed: saved, recovered, empty, and unrecoverable drafts.")
        print("Backup close policy checks passed: clean close, all choices, missing folder, unsaved words, failure, and write race.")
    }
}
