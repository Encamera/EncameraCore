//
//  AuthenticationView.swift
//  Encamera
//
//  Created by Alexander Freas on 10.07.22.
//

import SwiftUI
import Combine
import EncameraCore

private enum AuthenticationViewError: ErrorDescribable {
    case noPasswordGiven
    case passwordIncorrect
    case biometricsFailed
    case biometricsNotAvailable
    case keychainError(KeyManagerError)
    
    var displayDescription: String {
        switch self {
        case .noPasswordGiven:
            return L10n.missingPassword
        case .passwordIncorrect:
            if UserDefaultUtils.bool(forKey: .usesPinPassword) {
                return L10n.incorrectPinCode
            }
            return L10n.passwordIncorrect
        case .biometricsFailed:
            return L10n.biometricsFailed
        case .biometricsNotAvailable:
            return L10n.biometricsUnavailable
        case .keychainError(let keyManagerError):
            return keyManagerError.displayDescription
        }
    }
    
}

extension TimeInterval {
    func formatAsHoursMinutesSeconds() -> String {
        let hours = Int(self) / 3600
        let minutes = Int(self) / 60 % 60
        let seconds = Int(self) % 60
        if hours > 0 {
            return String(format: "%02i:%02i:%02i", hours, minutes, seconds)
        } else {
            return String(format: "%02i:%02i", minutes, seconds)
        }
    }
}


class AuthenticationViewModel: ObservableObject {
    private var authManager: AuthManager
    var keyManager: KeyManager
    @Published fileprivate var displayedError: AuthenticationViewError?
    @Published var enteredPassword: String = ""
    @Published var isPinCodeInputEnabled: Bool = true
    @Published var remainingLockoutTime: TimeInterval?
    private var passwordAttempts = 0
#if DEBUG
    private let lockoutDuration: TimeInterval = 30
#else
    private let lockoutDuration: TimeInterval = 3600 // 1 hour
#endif
    var cancellables = Set<AnyCancellable>()
    private var lockoutTimer: AnyCancellable?

    var availableBiometric: AuthenticationMethod? {
        if authManager.useBiometricsForAuth {
            return authManager.availableBiometric
        } else {
            return nil
        }
    }

