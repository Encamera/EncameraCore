import Foundation
import SwiftUI

struct AppModalModifier: ViewModifier {

    @Binding var isPresented: Bool
    var appModal: AppModal?
    func body(content: Content) -> some View {
        ZStack {
            content
                .environment(\.appModal, appModal)
        }
    }
}
