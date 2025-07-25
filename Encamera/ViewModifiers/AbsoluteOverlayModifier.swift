import SwiftUI

struct AbsoluteOverlayModifier<Overlay: View>: ViewModifier {
    let overlay: Overlay
    let alignment: Alignment
    let ignoresSafeArea: Bool
    let edges: Edge.Set
    
    init(
        @ViewBuilder overlay: () -> Overlay,
        alignment: Alignment = .topTrailing,
        ignoresSafeArea: Bool = true,
        edges: Edge.Set = .top
    ) {
        self.overlay = overlay()
        self.alignment = alignment
        self.ignoresSafeArea = ignoresSafeArea
        self.edges = edges
    }
    
    func body(content: Content) -> some View {
        ZStack(alignment: alignment) {
            content
            
            overlay
                .if(ignoresSafeArea) { view in
                    view.ignoresSafeArea(edges: edges)
                }
        }
    }
}

extension View {
    func absoluteOverlay<Overlay: View>(
        alignment: Alignment = .topTrailing,
        ignoresSafeArea: Bool = true,
        edges: Edge.Set = .top,
        @ViewBuilder overlay: () -> Overlay
    ) -> some View {
        modifier(AbsoluteOverlayModifier(
            overlay: overlay,
            alignment: alignment,
            ignoresSafeArea: ignoresSafeArea,
            edges: edges
        ))
    }
    
    func globalImportProgress(
        alignment: Alignment = .bottom,
        ignoresSafeArea: Bool = true,
        edges: Edge.Set = .top
    ) -> some View {
        absoluteOverlay(
            alignment: alignment,
            ignoresSafeArea: ignoresSafeArea,
            edges: edges
        ) {
            VStack {
                Spacer()
                GlobalImportProgressView()
                    .padding(.horizontal, 16)
                Spacer().frame(height: 26)
            }
        }
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
