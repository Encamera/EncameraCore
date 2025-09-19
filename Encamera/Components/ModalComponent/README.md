# Reusable Modal Component

A customizable, reusable modal component that provides a beautiful bottom-up modal experience with blur background, swipe gestures, and smooth animations.

## Features

- **Full-screen blur overlay** with ultraThinMaterial background
- **Bottom-up slide animation** with smooth spring animations
- **Swipe-to-dismiss gesture** with visual feedback
- **Tap outside to dismiss** functionality
- **24pt corner radius** on top corners only
- **Gradient background** applied to modal content
- **Flexible content** - accepts any SwiftUI view via ViewBuilder closure
- **Responsive height** - modal automatically sizes to fit content

## Usage

### Basic Usage

```swift
struct ContentView: View {
    @State private var showModal = false
    
    var body: some View {
        VStack {
            Button("Show Modal") {
                showModal = true
            }
        }
        .reusableModal(isPresented: $showModal) {
            VStack {
                Text("Your Custom Content")
                Button("Close") {
                    showModal = false
                }
            }
        }
    }
}
```

### Encryption Key Modal Example

```swift
.reusableModal(isPresented: $showEncryptionModal) {
    VStack(spacing: 24) {
        Image(systemName: "key.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 60, height: 60)
            .foregroundColor(.orange)
        
        Text("Back up your Encryption Key")
            .font(.title2)
            .fontWeight(.bold)
            .foregroundColor(.white)
        
        Text("Your photos are protected with a unique encryption key...")
            .font(.body)
            .foregroundColor(.white.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
        
        Button("View the Key") {
            showEncryptionModal = false
        }
        .primaryButton()
    }
    .padding(.vertical, 40)
}
```

## API Reference

### `reusableModal(isPresented:content:)`

A view modifier that presents a modal overlay.

**Parameters:**
- `isPresented: Binding<Bool>` - Controls the modal's visibility
- `content: @ViewBuilder () -> Content` - The content to display in the modal

### Gestures & Interactions

- **Swipe down** - Dismisses the modal with threshold-based detection
- **Tap outside** - Dismisses the modal
- **Drag feedback** - Shows real-time drag position with spring-back animation

### Styling

The modal automatically applies:
- `gradientBackground()` view modifier to the content area
- 24pt corner radius on top corners
- Safe area padding on bottom
- Swipe indicator at the top
- ultraThinMaterial blur for background

## Architecture

The component consists of:

1. **`ReusableModal`** - Parent component with ZStack overlay
2. **`ModalContent`** - Child component that hosts the actual content
3. **`SwipeIndicator`** - Visual indicator for swipe gesture
4. **`RoundedCorner`** - Custom shape for top-only corner radius

## Animation Details

- **Entrance**: Bottom-to-top slide with spring animation (0.6s response, 0.8 damping)
- **Exit**: Top-to-bottom slide with spring animation 
- **Drag gesture**: Real-time position with spring-back (0.3s response, 0.9 damping)
- **Threshold**: Dismisses if dragged >100pt or with sufficient velocity

## Dependencies

- SwiftUI
- EncameraCore (for gradientBackground modifier and other styling)

## Files

- `ReusableModal.swift` - Main component implementation
- `ModalUsageExample.swift` - Example usage demonstrations
- `README.md` - This documentation
