import SwiftUI
import EncameraCore
import Combine

fileprivate struct ImportManagerOverlayModifier: ViewModifier {
    let alignment: Alignment
    let ignoresSafeArea: Bool
    let edges: Edge.Set
    @StateObject private var importManager = BackgroundMediaImportManager.shared
    @State private var showProgressView: Bool = false {
        didSet {
            print("ImportManagerOverlayModifier setting showProgressView \(showProgressView)")
        }
    }
    @State private var cancellables = Set<AnyCancellable>()

    init(
        alignment: Alignment = .topTrailing,
        ignoresSafeArea: Bool = true,
        edges: Edge.Set = .top
    ) {
        self.alignment = alignment
        self.ignoresSafeArea = ignoresSafeArea
        self.edges = edges
    }



    func body(content: Content) -> some View {
        ZStack(alignment: alignment) {
            content
            if showProgressView {
                VStack {
                    Spacer()
                    GlobalImportProgressView(showProgressView: $showProgressView)
                        .padding(.horizontal, 16)
                    Spacer().frame(height: 26)
                }
                .if(ignoresSafeArea) { view in
                    view.ignoresSafeArea(edges: edges)
                }
            }
        }.onAppear {
            importManager.$isImporting.sink { value in
                if self.showProgressView == false {
                    self.showProgressView = value
                }
            }.store(in: &cancellables)

        }
    }
}

extension View {

    func globalImportProgress(
        alignment: Alignment = .bottom,
        ignoresSafeArea: Bool = true,
        edges: Edge.Set = .top
    ) -> some View {
        modifier(ImportManagerOverlayModifier(
            alignment: alignment,
            ignoresSafeArea: ignoresSafeArea,
            edges: edges
        ))
    }
}

#Preview("Global Import Progress Overlay") {
    NavigationView {
        VStack {
            Text("Sample Album Content")
                .font(.title)
                .padding()
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(0..<12, id: \.self) { index in
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(
                            Text("\(index + 1)")
                                .font(.caption)
                                .foregroundColor(.primary)
                        )
                }
            }
            .padding()
            
            Spacer()
        }
        .navigationTitle("Album View")
        .navigationBarTitleDisplayMode(.inline)
        .globalImportProgress()
    }
} 
