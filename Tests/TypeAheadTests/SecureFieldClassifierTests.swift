import Testing
@testable import TypeAhead

/// B8: TypeAhead must never read or suggest into secret fields. The AX `AXPasswordField` role
/// covers native secure fields; custom widgets (web/Electron PIN boxes, OTP inputs, masked
/// fields) need the subrole, their labels, or their masked contents to be recognized.
@Suite struct SecureFieldClassifierTests {

    // MARK: - Role / subrole

    @Test func passwordRoleIsSecure() {
        #expect(SecureFieldClassifier.isSecureRole(role: "AXPasswordField", subrole: nil))
    }

    @Test func secureTextFieldSubroleIsSecure() {
        #expect(SecureFieldClassifier.isSecureRole(role: "AXTextField", subrole: "AXSecureTextField"))
    }

    @Test func ordinaryTextFieldIsNotSecureByRole() {
        #expect(!SecureFieldClassifier.isSecureRole(role: "AXTextArea", subrole: nil))
        #expect(!SecureFieldClassifier.isSecureRole(role: nil, subrole: nil))
    }

    // MARK: - Labels (title / placeholder / description / identifier)

    @Test func secretLabelsAreRecognized() {
        for label in ["Password", "Enter your passcode", "Passphrase", "PIN", "Enter PIN",
                      "One-time code", "OTP", "2FA code", "Verification code", "Security code",
                      "CVV", "CVC", "new-password", "current_password"] {
            #expect(SecureFieldClassifier.labelsSuggestSecret([label]), "\(label)")
        }
    }

    @Test func ordinaryLabelsAreNotSecret() {
        for label in ["Message", "Shipping address", "Spinning up", "Pinned notes", "Subject",
                      "Search", "Write a reply…", "Opinion", "Topic", ""] {
            #expect(!SecureFieldClassifier.labelsSuggestSecret([label]), "\(label)")
        }
    }

    @Test func anyOneSecretLabelIsEnough() {
        #expect(SecureFieldClassifier.labelsSuggestSecret(["Log in", "", "Password"]))
    }

    // MARK: - Masked contents

    @Test func maskedValueIsSecret() {
        #expect(SecureFieldClassifier.looksMasked("•••"))
        #expect(SecureFieldClassifier.looksMasked("●●●●●●"))
        #expect(SecureFieldClassifier.looksMasked("∙∙∙∙"))
    }

    @Test func shortOrMixedValuesAreNotMasked() {
        #expect(!SecureFieldClassifier.looksMasked(""))
        #expect(!SecureFieldClassifier.looksMasked("••"))
        #expect(!SecureFieldClassifier.looksMasked("• bullet point"))
        // A markdown horizontal rule must not be mistaken for a masked password.
        #expect(!SecureFieldClassifier.looksMasked("***"))
        #expect(!SecureFieldClassifier.looksMasked("hello"))
    }
}
