import LocalAuthentication

public func faceIDFailureMessage(for error: CredentialStoreError) -> String {
    switch error {
    case .biometric(let code):
        switch code {
        case .authenticationFailed: "Face ID didn't match. Try again."
        case .userCancel, .systemCancel, .appCancel: "Unlock with Face ID to continue."
        case .biometryLockout: "Face ID is locked after too many attempts. Unlock your iPhone with your passcode, then try again."
        case .biometryNotEnrolled: "Set up Face ID in Settings to use this app"
        case .biometryNotAvailable: "Face ID is off for cc-controller. Turn it on in Settings."
        default: "Face ID did not work. Try again."
        }
    case .accessDenied: "Secure storage could not be unlocked."
    case .unavailable: "Secure storage is unavailable on this device."
    case .invalidData: "Secure storage contained invalid data."
    case .system(let message), .systemStatus(_, let message): message
    }
}
