//
//  PromptToErase.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import SwiftUI
import Combine
import EncameraCore

class PromptToEraseViewModel: ObservableObject {
    
    enum Constants {
        static let defaultCountdown = 5
    }
    
    @Published var eraseButtonPressed = false
    @Published var error: KeyManagerError?
    @Published var countdown: Int = Constants.defaultCountdown
    @Published var holding = false {
        didSet {
            if holding == true {
                Timer
                    .publish(every: 1.0, on: .main, in: .common)
                    .autoconnect()
                    .sink { _ in
                        guard self.countdown >= 0 else {
                            return
                        }
                        self.countdown -= 1
                    }.store(in: &cancellables)
            } else {
                cancellables.forEach({$0.cancel()})
                countdown = Constants.defaultCountdown
            }
        }
    }
    
    
    var eraserUtil: EraserUtils
    var keyManager: KeyManager
    var scope: ErasureScope
    private var cancellables = Set<AnyCancellable>()
    
    
    init(scope: ErasureScope, keyManager: KeyManager, fileAccess: FileAccess) {
        self.eraserUtil = EraserUtils(keyManager: keyManager, fileAccess: fileAccess, erasureScope: scope)
        self.keyManager = keyManager
        self.scope = scope
        self.$countdown.sink { value in
            if self.countdown <= 0 {
                self.performErase()
            }
        }.store(in: &cancellables)
    }
    
    func performErase() {
        Task {
            do {
                try await eraserUtil.erase()
                exit(0)
                
            } catch let keyManagerError as KeyManagerError {
                await MainActor.run {
                    self.error = keyManagerError
                }
            } catch {
                print("Error", error)
            }
        }
    }
    
    
}

struct PromptToErase: View {
    
    @StateObject var viewModel: PromptToEraseViewModel
    
    var body: some View {
        ScrollView{
            VStack(spacing: 10) {
                confirmationPlaceholder
                    .frame(maxWidth: .infinity, minHeight: 60)
                Group {
                    Text(viewModel.scope.explanationString)
                    Button(L10n.holdToErase) {
                        
                    }
                    .primaryButton()
                    .onLongPressGesture(perform: {
                    }, onPressingChanged: { value in
                        viewModel.holding = value
                    })
                }
                .fontType(.pt18)
                Spacer()
            }.padding()
                .navigationTitle(L10n.eraseAppData)
        }
        .animation(.easeIn, value: viewModel.holding)
        .background(Color.background)
    }
    
    var confirmationPlaceholder: some View {
        var confirmationPlaceholder: AnyView = AnyView(Color.clear)
        if viewModel.holding == true {
            confirmationPlaceholder = AnyView(Text(L10n.erasingIn(viewModel.countdown))
                .fontType(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundColor(.background)
                                              
                .background(Color.videoRecordingIndicator)
                                              
            )
            
        }
        return confirmationPlaceholder
        
            .transition(.move(edge: .top))
        
    }
}


extension ErasureScope {
    
    var explanationString: String {
        switch self {
        case .appData:
            return appDataExplanation
        case .allData:
            return allDataExplanation
        }
    }
    
    private var allDataExplanation: String {
        L10n.allDataExplanation
        
    }
    
    private var appDataExplanation: String {
        L10n.appDataExplanation
    }
}

struct PromptToErase_Previews: PreviewProvider {
    static var manager: KeyManager {
        let manager = DemoKeyManager()
        manager.password = "pass"
        return manager
    }
    static var previews: some View {
        NavigationView {
            PromptToErase(viewModel: .init(scope: .allData, keyManager: manager, fileAccess: DemoFileEnumerator()))
        }
        
    }
}
