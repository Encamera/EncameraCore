import SwiftUI
import Photos
import PhotosUI
import EncameraCore

/// A wrapper that automatically selects the appropriate photo picker based on permissions
/// Uses CustomPhotoPicker with swipe selection when full access is granted,
/// falls back to standard PhotoPicker for limited access
struct PhotoPickerWrapper: View {
    var selectedItems: ([MediaSelectionResult]) -> ()
    var filter: PHPickerFilter = .images
    var selectionLimit: Int = 0 // 0 for unlimited
    
    @State private var showPermissionAlert = false
    
    var body: some View {
        Group {
            CustomPhotoPicker(
                selectedItems: selectedItems,
                filter: filter,
                selectionLimit: selectionLimit
            )
        }
        .onAppear {
            checkPhotoPermissions()
        }
        .alert(L10n.PhotoPickerWrapper.upgradeTitle, isPresented: $showPermissionAlert) {
            Button(L10n.PhotoPickerWrapper.continueLimited) {
                // User chose to continue with limited access
            }
            Button(L10n.PhotoPickerWrapper.grantFullAccess) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text(L10n.PhotoPickerWrapper.upgradeMessage)
        }
    }
    
    private func checkPhotoPermissions() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch status {
        case .limited:
            // Only show upgrade prompt once per session
            let hasSeenPrompt = UserDefaults.standard.bool(forKey: "HasSeenPhotoAccessUpgradePrompt")
            if !hasSeenPrompt {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showPermissionAlert = true
                    UserDefaults.standard.set(true, forKey: "HasSeenPhotoAccessUpgradePrompt")
                }
            }
        case .authorized, .denied, .restricted, .notDetermined:
            // No need to show upgrade prompt for these statuses
            break
        @unknown default:
            // Handle any future status cases
            break
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
                    Text(L10n.PhotoPickerWrapper.enableSwipeSelection)
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text(L10n.PhotoPickerWrapper.grantAccessDescription)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                
                VStack(spacing: 12) {
                    // Features list
                    FeatureRow(
                        icon: "hand.draw",
                        title: L10n.PhotoPickerWrapper.swipeToSelect,
                        description: L10n.PhotoPickerWrapper.swipeDescription
                    )
                    
                    FeatureRow(
                        icon: "speedometer",
                        title: L10n.PhotoPickerWrapper.fasterImport,
                        description: L10n.PhotoPickerWrapper.fasterImportDescription
                    )
                    
                    FeatureRow(
                        icon: "checkmark.shield",
                        title: L10n.PhotoPickerWrapper.privacyFirst,
                        description: L10n.PhotoPickerWrapper.privacyDescription
                    )
                }
                .padding(.horizontal)
                
                Spacer()
                
                VStack(spacing: 12) {
                    Button(action: requestFullAccess) {
                        Text(currentStatus == .limited ? L10n.PhotoPickerWrapper.upgradeToFullAccess : L10n.PhotoPickerWrapper.grantAccess)
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
                        Text(currentStatus == .limited ? L10n.PhotoPickerWrapper.continueLimited : L10n.PhotoPickerWrapper.notNow)
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
                    Button(L10n.done) {
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
