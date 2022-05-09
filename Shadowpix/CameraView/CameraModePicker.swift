//
//  CameraModePicker.swift
//  Shadowpix
//
//  Created by Alexander Freas on 04.05.22.
//

import SwiftUI

enum CameraModeSelection: Int, CaseIterable {
    case photo
    case video
    
    
    var systemImageName: String {
        switch self {
        case .video:
            return "video.circle"
        case .photo:
            return "camera.circle"
        }
    }
    
    var activeBackgroundColor: Color {
        switch self {
        case .video:
            return .red
        case .photo:
            return .white
        }
    }
}

class CameraModePickerViewModel: ObservableObject {
}

// based off of https://gist.github.com/xtabbas/97b44b854e1315384b7d1d5ccce20623
struct CameraModePicker: View {
    
    @EnvironmentObject var stateModel: CameraModeStateModel
        
    var body: some View {
        let cardHeight: CGFloat = 279
        
        return Canvas {
            Carousel(
                numberOfItems: CGFloat(CameraModeSelection.allCases.count)
            ) {
                ForEach(CameraModeSelection.allCases, id: \.rawValue) { item in
                    Item(
                        _id: item.rawValue,
                        cardHeight: cardHeight
                    ) {
                        Image(systemName: item.systemImageName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                        
                    }
                    .foregroundColor(Color.white)
                    .transition(AnyTransition.slide)
                    .animation(.spring())
                }
            }
        }
    }
}

struct Card: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String = ""
}

public class CameraModeStateModel: ObservableObject {
    var activeIndex: Int {
        get {
            selectedMode.rawValue
        }
        set {
            selectedMode = CameraMode(rawValue: newValue)!
        }
    }
    @Published var isModeActive: Bool = false
    @Published var selectedMode: CameraMode = .photo
    @Published var screenDrag: Float = 0.0
    var viewportSize: CGFloat = 200
    var visibleWidthOfHiddenCard: CGFloat = 20
    var spacing: CGFloat = 16
    var cardWidth: CGFloat {
        viewportSize - (visibleWidthOfHiddenCard*2) - (spacing*2)
    }
    var snapTolerance: CGFloat = 50
    var heightShrink: CGFloat = 0.70
    var cardHeight: CGFloat = 100
}

struct Carousel<Items: View>: View {
    
    let items: Items
    let numberOfItems: CGFloat
    
    @GestureState var isDetectingLongPress = false
    
    @EnvironmentObject var stateModel: CameraModeStateModel
    
    private var totalSpacing: CGFloat {
        (numberOfItems - 1) * stateModel.spacing
    }
    
    @inlinable public init(
        numberOfItems: CGFloat,
        @ViewBuilder _ items: () -> Items
    ) {
        self.items = items()
        self.numberOfItems = numberOfItems
    }
    
    
    var body: some View {
        let totalCanvasWidth: CGFloat = (stateModel.cardWidth * numberOfItems) + totalSpacing
        let xOffsetToShift = (totalCanvasWidth - stateModel.viewportSize) / 2
        let leftPadding = stateModel.visibleWidthOfHiddenCard + stateModel.spacing
        let totalPossibleMovement = stateModel.cardWidth + stateModel.spacing
        
        let activeOffset: Float = Float(xOffsetToShift + leftPadding - (totalPossibleMovement * CGFloat(stateModel.activeIndex)))
        let nextOffset: Float = Float(xOffsetToShift + leftPadding - (totalPossibleMovement * CGFloat(stateModel.activeIndex) + 1))
        
        var calcOffset = activeOffset
        
        if (calcOffset != nextOffset) {
            calcOffset = activeOffset + stateModel.screenDrag
        }
        
        return HStack(alignment: .center, spacing: stateModel.spacing) {
            items
        }
        .offset(x: CGFloat(calcOffset), y: 0)
        .gesture(DragGesture().updating($isDetectingLongPress) { currentState, gestureState, transaction in
            self.stateModel.screenDrag = Float(currentState.translation.width)
        }.onEnded { value in
            self.stateModel.screenDrag = 0
            
            if value.translation.width < -stateModel.snapTolerance {
                self.stateModel.activeIndex = self.stateModel.activeIndex + 1
            }
            
            if value.translation.width > stateModel.snapTolerance {
                self.stateModel.activeIndex = min(max(0, self.stateModel.activeIndex - 1), Int(self.numberOfItems))
            }
        })
    }
    
}

struct Canvas<Content: View>: View {
    let content: Content
    @EnvironmentObject var stateModel: CameraModeStateModel
    
    @inlinable init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .frame(minWidth: 0.0, maxWidth: .infinity, minHeight: 0, alignment: .center)
            .background(Color.clear.edgesIgnoringSafeArea(.all))
    }
}

struct Item<Content: View>: View {
    
    @EnvironmentObject var stateModel: CameraModeStateModel
    
    var _id: Int
    var content: Content
    
    @inlinable public init(
        _id: Int,
        cardHeight: CGFloat,
        @ViewBuilder _ content: () -> Content
    ) {
        self.content = content()
        self._id = _id
    }
    
    var body: some View {
        let transformScale = _id == stateModel.activeIndex ? 1.0 : stateModel.heightShrink
        content
            .scaleEffect(transformScale)
            .frame(
                width: stateModel.cardWidth,
                height: stateModel.cardHeight,
                alignment: .center
            )
            .background(stateModel.isModeActive ? Color.red : Color.clear)
    }
}

struct SnapCarousel_Previews: PreviewProvider {
    static var previews: some View {
        CameraModePicker()
            .background(Color.black)
            .environmentObject(CameraModeStateModel())
    }
}

