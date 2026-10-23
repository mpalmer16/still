import Foundation

enum CloseChoice {
    case backUpAndClose
    case closeWithoutBackingUp
    case cancel
}

enum CloseDecision: Equatable {
    case close
    case askForChoice
    case backUp
    case chooseBackupFolder
    case cancel
}

enum BackupCloseResult: Equatable {
    case close
    case keepOpenForUnsavedWords
    case keepOpenForNewerChanges
    case keepOpenAfterFailure
}

enum ClosePolicy {
    static func resolve(changed: Bool, editorReady: Bool = true, choice: CloseChoice? = nil,
                        hasBackupFolder: Bool = true) -> CloseDecision {
        guard changed || !editorReady else { return .close }
        guard let choice else { return .askForChoice }
        switch choice {
        case .cancel: return .cancel
        case .closeWithoutBackingUp: return .close
        case .backUpAndClose: return hasBackupFolder ? .backUp : .chooseBackupFolder
        }
    }

    static func backupResult(editorReady: Bool, backupConfirmed: Bool, stillChanged: Bool) -> BackupCloseResult {
        guard editorReady else { return .keepOpenForUnsavedWords }
        guard backupConfirmed else { return .keepOpenAfterFailure }
        guard !stillChanged else { return .keepOpenForNewerChanges }
        return .close
    }
}
