//
//  CameraModePicker.swift
//  Shadowpix
//
//  Created by Alexander Freas on 04.05.22.
//

import SwiftUI

// based off of https://gist.github.com/xtabbas/97b44b854e1315384b7d1d5ccce20623
struct SnapCarousel: View {
    
    @EnvironmentObject var UIState: UIStateModel
    
    
    
    var body: some View {
        let cardHeight: CGFloat = 279
        
        let items = [
            Card(id: 0, name: "camera.circle"),
            Card(id: 1, name: "video.circle")
        ]
        
        return Canvas {
            Carousel(
                numberOfItems: CGFloat(items.count)
            ) {
                ForEach(items, id: \.self.id) { item in
                    Item(
                        _id: Int(item.id),
                        cardHeight: cardHeight
                    ) {
                        Image(systemName: item.name)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                        
                    }
                    .foregroundColor(Color.black)
                    .transition(AnyTransition.slide)
                    .animation(.spring(), value: UIState.screenDrag)
                }
            }
        }
    }
}

struct Card: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String = ""
}

public class UIStateModel: ObservableObject {
    @Published var activeCard: Int = 0
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
    
    @EnvironmentObject var UIState: UIStateModel
    
    private var totalSpacing: CGFloat {
        (numberOfItems - 1) * UIState.spacing
    }
    
    @inlinable public init(
        numberOfItems: CGFloat,
        @ViewBuilder _ items: () -> Items
    ) {
        self.items = items()
        self.numberOfItems = numberOfItems
    }
    
    
    var body: some View {
        let totalCanvasWidth: CGFloat = (UIState.cardWidth * numberOfItems) + totalSpacing
        let xOffsetToShift = (totalCanvasWidth - UIState.viewportSize) / 2
        let leftPadding = UIState.visibleWidthOfHiddenCard + UIState.spacing
        let totalPossibleMovement = UIState.cardWidth + UIState.spacing
        
        let activeOffset: Float = Float(xOffsetToShift + leftPadding - (totalPossibleMovement * CGFloat(UIState.activeCard)))
        let nextOffset: Float = Float(xOffsetToShift + leftPadding - (totalPossibleMovement * CGFloat(UIState.activeCard) + 1))
        
        var calcOffset = activeOffset
        
        if (calcOffset != nextOffset) {
            calcOffset = activeOffset + UIState.screenDrag
        }
        
        return HStack(alignment: .center, spacing: UIState.spacing) {
            items
        }
        .offset(x: CGFloat(calcOffset), y: 0)
        .gesture(DragGesture().updating($isDetectingLongPress) { currentState, gestureState, transaction in
            self.UIState.screenDrag = Float(currentState.translation.width)
        }.onEnded { value in
            self.UIState.screenDrag = 0
            
            if value.translation.width < -UIState.snapTolerance {
                self.UIState.activeCard = self.UIState.activeCard + 1
            }
            
            if value.translation.width > UIState.snapTolerance {
                self.UIState.activeCard = self.UIState.activeCard - 1
            }
        })
    }
    
}

struct Canvas<Content: View>: View {
    let content: Content
    @EnvironmentObject var UIState: UIStateModel
    
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
    
    @EnvironmentObject var UIState: UIStateModel
    
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
        let transformScale = _id == UIState.activeCard ? 1.0 : UIState.heightShrink
        content
            .scaleEffect(transformScale)
            .frame(
                width: UIState.cardWidth,
                height: UIState.cardHeight,
                alignment: .center
            )
    }
}

struct SnapCarousel_Previews: PreviewProvider {
    static var previews: some View {
        SnapCarousel()
            .environmentObject(UIStateModel())
    }
}