    init(authManager: AuthManager, keyManager: KeyManager) {
        self.authManager = authManager
        self.keyManager = keyManager
        setupLockoutTimer()

        if UserDefaultUtils.bool(forKey: .usesPinPassword) {
            $enteredPassword
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] password in
                    print("Entered password", password)
                    guard PasswordValidator.validate(password: password) == .valid else {
                        return
                    }
                    self?.authenticatePassword(password: password)
            }.store(in: &cancellables)
        }

        NotificationUtils.willEnterForegroundPublisher
            .sink { [weak self] _ in
                self?.authenticateWithBiometrics()
                self?.checkLockoutStatus()
            }
            .store(in: &cancellables)
    }

    private func setupLockoutTimer() {
        if let lockoutEnd = UserDefaultUtils.value(forKey: .lockoutEnd) as? Date, Date() < lockoutEnd {
            startLockoutTimer(until: lockoutEnd)
        }
    }

    func authenticatePassword(password: String) {
        guard isPinCodeInputEnabled else { return }
        debugPrint("Password", password, "attempts", passwordAttempts)

        if password.count > 0 {
            do {

                try authManager.authorize(with: password, using: keyManager)
                passwordAttempts = 0 // Reset attempts on successful auth

            } catch let keyManagerError as KeyManagerError {
                displayedError = .keychainError(keyManagerError)
                enteredPassword = ""
            } catch let authManagerError as AuthManagerError {
                handleAuthManagerError(authManagerError)
                passwordAttempts += 1
                enteredPassword = ""
                if passwordAttempts > 3 {
                    let lockoutEnd = Date().addingTimeInterval(lockoutDuration)
                    UserDefaultUtils.set(lockoutEnd, forKey: .lockoutEnd)
                    startLockoutTimer(until: lockoutEnd)
                }
            } catch {
                debugPrint("Auth manager error", error)
            }
        }
    }

    private func startLockoutTimer(until endDate: Date) {
        isPinCodeInputEnabled = false
        lockoutTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            let remainingTime = endDate.timeIntervalSinceNow
            if remainingTime <= 0 {
                self?.clearLockoutTimer()
            } else {
                self?.isPinCodeInputEnabled = false
                self?.remainingLockoutTime = remainingTime
            }
        }
    }

    func clearLockoutTimer() {
        isPinCodeInputEnabled = true
        remainingLockoutTime = nil
        lockoutTimer?.cancel()
        UserDefaultUtils.removeObject(forKey: .lockoutEnd)
    }

    func checkLockoutStatus() {
        if let lockoutEnd = UserDefaultUtils.value(forKey: .lockoutEnd) as? Date, Date() < lockoutEnd {
            startLockoutTimer(until: lockoutEnd)
        } else {
            remainingLockoutTime = nil
            isPinCodeInputEnabled = true
        }
    }

    func authenticateWithBiometrics() {
        guard authManager.useBiometricsForAuth else {
            debugPrint("Biometrics not enabled")
            return
        }
        Task {
            do {
                try await authManager.authorizeWithBiometrics()
                clearLockoutTimer()
            } catch let authManagerError as AuthManagerError {
                await MainActor.run {
                    handleAuthManagerError(authManagerError)
                }
            } catch {
                debugPrint("Error handling auth", error)
            }
        }
    }
    
    
    func handleAuthManagerError(_ error: AuthManagerError) {
        let displayError: AuthenticationViewError?
        switch error {
        case .passwordIncorrect:
            displayError = .passwordIncorrect
        case .biometricsFailed:
            displayError = nil
        case .biometricsNotAvailable:
            displayError = .biometricsNotAvailable
        case .userCancelledBiometrics:
            displayError = .biometricsFailed
        }
        displayedError = displayError
    }
}
struct AuthenticationView: View {
    
    
    @StateObject var viewModel: AuthenticationViewModel
    @State var enteredPassword: String = ""
    var body: some View {
        VStack(spacing: 8) {
            Image("LogoSquare").frame(height: 100)
            Text(L10n.welcomeBack)
                .fontType(.pt20, weight: .bold)
            if viewModel.keyManager.passwordExists() {
                if let biometric = viewModel.availableBiometric {
                    Text("\(L10n.enterPassword) \(L10n.or.lowercased()) \(biometric.nameForMethod)")
                } else {
                    Text("\(L10n.enterPassword)")
                }
                Spacer().frame(height: 32)
                
                if UserDefaultUtils.bool(forKey: .usesPinPassword) {
                    if viewModel.isPinCodeInputEnabled {
                        PinCodeView(pinCode: $enteredPassword, pinActionButtonTitle: L10n.unlockWithPin) { pinCode in
                            if PasswordValidator.validate(password: pinCode) == .valid {
                                viewModel.authenticatePassword(password: pinCode)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    enteredPassword = ""
                                }
                            }
                        }

                    } else if let lockoutTime = viewModel.remainingLockoutTime {
                        Text(L10n.pinCodeLockTryAgainIn(lockoutTime.formatAsHoursMinutesSeconds()))
                            .fontType(.pt14, weight: .bold)
                            .opacity(0.5)
                    }
                } else {
                    PasswordEntry(viewModel: .init(
                        keyManager: viewModel.keyManager, stateUpdate: { update in
                            if case .valid(let password) = update {
                                viewModel.authenticatePassword(password: password)
                            }
                        }))
                }
            }

            if let error = viewModel.displayedError, viewModel.remainingLockoutTime == nil {
                Text("\(error.displayDescription)")
                    .alertText()
            }
            Spacer()
                .frame(height: 28.0)
            if viewModel.availableBiometric != nil && viewModel.keyManager.passwordExists() {
                Text(L10n.or.uppercased())
                    .fontType(.pt14, weight: .bold)
                    .opacity(0.5)
                Spacer().frame(height: 20)
            }
            if let biometric = viewModel.availableBiometric {
                Button {
                    viewModel.authenticateWithBiometrics()
                } label: {
                    VStack(spacing: 16) {
                        Image(systemName: biometric.imageNameForMethod)
                            .resizable()
                            .frame(width: 50.0, height: 50.0)
                            .opacity(0.5)
                        Text(L10n.unlockWith(biometric.nameForMethod))
                            .fontType(.pt14, weight: .bold)
                    }
                }.padding()
                
            }
            Spacer()
        }
        .onAppear {
            // delay 0.5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                viewModel.authenticateWithBiometrics()
            }
        }
        .padding()
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .gradientBackground()
        .ignoresSafeArea(edges: .bottom)
    }

}

struct AuthenticationView_Previews: PreviewProvider {
    static var previews: some View {
        AuthenticationView(viewModel: .init(authManager: DemoAuthManager(), keyManager: DemoKeyManager()))
            .preferredColorScheme(.dark)
    }
}
