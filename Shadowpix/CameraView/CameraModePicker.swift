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
    
    var cameraMode: CameraMode {
        switch self {
        case .photo:
            return .photo
        case .video:
            return .video
        }
    }
    
    var title: String {
        switch self {
        case .photo:
            return "PHOTO"
        case .video:
            return "VIDEO"
        }
    }
}

class CameraModePickerViewModel: ObservableObject {
}

// based off of https://gist.github.com/xtabbas/97b44b854e1315384b7d1d5ccce20623
struct CameraModePicker: View {
    
    @EnvironmentObject var stateModel: CameraModeStateModel
    var pressedAction: (CameraMode) -> Void
    var body: some View {
        let cardHeight: CGFloat = 279
        
        return Canvas {
            Carousel(
                numberOfItems: CGFloat(CameraModeSelection.allCases.count)
            ) {
                ForEach(CameraModeSelection.allCases, id: \.rawValue) { item in
                    Item(
                        _id: item.rawValue,
                        cardHeight: cardHeight,
                        pressedAction: {
                            pressedAction(item.cameraMode)
                        }
                    ) {
                        let itemActive = item.rawValue == stateModel.activeIndex
                        let foreground = itemActive ? Color.yellow : Color.white
                        Text(item.title)
                            .foregroundColor(foreground)
                        
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
    
//    var pressedAction: (CameraMode) -> Void
    var viewportSize: CGFloat = 200
    var visibleWidthOfHiddenCard: CGFloat = 20
    var spacing: CGFloat = 16
    var cardWidth: CGFloat {
        viewportSize - (visibleWidthOfHiddenCard*2) - (spacing*2)
    }
    var snapTolerance: CGFloat = 50
    var heightShrink: CGFloat = 0.70
    var cardHeight: CGFloat = 40
}

struct Carousel<Items: View>: View {
    
    let items: Items
    let numberOfItems: CGFloat
    
    @GestureState var isDetectingLongPress = false
    
    @EnvironmentObject var stateModel: CameraModeStateModel
    
    private var totalSpacing: CGFloat {
        (numberOfItems - 1) * stateModel.spacing
    }
    
    init(
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
            guard self.stateModel.isModeActive == false else {
                return
            }
            self.stateModel.screenDrag = Float(currentState.translation.width)
        }.onEnded { value in
            guard self.stateModel.isModeActive == false else {
                return
            }
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
    
    init(@ViewBuilder _ content: () -> Content) {
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
    var pressedAction: () -> Void
    
    init(
        _id: Int,
        cardHeight: CGFloat,
        pressedAction: @escaping () -> Void,
        @ViewBuilder _ content: () -> Content
    ) {
        self.content = content()
        self.pressedAction = pressedAction
        self._id = _id
    }
    
    var body: some View {
        ZStack {
            main
            .onTapGesture {
                pressedAction()
            }
        }
    }
    
    var main: AnyView {
        let transformScale = _id == stateModel.activeIndex ? 1.0 : stateModel.heightShrink
        
        return AnyView(content
            .scaleEffect(transformScale)
            .frame(
                width: stateModel.cardWidth,
                height: stateModel.cardHeight,
                alignment: .center
            ))
    }
}

struct SnapCarousel_Previews: PreviewProvider {
    static var model: CameraModeStateModel {
        let model = CameraModeStateModel()
        model.activeIndex = 1
        model.isModeActive = true
        return model
    }
    static var previews: some View {
        
        CameraModePicker(pressedAction: {mode in
            
        })
            .background(Color.black)
            .environmentObject(model)
    }
}

