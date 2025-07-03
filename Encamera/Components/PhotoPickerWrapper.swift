import SwiftUI
import Photos
import PhotosUI

/// A wrapper that automatically selects the appropriate photo picker based on permissions
/// Uses CustomPhotoPicker with swipe selection when full access is granted,
/// falls back to standard PhotoPicker for limited access
struct PhotoPickerWrapper: View {
    var selectedItems: ([MediaSelectionResult]) -> ()
    var filter: PHPickerFilter = .images
    var selectionLimit: Int = 0 // 0 for unlimited
    
    @State private var showPermissionAlert = false
    @State private var hasFullAccess = false
    @State private var permissionStatus: PHAuthorizationStatus = .notDetermined
    
    var body: some View {
        Group {
            if hasFullAccess {
                // Use custom picker with swipe selection
                CustomPhotoPicker(
                    selectedItems: selectedItems,
                    filter: filter,
                    selectionLimit: selectionLimit
                )
            } else {
                // Use standard picker
                PhotoPicker(
                    selectedItems: selectedItems,
                    filter: filter,
                    selectionLimit: selectionLimit
                )
            }
        }
        .onAppear {
            checkPhotoPermissions()
        }
        .alert("Upgrade to Full Photo Access", isPresented: $showPermissionAlert) {
            Button("Continue with Limited Access") {
                // User chose to continue with limited access
            }
            Button("Grant Full Access") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("You currently have limited photo access. Grant full access to enable swipe-to-select multiple photos at once, making importing much faster!")
        }
    }
    
    private func checkPhotoPermissions() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        permissionStatus = status
        
        switch status {
        case .authorized:
            hasFullAccess = true
        case .limited:
            hasFullAccess = false
            // Only show upgrade prompt once per session
            let hasSeenPrompt = UserDefaults.standard.bool(forKey: "HasSeenPhotoAccessUpgradePrompt")
            if !hasSeenPrompt {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showPermissionAlert = true
                    UserDefaults.standard.set(true, forKey: "HasSeenPhotoAccessUpgradePrompt")
                }
            }
        case .notDetermined:
            // This shouldn't happen as we now request permission before showing the picker
            hasFullAccess = false
        case .denied, .restricted:
            // This also shouldn't happen as we check before showing
            hasFullAccess = false
        @unknown default:
            hasFullAccess = false
        }
    }
}

/// A view modifier to prompt for full photo access when needed
struct PhotoAccessPromptModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onFullAccessGranted: () -> Void
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                PhotoAccessPromptView(
                    isPresented: $isPresented,
                    onFullAccessGranted: onFullAccessGranted
                )
            }
    }
}

/// A dedicated view for prompting photo access
struct PhotoAccessPromptView: View {
    @Binding var isPresented: Bool
    let onFullAccessGranted: () -> Void
    @State private var currentStatus: PHAuthorizationStatus = .notDetermined
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)
                    .padding(.top, 40)
                
                VStack(spacing: 16) {
                    Text("Enable Swipe Selection")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("Grant full access to your photos to enable swipe-to-select multiple photos at once!")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                
                VStack(spacing: 12) {
                    // Features list
                    FeatureRow(
                        icon: "hand.draw",
                        title: "Swipe to Select",
                        description: "Select multiple photos with a single swipe"
                    )
                    
                    FeatureRow(
                        icon: "speedometer",
                        title: "Faster Import",
                        description: "Import photos much more quickly"
                    )
                    
                    FeatureRow(
                        icon: "checkmark.shield",
                        title: "Privacy First",
                        description: "Your photos stay encrypted and private"
                    )
                }
                .padding(.horizontal)
                
                Spacer()
                
                VStack(spacing: 12) {
                    Button(action: requestFullAccess) {
                        Text(currentStatus == .limited ? "Upgrade to Full Access" : "Grant Access")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .cornerRadius(12)
                    }
                    
                    Button(action: {
                        isPresented = false
                    }) {
                        Text(currentStatus == .limited ? "Continue with Limited Access" : "Not Now")
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
        .onAppear {
            currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
    }
    
    private func requestFullAccess() {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        if currentStatus == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    self.currentStatus = status
                    if status == .authorized {
                        onFullAccessGranted()
                        isPresented = false
                    }
                }
            }
        } else {
            // Open settings for limited or denied status
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

extension View {
    func photoAccessPrompt(isPresented: Binding<Bool>, onFullAccessGranted: @escaping () -> Void) -> some View {
        modifier(PhotoAccessPromptModifier(isPresented: isPresented, onFullAccessGranted: onFullAccessGranted))
    }
} 