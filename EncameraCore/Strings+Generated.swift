// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// swiftlint:disable superfluous_disable_command file_length implicit_return prefer_self_in_static_references

// MARK: - Strings

// swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
public enum L10n {
  ///  icon in the camera view to change the active key.
  public static let iconInTheCameraViewToChangeTheActiveKey = L10n.tr("Localizable", " icon in the camera view to change the active key.", fallback: " icon in the camera view to change the active key.")
  ///  icon on the top left of the screen.
  public static let iconOnTheTopLeftOfTheScreen = L10n.tr("Localizable", " icon on the top left of the screen.", fallback: " icon on the top left of the screen.")
  /// Toggle("Hide", isOn: $viewModel.blurImages)
  public static func imageS(_ p1: Int) -> String {
    return L10n.tr("Localizable", "%@ image(s)", p1, fallback: "%@ image(s)")
  }
  /// ./EncameraCore/Utils/SettingsManager.swift
  public static func mustBeSet(_ p1: Any) -> String {
    return L10n.tr("Localizable", "%@ must be set", String(describing: p1), fallback: "%@ must be set")
  }
  /// ./Encamera/Store/PurchaseUpgradeOptionsListView.swift
  public static func purchased(_ p1: Any) -> String {
    return L10n.tr("Localizable", "**Purchased: %@**", String(describing: p1), fallback: "**Purchased: %@**")
  }
  /// return "Error coding keychain data."
  public static let aKeyWithThisNameAlreadyExists = L10n.tr("Localizable", "A key with this name already exists.", fallback: "A key with this name already exists.")
  /// ./Encamera/Camera/AlertError.swift
  public static let accept = L10n.tr("Localizable", "Accept", fallback: "Accept")
  /// .navigationTitle("Key Management")
  public static let active = L10n.tr("Localizable", "Active", fallback: "Active")
  /// KeyOperationCell(title: "Create New Key", imageName: "plus.app.fill")
  public static let addExistingKey = L10n.tr("Localizable", "Add Existing Key", fallback: "Add Existing Key")
  /// ./Encamera/KeyManagement/KeyOperationCell.swift
  public static let addKey = L10n.tr("Localizable", "Add Key", fallback: "Add Key")
  /// Text("Erase all data")
  public static let allDataExplanation = L10n.tr("Localizable", "allDataExplanation", fallback: "Are you sure you want to erase __all__ app data?\n\n__This will erase:__\n\n• All your stored keys 🔑\n• Your password 🔐\n• App settings 🎛\n• Media you have stored locally or on iCloud 💾\n\nYou can create a backup of your keys from the key management screen.\n\nThe app will quit after erase is finished.")
  /// Looks like you’re all set up! 🎊 Enjoy taking photos securely with Encamera’s top-notch encryption. 💪🔐
  public static let allSetupOnboarding = L10n.tr("Localizable", "AllSetupOnboarding", fallback: "Looks like you’re all set up! 🎊 Enjoy taking photos securely with Encamera’s top-notch encryption. 💪🔐")
  /// Are you sure you want to erase all app data?
  /// 
  /// __This will erase:__
  /// 
  /// • All your stored keys 🔑
  /// • Your password 🔐
  /// • App settings 🎛
  /// 
  /// __This will not erase:__
  /// 
  /// • Media you have stored locally or on iCloud 💾
  /// 
  /// You can create a backup of your keys from the key management screen.
  /// 
  /// The app will quit after erase is finished.
  /// 
  /// 
  public static let appDataExplanation = L10n.tr("Localizable", "appDataExplanation", fallback: "Are you sure you want to erase all app data?\n\n__This will erase:__\n\n• All your stored keys 🔑\n• Your password 🔐\n• App settings 🎛\n\n__This will not erase:__\n\n• Media you have stored locally or on iCloud 💾\n\nYou can create a backup of your keys from the key management screen.\n\nThe app will quit after erase is finished.\n\n")
  /// Backup Keys
  public static let backupKeys = L10n.tr("Localizable", "Backup Keys", fallback: "Backup Keys")
  /// return "Password incorrect"
  public static let biometricsFailed = L10n.tr("Localizable", "Biometrics failed", fallback: "Biometrics failed")
  /// return "Biometrics failed"
  public static let biometricsUnavailable = L10n.tr("Localizable", "Biometrics unavailable", fallback: "Biometrics unavailable")
  /// Text("This will save the media to your library.")
  public static let cancel = L10n.tr("Localizable", "Cancel", fallback: "Cancel")
  /// Button("Save") {
  public static let changePassword = L10n.tr("Localizable", "Change Password", fallback: "Change Password")
  /// Text("The media you tried to open could not be decrypted.")
  public static let checkThatTheSameKeyThatWasUsedToEncryptThisMediaIsSetAsTheActiveKey = L10n.tr("Localizable", "Check that the same key that was used to encrypt this media is set as the active key.", fallback: "Check that the same key that was used to encrypt this media is set as the active key.")
  /// Text("No private key or media found.")
  public static let close = L10n.tr("Localizable", "Close", fallback: "Close")
  /// Text("Save Key")
  public static let confirmAddingKey = L10n.tr("Localizable", "Confirm adding key", fallback: "Confirm adding key")
  /// ./Encamera/Tutorial/FirstPhotoTakenTutorial.swift
  public static let congratulations = L10n.tr("Localizable", "Congratulations!", fallback: "Congratulations!")
  /// .navigationTitle("Settings")
  public static let contact = L10n.tr("Localizable", "Contact", fallback: "Contact")
  /// Text("Delete All Key Data")
  public static let copiedToClipboard = L10n.tr("Localizable", "Copied to Clipboard", fallback: "Copied to Clipboard")
  /// Text("Share Key")
  public static let copyToClipboard = L10n.tr("Localizable", "Copy to clipboard", fallback: "Copy to clipboard")
  /// ./Encamera/ImageViewing/MovieViewing.swift
  public static func couldNotDecryptMovie(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Could not decrypt movie: %@", String(describing: p1), fallback: "Could not decrypt movie: %@")
  }
  /// ./EncameraCore/Utils/KeyManager.swift
  public static let couldNotDeleteKeychainItems = L10n.tr("Localizable", "Could not delete keychain items.", fallback: "Could not delete keychain items.")
  /// Text("View unlimited photos for each key.")
  public static let createAnUnlimitedNumberOfKeys = L10n.tr("Localizable", "Create an unlimited number of keys.", fallback: "Create an unlimited number of keys.")
  /// ./Encamera/KeyManagement/KeySelectionList.swift
  public static let createNewKey = L10n.tr("Localizable", "Create New Key", fallback: "Create New Key")
  /// Text("View unlimited photos 😍 ")
  public static let createUnlimitedKeys🔑 = L10n.tr("Localizable", "Create unlimited keys 🔑 ", fallback: "Create unlimited keys 🔑 ")
  /// ./Encamera/KeyManagement/KeyInformation.swift
  public static func created(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Created %@", String(describing: p1), fallback: "Created %@")
  }
  /// Text("Key Name: (viewModel.key.name)")
  public static func creationDate(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Creation Date: %@", String(describing: p1), fallback: "Creation Date: %@")
  }
  /// NavigationLink("Change Password", isActive: $viewModel.showDetailView) {
  public static let currentPassword = L10n.tr("Localizable", "Current Password", fallback: "Current Password")
  /// Text("Could not decrypt movie: (error.localizedDescription)")
  public static let decrypting = L10n.tr("Localizable", "Decrypting...", fallback: "Decrypting...")
  /// return "Decryption error: (wrapped.displayDescription)"
  public static func decryptionError(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Decryption error: %@", String(describing: p1), fallback: "Decryption error: %@")
  }
  /// ./EncameraCore/Constants/AppConstants.swift
  public static let defaultKey = L10n.tr("Localizable", "DefaultKey", fallback: "DefaultKey")
  /// }.confirmationDialog("Delete this image?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
  public static let delete = L10n.tr("Localizable", "Delete", fallback: "Delete")
  /// Text("Key copied to clipboard. Store this in a password manager or other secure place.")
  public static let deleteAllAssociatedData = L10n.tr("Localizable", "Delete All Associated Data?", fallback: "Delete All Associated Data?")
  /// Text("Delete Key")
  public static let deleteAllKeyData = L10n.tr("Localizable", "Delete All Key Data", fallback: "Delete All Key Data")
  /// .alert("Delete All Associated Data?", isPresented: $isShowingAlertForDeleteAllKeyData, actions: {
  public static let deleteEverything = L10n.tr("Localizable", "Delete Everything", fallback: "Delete Everything")
  /// Button("Copy to clipboard") {
  public static let deleteKey = L10n.tr("Localizable", "Delete Key", fallback: "Delete Key")
  /// Text("Do you want to delete this key and all media associated with it forever?")
  public static let deleteKeyQuestion = L10n.tr("Localizable", "Delete Key question", fallback: "Delete Key?")
  /// ./Encamera/ImageViewing/GalleryHorizontalScrollView.swift
  public static let deleteThisImage = L10n.tr("Localizable", "Delete this image?", fallback: "Delete this image?")
  /// Text("Do you want to delete this key forever? All media will remain saved.")
  public static let deletionError = L10n.tr("Localizable", "Deletion Error", fallback: "Deletion Error")
  /// Text("Enter the name of the key to delete all its data, including saved media, forever.")
  public static let doYouWantToDeleteThisKeyAndAllMediaAssociatedWithItForever = L10n.tr("Localizable", "Do you want to delete this key and all media associated with it forever?", fallback: "Do you want to delete this key and all media associated with it forever?")
  /// Text("Enter the name of the key to delete it forever. All media will remain saved.")
  public static let doYouWantToDeleteThisKeyForeverAllMediaWillRemainSaved = L10n.tr("Localizable", "Do you want to delete this key forever? All media will remain saved.", fallback: "Do you want to delete this key forever? All media will remain saved.")
  /// title: "Done!",
  public static let done = L10n.tr("Localizable", "Done", fallback: "Done")
  /// Text("Please select a storage location.")
  public static let doneOnboarding = L10n.tr("Localizable", "DoneOnboarding", fallback: "Done!")
  /// bottomButtonTitle: "Next", content:  {
  public static func enable(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Enable %@", String(describing: p1), fallback: "Enable %@")
  }
  /// title: "Use (method.nameForMethod)?",
  public static func enableToQuicklyAndSecurelyGainAccessToTheApp(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Enable %@ to quickly and securely gain access to the app.", String(describing: p1), fallback: "Enable %@ to quickly and securely gain access to the app.")
  }
  /// Text("Ready to take back your media? 📸")
  public static let encameraEncryptsAllDataItCreatesKeepingYourDataSafeFromThePryingEyesOfAIMediaAnalysisAndOtherViolationsOfPrivacy = L10n.tr("Localizable", "Encamera encrypts all data it creates, keeping your data safe from the prying eyes of AI, media analysis, and other violations of privacy.", fallback: "Encamera encrypts all data it creates, keeping your data safe from the prying eyes of AI, media analysis, and other violations of privacy.")
  /// ./Encamera/Styles/ViewModifiers/ButtonViewModifier.swift
  public static let encryptEverything = L10n.tr("Localizable", "Encrypt Everything", fallback: "Encrypt Everything")
  /// Toggle("Enable (method.nameForMethod)", isOn: $viewModel.useBiometrics)
  public static let encryptionKey = L10n.tr("Localizable", "Encryption Key", fallback: "Encryption Key")
  /// Text("No tracking, no funny business. Take control of what’s rightfully yours, your media, your data, your privacy.")
  public static let enterPassword = L10n.tr("Localizable", "Enter Password", fallback: "Enter Password")
  /// Text("Restore Purchases")
  public static let enterPromoCode = L10n.tr("Localizable", "Enter Promo Code", fallback: "Enter Promo Code")
  /// Button("Cancel", role: .cancel) {
  public static let enterTheNameOfTheKeyToDeleteAllItsDataIncludingSavedMediaForever = L10n.tr("Localizable", "Enter the name of the key to delete all its data, including saved media, forever.", fallback: "Enter the name of the key to delete all its data, including saved media, forever.")
  /// Erase
  public static let erase = L10n.tr("Localizable", "Erase", fallback: "Erase")
  /// Text("Erase keychain data")
  public static let eraseAllData = L10n.tr("Localizable", "Erase all data", fallback: "Erase all data")
  /// Button("Hold to erase") {
  public static let eraseAppData = L10n.tr("Localizable", "Erase app data", fallback: "Erase app data")
  /// Erase Device Data
  public static let eraseDeviceData = L10n.tr("Localizable", "Erase Device Data", fallback: "Erase Device Data")
  /// NavigationLink("Erase") {
  public static let eraseKeychainData = L10n.tr("Localizable", "Erase keychain data", fallback: "Erase keychain data")
  /// .navigationTitle("Erase app data")
  public static func erasingIn(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Erasing in %@", String(describing: p1), fallback: "Erasing in %@")
  }
  /// deleteActionError = "Error deleting key. Please try again."
  public static let errorClearingKeychain = L10n.tr("Localizable", "Error clearing keychain", fallback: "Error clearing keychain")
  /// return "Key not found."
  public static let errorCodingKeychainData = L10n.tr("Localizable", "Error coding keychain data.", fallback: "Error coding keychain data.")
  /// deleteActionError = "Error deleting key and associated files. Please try again or try to delete files manually via the Files app."
  public static let errorDeletingAllFiles = L10n.tr("Localizable", "Error deleting all files", fallback: "Error deleting all files")
  /// ./Encamera/KeyManagement/KeyEntry.swift
  public static let errorSavingKey = L10n.tr("Localizable", "Error saving key", fallback: "Error saving key")
  /// return "Touch ID"
  public static let faceID = L10n.tr("Localizable", "Face ID", fallback: "Face ID")
  /// ./Encamera/Styles/ViewModifiers/PurchaseOptionViewModifier.swift
  public static let familyShareable = L10n.tr("Localizable", "Family Shareable", fallback: "Family Shareable")
  /// Text("Your media is safely secured behind a key and stored locally on your device or cloud of choice.")
  public static let forYourEyesOnly👀 = L10n.tr("Localizable", "For your eyes only 👀", fallback: "For your eyes only 👀")
  /// Text("Family Shareable")
  public static let freeTrial = L10n.tr("Localizable", "Free Trial", fallback: "Free Trial")
  /// Got it!
  public static let gotIt = L10n.tr("Localizable", "Got it!", fallback: "Got it!")
  /// ./Encamera/ImageViewing/GalleryGridView.swift
  public static let hide = L10n.tr("Localizable", "Hide", fallback: "Hide")
  /// ./Encamera/Settings/PromptToErase.swift
  public static let holdToErase = L10n.tr("Localizable", "Hold to erase", fallback: "Hold to erase")
  /// Text("Share your encryption key with someone you trust.nnSharing it with them means they can decrypt any media you share with them that is encrypted with this key.")
  public static let holdToReveal = L10n.tr("Localizable", "Hold to reveal", fallback: "Hold to reveal")
  /// ./EncameraCore/Models/StorageType.swift
  public static let iCloud = L10n.tr("Localizable", "iCloud", fallback: "iCloud")
  /// var placeholderText = "Password"
  public static let invalidPassword = L10n.tr("Localizable", "Invalid Password", fallback: "Invalid Password")
  /// context.localizedCancelTitle = "Use Password"
  public static func keepYourEncryptedDataSafeByUsing(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Keep your encrypted data safe by using %@.", String(describing: p1), fallback: "Keep your encrypted data safe by using %@.")
  }
  /// Button("Save") {
  public static let keyEntry = L10n.tr("Localizable", "Key Entry", fallback: "Key Entry")
  /// Button("Set Active") {
  public static let keyInfo = L10n.tr("Localizable", "Key Info", fallback: "Key Info")
  /// Text("Created (DateUtils.dateOnlyString(from: key.creationDate))")
  public static func keyLength(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Key length: %@", String(describing: p1), fallback: "Key length: %@")
  }
  /// Section(header: Text("Keys")
  public static let keyManagement = L10n.tr("Localizable", "Key Management", fallback: "Key Management")
  /// bottomButtonTitle: "Next",
  public static let keyName = L10n.tr("Localizable", "Key Name", fallback: "Key Name")
  /// return "Not authenticated for this operation."
  public static let keyNameIsInvalidMustBeMoreThanTwoCharacters = L10n.tr("Localizable", "Key name is invalid, must be more than two characters", fallback: "Key name is invalid, must be more than two characters")
  /// ./Encamera/KeyManagement/AddExchangedKeyConfirmation.swift
  public static func keyName(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Key Name: %@", String(describing: p1), fallback: "Key Name: %@")
  }
  /// return "Key name is invalid, must be more than two characters"
  public static let keyNotFound = L10n.tr("Localizable", "Key not found.", fallback: "Key not found.")
  /// Key Selection
  public static let keySelection = L10n.tr("Localizable", "Key Selection", fallback: "Key Selection")
  /// Text("Encamera encrypts all data it creates, keeping your data safe from the prying eyes of AI, media analysis, and other violations of privacy.")
  public static let keyBasedEncryption🔑 = L10n.tr("Localizable", "Key-based encryption 🔑", fallback: "Key-based encryption 🔑")
  /// Keys
  public static let keys = L10n.tr("Localizable", "Keys", fallback: "Keys")
  /// return "iCloud"
  public static let local = L10n.tr("Localizable", "Local", fallback: "Local")
  /// ./Encamera/CameraView/CameraView.swift
  public static let missingCameraAccess = L10n.tr("Localizable", "Missing camera access.", fallback: "Missing camera access.")
  /// ./Encamera/AuthenticationView/AuthenticationView.swift
  public static let missingPassword = L10n.tr("Localizable", "Missing password", fallback: "Missing password")
  /// title: "New Key",
  public static let multipleKeysForMultiplePurposesExplanation = L10n.tr("Localizable", "MultipleKeysForMultiplePurposesExplanation", fallback: "You can have multiple keys for different purposes, e.g. one named \"Documents\" and another \"Personal\".")
  /// Text("Add Existing Key")
  public static let myKeys = L10n.tr("Localizable", "My Keys", fallback: "My Keys")
  /// New Key
  public static let newKey = L10n.tr("Localizable", "New Key", fallback: "New Key")
  /// title: "Encryption Key",
  public static let newKeySubheading = L10n.tr("Localizable", "New Key Subheading", fallback: "Set the name for this key.\n\nYou can have multiple keys for different purposes, e.g. one named \"Documents\" and another \"Personal\".")
  /// SecureField("Current Password", text: $viewModel.currentPassword)
  public static let newPassword = L10n.tr("Localizable", "New Password", fallback: "New Password")
  /// ./Encamera/Onboarding/OnboardingView.swift
  public static let next = L10n.tr("Localizable", "Next", fallback: "Next")
  /// return "No key available."
  public static let noFileAccessAvailable = L10n.tr("Localizable", "No file access available.", fallback: "No file access available.")
  /// ./EncameraCore/Utils/DataStorageUserDefaultsSetting.swift
  public static let noICloudAccountFoundOnThisDevice = L10n.tr("Localizable", "No iCloud account found on this device.", fallback: "No iCloud account found on this device.")
  /// ./Encamera/ImageViewing/PhotoInfoView.swift
  public static let noInfoAvailable = L10n.tr("Localizable", "No info available", fallback: "No info available")
  /// Text("Open settings to allow camera access permission")
  public static let noKey = L10n.tr("Localizable", "No Key", fallback: "No Key")
  /// ./Encamera/ImageViewing/ImageViewing.swift
  public static let noKeyAvailable = L10n.tr("Localizable", "No key available.", fallback: "No key available.")
  /// No Key Selected
  public static let noKeySelected = L10n.tr("Localizable", "No Key Selected", fallback: "No Key Selected")
  /// ./Encamera/EncameraApp.swift
  public static let noPrivateKeyOrMediaFound = L10n.tr("Localizable", "No private key or media found.", fallback: "No private key or media found.")
  /// Button("Free Trial") {
  public static let noThanks = L10n.tr("Localizable", "No, thanks", fallback: "No, thanks")
  /// return "Unhandled error."
  public static let notAuthenticatedForThisOperation = L10n.tr("Localizable", "Not authenticated for this operation.", fallback: "Not authenticated for this operation.")
  /// ./EncameraCore/Utils/PasswordValidator.swift
  public static let notDetermined = L10n.tr("Localizable", "Not determined.", fallback: "Not determined.")
  /// .alert("Deletion Error", isPresented: $viewModel.showDeleteActionError, actions: {
  public static let ok = L10n.tr("Localizable", "OK", fallback: "OK")
  /// Text("Subscription")
  public static let oneTimePurchase = L10n.tr("Localizable", "One-Time Purchase", fallback: "One-Time Purchase")
  /// Text("Missing camera access.")
  public static let openSettingsToAllowCameraAccessPermission = L10n.tr("Localizable", "Open settings to allow camera access permission", fallback: "Open settings to allow camera access permission")
  /// bottomButtonTitle: "Set Password",
  public static let password = L10n.tr("Localizable", "Password", fallback: "Password")
  /// return "Missing password"
  public static let passwordIncorrect = L10n.tr("Localizable", "Password incorrect", fallback: "Password incorrect")
  /// return "Passwords do not match."
  public static func passwordIsTooLong(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Password is too long, >%@", String(describing: p1), fallback: "Password is too long, >%@")
  }
  /// return "Password is valid."
  public static func passwordIsTooShort(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Password is too short, <%@", String(describing: p1), fallback: "Password is too short, <%@")
  }
  /// return "Not determined."
  public static let passwordIsValid = L10n.tr("Localizable", "Password is valid.", fallback: "Password is valid.")
  /// ./Encamera/Settings/SettingsView.swift
  public static let passwordSuccessfullyChanged = L10n.tr("Localizable", "Password successfully changed", fallback: "Password successfully changed")
  /// return "Password is too short, <(PasswordValidation.minPasswordLength)"
  public static let passwordsDoNotMatch = L10n.tr("Localizable", "Passwords do not match.", fallback: "Passwords do not match.")
  /// debugPrint("Error saving key", error)
  public static let pasteThePrivateKeyHere = L10n.tr("Localizable", "Paste the private key here.", fallback: "Paste the private key here.")
  /// ./Encamera/CameraView/CameraModePicker.swift
  public static let photo = L10n.tr("Localizable", "PHOTO", fallback: "PHOTO")
  /// bottomButtonTitle: "Next") {
  public static let pleaseSelectAStorageLocation = L10n.tr("Localizable", "Please select a storage location.", fallback: "Please select a storage location.")
  /// Text("Thank you for your support!")
  public static let premium = L10n.tr("Localizable", "premium", fallback: "premium")
  /// case changePasswordSuccess = "Password successfully changed"
  public static let premiumSparkles = L10n.tr("Localizable", "premium sparkles", fallback: "✨ Premium ✨")
  /// Button("Contact") {
  public static let privacyPolicy = L10n.tr("Localizable", "Privacy Policy", fallback: "Privacy Policy")
  /// bottomButtonTitle: "Next",
  public static let readyToTakeBackYourMedia📸 = L10n.tr("Localizable", "Ready to take back your media? 📸", fallback: "Ready to take back your media? 📸")
  /// EncameraTextField("Password", type: viewModel.showPassword ? .normal : .secure, text: $viewModel.password1).onSubmit {
  public static let repeatPassword = L10n.tr("Localizable", "Repeat Password", fallback: "Repeat Password")
  /// Text("Support privacy-focused development.")
  public static let restorePurchases = L10n.tr("Localizable", "Restore Purchases", fallback: "Restore Purchases")
  /// Button("Cancel", role: .cancel) {
  public static let save = L10n.tr("Localizable", "Save", fallback: "Save")
  /// return .init(title: "Storage Settings",
  public static let saveKey = L10n.tr("Localizable", "Save Key", fallback: "Save Key")
  /// Button("Close") {
  public static let saveThisMedia = L10n.tr("Localizable", "Save this media?", fallback: "Save this media?")
  /// Text("Subscribed")
  public static func saveAmount(_ p1: Any, _ p2: Any) -> String {
    return L10n.tr("Localizable", "SaveAmount %@ $@", String(describing: p1), String(describing: p2), fallback: "%@ (Save %@)")
  }
  /// return "Local"
  public static let savesEncryptedFilesToICloudDrive = L10n.tr("Localizable", "Saves encrypted files to iCloud Drive.", fallback: "Saves encrypted files to iCloud Drive.")
  /// return "Saves encrypted files to iCloud Drive."
  public static let savesEncryptedFilesToThisDevice = L10n.tr("Localizable", "Saves encrypted files to this device.", fallback: "Saves encrypted files to this device.")
  /// Text("You took your first photo! 📸 🥳")
  public static let seeThePhotosThatBelongToAKeyByTappingThe = L10n.tr("Localizable", "See the photos that belong to a key by tapping the ", fallback: "See the photos that belong to a key by tapping the ")
  /// bottomButtonTitle: "Save Key") {
  public static let selectAPlaceToKeepMediaForThisKey = L10n.tr("Localizable", "Select a place to keep media for this key.", fallback: "Select a place to keep media for this key.")
  /// EncameraTextField("Key Name", text: $viewModel.keyName)
  public static let selectStorage = L10n.tr("Localizable", "Select Storage", fallback: "Select Storage")
  /// debugPrint("Error deleting all files")
  public static let setActive = L10n.tr("Localizable", "Set Active", fallback: "Set Active")
  /// Set Password
  public static let setPassword = L10n.tr("Localizable", "Set Password", fallback: "Set Password")
  /// Button("Restore Purchases") {
  public static let settings = L10n.tr("Localizable", "Settings", fallback: "Settings")
  /// Button("Unlock") {
  public static let share = L10n.tr("Localizable", "Share", fallback: "Share")
  /// Button("Share Encrypted") {
  public static let shareDecrypted = L10n.tr("Localizable", "Share Decrypted", fallback: "Share Decrypted")
  /// Share Encrypted
  public static let shareEncrypted = L10n.tr("Localizable", "Share Encrypted", fallback: "Share Encrypted")
  /// Button("Delete", role: .destructive) {
  public static let shareImage = L10n.tr("Localizable", "Share Image", fallback: "Share Image")
  /// Text("Key Info")
  public static let shareKey = L10n.tr("Localizable", "Share Key", fallback: "Share Key")
  /// .confirmationDialog("Share Image", isPresented: $showingShareSheet) {
  public static let shareThisImage = L10n.tr("Localizable", "Share this image?", fallback: "Share this image?")
  /// ./Encamera/ShareHandling/ShareHandling.swift
  public static let sharedMedia = L10n.tr("Localizable", "Shared Media", fallback: "Shared Media")
  /// ./Encamera/Store/PurchaseUpgradeView.swift
  public static let startTrialOffer = L10n.tr("Localizable", "Start trial offer", fallback: "Start trial offer")
  /// subheading: ,
  public static let storageLocationOnboarding = L10n.tr("Localizable", "Storage location onboarding", fallback: "Where do you want to store your media? Each key will store data in its own directory once encrypted. 💾")
  /// bottomButtonTitle: "Next",
  public static let storageSettings = L10n.tr("Localizable", "Storage Settings", fallback: "Storage Settings")
  /// @Published var keyName: String = ""
  public static let storageSettingsSubheading = L10n.tr("Localizable", "StorageSettingsSubheading", fallback: "Where do you want to store media for files encrypted with this key?\nEach key will store data in its own directory.\n")
  /// Text("Start trial offer")
  public static let subscribe = L10n.tr("Localizable", "Subscribe", fallback: "Subscribe")
  /// ./Encamera/Store/SubscriptionOptionView.swift
  public static let subscribed = L10n.tr("Localizable", "Subscribed", fallback: "Subscribed")
  /// is only one "premium" purchasable product or
  public static let subscription = L10n.tr("Localizable", "Subscription", fallback: "Subscription")
  /// Text("Want more?")
  public static let supportPrivacyFocusedDevelopmentByUpgrading = L10n.tr("Localizable", "Support privacy-focused development by upgrading!", fallback: "Support privacy-focused development by upgrading!")
  /// Text("Create an unlimited number of keys.")
  public static let supportPrivacyFocusedDevelopment = L10n.tr("Localizable", "Support privacy-focused development.", fallback: "Support privacy-focused development.")
  /// Text("Check that the same key that was used to encrypt this media is set as the active key.")
  public static let tapThe = L10n.tr("Localizable", "Tap the ", fallback: "Tap the ")
  /// Text("Upgrade to view unlimited photos")
  public static let tapToUpgrade = L10n.tr("Localizable", "Tap to Upgrade", fallback: "Tap to Upgrade")
  /// Button("Privacy Policy") {
  public static let termsOfUse = L10n.tr("Localizable", "Terms of Use", fallback: "Terms of Use")
  /// Text("**Purchased: (product.displayName)**")
  public static let thankYouForYourSupport = L10n.tr("Localizable", "Thank you for your support!", fallback: "Thank you for your support!")
  /// ./Encamera/ImageViewing/DecryptErrorExplanation.swift
  public static let theMediaYouTriedToOpenCouldNotBeDecrypted = L10n.tr("Localizable", "The media you tried to open could not be decrypted.", fallback: "The media you tried to open could not be decrypted.")
  /// .alert("Save this media?", isPresented: $viewModel.promptToSaveMedia) {
  public static let thisWillSaveTheMediaToYourLibrary = L10n.tr("Localizable", "This will save the media to your library.", fallback: "This will save the media to your library.")
  /// ./EncameraCore/Utils/AuthManager.swift
  public static let touchID = L10n.tr("Localizable", "Touch ID", fallback: "Touch ID")
  /// return "Could not delete keychain items."
  public static let unhandledError = L10n.tr("Localizable", "Unhandled error.", fallback: "Unhandled error.")
  /// Button("Encrypt Everything") {
  public static let unlock = L10n.tr("Localizable", "Unlock", fallback: "Unlock")
  /// return "Biometrics unavailable"
  public static func unlockWith(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Unlock with %@", String(describing: p1), fallback: "Unlock with %@")
  }
  /// ./Encamera/InAppPurchase/PurchasePhotoSubscriptionOverlay.swift
  public static let upgradeToViewUnlimitedPhotos = L10n.tr("Localizable", "Upgrade to view unlimited photos", fallback: "Upgrade to view unlimited photos")
  /// EncameraTextField("Repeat Password", type: viewModel.showPassword ? .normal : .secure, text: $viewModel.password2)
  public static func use(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Use %@?", String(describing: p1), fallback: "Use %@?")
  }
  /// return "Password"
  public static let usePassword = L10n.tr("Localizable", "Use Password", fallback: "Use Password")
  /// return "PHOTO"
  public static let video = L10n.tr("Localizable", "VIDEO", fallback: "VIDEO")
  /// ./Encamera/Store/SubscriptionView.swift
  public static let viewUnlimitedPhotosForEachKey = L10n.tr("Localizable", "View unlimited photos for each key.", fallback: "View unlimited photos for each key.")
  /// Text("Support privacy-focused development by upgrading!")
  public static let viewUnlimitedPhotos😍 = L10n.tr("Localizable", "View unlimited photos 😍 ", fallback: "View unlimited photos 😍 ")
  /// ./Encamera/Tutorial/ExplanationForUpgradeTutorial.swift
  public static let wantMore = L10n.tr("Localizable", "Want more?", fallback: "Want more?")
  /// Text("Paste the private key here.")
  public static let whereDoYouWantToSaveThisKeySMedia = L10n.tr("Localizable", "Where do you want to save this key's media?", fallback: "Where do you want to save this key's media?")
  /// You don't have an active key selected, select one to continue saving media.
  public static let youDonTHaveAnActiveKeySelectedSelectOneToContinueSavingMedia = L10n.tr("Localizable", "You don't have an active key selected, select one to continue saving media.", fallback: "You don't have an active key selected, select one to continue saving media.")
  /// title: "Enter Password",
  public static let youHaveAnExistingPasswordForThisDevice = L10n.tr("Localizable", "You have an existing password for this device.", fallback: "You have an existing password for this device.")
  /// Text("Congratulations!")
  public static let youTookYourFirstPhoto📸🥳 = L10n.tr("Localizable", "You took your first photo! 📸 🥳", fallback: "You took your first photo! 📸 🥳")
  /// Text("Key-based encryption 🔑")
  public static let yourMediaIsSafelySecuredBehindAKeyAndStoredLocallyOnYourDeviceOrCloudOfChoice = L10n.tr("Localizable", "Your media is safely secured behind a key and stored locally on your device or cloud of choice.", fallback: "Your media is safely secured behind a key and stored locally on your device or cloud of choice.")
  public enum EnterTheNameOfTheKeyToDeleteItForever {
    /// Button("Cancel", role: .cancel) {
    public static let allMediaWillRemainSaved = L10n.tr("Localizable", "Enter the name of the key to delete it forever. All media will remain saved.", fallback: "Enter the name of the key to delete it forever. All media will remain saved.")
  }
  public enum ErrorDeletingKey {
    /// ./Encamera/KeyManagement/KeyDetailView.swift
    public static let pleaseTryAgain = L10n.tr("Localizable", "Error deleting key. Please try again.", fallback: "Error deleting key. Please try again.")
  }
  public enum ErrorDeletingKeyAndAssociatedFiles {
    /// debugPrint("Error clearing keychain", error)
    public static let pleaseTryAgainOrTryToDeleteFilesManuallyViaTheFilesApp = L10n.tr("Localizable", "Error deleting key and associated files. Please try again or try to delete files manually via the Files app.", fallback: "Error deleting key and associated files. Please try again or try to delete files manually via the Files app.")
  }
  public enum KeyCopiedToClipboard {
    /// Button("OK") {
    public static let storeThisInAPasswordManagerOrOtherSecurePlace = L10n.tr("Localizable", "Key copied to clipboard. Store this in a password manager or other secure place.", fallback: "Key copied to clipboard. Store this in a password manager or other secure place.")
  }
  public enum NoTrackingNoFunnyBusiness {
    /// Text("For your eyes only 👀")
    public static let takeControlOfWhatSRightfullyYoursYourMediaYourDataYourPrivacy = L10n.tr("Localizable", "No tracking, no funny business. Take control of what’s rightfully yours, your media, your data, your privacy.", fallback: "No tracking, no funny business. Take control of what’s rightfully yours, your media, your data, your privacy.")
  }
  public enum SetAPasswordToAccessTheApp {
    public enum BeSureToStoreItInASafePlaceYouCannotRecoverItLater {
      /// title: "Set Password",
      public static let 🙅 = L10n.tr("Localizable", "Set a password to access the app. Be sure to store it in a safe place – you cannot recover it later. 🙅", fallback: "Set a password to access the app. Be sure to store it in a safe place – you cannot recover it later. 🙅")
    }
  }
  public enum ShareYourEncryptionKeyWithSomeoneYouTrust {
    /// ./Encamera/KeyManagement/KeyExchange.swift
    public static let sharingItWithThemMeansTheyCanDecryptAnyMediaYouShareWithThemThatIsEncryptedWithThisKey = L10n.tr("Localizable", "Share your encryption key with someone you trust.\n\nSharing it with them means they can decrypt any media you share with them that is encrypted with this key.", fallback: "Share your encryption key with someone you trust.\n\nSharing it with them means they can decrypt any media you share with them that is encrypted with this key.")
  }
}
// swiftlint:enable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:enable nesting type_body_length type_name vertical_whitespace_opening_braces

// MARK: - Implementation Details

extension L10n {
  private static func tr(_ table: String, _ key: String, _ args: CVarArg..., fallback value: String) -> String {
    let format = BundleToken.bundle.localizedString(forKey: key, value: value, table: table)
    return String(format: format, locale: Locale.current, arguments: args)
  }
}

// swiftlint:disable convenience_type
private final class BundleToken {
  static let bundle: Bundle = {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle(for: BundleToken.self)
    #endif
  }()
}
// swiftlint:enable convenience_type
