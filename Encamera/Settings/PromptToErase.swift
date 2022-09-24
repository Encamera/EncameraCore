//
//  PromptToErase.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import SwiftUI
import Combine

class PromptToEraseViewModel: ObservableObject {
    
    enum Constants {
        static var defaultCountdown = 5
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
                    Text("Hold to erase")
                        .gesture(DragGesture(minimumDistance: 0).onChanged({ ended in
                            viewModel.holding = true
                        }).onEnded({ _ in
                            viewModel.holding = false
                        }))
                        .primaryButton()
                }.fontType(.small)
                Spacer()
            }.padding()
                .navigationTitle("Erase app data")
        }.animation(.easeIn, value: viewModel.holding)
    }
    
    var confirmationPlaceholder: some View {
        var confirmationPlaceholder: AnyView = AnyView(Color.clear)
        if viewModel.holding == true {
            confirmationPlaceholder = AnyView(Text("Erasing in \(viewModel.countdown)")
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
    
    var explanationString: LocalizedStringKey {
        switch self {
        case .appData:
            return appDataExplanation
        case .allData:
            return allDataExplanation
        }
    }
    
    private var allDataExplanation: LocalizedStringKey {
                """
                Are you sure you want to erase __all__ app data?
                
                __This will erase:__
                
                • All your stored keys 🔑
                • Your password 🔐
                • App settings 🎛
                • Media you have stored locally or on iCloud 💾
                
                You can create a backup of your keys from the key management screen.
                
                The app will quit after erase is finished.
                
                """
        
    }
    
    private var appDataExplanation: LocalizedStringKey {
        """
        Are you sure you want to erase all app data?
        
        __This will erase:__
        
        • All your stored keys 🔑
        • Your password 🔐
        • App settings 🎛
        
        __This will not erase:__
        
        • Media you have stored locally or on iCloud 💾
        
        You can create a backup of your keys from the key management screen.
        
        The app will quit after erase is finished.
        
        """
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
