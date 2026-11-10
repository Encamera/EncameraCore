// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import Foundation

// swiftlint:disable superfluous_disable_command file_length implicit_return prefer_self_in_static_references

// MARK: - Strings

// swiftlint:disable explicit_type_interface function_parameter_count identifier_name line_length
// swiftlint:disable nesting type_body_length type_name vertical_whitespace_opening_braces
public enum L10n {
  /// Plural format key: "%#@item_count@"
  public static func itemS(_ p1: Int) -> String {
    return L10n.tr("Localizable", "%@ Item(s)", p1, fallback: "Plural format key: \"%#@item_count@\"")
  }
  /// A key with this name already exists.
  public static let aKeyWithThisNameAlreadyExists = L10n.tr("Localizable", "A key with this name already exists.", fallback: "A key with this name already exists.")
  /// An album with that name already exists.
  public static let albumExistsError = L10n.tr("Localizable", "AlbumExistsError", fallback: "An album with that name already exists.")
  /// This album can't be renamed while items are moving. Try again when the move finishes.
  public static let albumMoveInProgressRenameError = L10n.tr("Localizable", "AlbumMoveInProgressRenameError", fallback: "This album can't be renamed while items are moving. Try again when the move finishes.")
  /// Album Name
  public static let albumName = L10n.tr("Localizable", "AlbumName", fallback: "Album Name")
  /// Album name must be longer than 1 character
  public static let albumNameInvalid = L10n.tr("Localizable", "AlbumNameInvalid", fallback: "Album name must be longer than 1 character")
  /// AlbumManager
  public static let albumNotFoundAtSourceLocation = L10n.tr("Localizable", "AlbumNotFoundAtSourceLocation", fallback: "Could not find the album at the source location. Use the Files app to ensure that it exists.")
  /// AlbumGrid
  public static let albumsTitle = L10n.tr("Localizable", "AlbumsTitle", fallback: "Albums")
  /// Unlock Method
  public static let authenticationMethod = L10n.tr("Localizable", "AuthenticationMethod", fallback: "Unlock Method")
  /// Face ID or Touch ID didn't work
  public static let biometricsFailed = L10n.tr("Localizable", "Biometrics failed", fallback: "Face ID or Touch ID didn't work")
  /// Face ID or Touch ID isn't available
  public static let biometricsUnavailable = L10n.tr("Localizable", "Biometrics unavailable", fallback: "Face ID or Touch ID isn't available")
  /// Cancel
  public static let cancel = L10n.tr("Localizable", "Cancel", fallback: "Cancel")
  /// Cannot Clear Alert
  public static let cannotClearTitle = L10n.tr("Localizable", "CannotClearTitle", fallback: "Can't Turn Off Passcode")
  /// Change Unlock Method
  public static let changeAuthenticationMethod = L10n.tr("Localizable", "Change Authentication Method", fallback: "Change Unlock Method")
  /// Change Passcode
  public static let changePasscode = L10n.tr("Localizable", "ChangePasscode", fallback: "Change Passcode")
  /// ./Encamera/Tutorial/ChooseStorageModal.swift
  public static let chooseYourStorage = L10n.tr("Localizable", "ChooseYourStorage", fallback: "Choose your storage")
  /// Choose where to securely save your media from now on.
  public static let chooseYourStorageDescription = L10n.tr("Localizable", "ChooseYourStorageDescription", fallback: "Choose where to securely save your media from now on.")
  /// Clear
  public static let clear = L10n.tr("Localizable", "Clear", fallback: "Clear")
  /// Authentication Method View
  public static let clearPassword = L10n.tr("Localizable", "Clear Password", fallback: "Turn Off Passcode")
  /// ./Encamera/EncameraApp.swift
  public static let close = L10n.tr("Localizable", "Close", fallback: "Close")
  /// Confirm 6-Digit PIN
  public static let confirm6DigitPIN = L10n.tr("Localizable", "Confirm 6-Digit PIN", fallback: "Confirm 6-Digit PIN")
  /// Confirm PIN
  public static let confirmPinCode = L10n.tr("Localizable", "ConfirmPinCode", fallback: "Confirm PIN")
  /// Confirm Storage
  public static let confirmStorage = L10n.tr("Localizable", "ConfirmStorage", fallback: "Confirm Storage")
  /// Continue
  public static let `continue` = L10n.tr("Localizable", "Continue", fallback: "Continue")
  /// Picture taken overlay
  public static let coolPicture = L10n.tr("Localizable", "CoolPicture", fallback: "Nice shot!")
  /// Could not rename album.
  public static let couldNotRenameAlbumError = L10n.tr("Localizable", "CouldNotRenameAlbumError", fallback: "Could not rename album.")
  /// ./Encamera/KeyManagement/AlbumGridItem.swift
  public static let createNewAlbum = L10n.tr("Localizable", "CreateNewAlbum", fallback: "Create New Album")
  /// Decryption error: %@. Please update Encamera to the latest version if you haven't already.
  public static func decryptionError(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Decryption error: %@", String(describing: p1), fallback: "Decryption error: %@. Please update Encamera to the latest version if you haven't already.")
  }
  /// ./EncameraCore/Constants/AppConstants.swift
  public static let defaultAlbumName = L10n.tr("Localizable", "DefaultAlbumName", fallback: "Default Album")
  /// Delete
  public static let delete = L10n.tr("Localizable", "Delete", fallback: "Delete")
  /// Delete Album and Its Items?
  public static let deleteAllAssociatedData = L10n.tr("Localizable", "Delete All Associated Data?", fallback: "Delete Album and Its Items?")
  /// Delete Album
  public static let deleteEverything = L10n.tr("Localizable", "Delete Everything", fallback: "Delete Album")
  /// Delete Album
  public static let deleteAlbum = L10n.tr("Localizable", "DeleteAlbum", fallback: "Delete Album")
  /// Deselect All
  public static let deselectAll = L10n.tr("Localizable", "Deselect All", fallback: "Deselect All")
  /// Done
  public static let done = L10n.tr("Localizable", "Done", fallback: "Done")
  /// Do you remember your passcode?
  public static let doYouRememberYourPasscode = L10n.tr("Localizable", "DoYouRememberYourPasscode", fallback: "Do you remember your passcode?")
  /// If you don't, you can set a new one by going to 'Change Passcode'
  public static let doYouRememberYourPasscodeSubtitle = L10n.tr("Localizable", "DoYouRememberYourPasscodeSubtitle", fallback: "If you don't, you can set a new one by going to 'Change Passcode'")
  /// ./Encamera/Store/SubscriptionView.swift
  public static let enterPromoCode = L10n.tr("Localizable", "Enter Promo Code", fallback: "Enter Promo Code")
  /// Enter Recovery Key
  public static let enterKeyPhrase = L10n.tr("Localizable", "EnterKeyPhrase", fallback: "Enter Recovery Key")
  /// Enter your recovery key. Put a space between each word.
  public static let enterKeyPhraseDescription = L10n.tr("Localizable", "EnterKeyPhraseDescription", fallback: "Enter your recovery key. Put a space between each word.")
  /// Enter Passcode
  public static let enterPasscode = L10n.tr("Localizable", "EnterPasscode", fallback: "Enter Passcode")
  /// Erase All Data
  public static let eraseAllData = L10n.tr("Localizable", "Erase All Data", fallback: "Erase All Data")
  /// Erasing in %@
  public static func erasingIn(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Erasing in %@", String(describing: p1), fallback: "Erasing in %@")
  }
  /// Error coding keychain data.
  public static let errorCodingKeychainData = L10n.tr("Localizable", "Error coding keychain data.", fallback: "Error coding keychain data.")
  /// Couldn't add this recovery key
  public static let errorImportingKeyPhrase = L10n.tr("Localizable", "ErrorImportingKeyPhrase", fallback: "Couldn't add this recovery key")
  /// Face ID
  public static let faceID = L10n.tr("Localizable", "Face ID", fallback: "Face ID")
  /// Failed to save password
  public static let failedToSavePassword = L10n.tr("Localizable", "FailedToSavePassword", fallback: "Failed to save password")
  /// Get Premium
  public static let getPremium = L10n.tr("Localizable", "GetPremium", fallback: "Get Premium")
  /// ./Encamera/ImageViewing/GalleryGridView.swift
  public static let hide = L10n.tr("Localizable", "Hide", fallback: "Hide")
  /// ./Encamera/Settings/PromptToErase.swift
  public static let holdToErase = L10n.tr("Localizable", "Hold to erase", fallback: "Hold to erase")
  /// I Forgot
  public static let iForgot = L10n.tr("Localizable", "IForgot", fallback: "I Forgot")
  /// Import
  public static let `import` = L10n.tr("Localizable", "Import", fallback: "Import")
  /// Import from Files
  public static let importFromFiles = L10n.tr("Localizable", "Import from files", fallback: "Import from Files")
  /// Enter Recovery Key
  public static let importKeyPhrase = L10n.tr("Localizable", "ImportKeyPhrase", fallback: "Enter Recovery Key")
  /// Wrong Passcode
  public static let invalidPassword = L10n.tr("Localizable", "Invalid Password", fallback: "Wrong Passcode")
  /// I Remember my Passcode
  public static let iRemember = L10n.tr("Localizable", "IRemember", fallback: "I Remember my Passcode")
  /// Join Discord
  public static let joinDiscord = L10n.tr("Localizable", "Join Discord", fallback: "Join Discord")
  /// Keep your encrypted data safe by using %@.
  public static func keepYourEncryptedDataSafeByUsing(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Keep your encrypted data safe by using %@.", String(describing: p1), fallback: "Keep your encrypted data safe by using %@.")
  }
  /// ./EncameraCore/Utils/KeyManager.swift
  public static let keyNotFound = L10n.tr("Localizable", "Key not found.", fallback: "Key not found.")
  /// Leave a Review
  public static let leaveAReview = L10n.tr("Localizable", "Leave a Review", fallback: "Leave a Review")
  /// Let's give your
  /// album a name
  public static let letsGiveYourAlbumAName = L10n.tr("Localizable", "LetsGiveYourAlbumAName", fallback: "Let's give your\nalbum a name")
  /// ./EncameraCore/Models/StorageType.swift
  public static let local = L10n.tr("Localizable", "Local", fallback: "This Device")
  /// this device
  public static let localDevice = L10n.tr("Localizable", "LocalDevice", fallback: "this device")
  /// Choose how you want to unlock Encamera.
  public static let loginMethodDescription = L10n.tr("Localizable", "LoginMethodDescription", fallback: "Choose how you want to unlock Encamera.")
  /// Make sure you remember your PIN!
  public static let makeSureYouRememberYourPin = L10n.tr("Localizable", "MakeSureYouRememberYourPin", fallback: "Make sure you remember your PIN!")
  /// ./Encamera/CameraView/CameraView.swift
  public static let missingCameraAccess = L10n.tr("Localizable", "Missing camera access", fallback: "Missing camera access")
  /// ./Encamera/AuthenticationView/AuthenticationView.swift
  public static let missingPassword = L10n.tr("Localizable", "Missing password", fallback: "Enter your passcode")
  /// Get Premium for unlimited photos and videos
  public static let modalUpgradeText = L10n.tr("Localizable", "ModalUpgradeText", fallback: "Get Premium for unlimited photos and videos")
  /// Change Storage
  public static let moveAlbumStorage = L10n.tr("Localizable", "MoveAlbumStorage", fallback: "Change Storage")
  /// New Album
  public static let newAlbum = L10n.tr("Localizable", "New Album", fallback: "New Album")
  /// Set the name for this encrypted photo album.
  public static let newAlbumSubheading = L10n.tr("Localizable", "New Album Subheading", fallback: "Set the name for this encrypted photo album.")
  /// ./Encamera/Onboarding/MainOnboardingView.swift
  public static let next = L10n.tr("Localizable", "Next", fallback: "Next")
  /// No
  public static let no = L10n.tr("Localizable", "No", fallback: "No")
  /// No file access available.
  public static let noFileAccessAvailable = L10n.tr("Localizable", "No file access available.", fallback: "No file access available.")
  /// ./EncameraCore/Utils/DataStorageUserDefaultsSetting.swift
  public static let noICloudAccountFoundOnThisDevice = L10n.tr("Localizable", "No iCloud account found on this device.", fallback: "No iCloud account found on this device.")
  /// ./Encamera/ImageViewing/ImageViewing.swift
  public static let noKeyAvailable = L10n.tr("Localizable", "No key available.", fallback: "No key available.")
  /// None
  public static let `none` = L10n.tr("Localizable", "None", fallback: "None")
  /// ./EncameraCore/Utils/PasswordValidator.swift
  public static let notDetermined = L10n.tr("Localizable", "Not determined.", fallback: "Not determined.")
  /// Notifications
  public static let notificationListTitle = L10n.tr("Localizable", "NotificationListTitle", fallback: "Notifications")
  /// OK
  public static let ok = L10n.tr("Localizable", "OK", fallback: "OK")
  /// ./Encamera/Settings/SettingsView.swift
  public static let openSource = L10n.tr("Localizable", "Open Source", fallback: "Open Source")
  /// Open Settings
  public static let openSettings = L10n.tr("Localizable", "OpenSettings", fallback: "Open Settings")
  /// Open Settings
  public static let openSystemSettings = L10n.tr("Localizable", "OpenSystemSettings", fallback: "Open Settings")
  /// Or
  public static let or = L10n.tr("Localizable", "Or", fallback: "Or")
  /// Password
  public static let password = L10n.tr("Localizable", "Password", fallback: "Password")
  /// Wrong Passcode
  public static let passwordIncorrect = L10n.tr("Localizable", "Password incorrect", fallback: "Wrong Passcode")
  /// Password is too long, >%@
  public static func passwordIsTooLong(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Password is too long, >%@", String(describing: p1), fallback: "Password is too long, >%@")
  }
  /// Password is too short, <%@
  public static func passwordIsTooShort(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Password is too short, <%@", String(describing: p1), fallback: "Password is too short, <%@")
  }
  /// Password is valid.
  public static let passwordIsValid = L10n.tr("Localizable", "Password is valid.", fallback: "Password is valid.")
  /// Passwords do not match
  public static let passwordMismatch = L10n.tr("Localizable", "PasswordMismatch", fallback: "Passwords do not match")
  /// Passwords do not match.
  public static let passwordsDoNotMatch = L10n.tr("Localizable", "Passwords do not match.", fallback: "Passwords do not match.")
  /// Password Set Successfully
  public static let passwordSetSuccessfully = L10n.tr("Localizable", "PasswordSetSuccessfully", fallback: "Password Set Successfully")
  /// Your new password has been saved
  public static let passwordSetSuccessMessage = L10n.tr("Localizable", "PasswordSetSuccessMessage", fallback: "Your new password has been saved")
  /// ./Encamera/CameraView/CameraModePicker.swift
  public static let photo = L10n.tr("Localizable", "PHOTO", fallback: "PHOTO")
  /// ./Encamera/InAppPurchase/PurchasePhotoSubscriptionOverlay.swift
  public static let photoLimitReached = L10n.tr("Localizable", "Photo limit reached", fallback: "Free Limit Reached")
  /// PINs don't match. Try again.
  public static let pinCodeMismatch = L10n.tr("Localizable", "PinCodeMismatch", fallback: "PINs don't match. Try again.")
  /// Passcode changed
  public static let pinSuccessfullyChanged = L10n.tr("Localizable", "PinSuccessfullyChanged", fallback: "Passcode changed")
  /// Please enter a name for the album
  public static let pleaseEnterAnAlbumName = L10n.tr("Localizable", "PleaseEnterAnAlbumName", fallback: "Please enter a name for the album")
  /// Privacy Policy
  public static let privacyPolicy = L10n.tr("Localizable", "Privacy Policy", fallback: "Privacy Policy")
  /// Widget
  public static let quicklyTakePictures = L10n.tr("Localizable", "QuicklyTakePictures", fallback: "Quickly take photos and videos.")
  /// ./Encamera/KeyManagement/AlbumDetailView.swift
  public static let rename = L10n.tr("Localizable", "Rename", fallback: "Rename")
  /// Confirm Password
  public static let repeatPassword = L10n.tr("Localizable", "RepeatPassword", fallback: "Confirm Password")
  /// Enter your password again to confirm.
  public static let repeatPasswordSubtitle = L10n.tr("Localizable", "repeatPasswordSubtitle", fallback: "Enter your password again to confirm.")
  /// Enter your PIN again to confirm.
  public static let repeatPinCodeSubtitle = L10n.tr("Localizable", "RepeatPinCodeSubtitle", fallback: "Enter your PIN again to confirm.")
  /// Restore Purchases
  public static let restorePurchases = L10n.tr("Localizable", "Restore Purchases", fallback: "Restore Purchases")
  /// Roadmap & Feature Requests
  public static let roadmap = L10n.tr("Localizable", "Roadmap", fallback: "Roadmap & Feature Requests")
  /// ./Encamera/ShareHandling/ShareHandling.swift
  public static let save = L10n.tr("Localizable", "Save", fallback: "Save")
  /// Save to this device
  public static let saveLocally = L10n.tr("Localizable", "SaveLocally", fallback: "Save to this device")
  /// Save to iCloud Drive
  public static let saveToiCloudDrive = L10n.tr("Localizable", "SaveToiCloudDrive", fallback: "Save to iCloud Drive")
  /// Select a place to keep media for this key.
  public static let selectAPlaceToKeepMediaForThisKey = L10n.tr("Localizable", "Select a place to keep media for this key.", fallback: "Select a place to keep media for this key.")
  /// ./Encamera/MediaImport/MediaImportView.swift
  public static let selectAll = L10n.tr("Localizable", "Select All", fallback: "Select All")
  /// How do you want to unlock Encamera?
  public static let selectLoginMethod = L10n.tr("Localizable", "Select Login Method", fallback: "How do you want to unlock Encamera?")
  /// PIN Code Setting
  public static let set6DigitPIN = L10n.tr("Localizable", "Set 6-Digit PIN", fallback: "Set 6-Digit PIN")
  /// You'll use this password to unlock Encamera. Make sure you remember it!
  public static let setPasswordSubtitle = L10n.tr("Localizable", "setPasswordSubtitle", fallback: "You'll use this password to unlock Encamera. Make sure you remember it!")
  /// Set PIN
  public static let setPinCode = L10n.tr("Localizable", "SetPinCode", fallback: "Set PIN")
  /// You'll use this PIN to unlock Encamera. Make sure you remember it!
  public static let setPinCodeSubtitle = L10n.tr("Localizable", "SetPinCodeSubtitle", fallback: "You'll use this PIN to unlock Encamera. Make sure you remember it!")
  /// Settings
  public static let settings = L10n.tr("Localizable", "Settings", fallback: "Settings")
  /// ./Encamera/Styles/ViewModifiers/ButtonViewModifier.swift
  public static let share = L10n.tr("Localizable", "Share", fallback: "Share")
  /// Take another photo
  public static let takeAnotherPhoto = L10n.tr("Localizable", "TakeAnotherPhoto", fallback: "Take another photo")
  /// TAKE YOUR FIRST PHOTO
  public static let takeYourFirstPicture = L10n.tr("Localizable", "TakeYourFirstPicture", fallback: "TAKE YOUR FIRST PHOTO")
  /// Terms of Use
  public static let termsOfUse = L10n.tr("Localizable", "Terms of Use", fallback: "Terms of Use")
  /// ./EncameraCore/Utils/AuthManager.swift
  public static let touchID = L10n.tr("Localizable", "Touch ID", fallback: "Touch ID")
  /// Try Again
  public static let tryAgain = L10n.tr("Localizable", "TryAgain", fallback: "Try Again")
  /// Unlock with %@
  public static func unlockWith(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Unlock with %@", String(describing: p1), fallback: "Unlock with %@")
  }
  /// New
  public static let unreadNotificationsIndicator = L10n.tr("Localizable", "UnreadNotificationsIndicator", fallback: "New")
  /// Get Premium
  public static let upgradeToPremium = L10n.tr("Localizable", "Upgrade to Premium", fallback: "Get Premium")
  /// Use %@?
  public static func use(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Use %@?", String(describing: p1), fallback: "Use %@?")
  }
  /// Use Passcode Instead
  public static let usePasscodeInstead = L10n.tr("Localizable", "Use Passcode instead", fallback: "Use Passcode Instead")
  /// VIDEO
  public static let video = L10n.tr("Localizable", "VIDEO", fallback: "VIDEO")
  /// View Albums
  public static let viewAlbums = L10n.tr("Localizable", "ViewAlbums", fallback: "View Albums")
  /// View in Files App
  public static let viewInFiles = L10n.tr("Localizable", "ViewInFiles", fallback: "View in Files App")
  /// ./Encamera/AuthenticationView/PasswordEntry.swift
  public static let welcomeBack = L10n.tr("Localizable", "WelcomeBack", fallback: "Welcome back!")
  /// You'll find your photos and videos in Albums.
  public static let whereToFindYourPictures = L10n.tr("Localizable", "WhereToFindYourPictures", fallback: "You'll find your photos and videos in Albums.")
  /// Yes
  public static let yes = L10n.tr("Localizable", "Yes", fallback: "Yes")
  public enum AddAlbumModal {
    /// Let's rename your
    /// album
    public static let renameAlbumTitle = L10n.tr("Localizable", "AddAlbumModal.RenameAlbumTitle", fallback: "Let's rename your\nalbum")
  }
  public enum AlbumDetailView {
    /// Add your first photo or video
    public static let addFirstMedia = L10n.tr("Localizable", "AlbumDetailView.AddFirstMedia", fallback: "Add your first photo or video")
    /// Photos and videos you add here are automatically encrypted
    public static let addFirstMediaSubtitle = L10n.tr("Localizable", "AlbumDetailView.AddFirstMediaSubtitle", fallback: "Photos and videos you add here are automatically encrypted")
    /// Album is now hidden
    public static let albumHiddenToast = L10n.tr("Localizable", "AlbumDetailView.AlbumHiddenToast", fallback: "Album is now hidden")
    /// Album unhidden
    public static let albumUnhiddenToast = L10n.tr("Localizable", "AlbumDetailView.AlbumUnhiddenToast", fallback: "Album unhidden")
    /// Capture
    public static let captureButton = L10n.tr("Localizable", "AlbumDetailView.CaptureButton", fallback: "Capture")
    /// Take photo
    public static let captureButtonAccessibilityLabel = L10n.tr("Localizable", "AlbumDetailView.CaptureButtonAccessibilityLabel", fallback: "Take photo")
    /// Checking iCloud…
    public static let checkingICloud = L10n.tr("Localizable", "AlbumDetailView.CheckingICloud", fallback: "Checking iCloud…")
    /// Clear Filters
    public static let clearFilters = L10n.tr("Localizable", "AlbumDetailView.ClearFilters", fallback: "Clear Filters")
    /// Confirm Delete
    public static let confirmDeletion = L10n.tr("Localizable", "AlbumDetailView.ConfirmDeletion", fallback: "Confirm Delete")
    /// Album cover hidden
    public static let coverImageRemovedToast = L10n.tr("Localizable", "AlbumDetailView.CoverImageRemovedToast", fallback: "Album cover hidden")
    /// Album cover set to latest item
    public static let coverImageResetToast = L10n.tr("Localizable", "AlbumDetailView.CoverImageResetToast", fallback: "Album cover set to latest item")
    /// This album is part of a move that hasn't finished, so it can't be deleted yet. Finish or resume the move first. Nothing was deleted.
    public static let deleteBlockedByMoveMessage = L10n.tr("Localizable", "AlbumDetailView.DeleteBlockedByMoveMessage", fallback: "This album is part of a move that hasn't finished, so it can't be deleted yet. Finish or resume the move first. Nothing was deleted.")
    /// Can't Delete Album
    public static let deleteBlockedByMoveTitle = L10n.tr("Localizable", "AlbumDetailView.DeleteBlockedByMoveTitle", fallback: "Can't Delete Album")
    /// Do you want to delete %@ %@?
    public static func deleteSelectedMedia(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.DeleteSelectedMedia", String(describing: p1), String(describing: p2), fallback: "Do you want to delete %@ %@?")
    }
    /// Hide Album Cover
    public static let disableCover = L10n.tr("Localizable", "AlbumDetailView.DisableCover", fallback: "Hide Album Cover")
    /// Show Album Cover
    public static let enableCover = L10n.tr("Localizable", "AlbumDetailView.EnableCover", fallback: "Show Album Cover")
    /// Plural format key: "%#@file_count@ on %2$@"
    public static func fileCountOnLocation(_ p1: Int, _ p2: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.FileCountOnLocation", p1, String(describing: p2), fallback: "Plural format key: \"%#@file_count@ on %2$@\"")
    }
    /// Filter
    public static let filterButton = L10n.tr("Localizable", "AlbumDetailView.FilterButton", fallback: "Filter")
    /// Sort and filter
    public static let filterButtonAccessibilityLabel = L10n.tr("Localizable", "AlbumDetailView.FilterButtonAccessibilityLabel", fallback: "Sort and filter")
    /// Are you sure you want to hide this album? You MUST remember the name of this album to access it again.
    public static let hideAlbumAlertMessage = L10n.tr("Localizable", "AlbumDetailView.HideAlbumAlertMessage", fallback: "Are you sure you want to hide this album? You MUST remember the name of this album to access it again.")
    /// Hide this album?
    public static let hideAlbumAlertTitle = L10n.tr("Localizable", "AlbumDetailView.HideAlbumAlertTitle", fallback: "Hide this album?")
    /// Hide
    public static let hideAlbumRowTitle = L10n.tr("Localizable", "AlbumDetailView.HideAlbumRowTitle", fallback: "Hide")
    /// Import
    public static let importButton = L10n.tr("Localizable", "AlbumDetailView.ImportButton", fallback: "Import")
    /// None of the selected items could be imported (%@).
    public static func importFailedAlertMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.ImportFailedAlertMessage", String(describing: p1), fallback: "None of the selected items could be imported (%@).")
    }
    /// Import Failed
    public static let importFailedAlertTitle = L10n.tr("Localizable", "AlbumDetailView.ImportFailedAlertTitle", fallback: "Import Failed")
    /// Imported %@ of %@ items. %@ skipped (%@).
    public static func importPartialSkipToast(_ p1: Any, _ p2: Any, _ p3: Any, _ p4: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.ImportPartialSkipToast", String(describing: p1), String(describing: p2), String(describing: p3), String(describing: p4), fallback: "Imported %@ of %@ items. %@ skipped (%@).")
    }
    /// could not be downloaded from iCloud
    public static let importReasonAssetDownloadFailed = L10n.tr("Localizable", "AlbumDetailView.ImportReasonAssetDownloadFailed", fallback: "could not be downloaded from iCloud")
    /// no longer shared with Encamera
    public static let importReasonAssetNoLongerShared = L10n.tr("Localizable", "AlbumDetailView.ImportReasonAssetNoLongerShared", fallback: "no longer shared with Encamera")
    /// this device ran out of space
    public static let importReasonOutOfSpace = L10n.tr("Localizable", "AlbumDetailView.ImportReasonOutOfSpace", fallback: "this device ran out of space")
    /// file could not be read
    public static let importReasonReadError = L10n.tr("Localizable", "AlbumDetailView.ImportReasonReadError", fallback: "file could not be read")
    /// could not be converted
    public static let importReasonTranscodeFailed = L10n.tr("Localizable", "AlbumDetailView.ImportReasonTranscodeFailed", fallback: "could not be converted")
    /// unsupported format
    public static let importReasonUnsupportedFormat = L10n.tr("Localizable", "AlbumDetailView.ImportReasonUnsupportedFormat", fallback: "unsupported format")
    /// Imported %@ of %@. This device is full.
    public static func importStoppedForSpaceToast(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.ImportStoppedForSpaceToast", String(describing: p1), String(describing: p2), fallback: "Imported %@ of %@. This device is full.")
    }
    /// Import
    public static let importToolbarButton = L10n.tr("Localizable", "AlbumDetailView.ImportToolbarButton", fallback: "Import")
    /// Import from Photos
    public static let importToolbarButtonAccessibilityLabel = L10n.tr("Localizable", "AlbumDetailView.ImportToolbarButtonAccessibilityLabel", fallback: "Import from Photos")
    /// Cancel Import
    public static let insufficientSpaceCancel = L10n.tr("Localizable", "AlbumDetailView.InsufficientSpaceCancel", fallback: "Cancel Import")
    /// Change Selection
    public static let insufficientSpaceChangeSelection = L10n.tr("Localizable", "AlbumDetailView.InsufficientSpaceChangeSelection", fallback: "Change Selection")
    /// Continue Until Full
    public static let insufficientSpaceContinue = L10n.tr("Localizable", "AlbumDetailView.InsufficientSpaceContinue", fallback: "Continue Until Full")
    /// This import needs about %@, but this device has %@ free. About %@ of %@ %@ will fit.
    public static func insufficientSpaceMessage(_ p1: Any, _ p2: Any, _ p3: Any, _ p4: Any, _ p5: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.InsufficientSpaceMessage", String(describing: p1), String(describing: p2), String(describing: p3), String(describing: p4), String(describing: p5), fallback: "This import needs about %@, but this device has %@ free. About %@ of %@ %@ will fit.")
    }
    /// Not Enough Space
    public static let insufficientSpaceTitle = L10n.tr("Localizable", "AlbumDetailView.InsufficientSpaceTitle", fallback: "Not Enough Space")
    /// Leave Encamera open and connected to Wi-Fi for best results.
    public static let largeImportWarningMessage = L10n.tr("Localizable", "AlbumDetailView.LargeImportWarningMessage", fallback: "Leave Encamera open and connected to Wi-Fi for best results.")
    /// For Faster Imports
    public static let largeImportWarningTitle = L10n.tr("Localizable", "AlbumDetailView.LargeImportWarningTitle", fallback: "For Faster Imports")
    /// A move is already running for one of these albums. Try again when it finishes.
    public static let moveBusyToast = L10n.tr("Localizable", "AlbumDetailView.MoveBusyToast", fallback: "A move is already running for one of these albums. Try again when it finishes.")
    /// Move canceled: %@ %@ moved to %@
    public static func moveCancelledToast(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MoveCancelledToast", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "Move canceled: %@ %@ moved to %@")
    }
    /// Moved %@ %@ to %@
    public static func movedToast(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MovedToast", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "Moved %@ %@ to %@")
    }
    /// Failed to move %@ %@
    public static func moveErrorToast(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MoveErrorToast", String(describing: p1), String(describing: p2), fallback: "Failed to move %@ %@")
    }
    /// The album was not moved and stays where it is. %@
    public static func moveFailedAlertMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MoveFailedAlertMessage", String(describing: p1), fallback: "The album was not moved and stays where it is. %@")
    }
    /// Couldn't Move Album
    public static let moveFailedAlertTitle = L10n.tr("Localizable", "AlbumDetailView.MoveFailedAlertTitle", fallback: "Couldn't Move Album")
    /// %@ items stayed in iCloud Drive because they couldn't be downloaded. Everything else was moved to this device, so the album now shows in both places. Try the move again when you're online to move the rest.
    public static func moveLeftItemsInICloudDriveAlertMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MoveLeftItemsInICloudDriveAlertMessage", String(describing: p1), fallback: "%@ items stayed in iCloud Drive because they couldn't be downloaded. Everything else was moved to this device, so the album now shows in both places. Try the move again when you're online to move the rest.")
    }
    /// Some Items Stayed in iCloud Drive
    public static let moveLeftItemsInICloudDriveAlertTitle = L10n.tr("Localizable", "AlbumDetailView.MoveLeftItemsInICloudDriveAlertTitle", fallback: "Some Items Stayed in iCloud Drive")
    /// Upgrade “%@” first, then move items into it
    public static func moveNeedsUpgradeToast(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MoveNeedsUpgradeToast", String(describing: p1), fallback: "Upgrade “%@” first, then move items into it")
    }
    /// Moved %@ %@, %@ %@ failed
    public static func movePartialToast(_ p1: Any, _ p2: Any, _ p3: Any, _ p4: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MovePartialToast", String(describing: p1), String(describing: p2), String(describing: p3), String(describing: p4), fallback: "Moved %@ %@, %@ %@ failed")
    }
    /// No photos or videos
    public static let noMediaFound = L10n.tr("Localizable", "AlbumDetailView.NoMediaFound", fallback: "No photos or videos")
    /// Open Camera
    public static let openCamera = L10n.tr("Localizable", "AlbumDetailView.OpenCamera", fallback: "Open Camera")
    /// Premium
    public static let premiumCardBadge = L10n.tr("Localizable", "AlbumDetailView.PremiumCardBadge", fallback: "Premium")
    /// Store unlimited encrypted photos and videos
    public static let premiumCardSubtitle = L10n.tr("Localizable", "AlbumDetailView.PremiumCardSubtitle", fallback: "Store unlimited encrypted photos and videos")
    /// Store More with Premium
    public static let premiumCardTitle = L10n.tr("Localizable", "AlbumDetailView.PremiumCardTitle", fallback: "Store More with Premium")
    /// Use Latest Item
    public static let resetCoverImage = L10n.tr("Localizable", "AlbumDetailView.ResetCoverImage", fallback: "Use Latest Item")
    /// Select
    public static let select = L10n.tr("Localizable", "AlbumDetailView.Select", fallback: "Select")
    /// this device
    public static let storageLocationThisDevice = L10n.tr("Localizable", "AlbumDetailView.StorageLocationThisDevice", fallback: "this device")
    /// Saved on %@
    public static func storageMenuSubtitle(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.StorageMenuSubtitle", String(describing: p1), fallback: "Saved on %@")
    }
    /// Unhide
    public static let unhideAlbumRowTitle = L10n.tr("Localizable", "AlbumDetailView.UnhideAlbumRowTitle", fallback: "Unhide")
    public enum SortFilter {
      /// Sort & Filter
      public static let dateAddedNewest = L10n.tr("Localizable", "AlbumDetailView.SortFilter.DateAddedNewest", fallback: "Date Added: Newest First")
      /// Date Added: Oldest First
      public static let dateAddedOldest = L10n.tr("Localizable", "AlbumDetailView.SortFilter.DateAddedOldest", fallback: "Date Added: Oldest First")
      /// Date Captured: Newest First
      public static let dateCapturedNewest = L10n.tr("Localizable", "AlbumDetailView.SortFilter.DateCapturedNewest", fallback: "Date Captured: Newest First")
      /// Date Captured: Oldest First
      public static let dateCapturedOldest = L10n.tr("Localizable", "AlbumDetailView.SortFilter.DateCapturedOldest", fallback: "Date Captured: Oldest First")
    }
  }
  public enum AlbumGrid {
    public enum EmptyState {
      /// Everything you add to an album is encrypted on your device. Create one to get started.
      public static let subtitle = L10n.tr("Localizable", "AlbumGrid.EmptyState.Subtitle", fallback: "Everything you add to an album is encrypted on your device. Create one to get started.")
      /// Create your first album
      public static let title = L10n.tr("Localizable", "AlbumGrid.EmptyState.Title", fallback: "Create your first album")
    }
  }
  public enum AlbumGridItem {
    /// Plural format key: "%#@item_count@"
    public static func itemCount(_ p1: Int) -> String {
      return L10n.tr("Localizable", "AlbumGridItem.ItemCount", p1, fallback: "Plural format key: \"%#@item_count@\"")
    }
    /// Stored in iCloud
    public static let storedInICloud = L10n.tr("Localizable", "AlbumGridItem.StoredInICloud", fallback: "Stored in iCloud")
    /// Stored on this device
    public static let storedOnDevice = L10n.tr("Localizable", "AlbumGridItem.StoredOnDevice", fallback: "Stored on this device")
  }
  public enum AlbumMove {
    /// %@ items stayed in iCloud Drive because they couldn't be downloaded.
    public static func itemsStayedInICloudDrive(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumMove.ItemsStayedInICloudDrive", String(describing: p1), fallback: "%@ items stayed in iCloud Drive because they couldn't be downloaded.")
    }
  }
  public enum AlbumNameValidator {
    /// ./EncameraCore/Utils/AlbumNameValidator.swift
    public static let forbidden = L10n.tr("Localizable", "AlbumNameValidator.Forbidden", fallback: "Album names can't be \".\" or \"..\", or contain \"/\" or \":\".")
  }
  public enum AlbumSelectionModal {
    /// ./Encamera/AlbumManagement/AlbumSelectionModal.swift
    public static func description(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumSelectionModal.Description", String(describing: p1), fallback: "Select an album to move %@ items to")
    }
    /// Move
    public static let move = L10n.tr("Localizable", "AlbumSelectionModal.Move", fallback: "Move")
    /// Type to create or open
    public static let newOrHiddenAlbumSubtitle = L10n.tr("Localizable", "AlbumSelectionModal.NewOrHiddenAlbumSubtitle", fallback: "Type to create or open")
    /// New or hidden album
    public static let newOrHiddenAlbumTitle = L10n.tr("Localizable", "AlbumSelectionModal.NewOrHiddenAlbumTitle", fallback: "New or hidden album")
    /// Create another album first.
    public static let noAlbumsDescription = L10n.tr("Localizable", "AlbumSelectionModal.NoAlbumsDescription", fallback: "Create another album first.")
  }
  public enum AppIcon {
    /// Calculator
    public static let calculator = L10n.tr("Localizable", "AppIcon.Calculator", fallback: "Calculator")
    /// Clock
    public static let clock = L10n.tr("Localizable", "AppIcon.Clock", fallback: "Clock")
    /// Compass
    public static let compass = L10n.tr("Localizable", "AppIcon.Compass", fallback: "Compass")
    /// Jazz
    public static let jazz = L10n.tr("Localizable", "AppIcon.Jazz", fallback: "Jazz")
    /// Light
    public static let light = L10n.tr("Localizable", "AppIcon.Light", fallback: "Light")
    /// Numbers
    public static let numbers = L10n.tr("Localizable", "AppIcon.Numbers", fallback: "Numbers")
    /// Default
    public static let primary = L10n.tr("Localizable", "AppIcon.Primary", fallback: "Default")
  }
  public enum AppIconSelection {
    /// Current
    public static let currentIcon = L10n.tr("Localizable", "AppIconSelection.CurrentIcon", fallback: "Current")
    /// Select an icon
    public static let selectIcon = L10n.tr("Localizable", "AppIconSelection.SelectIcon", fallback: "Select an icon")
    /// ./Encamera/Settings/AppIconSelectionView.swift - App Icon Selection
    public static let title = L10n.tr("Localizable", "AppIconSelection.Title", fallback: "App Icon")
  }
  public enum AskForReview {
    /// Ask Me Later
    public static let askMeLater = L10n.tr("Localizable", "AskForReview.AskMeLater", fallback: "Ask Me Later")
    /// Are you enjoying the app?
    public static let enjoyingTheApp = L10n.tr("Localizable", "AskForReview.EnjoyingTheApp", fallback: "Are you enjoying the app?")
  }
  public enum AuthenticationMethod {
    public enum TextDescription {
      /// Authentication Method Text Descriptions
      public static let password = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.Password", fallback: "Password")
      /// Authentication Method Types
      public static let pinCode4Digit = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.pinCode4Digit", fallback: "4-digit PIN")
      /// 6-digit PIN
      public static let pinCode6Digit = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.pinCode6Digit", fallback: "6-digit PIN")
    }
  }
  public enum AuthenticationView {
    /// Forgot Passcode? Reset Encamera
    public static let forgotPassword = L10n.tr("Localizable", "AuthenticationView.ForgotPassword", fallback: "Forgot Passcode? Reset Encamera")
    /// Try again in %@
    public static func retryIn(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationView.RetryIn", String(describing: p1), fallback: "Try again in %@")
    }
    /// ./Encamera/AuthenticationView/AuthenticationView.swift
    public static let tooManyAttempts = L10n.tr("Localizable", "AuthenticationView.TooManyAttempts", fallback: "Too many attempts")
    /// Try Again
    public static let tryAgain = L10n.tr("Localizable", "AuthenticationView.TryAgain", fallback: "Try Again")
    public enum AwaitPasscode {
      /// Open Settings to allow %@, or set up a passcode on your other device to continue.
      public static func allowOrSetPasscode(_ p1: Any) -> String {
        return L10n.tr("Localizable", "AuthenticationView.AwaitPasscode.AllowOrSetPasscode", String(describing: p1), fallback: "Open Settings to allow %@, or set up a passcode on your other device to continue.")
      }
      /// Open Settings
      public static let goToSettings = L10n.tr("Localizable", "AuthenticationView.AwaitPasscode.GoToSettings", fallback: "Open Settings")
      /// I don’t have my other device
      public static let noOtherDevice = L10n.tr("Localizable", "AuthenticationView.AwaitPasscode.NoOtherDevice", fallback: "I don’t have my other device")
      /// %@ isn’t allowed for Encamera on this device.
      public static func notAllowed(_ p1: Any) -> String {
        return L10n.tr("Localizable", "AuthenticationView.AwaitPasscode.NotAllowed", String(describing: p1), fallback: "%@ isn’t allowed for Encamera on this device.")
      }
      /// Welcome back to Encamera
      public static let title = L10n.tr("Localizable", "AuthenticationView.AwaitPasscode.Title", fallback: "Welcome back to Encamera")
      /// We found that you’ve used Encamera on %@.
      public static func usedOnDevice(_ p1: Any) -> String {
        return L10n.tr("Localizable", "AuthenticationView.AwaitPasscode.UsedOnDevice", String(describing: p1), fallback: "We found that you’ve used Encamera on %@.")
      }
      /// We found that you’ve used Encamera on another device.
      public static let usedOnOtherDevice = L10n.tr("Localizable", "AuthenticationView.AwaitPasscode.UsedOnOtherDevice", fallback: "We found that you’ve used Encamera on another device.")
      /// Waiting for you to set up a passcode…
      public static let waiting = L10n.tr("Localizable", "AuthenticationView.AwaitPasscode.Waiting", fallback: "Waiting for you to set up a passcode…")
    }
    public enum BiometricsOnly {
      /// Turn on %@ in Settings to continue, or reset Encamera.
      public static func enableInSettings(_ p1: Any) -> String {
        return L10n.tr("Localizable", "AuthenticationView.BiometricsOnly.EnableInSettings", String(describing: p1), fallback: "Turn on %@ in Settings to continue, or reset Encamera.")
      }
      /// You haven't set a passcode, so %@ is the only way to unlock Encamera.
      public static func explanation(_ p1: Any) -> String {
        return L10n.tr("Localizable", "AuthenticationView.BiometricsOnly.Explanation", String(describing: p1), fallback: "You haven't set a passcode, so %@ is the only way to unlock Encamera.")
      }
      /// Reset Encamera
      public static let reset = L10n.tr("Localizable", "AuthenticationView.BiometricsOnly.Reset", fallback: "Reset Encamera")
      /// Encamera was only set up with %@, which isn’t available on this device.
      public static func unavailable(_ p1: Any) -> String {
        return L10n.tr("Localizable", "AuthenticationView.BiometricsOnly.Unavailable", String(describing: p1), fallback: "Encamera was only set up with %@, which isn’t available on this device.")
      }
    }
  }
  public enum BackgroundTaskProgress {
    /// Edit canceled
    public static let editCancelled = L10n.tr("Localizable", "BackgroundTaskProgress.EditCancelled", fallback: "Edit canceled")
    /// ./Encamera/Components/ImportProgress/BackgroundTaskProgressView.swift - Edit Operations
    public static let editCompleted = L10n.tr("Localizable", "BackgroundTaskProgress.EditCompleted", fallback: "Edit completed")
    /// Editing…
    public static let editing = L10n.tr("Localizable", "BackgroundTaskProgress.Editing", fallback: "Editing…")
    /// Edit stopped
    public static let editStopped = L10n.tr("Localizable", "BackgroundTaskProgress.EditStopped", fallback: "Edit stopped")
    /// Move to iCloud canceled
    public static let migrateCanceled = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateCanceled", fallback: "Move to iCloud canceled")
    /// ./Encamera/Components/ImportProgress/BackgroundTaskProgressView.swift - CloudKit Migration
    public static let migrateCompleted = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateCompleted", fallback: "Moved to iCloud")
    /// Move to iCloud stopped
    public static let migrateStopped = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateStopped", fallback: "Move to iCloud stopped")
    /// Move to this device canceled
    public static let migrateToLocalCanceled = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateToLocalCanceled", fallback: "Move to this device canceled")
    /// Moved to this device
    public static let migrateToLocalCompleted = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateToLocalCompleted", fallback: "Moved to this device")
    /// Move to this device stopped
    public static let migrateToLocalStopped = L10n.tr("Localizable", "BackgroundTaskProgress.MigrateToLocalStopped", fallback: "Move to this device stopped")
    /// Moving %@ albums to iCloud
    public static func migratingBatches(_ p1: Any) -> String {
      return L10n.tr("Localizable", "BackgroundTaskProgress.MigratingBatches", String(describing: p1), fallback: "Moving %@ albums to iCloud")
    }
    /// Moving %@ of %@ to iCloud
    public static func migratingProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "BackgroundTaskProgress.MigratingProgress", String(describing: p1), String(describing: p2), fallback: "Moving %@ of %@ to iCloud")
    }
    /// Moving %@ albums to this device
    public static func migratingToLocalBatches(_ p1: Any) -> String {
      return L10n.tr("Localizable", "BackgroundTaskProgress.MigratingToLocalBatches", String(describing: p1), fallback: "Moving %@ albums to this device")
    }
    /// Moving %@ of %@ to this device
    public static func migratingToLocalProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "BackgroundTaskProgress.MigratingToLocalProgress", String(describing: p1), String(describing: p2), fallback: "Moving %@ of %@ to this device")
    }
    /// Move canceled
    public static let moveCanceled = L10n.tr("Localizable", "BackgroundTaskProgress.MoveCanceled", fallback: "Move canceled")
    /// ./Encamera/Components/ImportProgress/BackgroundTaskProgressView.swift - Move Operations
    public static let moveCompleted = L10n.tr("Localizable", "BackgroundTaskProgress.MoveCompleted", fallback: "Move completed")
    /// Move stopped
    public static let moveStopped = L10n.tr("Localizable", "BackgroundTaskProgress.MoveStopped", fallback: "Move stopped")
    /// Moving %@ batches
    public static func movingBatches(_ p1: Any) -> String {
      return L10n.tr("Localizable", "BackgroundTaskProgress.MovingBatches", String(describing: p1), fallback: "Moving %@ batches")
    }
    /// Moving %@ of %@
    public static func movingProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "BackgroundTaskProgress.MovingProgress", String(describing: p1), String(describing: p2), fallback: "Moving %@ of %@")
    }
    /// No active tasks
    public static let noActiveTasks = L10n.tr("Localizable", "BackgroundTaskProgress.NoActiveTasks", fallback: "No active tasks")
    /// Removing %@ of %@ from iCloud
    public static func removingFromICloudProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "BackgroundTaskProgress.RemovingFromICloudProgress", String(describing: p1), String(describing: p2), fallback: "Removing %@ of %@ from iCloud")
    }
  }
  public enum BillingFrequency {
    /// ./Encamera/Store/Extensions/Package+PremiumPurchasable.swift
    public static let perMonth = L10n.tr("Localizable", "BillingFrequency.PerMonth", fallback: "per month")
    /// per year
    public static let perYear = L10n.tr("Localizable", "BillingFrequency.PerYear", fallback: "per year")
  }
  public enum BiometricAvailability {
    /// Face ID or Touch ID
    public static let faceIDOrTouchID = L10n.tr("Localizable", "BiometricAvailability.FaceIDOrTouchID", fallback: "Face ID or Touch ID")
    /// Shown when biometrics is the only way into the app and it cannot run.
    public static let genericName = L10n.tr("Localizable", "BiometricAvailability.GenericName", fallback: "Face ID or Touch ID")
    public enum CannotUnlock {
      /// %@ is turned off for Encamera. Turn it back on in Settings > Encamera, then try again.
      public static func deniedBySystemSettings(_ p1: Any) -> String {
        return L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.DeniedBySystemSettings", String(describing: p1), fallback: "%@ is turned off for Encamera. Turn it back on in Settings > Encamera, then try again.")
      }
      /// %@ is locked after too many failed attempts. Lock your device, unlock it, then try again.
      public static func lockedOut(_ p1: Any) -> String {
        return L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.LockedOut", String(describing: p1), fallback: "%@ is locked after too many failed attempts. Lock your device, unlock it, then try again.")
      }
      /// This device has no Face ID or Touch ID, and no passcode is set. To proceed, add a passcode on your other device.
      public static let noHardware = L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.NoHardware", fallback: "This device has no Face ID or Touch ID, and no passcode is set. To proceed, add a passcode on your other device.")
      /// This device has no Face ID or Touch ID, and no passcode is set. Reset Encamera to start over.
      public static let noHardwareSyncOff = L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.NoHardwareSyncOff", fallback: "This device has no Face ID or Touch ID, and no passcode is set. Reset Encamera to start over.")
      /// %@ hasn't been turned on for Encamera on this device yet.
      public static func notEnabled(_ p1: Any) -> String {
        return L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.NotEnabled", String(describing: p1), fallback: "%@ hasn't been turned on for Encamera on this device yet.")
      }
      /// %@ isn't set up on this device. Set it up in Settings, or add a passcode on your other device.
      public static func notEnrolled(_ p1: Any) -> String {
        return L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.NotEnrolled", String(describing: p1), fallback: "%@ isn't set up on this device. Set it up in Settings, or add a passcode on your other device.")
      }
      /// %@ isn't set up on this device. Set it up in Settings, then try again.
      public static func notEnrolledSyncOff(_ p1: Any) -> String {
        return L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.NotEnrolledSyncOff", String(describing: p1), fallback: "%@ isn't set up on this device. Set it up in Settings, then try again.")
      }
      /// Face ID or Touch ID isn't available right now, and no passcode is set. Try again later, or add a passcode on your other device.
      public static let unavailable = L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.Unavailable", fallback: "Face ID or Touch ID isn't available right now, and no passcode is set. Try again later, or add a passcode on your other device.")
      /// Face ID or Touch ID isn't available right now, and no passcode is set.
      public static let unavailableSyncOff = L10n.tr("Localizable", "BiometricAvailability.CannotUnlock.UnavailableSyncOff", fallback: "Face ID or Touch ID isn't available right now, and no passcode is set.")
    }
  }
  public enum BiometricMethod {
    /// You can't turn off your passcode unless %@ is turned on.
    public static func cannotClearPasscode(_ p1: Any) -> String {
      return L10n.tr("Localizable", "BiometricMethod.CannotClearPasscode", String(describing: p1), fallback: "You can't turn off your passcode unless %@ is turned on.")
    }
    /// You have turned off %1$@ for Encamera. Turn it on in Settings to unlock with %1$@.
    public static func disabledOpenSettings(_ p1: Any) -> String {
      return L10n.tr("Localizable", "BiometricMethod.DisabledOpenSettings", String(describing: p1), fallback: "You have turned off %1$@ for Encamera. Turn it on in Settings to unlock with %1$@.")
    }
    /// %@ Is Off
    public static func disabledTitle(_ p1: Any) -> String {
      return L10n.tr("Localizable", "BiometricMethod.DisabledTitle", String(describing: p1), fallback: "%@ Is Off")
    }
    /// Notification Banners
    public static func enable(_ p1: Any) -> String {
      return L10n.tr("Localizable", "BiometricMethod.Enable", String(describing: p1), fallback: "Turn On %@")
    }
    /// Face ID or Touch ID
    public static let generic = L10n.tr("Localizable", "BiometricMethod.Generic", fallback: "Face ID or Touch ID")
    /// This will remove your passcode. You will only be able to use %@ to unlock Encamera. Continue?
    public static func removePasscode(_ p1: Any) -> String {
      return L10n.tr("Localizable", "BiometricMethod.RemovePasscode", String(describing: p1), fallback: "This will remove your passcode. You will only be able to use %@ to unlock Encamera. Continue?")
    }
  }
  public enum CameraCapture {
    /// Camera capture: blocked shutter and save failures
    public static let blockedNoAlbum = L10n.tr("Localizable", "CameraCapture.BlockedNoAlbum", fallback: "There's no album to save to. Choose or unlock an album to take photos.")
    /// Choose Album
    public static let chooseAlbum = L10n.tr("Localizable", "CameraCapture.ChooseAlbum", fallback: "Choose Album")
    /// Delete
    public static let deleteCapture = L10n.tr("Localizable", "CameraCapture.DeleteCapture", fallback: "Delete")
    /// Microphone access denied, tap to open Settings
    public static let microphoneAccessDenied = L10n.tr("Localizable", "CameraCapture.MicrophoneAccessDenied", fallback: "Microphone access denied, tap to open Settings")
    /// Open Albums
    public static let openAlbums = L10n.tr("Localizable", "CameraCapture.OpenAlbums", fallback: "Open Albums")
    /// Encamera couldn't save this photo. Try saving it again, or delete it.
    public static let photoSaveFailedMessage = L10n.tr("Localizable", "CameraCapture.PhotoSaveFailedMessage", fallback: "Encamera couldn't save this photo. Try saving it again, or delete it.")
    /// Photo Not Saved
    public static let photoSaveFailedTitle = L10n.tr("Localizable", "CameraCapture.PhotoSaveFailedTitle", fallback: "Photo Not Saved")
    /// Try Again
    public static let tryAgain = L10n.tr("Localizable", "CameraCapture.TryAgain", fallback: "Try Again")
    /// Encamera couldn't save this video. The recording is still on this device, unencrypted, until you save it again or delete it.
    public static let videoSaveFailedMessage = L10n.tr("Localizable", "CameraCapture.VideoSaveFailedMessage", fallback: "Encamera couldn't save this video. The recording is still on this device, unencrypted, until you save it again or delete it.")
    /// Video Not Saved
    public static let videoSaveFailedTitle = L10n.tr("Localizable", "CameraCapture.VideoSaveFailedTitle", fallback: "Video Not Saved")
  }
  public enum ChangingYourAuthenticationMethodWillRequireSettingUpANewPINOrPassword {
    /// Changing your unlock method means setting up a new PIN or password. Continue?
    public static let wouldYouLikeToContinue = L10n.tr("Localizable", "Changing your authentication method will require setting up a new PIN or password. Would you like to continue?", fallback: "Changing your unlock method means setting up a new PIN or password. Continue?")
  }
  public enum CloudKitMigration {
    /// Sign in to iCloud in Settings, then resume the move.
    public static let accountUnavailableMessage = L10n.tr("Localizable", "CloudKitMigration.AccountUnavailableMessage", fallback: "Sign in to iCloud in Settings, then resume the move.")
    /// iCloud is unavailable
    public static let accountUnavailableTitle = L10n.tr("Localizable", "CloudKitMigration.AccountUnavailableTitle", fallback: "iCloud is unavailable")
    /// New items kept arriving in this album while it moved, so the move stopped before finishing. Nothing was lost. Resume the move to bring the new items over.
    public static let albumKeptGainingItems = L10n.tr("Localizable", "CloudKitMigration.AlbumKeptGainingItems", fallback: "New items kept arriving in this album while it moved, so the move stopped before finishing. Nothing was lost. Resume the move to bring the new items over.")
    /// This album still has items in iCloud that haven't been moved, so it was left in iCloud. Resume the move to bring them over.
    public static let albumStillHasItems = L10n.tr("Localizable", "CloudKitMigration.AlbumStillHasItems", fallback: "This album still has items in iCloud that haven't been moved, so it was left in iCloud. Resume the move to bring them over.")
    /// Not Now
    public static let alertCancel = L10n.tr("Localizable", "CloudKitMigration.AlertCancel", fallback: "Not Now")
    /// Move to iCloud
    public static let alertConfirm = L10n.tr("Localizable", "CloudKitMigration.AlertConfirm", fallback: "Move to iCloud")
    /// This uploads %@ items (%@) to iCloud and can take about %@. Stay on Wi-Fi and keep Encamera open — you can switch apps, but don't force-quit. Your files stay end-to-end encrypted.
    public static func alertMessage(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.AlertMessage", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "This uploads %@ items (%@) to iCloud and can take about %@. Stay on Wi-Fi and keep Encamera open — you can switch apps, but don't force-quit. Your files stay end-to-end encrypted.")
    }
    /// ./Encamera/AlbumManagement/AlbumDetailView.swift - Move a local album to iCloud (CloudKit)
    public static let alertTitle = L10n.tr("Localizable", "CloudKitMigration.AlertTitle", fallback: "Move this album to iCloud?")
    /// %@ moved to iCloud, %@ left to move
    public static func bannerCounts(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.BannerCounts", String(describing: p1), String(describing: p2), fallback: "%@ moved to iCloud, %@ left to move")
    }
    /// ./Encamera/AlbumManagement/PartialMigrationBanner.swift - Persistent banner for an album left split between this device and iCloud
    public static let bannerMessage = L10n.tr("Localizable", "CloudKitMigration.BannerMessage", fallback: "Everything is still on this device. Tap to continue or cancel.")
    /// Cancel Move
    public static let cancelMove = L10n.tr("Localizable", "CloudKitMigration.CancelMove", fallback: "Cancel Move")
    /// The move couldn't be canceled. Nothing was lost. Check your connection and try again, or resume the move.
    public static let cancelMoveFailed = L10n.tr("Localizable", "CloudKitMigration.CancelMoveFailed", fallback: "The move couldn't be canceled. Nothing was lost. Check your connection and try again, or resume the move.")
    /// This album is moving to This Device. Choose another album to take photos, or wait until the move finishes.
    public static let captureBlockedMovingToLocal = L10n.tr("Localizable", "CloudKitMigration.CaptureBlockedMovingToLocal", fallback: "This album is moving to This Device. Choose another album to take photos, or wait until the move finishes.")
    /// Moving %@ items (%@) off iCloud Drive downloads them to this device and then uploads them to iCloud, so every file travels twice — about %@ on a good connection. The move runs only on Wi-Fi and waits while you're on cellular. Keep Encamera open; you can switch apps, but don't force-quit. Your files stay end-to-end encrypted.
    public static func driveAlertMessage(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.DriveAlertMessage", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "Moving %@ items (%@) off iCloud Drive downloads them to this device and then uploads them to iCloud, so every file travels twice — about %@ on a good connection. The move runs only on Wi-Fi and waits while you're on cellular. Keep Encamera open; you can switch apps, but don't force-quit. Your files stay end-to-end encrypted.")
    }
    /// less than a minute
    public static let estimateLessThanAMinute = L10n.tr("Localizable", "CloudKitMigration.EstimateLessThanAMinute", fallback: "less than a minute")
    /// %@ minutes
    public static func estimateMinutes(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.EstimateMinutes", String(describing: p1), fallback: "%@ minutes")
    }
    /// more than an hour
    public static let estimateOverAnHour = L10n.tr("Localizable", "CloudKitMigration.EstimateOverAnHour", fallback: "more than an hour")
    /// Something went wrong: %@. You may need to be connected to Wi-Fi to continue. You can resume the move.
    public static func failedMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.FailedMessage", String(describing: p1), fallback: "Something went wrong: %@. You may need to be connected to Wi-Fi to continue. You can resume the move.")
    }
    /// The move to iCloud didn't finish
    public static let failedTitle = L10n.tr("Localizable", "CloudKitMigration.FailedTitle", fallback: "The move to iCloud didn't finish")
    /// The move to this device didn't finish
    public static let failedToLocalTitle = L10n.tr("Localizable", "CloudKitMigration.FailedToLocalTitle", fallback: "The move to this device didn't finish")
    /// The move hasn't completely finished. Tap to continue or cancel.
    public static let finishingICloudCleanupMessage = L10n.tr("Localizable", "CloudKitMigration.FinishingICloudCleanupMessage", fallback: "The move hasn't completely finished. Tap to continue or cancel.")
    /// Everything is on this device, but iCloud hasn't confirmed that it removed every item yet, so the move isn't finished. It will try again automatically, or you can resume it now.
    public static let iCloudCleanupPending = L10n.tr("Localizable", "CloudKitMigration.ICloudCleanupPending", fallback: "Everything is on this device, but iCloud hasn't confirmed that it removed every item yet, so the move isn't finished. It will try again automatically, or you can resume it now.")
    /// This item changed after it was copied to iCloud, so it was kept on this device. The copy in iCloud is the earlier version.
    public static let itemChangedDuringMove = L10n.tr("Localizable", "CloudKitMigration.ItemChangedDuringMove", fallback: "This item changed after it was copied to iCloud, so it was kept on this device. The copy in iCloud is the earlier version.")
    /// Couldn't check iCloud for items still in this album, so the move stopped before finishing. Nothing was lost. Check your connection, then resume the move.
    public static let membershipCheckFailed = L10n.tr("Localizable", "CloudKitMigration.MembershipCheckFailed", fallback: "Couldn't check iCloud for items still in this album, so the move stopped before finishing. Nothing was lost. Check your connection, then resume the move.")
    /// %@ %@ can't be moved right now
    public static func migrationBannerFailedCount(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.MigrationBannerFailedCount", String(describing: p1), String(describing: p2), fallback: "%@ %@ can't be moved right now")
    }
    /// ./Encamera/AlbumManagement/AlbumDetailView/Banners/MigrationBanner.swift
    public static let migrationBannerMovingTitle = L10n.tr("Localizable", "CloudKitMigration.MigrationBannerMovingTitle", fallback: "Moving to iCloud")
    /// Paused until you sign in to iCloud in Settings.
    public static let migrationBannerPausedAccountUnavailable = L10n.tr("Localizable", "CloudKitMigration.MigrationBannerPausedAccountUnavailable", fallback: "Paused until you sign in to iCloud in Settings.")
    /// Paused while Low Power Mode is on.
    public static let migrationBannerPausedLowPowerMode = L10n.tr("Localizable", "CloudKitMigration.MigrationBannerPausedLowPowerMode", fallback: "Paused while Low Power Mode is on.")
    /// Paused until iCloud is ready for this version of Encamera. Make sure Encamera is up to date.
    public static let migrationBannerPausedSchemaNotDeployed = L10n.tr("Localizable", "CloudKitMigration.MigrationBannerPausedSchemaNotDeployed", fallback: "Paused until iCloud is ready for this version of Encamera. Make sure Encamera is up to date.")
    /// Paused while your device cools down.
    public static let migrationBannerPausedThermal = L10n.tr("Localizable", "CloudKitMigration.MigrationBannerPausedThermal", fallback: "Paused while your device cools down.")
    /// Move to iCloud paused
    public static let migrationBannerPausedTitle = L10n.tr("Localizable", "CloudKitMigration.MigrationBannerPausedTitle", fallback: "Move to iCloud paused")
    /// Paused until your device is on Wi-Fi.
    public static let migrationBannerPausedWaitingForWiFi = L10n.tr("Localizable", "CloudKitMigration.MigrationBannerPausedWaitingForWiFi", fallback: "Paused until your device is on Wi-Fi.")
    /// %@ of %@ moved
    public static func migrationBannerProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.MigrationBannerProgress", String(describing: p1), String(describing: p2), fallback: "%@ of %@ moved")
    }
    /// Open Settings
    public static let migrationBannerQuotaOpenSettings = L10n.tr("Localizable", "CloudKitMigration.MigrationBannerQuotaOpenSettings", fallback: "Open Settings")
    /// This album needs about %@ more iCloud storage to finish moving.
    public static func migrationBannerQuotaSpaceNeeded(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.MigrationBannerQuotaSpaceNeeded", String(describing: p1), fallback: "This album needs about %@ more iCloud storage to finish moving.")
    }
    /// Free up iCloud storage to finish moving this album.
    public static let migrationBannerQuotaSpaceUnknown = L10n.tr("Localizable", "CloudKitMigration.MigrationBannerQuotaSpaceUnknown", fallback: "Free up iCloud storage to finish moving this album.")
    /// iCloud storage full, paused
    public static let migrationBannerQuotaTitle = L10n.tr("Localizable", "CloudKitMigration.MigrationBannerQuotaTitle", fallback: "iCloud storage full, paused")
    /// Your device stays awake while this screen is open and items are moving.
    public static let migrationScreenKeepsAwake = L10n.tr("Localizable", "CloudKitMigration.MigrationScreenKeepsAwake", fallback: "Your device stays awake while this screen is open and items are moving.")
    /// Use Cellular Data
    public static let migrationScreenUseCellular = L10n.tr("Localizable", "CloudKitMigration.MigrationScreenUseCellular", fallback: "Use Cellular Data")
    /// Use Wi-Fi Only
    public static let migrationScreenUseWifiOnly = L10n.tr("Localizable", "CloudKitMigration.MigrationScreenUseWifiOnly", fallback: "Use Wi-Fi Only")
    /// Move to This Device
    public static let moveToLocalAlertConfirm = L10n.tr("Localizable", "CloudKitMigration.MoveToLocalAlertConfirm", fallback: "Move to This Device")
    /// This downloads %@ %@ (%@) to this device and then removes them from iCloud. The album will be removed from your other devices. Keep Encamera open until it finishes. Once the iCloud copies are being removed, the move can't be stopped.
    public static func moveToLocalAlertMessage(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.MoveToLocalAlertMessage", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "This downloads %@ %@ (%@) to this device and then removes them from iCloud. The album will be removed from your other devices. Keep Encamera open until it finishes. Once the iCloud copies are being removed, the move can't be stopped.")
    }
    /// Move this album to This Device?
    public static let moveToLocalAlertTitle = L10n.tr("Localizable", "CloudKitMigration.MoveToLocalAlertTitle", fallback: "Move this album to This Device?")
    /// Moving this album to this device needs about %@, but only %@ is free. Free up space and try again. The album stays in iCloud.
    public static func moveToLocalNeedsSpaceMessage(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.MoveToLocalNeedsSpaceMessage", String(describing: p1), String(describing: p2), fallback: "Moving this album to this device needs about %@, but only %@ is free. Free up space and try again. The album stays in iCloud.")
    }
    /// Not Enough Space
    public static let moveToLocalNeedsSpaceTitle = L10n.tr("Localizable", "CloudKitMigration.MoveToLocalNeedsSpaceTitle", fallback: "Not Enough Space")
    /// Stop the move
    public static let overlayCancel = L10n.tr("Localizable", "CloudKitMigration.OverlayCancel", fallback: "Stop the move")
    /// Every item is already on this device. This last step can't be stopped, or the album would be left half-removed from iCloud.
    public static let overlayCancelUnavailable = L10n.tr("Localizable", "CloudKitMigration.OverlayCancelUnavailable", fallback: "Every item is already on this device. This last step can't be stopped, or the album would be left half-removed from iCloud.")
    /// %@ couldn't be moved yet
    public static func overlayFailedItems(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.OverlayFailedItems", String(describing: p1), fallback: "%@ couldn't be moved yet")
    }
    /// %@ of %@ items
    public static func overlayItemProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.OverlayItemProgress", String(describing: p1), String(describing: p2), fallback: "%@ of %@ items")
    }
    /// Keep Encamera open. You can switch apps, but don't force-quit. You may need to be connected to Wi-Fi for this to complete, depending on your system settings.
    public static let overlayKeepOpen = L10n.tr("Localizable", "CloudKitMigration.OverlayKeepOpen", fallback: "Keep Encamera open. You can switch apps, but don't force-quit. You may need to be connected to Wi-Fi for this to complete, depending on your system settings.")
    /// Downloading from iCloud
    public static let overlayPhaseDownloading = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseDownloading", fallback: "Downloading from iCloud")
    /// Downloading from iCloud Drive
    public static let overlayPhaseMaterializing = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseMaterializing", fallback: "Downloading from iCloud Drive")
    /// Preparing
    public static let overlayPhasePreparing = L10n.tr("Localizable", "CloudKitMigration.OverlayPhasePreparing", fallback: "Preparing")
    /// Removing local copy
    public static let overlayPhaseRemovingLocalCopy = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseRemovingLocalCopy", fallback: "Removing local copy")
    /// Removing iCloud copy
    public static let overlayPhaseRemovingRemoteCopy = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseRemovingRemoteCopy", fallback: "Removing iCloud copy")
    /// Removing %@ of %@ from iCloud
    public static func overlayPhaseRemovingRemoteCopyProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseRemovingRemoteCopyProgress", String(describing: p1), String(describing: p2), fallback: "Removing %@ of %@ from iCloud")
    }
    /// Retrying
    public static let overlayPhaseRetrying = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseRetrying", fallback: "Retrying")
    /// Uploading
    public static let overlayPhaseUploading = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseUploading", fallback: "Uploading")
    /// Verifying in iCloud
    public static let overlayPhaseVerifying = L10n.tr("Localizable", "CloudKitMigration.OverlayPhaseVerifying", fallback: "Verifying in iCloud")
    /// About %@ remaining
    public static func overlayTimeRemaining(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.OverlayTimeRemaining", String(describing: p1), fallback: "About %@ remaining")
    }
    /// ./Encamera/AlbumManagement/MigrationStatusOverlay.swift - Blocking status view shown for the duration of a move to iCloud
    public static let overlayTitle = L10n.tr("Localizable", "CloudKitMigration.OverlayTitle", fallback: "Moving to iCloud")
    /// Moving to This Device
    public static let overlayTitleToLocal = L10n.tr("Localizable", "CloudKitMigration.OverlayTitleToLocal", fallback: "Moving to This Device")
    /// %@ total
    public static func overlayTotalSize(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.OverlayTotalSize", String(describing: p1), fallback: "%@ total")
    }
    /// Plural format key: "%1$#@moved@ %2$@, %3$#@remaining@"
    public static func partialMoveBannerMessage(_ p1: Int, _ p2: Any, _ p3: Int) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.PartialMoveBannerMessage", p1, String(describing: p2), p3, fallback: "Plural format key: \"%1$#@moved@ %2$@, %3$#@remaining@\"")
    }
    /// “%@” no longer exists, so this move can't be finished. Cancel the move to keep every item where it is now.
    public static func partialMoveDestinationMissing(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.PartialMoveDestinationMissing", String(describing: p1), fallback: "“%@” no longer exists, so this move can't be finished. Cancel the move to keep every item where it is now.")
    }
    /// Cancel Move
    public static let partialMoveDiscard = L10n.tr("Localizable", "CloudKitMigration.PartialMoveDiscard", fallback: "Cancel Move")
    /// ./Encamera/AlbumManagement/PartialMigrationBanner.swift - Persistent banner for a cross-plane media move left incomplete
    public static let partialMoveTitle = L10n.tr("Localizable", "CloudKitMigration.PartialMoveTitle", fallback: "Move Not Finished")
    /// %@ moved to this device, %@ left to move
    public static func partialMoveToLocalCounts(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CloudKitMigration.PartialMoveToLocalCounts", String(describing: p1), String(describing: p2), fallback: "%@ moved to this device, %@ left to move")
    }
    /// The album is still in iCloud. Tap to continue or cancel.
    public static let partialMoveToLocalMessage = L10n.tr("Localizable", "CloudKitMigration.PartialMoveToLocalMessage", fallback: "The album is still in iCloud. Tap to continue or cancel.")
    /// Move to this device not finished
    public static let partialMoveToLocalTitle = L10n.tr("Localizable", "CloudKitMigration.PartialMoveToLocalTitle", fallback: "Move to this device not finished")
    /// Move to iCloud not finished
    public static let partialTitle = L10n.tr("Localizable", "CloudKitMigration.PartialTitle", fallback: "Move to iCloud not finished")
    /// Free up space in iCloud, then resume the move.
    public static let quotaMessage = L10n.tr("Localizable", "CloudKitMigration.QuotaMessage", fallback: "Free up space in iCloud, then resume the move.")
    /// iCloud storage is full
    public static let quotaTitle = L10n.tr("Localizable", "CloudKitMigration.QuotaTitle", fallback: "iCloud storage is full")
    /// Resume
    public static let resume = L10n.tr("Localizable", "CloudKitMigration.Resume", fallback: "Resume")
    /// This album is moving to This Device, so nothing can be added to it until the move finishes.
    public static let saveBlockedMovingToLocal = L10n.tr("Localizable", "CloudKitMigration.SaveBlockedMovingToLocal", fallback: "This album is moving to This Device, so nothing can be added to it until the move finishes.")
    /// iCloud isn't ready for this version of Encamera yet. Your photos are safe on this device — please make sure Encamera is up to date and try again later.
    public static let schemaNotDeployedMessage = L10n.tr("Localizable", "CloudKitMigration.SchemaNotDeployedMessage", fallback: "iCloud isn't ready for this version of Encamera yet. Your photos are safe on this device — please make sure Encamera is up to date and try again later.")
    /// iCloud can't accept this album yet
    public static let schemaNotDeployedTitle = L10n.tr("Localizable", "CloudKitMigration.SchemaNotDeployedTitle", fallback: "iCloud can't accept this album yet")
  }
  public enum CloudKitUpgrade {
    /// Upgrade it now for faster, more reliable syncing
    public static let albumCardBody = L10n.tr("Localizable", "CloudKitUpgrade.AlbumCardBody", fallback: "Upgrade it now for faster, more reliable syncing")
    /// Get better syncing for this album
    public static let albumCardTitle = L10n.tr("Localizable", "CloudKitUpgrade.AlbumCardTitle", fallback: "Get better syncing for this album")
    /// Plural format key: "%#@item_count@"
    public static func albumItemCount(_ p1: Int) -> String {
      return L10n.tr("Localizable", "CloudKitUpgrade.AlbumItemCount", p1, fallback: "Plural format key: \"%#@item_count@\"")
    }
    /// Albums included
    public static let albumsIncludedTitle = L10n.tr("Localizable", "CloudKitUpgrade.AlbumsIncludedTitle", fallback: "Albums included")
    /// Your photos and videos will upload to iCloud whenever your device is on Wi-Fi. For the best results, keep Encamera open and your device unlocked. Each album shows its progress in a banner at the top.
    public static let initiatedBody = L10n.tr("Localizable", "CloudKitUpgrade.InitiatedBody", fallback: "Your photos and videos will upload to iCloud whenever your device is on Wi-Fi. For the best results, keep Encamera open and your device unlocked. Each album shows its progress in a banner at the top.")
    /// Upgrade started
    public static let initiatedTitle = L10n.tr("Localizable", "CloudKitUpgrade.InitiatedTitle", fallback: "Upgrade started")
    /// To start using the new syncing experience, your iCloud albums need a one-time upgrade.
    public static let introBody = L10n.tr("Localizable", "CloudKitUpgrade.IntroBody", fallback: "To start using the new syncing experience, your iCloud albums need a one-time upgrade.")
    /// Plural format key: "This upgrade includes %#@album_count@"
    public static func introIncludes(_ p1: Int) -> String {
      return L10n.tr("Localizable", "CloudKitUpgrade.IntroIncludes", p1, fallback: "Plural format key: \"This upgrade includes %#@album_count@\"")
    }
    /// Your photos stay in your iCloud account and remain end-to-end encrypted throughout the process.
    public static let introSecurity = L10n.tr("Localizable", "CloudKitUpgrade.IntroSecurity", fallback: "Your photos stay in your iCloud account and remain end-to-end encrypted throughout the process.")
    /// ./Encamera/Onboarding/CloudKitUpgrade - One-time upgrade of all iCloud Drive albums to CloudKit
    public static let introTitle = L10n.tr("Localizable", "CloudKitUpgrade.IntroTitle", fallback: "Faster, more reliable iCloud sync")
    /// Maybe Later
    public static let laterMaybeLater = L10n.tr("Localizable", "CloudKitUpgrade.LaterMaybeLater", fallback: "Maybe Later")
    /// You'll still be able to use Encamera, but your existing albums won't get the improved sync until you complete the upgrade.
    public static let laterMessage = L10n.tr("Localizable", "CloudKitUpgrade.LaterMessage", fallback: "You'll still be able to use Encamera, but your existing albums won't get the improved sync until you complete the upgrade.")
    /// Upgrade later?
    public static let laterTitle = L10n.tr("Localizable", "CloudKitUpgrade.LaterTitle", fallback: "Upgrade later?")
    /// Upgrade Now
    public static let laterUpdateNow = L10n.tr("Localizable", "CloudKitUpgrade.LaterUpdateNow", fallback: "Upgrade Now")
    /// Start Upgrade
    public static let startUpgrade = L10n.tr("Localizable", "CloudKitUpgrade.StartUpgrade", fallback: "Start Upgrade")
    /// Why Upgrade?
    public static let whyUpgrade = L10n.tr("Localizable", "CloudKitUpgrade.WhyUpgrade", fallback: "Why Upgrade?")
  }
  public enum Common {
    /// Cancel
    public static let cancel = L10n.tr("Localizable", "Common.Cancel", fallback: "Cancel")
    /// Confirm
    public static let confirm = L10n.tr("Localizable", "Common.Confirm", fallback: "Confirm")
  }
  public enum CompletedImportHistory {
    /// Clear All
    public static let clearAll = L10n.tr("Localizable", "CompletedImportHistory.ClearAll", fallback: "Clear All")
    /// This will delete %@ photo(s) from your Photos library.
    public static func deleteConfirmMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CompletedImportHistory.DeleteConfirmMessage", String(describing: p1), fallback: "This will delete %@ photo(s) from your Photos library.")
    }
    /// This will delete %@ photo(s) from your Photos library. %@ imported photo(s) are no longer in Encamera, so their originals will be kept.
    public static func deleteConfirmMessageSkipping(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CompletedImportHistory.DeleteConfirmMessageSkipping", String(describing: p1), String(describing: p2), fallback: "This will delete %@ photo(s) from your Photos library. %@ imported photo(s) are no longer in Encamera, so their originals will be kept.")
    }
    /// Delete from Photos Library?
    public static let deleteConfirmTitle = L10n.tr("Localizable", "CompletedImportHistory.DeleteConfirmTitle", fallback: "Delete from Photos Library?")
    /// No completed imports
    public static let emptyState = L10n.tr("Localizable", "CompletedImportHistory.EmptyState", fallback: "No completed imports")
    /// %@ of %@ imported
    public static func itemsImported(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "CompletedImportHistory.ItemsImported", String(describing: p1), String(describing: p2), fallback: "%@ of %@ imported")
    }
    /// ./Encamera/Components/ImportProgress/CompletedImportHistoryView.swift
    public static let title = L10n.tr("Localizable", "CompletedImportHistory.Title", fallback: "Import History")
    /// View Import History
    public static let viewImportHistory = L10n.tr("Localizable", "CompletedImportHistory.ViewImportHistory", fallback: "View Import History")
  }
  public enum CreateAlbumModal {
    /// Create Album
    public static let createAlbum = L10n.tr("Localizable", "CreateAlbumModal.CreateAlbum", fallback: "Create Album")
    /// ./Encamera/AlbumManagement/CreateAlbumModal.swift - Create Album Modal
    public static let headerText = L10n.tr("Localizable", "CreateAlbumModal.HeaderText", fallback: "Name this encrypted album")
    /// Your memories
    public static let placeholder = L10n.tr("Localizable", "CreateAlbumModal.Placeholder", fallback: "Your memories")
  }
  public enum CustomPhotoPicker {
    /// Add
    public static let add = L10n.tr("Localizable", "CustomPhotoPicker.Add", fallback: "Add")
    /// Open Settings
    public static let emptyDeniedButton = L10n.tr("Localizable", "CustomPhotoPicker.EmptyDeniedButton", fallback: "Open Settings")
    /// Encamera needs access to your Photos library to import photos. You can turn it on in Settings.
    public static let emptyDeniedMessage = L10n.tr("Localizable", "CustomPhotoPicker.EmptyDeniedMessage", fallback: "Encamera needs access to your Photos library to import photos. You can turn it on in Settings.")
    /// Photo access is off
    public static let emptyDeniedTitle = L10n.tr("Localizable", "CustomPhotoPicker.EmptyDeniedTitle", fallback: "Photo access is off")
    /// Show All Photos
    public static let emptyFilteredButton = L10n.tr("Localizable", "CustomPhotoPicker.EmptyFilteredButton", fallback: "Show All Photos")
    /// No photos in your library match this filter.
    public static let emptyFilteredMessage = L10n.tr("Localizable", "CustomPhotoPicker.EmptyFilteredMessage", fallback: "No photos in your library match this filter.")
    /// Nothing to show here
    public static let emptyFilteredTitle = L10n.tr("Localizable", "CustomPhotoPicker.EmptyFilteredTitle", fallback: "Nothing to show here")
    /// Select Photos
    public static let emptyLimitedButton = L10n.tr("Localizable", "CustomPhotoPicker.EmptyLimitedButton", fallback: "Select Photos")
    /// Give Encamera access to at least one photo or video.
    public static let emptyLimitedMessage = L10n.tr("Localizable", "CustomPhotoPicker.EmptyLimitedMessage", fallback: "Give Encamera access to at least one photo or video.")
    /// No photos selected
    public static let emptyLimitedTitle = L10n.tr("Localizable", "CustomPhotoPicker.EmptyLimitedTitle", fallback: "No photos selected")
    /// Please grant full access to your Photos library to use swipe selection. You can change this in Settings.
    public static let grantAccessMessage = L10n.tr("Localizable", "CustomPhotoPicker.GrantAccessMessage", fallback: "Please grant full access to your Photos library to use swipe selection. You can change this in Settings.")
    /// Select more photos or allow full access
    public static let limitedAccessSubtitle = L10n.tr("Localizable", "CustomPhotoPicker.LimitedAccessSubtitle", fallback: "Select more photos or allow full access")
    /// Limited access
    public static let limitedAccessTitle = L10n.tr("Localizable", "CustomPhotoPicker.LimitedAccessTitle", fallback: "Limited access")
    /// Loading more photos…
    public static let loadingMore = L10n.tr("Localizable", "CustomPhotoPicker.LoadingMore", fallback: "Loading more photos…")
    /// Photos Access Needed
    public static let photoAccessRequired = L10n.tr("Localizable", "CustomPhotoPicker.PhotoAccessRequired", fallback: "Photos Access Needed")
    /// %@ Selected
    public static func selected(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CustomPhotoPicker.Selected", String(describing: p1), fallback: "%@ Selected")
    }
    /// Select Photos
    public static let selectPhotos = L10n.tr("Localizable", "CustomPhotoPicker.SelectPhotos", fallback: "Select Photos")
    /// ./Encamera/Components/CustomPhotoPicker.swift
    public static let swipeInstruction = L10n.tr("Localizable", "CustomPhotoPicker.SwipeInstruction", fallback: "Long press & swipe to select multiple photos")
  }
  public enum EncameraDrawerFactory {
    /// ./Encamera/ViewModifiers/EncameraDrawerFactoryModifier.swift
    public static let goBack = L10n.tr("Localizable", "EncameraDrawerFactory.GoBack", fallback: "Go Back")
    public enum CloudKitUpgradeFailedDrawer {
      /// Not Now
      public static let notNow = L10n.tr("Localizable", "EncameraDrawerFactory.CloudKitUpgradeFailedDrawer.NotNow", fallback: "Not Now")
    }
    public enum ContinueWithoutKeyDrawer {
      /// Your existing encrypted photos and videos won't be accessible on this device until you enter your recovery key.
      public static let body = L10n.tr("Localizable", "EncameraDrawerFactory.ContinueWithoutKeyDrawer.Body", fallback: "Your existing encrypted photos and videos won't be accessible on this device until you enter your recovery key.")
      /// Continue without your key?
      public static let title = L10n.tr("Localizable", "EncameraDrawerFactory.ContinueWithoutKeyDrawer.Title", fallback: "Continue without your key?")
    }
    public enum DisableICloudBackupAndSyncDrawer {
      /// Turn Off
      public static let confirm = L10n.tr("Localizable", "EncameraDrawerFactory.DisableICloudBackupAndSyncDrawer.Confirm", fallback: "Turn Off")
      /// Turn Off iCloud Backup & Sync?
      public static let title = L10n.tr("Localizable", "EncameraDrawerFactory.DisableICloudBackupAndSyncDrawer.Title", fallback: "Turn Off iCloud Backup & Sync?")
    }
    public enum FirstCaptureExplainerDrawer {
      /// The %@ you just took isn't in your Photos library. It's encrypted and can only be opened in Encamera. Taking photos here keeps them out of your Photos library, iCloud Photos and other apps.
      public static func body(_ p1: Any) -> String {
        return L10n.tr("Localizable", "EncameraDrawerFactory.FirstCaptureExplainerDrawer.Body", String(describing: p1), fallback: "The %@ you just took isn't in your Photos library. It's encrypted and can only be opened in Encamera. Taking photos here keeps them out of your Photos library, iCloud Photos and other apps.")
      }
      /// Got It
      public static let gotIt = L10n.tr("Localizable", "EncameraDrawerFactory.FirstCaptureExplainerDrawer.GotIt", fallback: "Got It")
      /// photo
      public static let photo = L10n.tr("Localizable", "EncameraDrawerFactory.FirstCaptureExplainerDrawer.Photo", fallback: "photo")
      /// Only in Encamera
      public static let title = L10n.tr("Localizable", "EncameraDrawerFactory.FirstCaptureExplainerDrawer.Title", fallback: "Only in Encamera")
      /// video
      public static let video = L10n.tr("Localizable", "EncameraDrawerFactory.FirstCaptureExplainerDrawer.Video", fallback: "video")
    }
    public enum KeyBackupDrawer {
      /// Your media is protected with a unique encryption key. This key is the only way to decrypt it if you switch devices or reinstall Encamera.
      public static let explanation = L10n.tr("Localizable", "EncameraDrawerFactory.KeyBackupDrawer.Explanation", fallback: "Your media is protected with a unique encryption key. This key is the only way to decrypt it if you switch devices or reinstall Encamera.")
      /// Back Up Your Recovery Key
      public static let title = L10n.tr("Localizable", "EncameraDrawerFactory.KeyBackupDrawer.Title", fallback: "Back Up Your Recovery Key")
      /// View Recovery Key
      public static let viewTheKey = L10n.tr("Localizable", "EncameraDrawerFactory.KeyBackupDrawer.ViewTheKey", fallback: "View Recovery Key")
      /// You will not be able to view your media without this key.
      public static let warning = L10n.tr("Localizable", "EncameraDrawerFactory.KeyBackupDrawer.Warning", fallback: "You will not be able to view your media without this key.")
    }
    public enum PartialMediaMoveDrawer {
      /// Resume to move the rest of the items to “%@”. Cancel Move stops the move: items already moved stay in “%@”, and the rest stay in this album.
      public static func body(_ p1: Any, _ p2: Any) -> String {
        return L10n.tr("Localizable", "EncameraDrawerFactory.PartialMediaMoveDrawer.Body", String(describing: p1), String(describing: p2), fallback: "Resume to move the rest of the items to “%@”. Cancel Move stops the move: items already moved stay in “%@”, and the rest stay in this album.")
      }
    }
    public enum PartialMigrationDrawer {
      /// Resume to move the rest of the album to iCloud. Cancel the move to bring back what has already moved, and the album stays on this device.
      public static let toCloudKitBody = L10n.tr("Localizable", "EncameraDrawerFactory.PartialMigrationDrawer.ToCloudKitBody", fallback: "Resume to move the rest of the album to iCloud. Cancel the move to bring back what has already moved, and the album stays on this device.")
      /// Resume to move the rest of the album to this device. Cancel the move to put back what has already moved, and the album stays in iCloud.
      public static let toLocalBody = L10n.tr("Localizable", "EncameraDrawerFactory.PartialMigrationDrawer.ToLocalBody", fallback: "Resume to move the rest of the album to this device. Cancel the move to put back what has already moved, and the album stays in iCloud.")
    }
    public enum PasscodeSetDrawer {
      /// You've set your password successfully. Remember it, you'll need it to unlock Encamera.
      public static let passwordBody = L10n.tr("Localizable", "EncameraDrawerFactory.PasscodeSetDrawer.PasswordBody", fallback: "You've set your password successfully. Remember it, you'll need it to unlock Encamera.")
      /// You've set your PIN successfully. Remember it, you'll need it to unlock Encamera.
      public static let pinBody = L10n.tr("Localizable", "EncameraDrawerFactory.PasscodeSetDrawer.PinBody", fallback: "You've set your PIN successfully. Remember it, you'll need it to unlock Encamera.")
      /// You're all set
      public static let title = L10n.tr("Localizable", "EncameraDrawerFactory.PasscodeSetDrawer.Title", fallback: "You're all set")
    }
    public enum RecoveryKeyPromptDrawer {
      /// Your media is encrypted and only you can access it. Save your recovery key to make sure you can recover it on a new device.
      public static let body = L10n.tr("Localizable", "EncameraDrawerFactory.RecoveryKeyPromptDrawer.Body", fallback: "Your media is encrypted and only you can access it. Save your recovery key to make sure you can recover it on a new device.")
      /// Maybe Later
      public static let later = L10n.tr("Localizable", "EncameraDrawerFactory.RecoveryKeyPromptDrawer.Later", fallback: "Maybe Later")
      /// Save Recovery Key
      public static let save = L10n.tr("Localizable", "EncameraDrawerFactory.RecoveryKeyPromptDrawer.Save", fallback: "Save Recovery Key")
      /// Never lose access to your media
      public static let title = L10n.tr("Localizable", "EncameraDrawerFactory.RecoveryKeyPromptDrawer.Title", fallback: "Never lose access to your media")
    }
    public enum RecoveryKeySavedDrawer {
      /// Make sure you save a copy somewhere safe. You can always find your key in Settings.
      public static let body = L10n.tr("Localizable", "EncameraDrawerFactory.RecoveryKeySavedDrawer.Body", fallback: "Make sure you save a copy somewhere safe. You can always find your key in Settings.")
      /// I've Saved My Recovery Key
      public static let confirm = L10n.tr("Localizable", "EncameraDrawerFactory.RecoveryKeySavedDrawer.Confirm", fallback: "I've Saved My Recovery Key")
      /// I'll do it later
      public static let later = L10n.tr("Localizable", "EncameraDrawerFactory.RecoveryKeySavedDrawer.Later", fallback: "I'll do it later")
      /// Have you saved your recovery key?
      public static let title = L10n.tr("Localizable", "EncameraDrawerFactory.RecoveryKeySavedDrawer.Title", fallback: "Have you saved your recovery key?")
    }
    public enum ResetDrawer {
      /// If you don’t have access to your other device, you can reset Encamera. You will not lose any of your encrypted photos and videos, but your encryption key and your passcode will be deleted from all devices.
      public static let body = L10n.tr("Localizable", "EncameraDrawerFactory.ResetDrawer.Body", fallback: "If you don’t have access to your other device, you can reset Encamera. You will not lose any of your encrypted photos and videos, but your encryption key and your passcode will be deleted from all devices.")
      /// This removes your passcode, encryption keys and app settings from all your devices. Your photos and videos are kept. This can’t be undone.
      public static let bodySyncOff = L10n.tr("Localizable", "EncameraDrawerFactory.ResetDrawer.BodySyncOff", fallback: "This removes your passcode, encryption keys and app settings from all your devices. Your photos and videos are kept. This can’t be undone.")
      /// Reset Encamera
      public static let confirm = L10n.tr("Localizable", "EncameraDrawerFactory.ResetDrawer.Confirm", fallback: "Reset Encamera")
      /// ./Encamera/ViewModifiers/EncameraDrawerFactoryModifier.swift
      public static let title = L10n.tr("Localizable", "EncameraDrawerFactory.ResetDrawer.Title", fallback: "Reset Encamera?")
    }
    public enum WelcomeBackDrawer {
      /// Enter Passcode
      public static let `continue` = L10n.tr("Localizable", "EncameraDrawerFactory.WelcomeBackDrawer.Continue", fallback: "Enter Passcode")
      /// We found Encamera data from another device. Enter your passcode to unlock it here.
      public static let message = L10n.tr("Localizable", "EncameraDrawerFactory.WelcomeBackDrawer.Message", fallback: "We found Encamera data from another device. Enter your passcode to unlock it here.")
      /// Welcome back!
      public static let title = L10n.tr("Localizable", "EncameraDrawerFactory.WelcomeBackDrawer.Title", fallback: "Welcome back!")
    }
  }
  public enum EraseProgress {
    /// Erase complete
    public static let complete = L10n.tr("Localizable", "EraseProgress.Complete", fallback: "Erase complete")
    /// Everything was deleted and verified. Tap Finish to restart Encamera.
    public static let completeMessage = L10n.tr("Localizable", "EraseProgress.CompleteMessage", fallback: "Everything was deleted and verified. Tap Finish to restart Encamera.")
    /// Erase finished with problems
    public static let completeWithProblems = L10n.tr("Localizable", "EraseProgress.CompleteWithProblems", fallback: "Erase finished with problems")
    /// Copy Report
    public static let copyReport = L10n.tr("Localizable", "EraseProgress.CopyReport", fallback: "Copy Report")
    /// Finish Erase (Restart)
    public static let finish = L10n.tr("Localizable", "EraseProgress.Finish", fallback: "Finish Erase (Restart)")
    /// Hide Details
    public static let hideDetails = L10n.tr("Localizable", "EraseProgress.HideDetails", fallback: "Hide Details")
    /// Keep Encamera open until this finishes.
    public static let keepOpen = L10n.tr("Localizable", "EraseProgress.KeepOpen", fallback: "Keep Encamera open until this finishes.")
    /// Some steps could not be verified. Follow the hints below, then tap Finish to restart Encamera.
    public static let problemsMessage = L10n.tr("Localizable", "EraseProgress.ProblemsMessage", fallback: "Some steps could not be verified. Follow the hints below, then tap Finish to restart Encamera.")
    /// Report copied
    public static let reportCopied = L10n.tr("Localizable", "EraseProgress.ReportCopied", fallback: "Report copied")
    /// Erasing…
    public static let running = L10n.tr("Localizable", "EraseProgress.Running", fallback: "Erasing…")
    /// Show Details
    public static let showDetails = L10n.tr("Localizable", "EraseProgress.ShowDetails", fallback: "Show Details")
    /// Skipped
    public static let skipped = L10n.tr("Localizable", "EraseProgress.Skipped", fallback: "Skipped")
    /// ./Encamera/Settings/EraseProgressView.swift
    public static let title = L10n.tr("Localizable", "EraseProgress.Title", fallback: "Erasing All Data")
    public enum Hint {
      /// Encamera couldn't reach iCloud. Connect to the internet and open Encamera again; it will finish deleting your iCloud data automatically.
      public static let cloudUnreachable = L10n.tr("Localizable", "EraseProgress.Hint.CloudUnreachable", fallback: "Encamera couldn't reach iCloud. Connect to the internet and open Encamera again; it will finish deleting your iCloud data automatically.")
      /// Some files could not be removed. Delete Encamera from your device to remove them.
      public static let files = L10n.tr("Localizable", "EraseProgress.Hint.Files", fallback: "Some files could not be removed. Delete Encamera from your device to remove them.")
      /// Some keys could not be removed. Erase again; if this keeps happening, delete Encamera from your device and reinstall it.
      public static let keychain = L10n.tr("Localizable", "EraseProgress.Hint.Keychain", fallback: "Some keys could not be removed. Erase again; if this keeps happening, delete Encamera from your device and reinstall it.")
      /// Try erasing again. If the problem persists, delete and reinstall Encamera.
      public static let retry = L10n.tr("Localizable", "EraseProgress.Hint.Retry", fallback: "Try erasing again. If the problem persists, delete and reinstall Encamera.")
      /// Some settings could not be reset. Erase again, or delete and reinstall Encamera.
      public static let settings = L10n.tr("Localizable", "EraseProgress.Hint.Settings", fallback: "Some settings could not be reset. Erase again, or delete and reinstall Encamera.")
    }
    public enum Reset {
      /// Reset complete
      public static let complete = L10n.tr("Localizable", "EraseProgress.Reset.Complete", fallback: "Reset complete")
      /// Your passcode, keys and settings were removed and verified. Your encrypted photos and videos were kept. Tap Finish to restart Encamera.
      public static let completeMessage = L10n.tr("Localizable", "EraseProgress.Reset.CompleteMessage", fallback: "Your passcode, keys and settings were removed and verified. Your encrypted photos and videos were kept. Tap Finish to restart Encamera.")
      /// Reset finished with problems
      public static let completeWithProblems = L10n.tr("Localizable", "EraseProgress.Reset.CompleteWithProblems", fallback: "Reset finished with problems")
      /// Verify the reset
      public static let finalVerify = L10n.tr("Localizable", "EraseProgress.Reset.FinalVerify", fallback: "Verify the reset")
      /// Finish Reset (Restart)
      public static let finish = L10n.tr("Localizable", "EraseProgress.Reset.Finish", fallback: "Finish Reset (Restart)")
      /// Resetting…
      public static let running = L10n.tr("Localizable", "EraseProgress.Reset.Running", fallback: "Resetting…")
      /// Resetting Encamera
      public static let title = L10n.tr("Localizable", "EraseProgress.Reset.Title", fallback: "Resetting Encamera")
    }
    public enum Section {
      /// Stopping activity
      public static let activity = L10n.tr("Localizable", "EraseProgress.Section.Activity", fallback: "Stopping activity")
      /// App services
      public static let app = L10n.tr("Localizable", "EraseProgress.Section.App", fallback: "App services")
      /// iCloud
      public static let cloud = L10n.tr("Localizable", "EraseProgress.Section.Cloud", fallback: "iCloud")
      /// Final check
      public static let finalCheck = L10n.tr("Localizable", "EraseProgress.Section.FinalCheck", fallback: "Final check")
      /// Keys & settings
      public static let keys = L10n.tr("Localizable", "EraseProgress.Section.Keys", fallback: "Keys & settings")
      /// Media & caches
      public static let media = L10n.tr("Localizable", "EraseProgress.Section.Media", fallback: "Media & caches")
    }
    public enum Step {
      /// Delete analytics data
      public static let appAnalytics = L10n.tr("Localizable", "EraseProgress.Step.AppAnalytics", fallback: "Delete analytics data")
      /// Sign out of purchases
      public static let appPurchases = L10n.tr("Localizable", "EraseProgress.Step.AppPurchases", fallback: "Sign out of purchases")
      /// Cancel background tasks and caches
      public static let appSystem = L10n.tr("Localizable", "EraseProgress.Step.AppSystem", fallback: "Cancel background tasks and caches")
      /// Remove iCloud notifications
      public static let cloudSubscriptions = L10n.tr("Localizable", "EraseProgress.Step.CloudSubscriptions", fallback: "Remove iCloud notifications")
      /// Delete iCloud data
      public static let cloudZones = L10n.tr("Localizable", "EraseProgress.Step.CloudZones", fallback: "Delete iCloud data")
      /// Verify the device is empty
      public static let finalVerify = L10n.tr("Localizable", "EraseProgress.Step.FinalVerify", fallback: "Verify the device is empty")
      /// Delete keys and passcode
      public static let keysKeychain = L10n.tr("Localizable", "EraseProgress.Step.KeysKeychain", fallback: "Delete keys and passcode")
      /// Delete current album media
      public static let mediaActiveBackend = L10n.tr("Localizable", "EraseProgress.Step.MediaActiveBackend", fallback: "Delete current album media")
      /// Delete downloaded copies and pending uploads
      public static let mediaBlobCache = L10n.tr("Localizable", "EraseProgress.Step.MediaBlobCache", fallback: "Delete downloaded copies and pending uploads")
      /// Delete media indexes
      public static let mediaIndexes = L10n.tr("Localizable", "EraseProgress.Step.MediaIndexes", fallback: "Delete media indexes")
      /// Delete local and iCloud Drive albums
      public static let mediaLocalAlbums = L10n.tr("Localizable", "EraseProgress.Step.MediaLocalAlbums", fallback: "Delete local and iCloud Drive albums")
      /// Delete shared imports
      public static let mediaSharedImports = L10n.tr("Localizable", "EraseProgress.Step.MediaSharedImports", fallback: "Delete shared imports")
      /// Delete temporary files
      public static let mediaTemp = L10n.tr("Localizable", "EraseProgress.Step.MediaTemp", fallback: "Delete temporary files")
      /// Delete thumbnails
      public static let mediaThumbnails = L10n.tr("Localizable", "EraseProgress.Step.MediaThumbnails", fallback: "Delete thumbnails")
      /// Cancel migrations
      public static let migrationState = L10n.tr("Localizable", "EraseProgress.Step.MigrationState", fallback: "Cancel migrations")
      /// Reset settings
      public static let settingsDefaults = L10n.tr("Localizable", "EraseProgress.Step.SettingsDefaults", fallback: "Reset settings")
      /// Remove remaining files
      public static let sweepResidual = L10n.tr("Localizable", "EraseProgress.Step.SweepResidual", fallback: "Remove remaining files")
      /// Stop iCloud sync
      public static let syncShutdown = L10n.tr("Localizable", "EraseProgress.Step.SyncShutdown", fallback: "Stop iCloud sync")
    }
  }
  public enum Error {
    public enum Alert {
      /// Failed to load file: %@
      public static func failedToLoadFile(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Error.Alert.FailedToLoadFile", String(describing: p1), fallback: "Failed to load file: %@")
      }
      /// Error
      public static let title = L10n.tr("Localizable", "Error.Alert.Title", fallback: "Error")
    }
  }
  public enum FeatureFlagToast {
    /// disabled
    public static let disabled = L10n.tr("Localizable", "FeatureFlagToast.Disabled", fallback: "disabled")
    /// enabled
    public static let enabled = L10n.tr("Localizable", "FeatureFlagToast.Enabled", fallback: "enabled")
    /// Feature Flag Toast - Deep Link Activation
    public static func message(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "FeatureFlagToast.Message", String(describing: p1), String(describing: p2), fallback: "Feature '%@' is now %@")
    }
  }
  public enum FeatureToggles {
    /// Detect Duplicates
    public static let detectDuplicates = L10n.tr("Localizable", "FeatureToggles.DetectDuplicates", fallback: "Detect Duplicates")
    /// Enable the find duplicates option in album menus
    public static let detectDuplicatesDescription = L10n.tr("Localizable", "FeatureToggles.DetectDuplicatesDescription", fallback: "Enable the find duplicates option in album menus")
    /// Edit Rotation
    public static let editRotation = L10n.tr("Localizable", "FeatureToggles.EditRotation", fallback: "Edit Rotation")
    /// Enable the edit button in the lightbox to rotate media
    public static let editRotationDescription = L10n.tr("Localizable", "FeatureToggles.EditRotationDescription", fallback: "Enable the edit button in the lightbox to rotate media")
    /// Test RevenueCat
    public static let enableTestRevenueCat = L10n.tr("Localizable", "FeatureToggles.EnableTestRevenueCat", fallback: "Test RevenueCat")
    /// Enable RevenueCat testing mode
    public static let enableTestRevenueCatDescription = L10n.tr("Localizable", "FeatureToggles.EnableTestRevenueCatDescription", fallback: "Enable RevenueCat testing mode")
    /// Encrypted Zip Export
    public static let encryptedZipExport = L10n.tr("Localizable", "FeatureToggles.EncryptedZipExport", fallback: "Encrypted Zip Export")
    /// Enable sharing media as an encrypted zip
    public static let encryptedZipExportDescription = L10n.tr("Localizable", "FeatureToggles.EncryptedZipExportDescription", fallback: "Enable sharing media as an encrypted zip")
    /// Changing RevenueCat mode requires restarting the app. Continue?
    public static let revenuecatToggleMessage = L10n.tr("Localizable", "FeatureToggles.RevenuecatToggleMessage", fallback: "Changing RevenueCat mode requires restarting the app. Continue?")
    /// Restart Required
    public static let revenuecatToggleTitle = L10n.tr("Localizable", "FeatureToggles.RevenuecatToggleTitle", fallback: "Restart Required")
    /// 🎨 Design System
    public static let showDesignSystem = L10n.tr("Localizable", "FeatureToggles.ShowDesignSystem", fallback: "🎨 Design System")
    /// Show hidden design system showcase
    public static let showDesignSystemDescription = L10n.tr("Localizable", "FeatureToggles.ShowDesignSystemDescription", fallback: "Show hidden design system showcase")
    /// Show Feature Toggles
    public static let showFeatureToggles = L10n.tr("Localizable", "FeatureToggles.ShowFeatureToggles", fallback: "Show Feature Toggles")
    /// Enable the feature toggles menu in settings
    public static let showFeatureTogglesDescription = L10n.tr("Localizable", "FeatureToggles.ShowFeatureTogglesDescription", fallback: "Enable the feature toggles menu in settings")
    /// ./Encamera/Settings/FeatureTogglesView.swift
    public static let title = L10n.tr("Localizable", "FeatureToggles.Title", fallback: "Feature Toggles")
  }
  public enum FeedbackView {
    /// What could we improve?
    public static let placeholderText = L10n.tr("Localizable", "FeedbackView.PlaceholderText", fallback: "What could we improve?")
    /// Your feedback is really important to us and helps us build a better product. We really appreciate it!
    public static let subheading = L10n.tr("Localizable", "FeedbackView.Subheading", fallback: "Your feedback is really important to us and helps us build a better product. We really appreciate it!")
    /// Submit
    public static let submit = L10n.tr("Localizable", "FeedbackView.Submit", fallback: "Submit")
    /// Thanks!
    public static let thanks = L10n.tr("Localizable", "FeedbackView.Thanks", fallback: "Thanks!")
    /// Leave feedback
    public static let title = L10n.tr("Localizable", "FeedbackView.Title", fallback: "Leave feedback")
    /// We appreciate your feedback
    public static let weAppreciateIt = L10n.tr("Localizable", "FeedbackView.WeAppreciateIt", fallback: "We appreciate your feedback")
  }
  public enum FileLoading {
    /// You are on cellular data. Large files may take longer to download from iCloud.
    public static let cellularWarning = L10n.tr("Localizable", "FileLoading.CellularWarning", fallback: "You are on cellular data. Large files may take longer to download from iCloud.")
    /// Decrypting media
    public static let decrypting = L10n.tr("Localizable", "FileLoading.Decrypting", fallback: "Decrypting media")
    /// Downloading media from iCloud
    public static let downloading = L10n.tr("Localizable", "FileLoading.Downloading", fallback: "Downloading media from iCloud")
    /// STEP %d OF 2
    public static func stepIndicator(_ p1: Int) -> String {
      return L10n.tr("Localizable", "FileLoading.StepIndicator", p1, fallback: "STEP %d OF 2")
    }
    /// STEP %d OF %d
    public static func stepIndicatorGeneric(_ p1: Int, _ p2: Int) -> String {
      return L10n.tr("Localizable", "FileLoading.StepIndicatorGeneric", p1, p2, fallback: "STEP %d OF %d")
    }
  }
  public enum FooterView {
    public enum Slideshow {
      /// 15 Seconds
      public static let fifteenSeconds = L10n.tr("Localizable", "FooterView.Slideshow.FifteenSeconds", fallback: "15 Seconds")
      /// 5 Seconds
      public static let fiveSeconds = L10n.tr("Localizable", "FooterView.Slideshow.FiveSeconds", fallback: "5 Seconds")
      /// 1 Second
      public static let oneSecond = L10n.tr("Localizable", "FooterView.Slideshow.OneSecond", fallback: "1 Second")
      /// Slideshow Duration
      public static let selectDuration = L10n.tr("Localizable", "FooterView.Slideshow.SelectDuration", fallback: "Slideshow Duration")
      /// 3 Seconds
      public static let threeSeconds = L10n.tr("Localizable", "FooterView.Slideshow.ThreeSeconds", fallback: "3 Seconds")
    }
  }
  public enum GalleryView {
    /// Album cover set
    public static let albumCoverSetToast = L10n.tr("Localizable", "GalleryView.AlbumCoverSetToast", fallback: "Album cover set")
    /// ./Encamera/ImageViewing/GalleryHorizontalScrollView.swift
    public static let makeAlbumCover = L10n.tr("Localizable", "GalleryView.MakeAlbumCover", fallback: "Make Album Cover")
  }
  public enum GlobalImportProgress {
    /// This will delete %@ photo(s) from your Photos library.
    public static func deleteCountMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "GlobalImportProgress.DeleteCountMessage", String(describing: p1), fallback: "This will delete %@ photo(s) from your Photos library.")
    }
    /// This will delete %@ photo(s) from your Photos library. %@ imported photo(s) are no longer in Encamera, so their originals will be kept.
    public static func deleteCountMessageSkipping(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "GlobalImportProgress.DeleteCountMessageSkipping", String(describing: p1), String(describing: p2), fallback: "This will delete %@ photo(s) from your Photos library. %@ imported photo(s) are no longer in Encamera, so their originals will be kept.")
    }
    /// Delete from Photos Library?
    public static let deleteFromPhotoLibraryAlert = L10n.tr("Localizable", "GlobalImportProgress.DeleteFromPhotoLibraryAlert", fallback: "Delete from Photos Library?")
    /// Import canceled
    public static let importCanceled = L10n.tr("Localizable", "GlobalImportProgress.ImportCanceled", fallback: "Import canceled")
    /// ./Encamera/Components/ImportProgress/GlobalImportProgressView.swift
    public static let importCompleted = L10n.tr("Localizable", "GlobalImportProgress.ImportCompleted", fallback: "Import completed")
    /// Importing %@ batches
    public static func importingBatches(_ p1: Any) -> String {
      return L10n.tr("Localizable", "GlobalImportProgress.ImportingBatches", String(describing: p1), fallback: "Importing %@ batches")
    }
    /// Importing %@ of %@
    public static func importingProgress(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "GlobalImportProgress.ImportingProgress", String(describing: p1), String(describing: p2), fallback: "Importing %@ of %@")
    }
    /// Import stopped
    public static let importStopped = L10n.tr("Localizable", "GlobalImportProgress.ImportStopped", fallback: "Import stopped")
    /// Deleted from Photos library
    public static let photosDeleted = L10n.tr("Localizable", "GlobalImportProgress.PhotosDeleted", fallback: "Deleted from Photos library")
    /// Remaining
    public static let remaining = L10n.tr("Localizable", "GlobalImportProgress.Remaining", fallback: "Remaining")
  }
  public enum GuidedSync {
    /// On your other device, open Encamera and turn on iCloud Backup & Sync in Settings. Your key will sync to this device automatically.
    public static let body = L10n.tr("Localizable", "GuidedSync.Body", fallback: "On your other device, open Encamera and turn on iCloud Backup & Sync in Settings. Your key will sync to this device automatically.")
    /// On %@, open Encamera and turn on iCloud Backup & Sync in Settings. Your key will sync to this device automatically.
    public static func bodyNamed(_ p1: Any) -> String {
      return L10n.tr("Localizable", "GuidedSync.BodyNamed", String(describing: p1), fallback: "On %@, open Encamera and turn on iCloud Backup & Sync in Settings. Your key will sync to this device automatically.")
    }
    /// Continue
    public static let `continue` = L10n.tr("Localizable", "GuidedSync.Continue", fallback: "Continue")
    /// Enter Recovery Key Instead
    public static let enterManually = L10n.tr("Localizable", "GuidedSync.EnterManually", fallback: "Enter Recovery Key Instead")
    /// A key arrived from another device, but it isn't the one your photos here need. Enter your recovery key instead, or keep waiting for the right device to sync.
    public static let mismatchBody = L10n.tr("Localizable", "GuidedSync.MismatchBody", fallback: "A key arrived from another device, but it isn't the one your photos here need. Enter your recovery key instead, or keep waiting for the right device to sync.")
    /// That's a different key
    public static let mismatchTitle = L10n.tr("Localizable", "GuidedSync.MismatchTitle", fallback: "That's a different key")
    /// Keep Waiting
    public static let retry = L10n.tr("Localizable", "GuidedSync.Retry", fallback: "Keep Waiting")
    /// Your key arrived from your other device. You're all set to continue on this device.
    public static let successBody = L10n.tr("Localizable", "GuidedSync.SuccessBody", fallback: "Your key arrived from your other device. You're all set to continue on this device.")
    /// Key synced
    public static let successTitle = L10n.tr("Localizable", "GuidedSync.SuccessTitle", fallback: "Key synced")
    /// Your key hasn't arrived yet. Make sure iCloud Keychain is turned on: check Settings → iCloud → Passwords & Keychain on both devices, then try again.
    public static let timeoutBody = L10n.tr("Localizable", "GuidedSync.TimeoutBody", fallback: "Your key hasn't arrived yet. Make sure iCloud Keychain is turned on: check Settings → iCloud → Passwords & Keychain on both devices, then try again.")
    /// Still waiting for your key
    public static let timeoutTitle = L10n.tr("Localizable", "GuidedSync.TimeoutTitle", fallback: "Still waiting for your key")
    /// ./Encamera/Onboarding/OnboardingGuidedSyncView.swift - Guided flip-the-switch flow: wait for the key to arrive via iCloud Keychain (ENC-93)
    public static let title = L10n.tr("Localizable", "GuidedSync.Title", fallback: "Turn on iCloud Backup & Sync")
    /// Waiting for your key to arrive…
    public static let waiting = L10n.tr("Localizable", "GuidedSync.Waiting", fallback: "Waiting for your key to arrive…")
  }
  public enum HideAlbumTutorial {
    /// Hide Album Tutorial
    public static let headingText1 = L10n.tr("Localizable", "HideAlbumTutorial.HeadingText1", fallback: "Hide Your Albums")
    /// Remember the Name
    public static let headingText2 = L10n.tr("Localizable", "HideAlbumTutorial.HeadingText2", fallback: "Remember the Name")
    /// View Hidden Albums
    public static let headingText3 = L10n.tr("Localizable", "HideAlbumTutorial.HeadingText3", fallback: "View Hidden Albums")
    /// Access the Albums
    public static let headingText4 = L10n.tr("Localizable", "HideAlbumTutorial.HeadingText4", fallback: "Access the Albums")
    /// Tap the hide icon to hide your albums. Hidden albums don't appear in your album list.
    public static let subheadingText1 = L10n.tr("Localizable", "HideAlbumTutorial.SubheadingText1", fallback: "Tap the hide icon to hide your albums. Hidden albums don't appear in your album list.")
    /// You'll need the album name to open it later. Choose a name you'll remember or keep it noted somewhere safe.
    public static let subheadingText2 = L10n.tr("Localizable", "HideAlbumTutorial.SubheadingText2", fallback: "You'll need the album name to open it later. Choose a name you'll remember or keep it noted somewhere safe.")
    /// Need a quick overview? Long press the "Hide Albums" section to see a list of all your hidden albums.
    public static let subheadingText3 = L10n.tr("Localizable", "HideAlbumTutorial.SubheadingText3", fallback: "Need a quick overview? Long press the \"Hide Albums\" section to see a list of all your hidden albums.")
    /// To unhide an album, create a new album with the exact same name. Your hidden albums will instantly reappear.
    public static let subheadingText4 = L10n.tr("Localizable", "HideAlbumTutorial.SubheadingText4", fallback: "To unhide an album, create a new album with the exact same name. Your hidden albums will instantly reappear.")
  }
  public enum ICloudError {
    /// Could not download '%@' from iCloud: %@
    public static func downloadFailed(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "ICloudError.DownloadFailed", String(describing: p1), String(describing: p2), fallback: "Could not download '%@' from iCloud: %@")
    }
    /// Could not download '%@' from iCloud. Please check your internet connection and iCloud settings.
    public static func downloadFailedGeneric(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ICloudError.DownloadFailedGeneric", String(describing: p1), fallback: "Could not download '%@' from iCloud. Please check your internet connection and iCloud settings.")
    }
    /// File '%@' is still downloading from iCloud. Please wait.
    public static func downloadInProgress(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ICloudError.DownloadInProgress", String(describing: p1), fallback: "File '%@' is still downloading from iCloud. Please wait.")
    }
    /// iCloud download timed out. Please check your internet connection and try again.
    public static let downloadTimeout = L10n.tr("Localizable", "ICloudError.DownloadTimeout", fallback: "iCloud download timed out. Please check your internet connection and try again.")
    /// ./Encamera/ImageViewing/MediaViewingError.swift - iCloud Error Messages
    public static let fileNotDownloaded = L10n.tr("Localizable", "ICloudError.FileNotDownloaded", fallback: "This file is stored in iCloud and needs to be downloaded. Please check your internet connection and try again.")
    /// This file is stored in iCloud and could not be downloaded. Connect to Wi-Fi and try again.
    public static let notAvailableCellular = L10n.tr("Localizable", "ICloudError.NotAvailableCellular", fallback: "This file is stored in iCloud and could not be downloaded. Connect to Wi-Fi and try again.")
    /// This file is stored in iCloud and could not be downloaded. Connect to the internet and try again.
    public static let notAvailableNoConnection = L10n.tr("Localizable", "ICloudError.NotAvailableNoConnection", fallback: "This file is stored in iCloud and could not be downloaded. Connect to the internet and try again.")
    /// This file is stored in iCloud and could not be downloaded. Check your iCloud connection and try again.
    public static let notAvailableWiFi = L10n.tr("Localizable", "ICloudError.NotAvailableWiFi", fallback: "This file is stored in iCloud and could not be downloaded. Check your iCloud connection and try again.")
  }
  public enum ICloudStatus {
    /// ./Encamera/Components/iCloudSyncStatusIndicator.swift - Directory Sync Status
    public static let allSynced = L10n.tr("Localizable", "ICloudStatus.AllSynced", fallback: "All files downloaded")
    /// No files in iCloud
    public static let noFiles = L10n.tr("Localizable", "ICloudStatus.NoFiles", fallback: "No files in iCloud")
    /// %d files need download
    public static func pendingDownload(_ p1: Int) -> String {
      return L10n.tr("Localizable", "ICloudStatus.PendingDownload", p1, fallback: "%d files need download")
    }
    /// Downloading %d of %d files
    public static func syncing(_ p1: Int, _ p2: Int) -> String {
      return L10n.tr("Localizable", "ICloudStatus.Syncing", p1, p2, fallback: "Downloading %d of %d files")
    }
  }
  public enum KeyEntry {
    /// That's not the key these photos need. You entered key %@, but they need key %@.
    public static func fingerprintMismatch(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "KeyEntry.FingerprintMismatch", String(describing: p1), String(describing: p2), fallback: "That's not the key these photos need. You entered key %@, but they need key %@.")
    }
    /// Enter your recovery key. Your existing photos and videos are encrypted with it.
    public static let prompt = L10n.tr("Localizable", "KeyEntry.Prompt", fallback: "Enter your recovery key. Your existing photos and videos are encrypted with it.")
    /// Enter your recovery key. We couldn't reach your existing photos to check it now — we'll verify it when they load.
    public static let promptUnknown = L10n.tr("Localizable", "KeyEntry.PromptUnknown", fallback: "Enter your recovery key. We couldn't reach your existing photos to check it now — we'll verify it when they load.")
    /// Enter the recovery key for key %@. Your existing photos and videos are encrypted with it.
    public static func promptWithFingerprint(_ p1: Any) -> String {
      return L10n.tr("Localizable", "KeyEntry.PromptWithFingerprint", String(describing: p1), fallback: "Enter the recovery key for key %@. Your existing photos and videos are encrypted with it.")
    }
    /// Verify and Continue
    public static let submit = L10n.tr("Localizable", "KeyEntry.Submit", fallback: "Verify and Continue")
    /// ./Encamera/Onboarding/OnboardingKeyEntryView.swift - Manual key-phrase entry with fingerprint validation (ENC-92)
    public static let title = L10n.tr("Localizable", "KeyEntry.Title", fallback: "Enter your recovery key")
    /// Checking your recovery key…
    public static let verifying = L10n.tr("Localizable", "KeyEntry.Verifying", fallback: "Checking your recovery key…")
  }
  public enum KeyMissing {
    /// another device
    public static let anotherDevice = L10n.tr("Localizable", "KeyMissing.AnotherDevice", fallback: "another device")
    /// iCloud Backup & Sync was turned off from %@, which removes the key from all other devices.
    public static func disabledFromDevice(_ p1: Any) -> String {
      return L10n.tr("Localizable", "KeyMissing.DisabledFromDevice", String(describing: p1), fallback: "iCloud Backup & Sync was turned off from %@, which removes the key from all other devices.")
    }
    /// iCloud Backup & Sync was turned off from %@ on %@, which removes the key from all other devices.
    public static func disabledFromDeviceOn(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "KeyMissing.DisabledFromDeviceOn", String(describing: p1), String(describing: p2), fallback: "iCloud Backup & Sync was turned off from %@ on %@, which removes the key from all other devices.")
    }
    /// Enter Recovery Key
    public static let enterKeyPhrase = L10n.tr("Localizable", "KeyMissing.EnterKeyPhrase", fallback: "Enter Recovery Key")
    /// Set Up as a New Device
    public static let startFresh = L10n.tr("Localizable", "KeyMissing.StartFresh", fallback: "Set Up as a New Device")
    /// Your encryption key isn't available on this device, so existing photos can't be decrypted.
    public static let subtitle = L10n.tr("Localizable", "KeyMissing.Subtitle", fallback: "Your encryption key isn't available on this device, so existing photos can't be decrypted.")
    /// ./Encamera/Components/KeyMissingView.swift - No encryption key on this device
    public static let title = L10n.tr("Localizable", "KeyMissing.Title", fallback: "No encryption key on this device")
  }
  public enum KeyPhrase {
    /// Copied to clipboard
    public static let copiedToClipboard = L10n.tr("Localizable", "KeyPhrase.CopiedToClipboard", fallback: "Copied to clipboard")
    /// Copy to Clipboard
    public static let copyToClipboard = L10n.tr("Localizable", "KeyPhrase.CopyToClipboard", fallback: "Copy to Clipboard")
    /// This key unlocks your encrypted albums. Keep a copy somewhere safe in case you ever need it.
    public static let privacyKeySubtitle = L10n.tr("Localizable", "KeyPhrase.PrivacyKeySubtitle", fallback: "This key unlocks your encrypted albums. Keep a copy somewhere safe in case you ever need it.")
    /// Key Phrase Display Screen
    public static let privacyKeyTitle = L10n.tr("Localizable", "KeyPhrase.PrivacyKeyTitle", fallback: "Your Recovery Key")
  }
  public enum KeyPhrasePicker {
    /// In Use
    public static let currentKey = L10n.tr("Localizable", "KeyPhrasePicker.CurrentKey", fallback: "In Use")
    /// Plural format key: "%#@item_count@"
    public static func itemCount(_ p1: Int) -> String {
      return L10n.tr("Localizable", "KeyPhrasePicker.ItemCount", p1, fallback: "Plural format key: \"%#@item_count@\"")
    }
    /// Key for %@
    public static func keyForAlbum(_ p1: Any) -> String {
      return L10n.tr("Localizable", "KeyPhrasePicker.KeyForAlbum", String(describing: p1), fallback: "Key for %@")
    }
    /// Plural format key: "%#@album_count@"
    public static func keyForAlbums(_ p1: Int) -> String {
      return L10n.tr("Localizable", "KeyPhrasePicker.KeyForAlbums", p1, fallback: "Plural format key: \"%#@album_count@\"")
    }
    /// Key with No Albums
    public static let keyWithNoAlbums = L10n.tr("Localizable", "KeyPhrasePicker.KeyWithNoAlbums", fallback: "Key with No Albums")
    /// Made on %@
    public static func originDevice(_ p1: Any) -> String {
      return L10n.tr("Localizable", "KeyPhrasePicker.OriginDevice", String(describing: p1), fallback: "Made on %@")
    }
    /// Made on another device
    public static let originOtherDevice = L10n.tr("Localizable", "KeyPhrasePicker.OriginOtherDevice", fallback: "Made on another device")
    /// Made on this device
    public static let originThisDevice = L10n.tr("Localizable", "KeyPhrasePicker.OriginThisDevice", fallback: "Made on this device")
    /// Each key opens the media it encrypted. You may have multiple keys because you used Encamera with multiple devices before turning iCloud Backup & Sync on, and a key was created for each device.
    public static let subtitle = L10n.tr("Localizable", "KeyPhrasePicker.Subtitle", fallback: "Each key opens the media it encrypted. You may have multiple keys because you used Encamera with multiple devices before turning iCloud Backup & Sync on, and a key was created for each device.")
    /// ./Encamera/Settings/KeyPhrasePickerDrawer.swift - Drawer listing the keys whose recovery phrase can be backed up
    public static let title = L10n.tr("Localizable", "KeyPhrasePicker.Title", fallback: "Which key do you want to back up?")
  }
  public enum Lightbox {
    /// ./Encamera/Lightbox/LightboxController.swift - Edit Mode
    public static let edit = L10n.tr("Localizable", "Lightbox.Edit", fallback: "Edit")
    public enum Edit {
      /// Edit saved
      public static let completed = L10n.tr("Localizable", "Lightbox.Edit.Completed", fallback: "Edit saved")
      /// Decrypting…
      public static let decrypting = L10n.tr("Localizable", "Lightbox.Edit.Decrypting", fallback: "Decrypting…")
      /// Encrypting…
      public static let encrypting = L10n.tr("Localizable", "Lightbox.Edit.Encrypting", fallback: "Encrypting…")
      /// Rotating…
      public static let rotating = L10n.tr("Localizable", "Lightbox.Edit.Rotating", fallback: "Rotating…")
    }
  }
  public enum MainHomeView {
    public enum TabBar {
      /// ./Encamera/MainHomeView/MainHomeView.swift
      public static let camera = L10n.tr("Localizable", "MainHomeView.TabBar.Camera", fallback: "Camera")
    }
  }
  public enum MediaInfo {
    /// Additional Details
    public static let additionalDetails = L10n.tr("Localizable", "MediaInfo.AdditionalDetails", fallback: "Additional Details")
    /// Burst Photo
    public static let burstPhoto = L10n.tr("Localizable", "MediaInfo.BurstPhoto", fallback: "Burst Photo")
    /// Downloaded
    public static let cachedOnDevice = L10n.tr("Localizable", "MediaInfo.CachedOnDevice", fallback: "Downloaded")
    /// Chunks
    public static let chunks = L10n.tr("Localizable", "MediaInfo.Chunks", fallback: "Chunks")
    /// Codec
    public static let codec = L10n.tr("Localizable", "MediaInfo.Codec", fallback: "Codec")
    /// Delete Permanently
    public static let deletePermanently = L10n.tr("Localizable", "MediaInfo.DeletePermanently", fallback: "Delete Permanently")
    /// This media will be deleted everywhere it is stored, including iCloud. This cannot be undone.
    public static let deletePermanentlyMessage = L10n.tr("Localizable", "MediaInfo.DeletePermanentlyMessage", fallback: "This media will be deleted everywhere it is stored, including iCloud. This cannot be undone.")
    /// Duration
    public static let duration = L10n.tr("Localizable", "MediaInfo.Duration", fallback: "Duration")
    /// Encrypted
    public static let encrypted = L10n.tr("Localizable", "MediaInfo.Encrypted", fallback: "Encrypted")
    /// This media is stored only on this device, so there's no downloaded copy to remove.
    public static let evictUnavailableLocalOnly = L10n.tr("Localizable", "MediaInfo.EvictUnavailableLocalOnly", fallback: "This media is stored only on this device, so there's no downloaded copy to remove.")
    /// Original File Name
    public static let filename = L10n.tr("Localizable", "MediaInfo.Filename", fallback: "Original File Name")
    /// Format
    public static let format = L10n.tr("Localizable", "MediaInfo.Format", fallback: "Format")
    /// Frame Rate
    public static let frameRate = L10n.tr("Localizable", "MediaInfo.FrameRate", fallback: "Frame Rate")
    /// Key ID
    public static let keyFingerprint = L10n.tr("Localizable", "MediaInfo.KeyFingerprint", fallback: "Key ID")
    /// Metadata Not Available
    public static let metadataNotAvailable = L10n.tr("Localizable", "MediaInfo.MetadataNotAvailable", fallback: "Metadata Not Available")
    /// Not Downloaded
    public static let notCached = L10n.tr("Localizable", "MediaInfo.NotCached", fallback: "Not Downloaded")
    /// On This Device
    public static let onDevice = L10n.tr("Localizable", "MediaInfo.OnDevice", fallback: "On This Device")
    /// Remove Download
    public static let removeCachedCopy = L10n.tr("Localizable", "MediaInfo.RemoveCachedCopy", fallback: "Remove Download")
    /// The encrypted copy on this device will be removed. This media stays in iCloud and downloads again the next time you open it.
    public static let removeCachedCopyMessage = L10n.tr("Localizable", "MediaInfo.RemoveCachedCopyMessage", fallback: "The encrypted copy on this device will be removed. This media stays in iCloud and downloads again the next time you open it.")
    /// Screenshot
    public static let screenshot = L10n.tr("Localizable", "MediaInfo.Screenshot", fallback: "Screenshot")
    /// Storage
    public static let storage = L10n.tr("Localizable", "MediaInfo.Storage", fallback: "Storage")
    /// Couldn't Complete
    public static let storageActionFailed = L10n.tr("Localizable", "MediaInfo.StorageActionFailed", fallback: "Couldn't Complete")
    /// Type
    public static let type = L10n.tr("Localizable", "MediaInfo.Type", fallback: "Type")
    /// ./Encamera/Lightbox/Views/MediaInfoDetailView.swift - Media Info
    public static let unknownDevice = L10n.tr("Localizable", "MediaInfo.UnknownDevice", fallback: "Unknown Device")
  }
  public enum MediaSelectionTray {
    /// Selected
    public static let itemSelected = L10n.tr("Localizable", "MediaSelectionTray.ItemSelected", fallback: "Selected")
    /// ./Encamera/AlbumManagement/MediaSelectionTray.swift
    public static let moveToAlbum = L10n.tr("Localizable", "MediaSelectionTray.MoveToAlbum", fallback: "Move to Album")
    /// Select
    public static let selectMedia = L10n.tr("Localizable", "MediaSelectionTray.SelectMedia", fallback: "Select")
  }
  public enum MissingKey {
    /// Enter Recovery Key
    public static let addKey = L10n.tr("Localizable", "MissingKey.AddKey", fallback: "Enter Recovery Key")
    /// Enter the recovery key for key %@. It will only be used to open existing media — new photos keep using this device's key.
    public static func addKeyPrompt(_ p1: Any) -> String {
      return L10n.tr("Localizable", "MissingKey.AddKeyPrompt", String(describing: p1), fallback: "Enter the recovery key for key %@. It will only be used to open existing media — new photos keep using this device's key.")
    }
    /// Enter the recovery key for the key this media needs. It will only be used to open existing media — new photos keep using this device's key.
    public static let addKeyPromptUnknown = L10n.tr("Localizable", "MissingKey.AddKeyPromptUnknown", fallback: "Enter the recovery key for the key this media needs. It will only be used to open existing media — new photos keep using this device's key.")
    /// Add a key
    public static let addKeyTitle = L10n.tr("Localizable", "MissingKey.AddKeyTitle", fallback: "Add a key")
    /// None of this album's photos or videos could be opened with any key on this device.
    public static let albumContentsUnreadable = L10n.tr("Localizable", "MissingKey.AlbumContentsUnreadable", fallback: "None of this album's photos or videos could be opened with any key on this device.")
    /// Name unavailable
    public static let albumNameUnavailable = L10n.tr("Localizable", "MissingKey.AlbumNameUnavailable", fallback: "Name unavailable")
    /// This album was encrypted with key %@, which isn't on this device.
    public static func albumSubtitleWithFingerprint(_ p1: Any) -> String {
      return L10n.tr("Localizable", "MissingKey.AlbumSubtitleWithFingerprint", String(describing: p1), fallback: "This album was encrypted with key %@, which isn't on this device.")
    }
    /// Missing Key
    public static let albumTitle = L10n.tr("Localizable", "MissingKey.AlbumTitle", fallback: "Missing Key")
    /// You already have that key on this device.
    public static let alreadyHaveKey = L10n.tr("Localizable", "MissingKey.AlreadyHaveKey", fallback: "You already have that key on this device.")
    /// This recovery key couldn't be checked because none of this album's media has downloaded yet. Wait for the download to finish and try again.
    public static let couldNotVerify = L10n.tr("Localizable", "MissingKey.CouldNotVerify", fallback: "This recovery key couldn't be checked because none of this album's media has downloaded yet. Wait for the download to finish and try again.")
    /// Enter Recovery Key
    public static let enterKey = L10n.tr("Localizable", "MissingKey.EnterKey", fallback: "Enter Recovery Key")
    /// Missing key
    public static let shortLabel = L10n.tr("Localizable", "MissingKey.ShortLabel", fallback: "Missing key")
    /// It was encrypted with a key that isn't on this device.
    public static let subtitleUnknown = L10n.tr("Localizable", "MissingKey.SubtitleUnknown", fallback: "It was encrypted with a key that isn't on this device.")
    /// It was encrypted with key %@, which isn't on this device.
    public static func subtitleWithFingerprint(_ p1: Any) -> String {
      return L10n.tr("Localizable", "MissingKey.SubtitleWithFingerprint", String(describing: p1), fallback: "It was encrypted with key %@, which isn't on this device.")
    }
    /// ENC-99 - Media encrypted with a key this device does not hold (placeholder copy; design in ENC-103)
    public static let title = L10n.tr("Localizable", "MissingKey.Title", fallback: "This item needs a different key")
    /// That recovery key is for key %@, but this media needs key %@.
    public static func wrongKey(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "MissingKey.WrongKey", String(describing: p1), String(describing: p2), fallback: "That recovery key is for key %@, but this media needs key %@.")
    }
    /// That recovery key doesn't open this media.
    public static let wrongKeyUnknown = L10n.tr("Localizable", "MissingKey.WrongKeyUnknown", fallback: "That recovery key doesn't open this media.")
  }
  public enum Onboarding {
    public enum DataLocation {
      /// Synced across your Apple devices
      public static let iCloudLabel = L10n.tr("Localizable", "Onboarding.DataLocation.iCloudLabel", fallback: "Synced across your Apple devices")
      /// Choose where your encrypted photos and videos live, along with your encryption key and passcode
      public static let subtitle = L10n.tr("Localizable", "Onboarding.DataLocation.subtitle", fallback: "Choose where your encrypted photos and videos live, along with your encryption key and passcode")
      /// Stored only on this device
      public static let thisIPhoneLabel = L10n.tr("Localizable", "Onboarding.DataLocation.thisIPhoneLabel", fallback: "Stored only on this device")
      /// This Device
      public static let thisIPhoneTitle = L10n.tr("Localizable", "Onboarding.DataLocation.thisIPhoneTitle", fallback: "This Device")
      /// Data location choice
      public static let title = L10n.tr("Localizable", "Onboarding.DataLocation.title", fallback: "iCloud or this device?")
    }
    public enum Encryption {
      /// Before it's stored on your device or in iCloud
      public static let row1 = L10n.tr("Localizable", "Onboarding.Encryption.row1", fallback: "Before it's stored on your device or in iCloud")
      /// Only you can unlock your photos and videos
      public static let row2 = L10n.tr("Localizable", "Onboarding.Encryption.row2", fallback: "Only you can unlock your photos and videos")
      /// Your recovery key is the only way to recover them if you lose access
      public static let row3 = L10n.tr("Localizable", "Onboarding.Encryption.row3", fallback: "Your recovery key is the only way to recover them if you lose access")
      /// Encryption explainer
      public static let title = L10n.tr("Localizable", "Onboarding.Encryption.title", fallback: "Every photo and video you add is encrypted")
    }
    public enum NeedKey {
      /// Without your encryption key, you won't be able to access your existing encrypted photos and videos on this device.
      /// 
      /// You can enter your recovery key later if you get access to it.
      public static let body = L10n.tr("Localizable", "Onboarding.NeedKey.body", fallback: "Without your encryption key, you won't be able to access your existing encrypted photos and videos on this device.\n\nYou can enter your recovery key later if you get access to it.")
      /// Continue Without Key
      public static let continueWithoutKey = L10n.tr("Localizable", "Onboarding.NeedKey.continueWithoutKey", fallback: "Continue Without Key")
      /// Need key
      public static let title = L10n.tr("Localizable", "Onboarding.NeedKey.title", fallback: "You'll need your encryption key")
    }
    public enum PasscodeTypeSelection {
      /// You can change this anytime in Settings
      public static let changeAnytime = L10n.tr("Localizable", "Onboarding.PasscodeTypeSelection.changeAnytime", fallback: "You can change this anytime in Settings")
      /// More characters for added security
      public static let passwordLabel = L10n.tr("Localizable", "Onboarding.PasscodeTypeSelection.passwordLabel", fallback: "More characters for added security")
      /// Password (Recommended)
      public static let passwordTitle = L10n.tr("Localizable", "Onboarding.PasscodeTypeSelection.passwordTitle", fallback: "Password (Recommended)")
      /// Quick and easy to enter
      public static let pinLabel = L10n.tr("Localizable", "Onboarding.PasscodeTypeSelection.pinLabel", fallback: "Quick and easy to enter")
      /// PIN
      public static let pinTitle = L10n.tr("Localizable", "Onboarding.PasscodeTypeSelection.pinTitle", fallback: "PIN")
      /// Choose the option that works best for you.
      public static let subtitle = L10n.tr("Localizable", "Onboarding.PasscodeTypeSelection.subtitle", fallback: "Choose the option that works best for you.")
      /// Passcode type selection
      public static let title = L10n.tr("Localizable", "Onboarding.PasscodeTypeSelection.title", fallback: "Password or PIN?")
    }
    public enum Password {
      /// Confirm your password
      public static let confirmTitle = L10n.tr("Localizable", "Onboarding.Password.confirmTitle", fallback: "Confirm your password")
      /// Your password
      public static let field = L10n.tr("Localizable", "Onboarding.Password.field", fallback: "Your password")
      /// Set Password
      public static let setButton = L10n.tr("Localizable", "Onboarding.Password.setButton", fallback: "Set Password")
      /// Use a longer password for added security
      public static let subtitle = L10n.tr("Localizable", "Onboarding.Password.subtitle", fallback: "Use a longer password for added security")
      /// Password
      public static let title = L10n.tr("Localizable", "Onboarding.Password.title", fallback: "Create your password")
    }
    public enum Pin {
      /// Confirm your PIN
      public static let confirmTitle = L10n.tr("Localizable", "Onboarding.Pin.confirmTitle", fallback: "Confirm your PIN")
      /// Choose a PIN you'll use to unlock your photos and videos
      public static let subtitle = L10n.tr("Localizable", "Onboarding.Pin.subtitle", fallback: "Choose a PIN you'll use to unlock your photos and videos")
      /// PIN
      public static let title = L10n.tr("Localizable", "Onboarding.Pin.title", fallback: "Create your PIN")
    }
    public enum Premium {
      /// Store up to %d photos and videos in Encamera at no cost.
      public static func body1(_ p1: Int) -> String {
        return L10n.tr("Localizable", "Onboarding.Premium.Body1", p1, fallback: "Store up to %d photos and videos in Encamera at no cost.")
      }
      /// Upgrade to Premium when you need more.
      public static let body2 = L10n.tr("Localizable", "Onboarding.Premium.Body2", fallback: "Upgrade to Premium when you need more.")
      /// ./Encamera/Onboarding/PremiumFeaturesExplanationView.swift - Premium features explainer (ENC-270)
      public static let title = L10n.tr("Localizable", "Onboarding.Premium.Title", fallback: "Privacy starts free")
    }
    public enum Ready {
      /// Go to My Album
      public static let goToAlbum = L10n.tr("Localizable", "Onboarding.Ready.goToAlbum", fallback: "Go to My Album")
      /// Your first private album is ready
      public static let subtitle = L10n.tr("Localizable", "Onboarding.Ready.subtitle", fallback: "Your first private album is ready")
      /// Ready
      public static let title = L10n.tr("Localizable", "Onboarding.Ready.title", fallback: "You're ready to use Encamera")
    }
    public enum Story {
      /// Get Started
      public static let letsStart = L10n.tr("Localizable", "Onboarding.Story.letsStart", fallback: "Get Started")
      /// Story carousel
      public static let title1 = L10n.tr("Localizable", "Onboarding.Story.title1", fallback: "Get your privacy back")
      /// What you shoot stays in Encamera, not in Photos
      public static let title2 = L10n.tr("Localizable", "Onboarding.Story.title2", fallback: "What you shoot stays in Encamera, not in Photos")
      /// Your photos live on your device or your iCloud
      public static let title3 = L10n.tr("Localizable", "Onboarding.Story.title3", fallback: "Your photos live on your device or your iCloud")
      /// Nobody can view your photos and videos except you
      public static let title4 = L10n.tr("Localizable", "Onboarding.Story.title4", fallback: "Nobody can view your photos and videos except you")
      /// ./Encamera/Onboarding/OnboardingStoryCarousel.swift - Story carousel welcome label (ENC-277)
      public static let welcome = L10n.tr("Localizable", "Onboarding.Story.welcome", fallback: "Welcome to Encamera")
    }
    public enum WelcomeBack {
      /// We found that you've used Encamera on your other device. Turn on iCloud Backup & Sync on that device, or enter your recovery key, to keep your albums in sync.
      public static let bodyGeneric = L10n.tr("Localizable", "Onboarding.WelcomeBack.bodyGeneric", fallback: "We found that you've used Encamera on your other device. Turn on iCloud Backup & Sync on that device, or enter your recovery key, to keep your albums in sync.")
      /// We found that you've used Encamera on %@. Turn on iCloud Backup & Sync on that device, or enter your recovery key, to keep your albums in sync.
      public static func bodyWithDevice(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Onboarding.WelcomeBack.bodyWithDevice", String(describing: p1), fallback: "We found that you've used Encamera on %@. Turn on iCloud Backup & Sync on that device, or enter your recovery key, to keep your albums in sync.")
      }
      /// Enter Recovery Key
      public static let importKey = L10n.tr("Localizable", "Onboarding.WelcomeBack.importKey", fallback: "Enter Recovery Key")
      /// I don't have my key
      public static let noKey = L10n.tr("Localizable", "Onboarding.WelcomeBack.noKey", fallback: "I don't have my key")
      /// Welcome back
      public static let title = L10n.tr("Localizable", "Onboarding.WelcomeBack.title", fallback: "Welcome back to Encamera")
    }
  }
  public enum OnboardingCarousel {
    /// Your memories, fully protected
    public static let headingText1 = L10n.tr("Localizable", "OnboardingCarousel.HeadingText1", fallback: "Your memories, fully protected")
    /// Only you hold the encryption key
    public static let headingText2 = L10n.tr("Localizable", "OnboardingCarousel.HeadingText2", fallback: "Only you hold the encryption key")
    /// No accounts. No profiling. No ads.
    public static let headingText3 = L10n.tr("Localizable", "OnboardingCarousel.HeadingText3", fallback: "No accounts. No profiling. No ads.")
    /// We encrypt every picture and video instantly. No one else can see them, not even us.
    public static let subheadingText1 = L10n.tr("Localizable", "OnboardingCarousel.SubheadingText1", fallback: "We encrypt every picture and video instantly. No one else can see them, not even us.")
    /// Your albums are locked with your unique key and stored safely on your device or iCloud.
    public static let subheadingText2 = L10n.tr("Localizable", "OnboardingCarousel.SubheadingText2", fallback: "Your albums are locked with your unique key and stored safely on your device or iCloud.")
    /// Encamera never collects your data. Your private moments stay completely yours.
    public static let subheadingText3 = L10n.tr("Localizable", "OnboardingCarousel.SubheadingText3", fallback: "Encamera never collects your data. Your private moments stay completely yours.")
  }
  public enum PasswordManager {
    /// Encamera
    public static let credentialTitle = L10n.tr("Localizable", "PasswordManager.CredentialTitle", fallback: "Encamera")
    /// Encamera (%@)
    public static func credentialTitleWithFingerprint(_ p1: Any) -> String {
      return L10n.tr("Localizable", "PasswordManager.CredentialTitleWithFingerprint", String(describing: p1), fallback: "Encamera (%@)")
    }
    /// ./Encamera/Settings/KeyPhrasePasswordManagerSaver.swift - Key phrase entry saved to the user's password manager
    public static let credentialUserName = L10n.tr("Localizable", "PasswordManager.CredentialUserName", fallback: "Encamera Recovery Key")
    /// Encamera Recovery Key (%@)
    public static func credentialUserNameWithFingerprint(_ p1: Any) -> String {
      return L10n.tr("Localizable", "PasswordManager.CredentialUserNameWithFingerprint", String(describing: p1), fallback: "Encamera Recovery Key (%@)")
    }
    /// Save to Password Manager
    public static let saveButton = L10n.tr("Localizable", "PasswordManager.SaveButton", fallback: "Save to Password Manager")
    /// Your password manager didn't accept the recovery key. Copy it to the clipboard and save it manually instead.
    public static let saveFailedMessage = L10n.tr("Localizable", "PasswordManager.SaveFailedMessage", fallback: "Your password manager didn't accept the recovery key. Copy it to the clipboard and save it manually instead.")
    /// Couldn't Save Recovery Key
    public static let saveFailedTitle = L10n.tr("Localizable", "PasswordManager.SaveFailedTitle", fallback: "Couldn't Save Recovery Key")
  }
  public enum PaywallView {
    /// Encamera
    public static let appName = L10n.tr("Localizable", "PaywallView.AppName", fallback: "Encamera")
    /// CURRENT PLAN
    public static let currentPlan = L10n.tr("Localizable", "PaywallView.CurrentPlan", fallback: "CURRENT PLAN")
    /// Get %@
    public static func getButton(_ p1: Any) -> String {
      return L10n.tr("Localizable", "PaywallView.GetButton", String(describing: p1), fallback: "Get %@")
    }
    /// Premium
    public static let premium = L10n.tr("Localizable", "PaywallView.Premium", fallback: "Premium")
    /// Privacy Policy
    public static let privacyPolicy = L10n.tr("Localizable", "PaywallView.PrivacyPolicy", fallback: "Privacy Policy")
    /// Restore Purchases
    public static let restorePurchase = L10n.tr("Localizable", "PaywallView.RestorePurchase", fallback: "Restore Purchases")
    /// Billed yearly
    public static let unlimitedAnnualSubtext = L10n.tr("Localizable", "PaywallView.UnlimitedAnnualSubtext", fallback: "Billed yearly")
  }
  public enum PendingImport {
    /// This cancels the import of these items. Do you want to continue?
    public static let cancelConfirmMessage = L10n.tr("Localizable", "PendingImport.CancelConfirmMessage", fallback: "This cancels the import of these items. Do you want to continue?")
    /// Cancel Import?
    public static let cancelConfirmTitle = L10n.tr("Localizable", "PendingImport.CancelConfirmTitle", fallback: "Cancel Import?")
    /// Delete Items
    public static let deleteMedia = L10n.tr("Localizable", "PendingImport.DeleteMedia", fallback: "Delete Items")
    /// ./Encamera/MediaImport/PendingImportView.swift - Pending Import
    public static func description(_ p1: Int) -> String {
      return L10n.tr("Localizable", "PendingImport.Description", p1, fallback: "Choose an album to import %d items into")
    }
    /// Import & Encrypt
    public static let importButton = L10n.tr("Localizable", "PendingImport.ImportButton", fallback: "Import & Encrypt")
    /// Type to create or open
    public static let newOrHiddenAlbumSubtitle = L10n.tr("Localizable", "PendingImport.NewOrHiddenAlbumSubtitle", fallback: "Type to create or open")
    /// New or hidden album
    public static let newOrHiddenAlbumTitle = L10n.tr("Localizable", "PendingImport.NewOrHiddenAlbumTitle", fallback: "New or hidden album")
    /// Create an album to import into.
    public static let noAlbumsDescription = L10n.tr("Localizable", "PendingImport.NoAlbumsDescription", fallback: "Create an album to import into.")
  }
  public enum PhotoDeletion {
    /// Nothing was deleted from your Photos library.
    public static let cancelledMessage = L10n.tr("Localizable", "PhotoDeletion.CancelledMessage", fallback: "Nothing was deleted from your Photos library.")
    /// Couldn't delete from your Photos library: %@
    public static func failedMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "PhotoDeletion.FailedMessage", String(describing: p1), fallback: "Couldn't delete from your Photos library: %@")
    }
    /// Those photos could not be found in your Photos library. They may no longer be shared with Encamera.
    public static let notFoundMessage = L10n.tr("Localizable", "PhotoDeletion.NotFoundMessage", fallback: "Those photos could not be found in your Photos library. They may no longer be shared with Encamera.")
    /// ./Encamera/Utils/PhotoDeletionManager.swift
    public static let outcomeTitle = L10n.tr("Localizable", "PhotoDeletion.OutcomeTitle", fallback: "Delete from Photos Library")
    /// Deleted %@ from your Photos library. %@ could not be found — they may no longer be shared with Encamera.
    public static func partialMessage(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "PhotoDeletion.PartialMessage", String(describing: p1), String(describing: p2), fallback: "Deleted %@ from your Photos library. %@ could not be found — they may no longer be shared with Encamera.")
    }
  }
  public enum PostPurchaseView {
    /// Maybe Later
    public static let maybeLater = L10n.tr("Localizable", "PostPurchaseView.MaybeLater", fallback: "Maybe Later")
    /// Help us with a review
    public static let reviewButton = L10n.tr("Localizable", "PostPurchaseView.ReviewButton", fallback: "Help us with a review")
    /// You are one of the early supporters of Encamera and we thank you for the support!
    public static let subtext1 = L10n.tr("Localizable", "PostPurchaseView.Subtext1", fallback: "You are one of the early supporters of Encamera and we thank you for the support!")
    /// In the meantime, we would highly appreciate if you could help us with a Review on the App Store
    public static let subtext2 = L10n.tr("Localizable", "PostPurchaseView.Subtext2", fallback: "In the meantime, we would highly appreciate if you could help us with a Review on the App Store")
    /// Thanks for your purchase!
    public static let thanksForYourPurchase = L10n.tr("Localizable", "PostPurchaseView.ThanksForYourPurchase", fallback: "Thanks for your purchase!")
  }
  public enum ProgressView {
    /// File loaded successfully
    public static let fileLoadedSuccessfully = L10n.tr("Localizable", "ProgressView.FileLoadedSuccessfully", fallback: "File loaded successfully")
  }
  public enum PromptToErase {
    /// You can back up your recovery key in Settings before erasing.
    public static let backupReminder = L10n.tr("Localizable", "PromptToErase.BackupReminder", fallback: "You can back up your recovery key in Settings before erasing.")
    /// ./Encamera/Settings/PromptToErase.swift — prompt
    public static let question = L10n.tr("Localizable", "PromptToErase.Question", fallback: "Erase all Encamera data?")
    /// Every step is checked as it runs. Encamera restarts when the erase is finished.
    public static let restartNote = L10n.tr("Localizable", "PromptToErase.RestartNote", fallback: "Every step is checked as it runs. Encamera restarts when the erase is finished.")
    /// This will erase
    public static let willErase = L10n.tr("Localizable", "PromptToErase.WillErase", fallback: "This will erase")
    public enum Item {
      /// All your stored keys
      public static let keys = L10n.tr("Localizable", "PromptToErase.Item.Keys", fallback: "All your stored keys")
      /// Media stored on this device or in iCloud
      public static let media = L10n.tr("Localizable", "PromptToErase.Item.Media", fallback: "Media stored on this device or in iCloud")
      /// Your passcode
      public static let password = L10n.tr("Localizable", "PromptToErase.Item.Password", fallback: "Your passcode")
      /// App settings
      public static let settings = L10n.tr("Localizable", "PromptToErase.Item.Settings", fallback: "App settings")
    }
    public enum Reset {
      /// Resetting in %@
      public static func countdown(_ p1: Any) -> String {
        return L10n.tr("Localizable", "PromptToErase.Reset.Countdown", String(describing: p1), fallback: "Resetting in %@")
      }
      /// This removes your passcode, encryption keys and app settings from this device and every other device on your iCloud account.
      public static let explanation = L10n.tr("Localizable", "PromptToErase.Reset.Explanation", fallback: "This removes your passcode, encryption keys and app settings from this device and every other device on your iCloud account.")
      /// Hold to reset
      public static let hold = L10n.tr("Localizable", "PromptToErase.Reset.Hold", fallback: "Hold to reset")
      /// Your photos and videos are not deleted. To see them again, you'll need the recovery key for each encryption key.
      public static let mediaKept = L10n.tr("Localizable", "PromptToErase.Reset.MediaKept", fallback: "Your photos and videos are not deleted. To see them again, you'll need the recovery key for each encryption key.")
      /// Reset Encamera?
      public static let question = L10n.tr("Localizable", "PromptToErase.Reset.Question", fallback: "Reset Encamera?")
      /// Every step is checked as it runs. Encamera restarts when the reset is finished.
      public static let restartNote = L10n.tr("Localizable", "PromptToErase.Reset.RestartNote", fallback: "Every step is checked as it runs. Encamera restarts when the reset is finished.")
      /// ./Encamera/Settings/PromptToErase.swift — reset prompt, reachable before unlock
      public static let title = L10n.tr("Localizable", "PromptToErase.Reset.Title", fallback: "Reset Encamera")
    }
  }
  public enum ProtectionLevel {
    /// ./EncameraCore/Authentication/PasscodeType.swift
    public static let low = L10n.tr("Localizable", "ProtectionLevel.Low", fallback: "Low protection")
    /// Moderate protection
    public static let moderate = L10n.tr("Localizable", "ProtectionLevel.Moderate", fallback: "Moderate protection")
    /// Strong protection
    public static let strong = L10n.tr("Localizable", "ProtectionLevel.Strong", fallback: "Strong protection")
    /// Strongest protection
    public static let strongest = L10n.tr("Localizable", "ProtectionLevel.Strongest", fallback: "Strongest protection")
  }
  public enum PurchaseScreen {
    /// Unable to load plans
    public static let errorLoadingSubscriptions = L10n.tr("Localizable", "PurchaseScreen.ErrorLoadingSubscriptions", fallback: "Unable to load plans")
    /// Loading plans…
    public static let loadingSubscriptions = L10n.tr("Localizable", "PurchaseScreen.LoadingSubscriptions", fallback: "Loading plans…")
    /// Retry
    public static let retry = L10n.tr("Localizable", "PurchaseScreen.Retry", fallback: "Retry")
  }
  public enum RecoveryKey {
    public enum Intro {
      /// Your recovery key is needed to recover your media on a new device
      public static let row1 = L10n.tr("Localizable", "RecoveryKey.Intro.Row1", fallback: "Your recovery key is needed to recover your media on a new device")
      /// Keep it somewhere safe, like a password manager
      public static let row2 = L10n.tr("Localizable", "RecoveryKey.Intro.Row2", fallback: "Keep it somewhere safe, like a password manager")
      /// If you lose it, we can't recover your media for you
      public static let row3 = L10n.tr("Localizable", "RecoveryKey.Intro.Row3", fallback: "If you lose it, we can't recover your media for you")
      /// The save-recovery-key flow
      public static let title = L10n.tr("Localizable", "RecoveryKey.Intro.Title", fallback: "Save your recovery key")
    }
  }
  public enum RestoringFromICloud {
    /// ./Encamera/Components/RestoringFromiCloudView.swift - iCloud Keychain restore wait screen
    public static let finishingRestore = L10n.tr("Localizable", "RestoringFromICloud.FinishingRestore", fallback: "Finishing restore…")
  }
  public enum ReturningUser {
    /// We found Encamera data in your iCloud. Choose how you'd like to continue on this device.
    public static let body = L10n.tr("Localizable", "ReturningUser.Body", fallback: "We found Encamera data in your iCloud. Choose how you'd like to continue on this device.")
    /// I don't have my key
    public static let iDontHaveMyKey = L10n.tr("Localizable", "ReturningUser.IDontHaveMyKey", fallback: "I don't have my key")
    /// I have my key
    public static let iHaveMyKey = L10n.tr("Localizable", "ReturningUser.IHaveMyKey", fallback: "I have my key")
    /// It's on my other device
    public static let keyOnOtherDevice = L10n.tr("Localizable", "ReturningUser.KeyOnOtherDevice", fallback: "It's on my other device")
    /// Previously used on: %@
    public static func knownDevices(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ReturningUser.KnownDevices", String(describing: p1), fallback: "Previously used on: %@")
    }
    /// %d encrypted items found in iCloud
    public static func mediaCountCloud(_ p1: Int) -> String {
      return L10n.tr("Localizable", "ReturningUser.MediaCountCloud", p1, fallback: "%d encrypted items found in iCloud")
    }
    /// %d files found in iCloud Drive
    public static func mediaCountLegacy(_ p1: Int) -> String {
      return L10n.tr("Localizable", "ReturningUser.MediaCountLegacy", p1, fallback: "%d files found in iCloud Drive")
    }
    /// Set Up as a New Device
    public static let setUpAsNew = L10n.tr("Localizable", "ReturningUser.SetUpAsNew", fallback: "Set Up as a New Device")
    /// ./Encamera/Onboarding/OnboardingHostingView.swift - Returning-user branch screen (ENC-91). Placeholder copy pending design (ENC-75).
    public static let title = L10n.tr("Localizable", "ReturningUser.Title", fallback: "You've used Encamera before")
    public enum Destructive {
      /// Continue
      public static let `continue` = L10n.tr("Localizable", "ReturningUser.Destructive.Continue", fallback: "Continue")
      /// Deleting your iCloud data…
      public static let deleting = L10n.tr("Localizable", "ReturningUser.Destructive.Deleting", fallback: "Deleting your iCloud data…")
      /// You're about to remove the Encamera data stored in your iCloud. Review what will be deleted before you continue.
      public static let existsBody = L10n.tr("Localizable", "ReturningUser.Destructive.ExistsBody", fallback: "You're about to remove the Encamera data stored in your iCloud. Review what will be deleted before you continue.")
      /// ./Encamera/Onboarding/OnboardingHostingView.swift - Destructive delete-my-iCloud-data path (ENC-94). Escalating confirmation, then hold-to-delete. Placeholder copy pending design (ENC-101/102).
      public static let existsTitle = L10n.tr("Localizable", "ReturningUser.Destructive.ExistsTitle", fallback: "Erase iCloud Data")
      /// Something went wrong and the deletion did not finish. Your iCloud data has not been fully deleted. Please try again.
      public static let failedBody = L10n.tr("Localizable", "ReturningUser.Destructive.FailedBody", fallback: "Something went wrong and the deletion did not finish. Your iCloud data has not been fully deleted. Please try again.")
      /// This data was created on another device.
      public static let genericScope = L10n.tr("Localizable", "ReturningUser.Destructive.GenericScope", fallback: "This data was created on another device.")
      /// Hold the button to permanently delete your iCloud data. This is your last chance to cancel.
      public static let holdBody = L10n.tr("Localizable", "ReturningUser.Destructive.HoldBody", fallback: "Hold the button to permanently delete your iCloud data. This is your last chance to cancel.")
      /// Hold to Delete
      public static let holdButton = L10n.tr("Localizable", "ReturningUser.Destructive.HoldButton", fallback: "Hold to Delete")
      /// Deleting in %d
      public static func holdCountdown(_ p1: Int) -> String {
        return L10n.tr("Localizable", "ReturningUser.Destructive.HoldCountdown", p1, fallback: "Deleting in %d")
      }
      /// Erase iCloud Data
      public static let holdTitle = L10n.tr("Localizable", "ReturningUser.Destructive.HoldTitle", fallback: "Erase iCloud Data")
      /// You must be online to delete your iCloud data. Connect to the internet and try again.
      public static let offline = L10n.tr("Localizable", "ReturningUser.Destructive.Offline", fallback: "You must be online to delete your iCloud data. Connect to the internet and try again.")
      /// Some of your data could not be deleted and still remains in iCloud. No new key was created. Please try again to finish deleting.
      public static let partialFailureBody = L10n.tr("Localizable", "ReturningUser.Destructive.PartialFailureBody", fallback: "Some of your data could not be deleted and still remains in iCloud. No new key was created. Please try again to finish deleting.")
      /// There is no recovery and no support path — like a crypto wallet, once this data is gone it is gone forever. Only continue if you are certain you cannot recover your key.
      public static let warningBody = L10n.tr("Localizable", "ReturningUser.Destructive.WarningBody", fallback: "There is no recovery and no support path — like a crypto wallet, once this data is gone it is gone forever. Only continue if you are certain you cannot recover your key.")
      /// This cannot be undone
      public static let warningTitle = L10n.tr("Localizable", "ReturningUser.Destructive.WarningTitle", fallback: "This cannot be undone")
    }
  }
  public enum Settings {
    /// Back Up Recovery Key
    public static let backupKeyPhrase = L10n.tr("Localizable", "Settings.BackupKeyPhrase", fallback: "Back Up Recovery Key")
    /// Banners Cleared
    public static let bannersCleared = L10n.tr("Localizable", "Settings.BannersCleared", fallback: "Banners Cleared")
    /// All dismissed banners have been reset and will appear again.
    public static let bannersClearedMessage = L10n.tr("Localizable", "Settings.BannersClearedMessage", fallback: "All dismissed banners have been reset and will appear again.")
    /// Reset Banners
    public static let clearDismissedBanners = L10n.tr("Localizable", "Settings.ClearDismissedBanners", fallback: "Reset Banners")
    /// Upgrade iCloud albums
    public static let cloudKitUpgradeRow = L10n.tr("Localizable", "Settings.CloudKitUpgradeRow", fallback: "Upgrade iCloud albums")
    /// Contact Support
    public static let contact = L10n.tr("Localizable", "Settings.Contact", fallback: "Contact Support")
    /// Copied to clipboard
    public static let copiedToClipboard = L10n.tr("Localizable", "Settings.CopiedToClipboard", fallback: "Copied to clipboard")
    /// Default Storage
    public static let defaultStorageOption = L10n.tr("Localizable", "Settings.DefaultStorageOption", fallback: "Default Storage")
    /// Give Instant Feedback
    public static let giveInstantFeedback = L10n.tr("Localizable", "Settings.GiveInstantFeedback", fallback: "Give Instant Feedback")
    /// Hidden Albums
    public static let hiddenAlbums = L10n.tr("Localizable", "Settings.HiddenAlbums", fallback: "Hidden Albums")
    /// iCloud Backup & Sync
    public static let iCloudBackupAndSync = L10n.tr("Localizable", "Settings.ICloudBackupAndSync", fallback: "iCloud Backup & Sync")
    /// Import Photo Metadata
    public static let importMediaMetadata = L10n.tr("Localizable", "Settings.ImportMediaMetadata", fallback: "Import Photo Metadata")
    /// Loop Videos
    public static let loopVideos = L10n.tr("Localizable", "Settings.LoopVideos", fallback: "Loop Videos")
    /// Purchases restored!
    public static let purchasesRestored = L10n.tr("Localizable", "Settings.PurchasesRestored", fallback: "Purchases restored!")
    /// Any valid purchases you made have been restored.
    public static let purchasesRestoredMessage = L10n.tr("Localizable", "Settings.PurchasesRestoredMessage", fallback: "Any valid purchases you made have been restored.")
    /// Could not restore purchases
    public static let purchasesRestoreFailed = L10n.tr("Localizable", "Settings.PurchasesRestoreFailed", fallback: "Could not restore purchases")
    /// Could not restore your purchases. Please try again or contact support.
    public static let purchasesRestoreFailedMessage = L10n.tr("Localizable", "Settings.PurchasesRestoreFailedMessage", fallback: "Could not restore your purchases. Please try again or contact support.")
    /// RevenueCat Customer ID
    public static let revenueCatCustomerId = L10n.tr("Localizable", "Settings.RevenueCatCustomerId", fallback: "RevenueCat Customer ID")
    /// Show Hidden Albums in Camera
    public static let showHiddenAlbumsInCameraPicker = L10n.tr("Localizable", "Settings.ShowHiddenAlbumsInCameraPicker", fallback: "Show Hidden Albums in Camera")
    /// Version
    public static let version = L10n.tr("Localizable", "Settings.Version", fallback: "Version")
    public enum HiddenAlbumsModal {
      /// %@ ALBUMS
      public static func albumsCount(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Settings.HiddenAlbumsModal.AlbumsCount", String(describing: p1), fallback: "%@ ALBUMS")
      }
      /// Access them by creating a new album with the exact same name
      public static let subtitle = L10n.tr("Localizable", "Settings.HiddenAlbumsModal.Subtitle", fallback: "Access them by creating a new album with the exact same name")
      /// Your hidden albums
      public static let title = L10n.tr("Localizable", "Settings.HiddenAlbumsModal.Title", fallback: "Your hidden albums")
    }
    public enum ICloudBackupAndSync {
      /// Turn On
      public static let confirmationEnable = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.ConfirmationEnable", fallback: "Turn On")
      /// Not Now
      public static let confirmationLater = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.ConfirmationLater", fallback: "Not Now")
      /// Enjoy Encamera seamlessly across all your devices using this iCloud account
      public static let confirmationRow1 = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.ConfirmationRow1", fallback: "Enjoy Encamera seamlessly across all your devices using this iCloud account")
      /// Use the same unlock method on all your devices
      public static let confirmationRow2 = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.ConfirmationRow2", fallback: "Use the same unlock method on all your devices")
      /// Your encryption key and passcode are stored in iCloud Keychain
      public static let confirmationRow3 = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.ConfirmationRow3", fallback: "Your encryption key and passcode are stored in iCloud Keychain")
      /// Back up and sync your key and passcode with iCloud
      public static let confirmationTitle = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.ConfirmationTitle", fallback: "Back up and sync your key and passcode with iCloud")
      /// Turning off iCloud Backup & Sync removes your key and passcode from your iCloud Keychain. This device keeps its copy. Any other device that only had the iCloud copy — including %@ — will no longer be able to open your photos.
      public static func disableDevicesWarning(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Settings.ICloudBackupAndSync.DisableDevicesWarning", String(describing: p1), fallback: "Turning off iCloud Backup & Sync removes your key and passcode from your iCloud Keychain. This device keeps its copy. Any other device that only had the iCloud copy — including %@ — will no longer be able to open your photos.")
      }
      /// Turning off iCloud Backup & Sync removes your key and passcode from your iCloud Keychain. This device keeps its copy. Any other device that only had the iCloud copy will no longer be able to open your photos.
      public static let disableGenericWarning = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.DisableGenericWarning", fallback: "Turning off iCloud Backup & Sync removes your key and passcode from your iCloud Keychain. This device keeps its copy. Any other device that only had the iCloud copy will no longer be able to open your photos.")
      /// iCloud Backup & Sync could not be changed. Your key and passcode were left as they were, and the switch has been set back to the real setting.
      public static let flipFailed = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.FlipFailed", fallback: "iCloud Backup & Sync could not be changed. Your key and passcode were left as they were, and the switch has been set back to the real setting.")
      /// Move to iCloud
      public static let migrateAlbumsConfirm = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.MigrateAlbumsConfirm", fallback: "Move to iCloud")
      /// These albums are still stored only on this device: %@. Your photos are safe — open an album to try moving it again.
      public static func migrateAlbumsFailedMessage(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Settings.ICloudBackupAndSync.MigrateAlbumsFailedMessage", String(describing: p1), fallback: "These albums are still stored only on this device: %@. Your photos are safe — open an album to try moving it again.")
      }
      /// Some albums didn't move
      public static let migrateAlbumsFailedTitle = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.MigrateAlbumsFailedTitle", fallback: "Some albums didn't move")
      /// %d of your albums are stored only on this device. Moving them to iCloud lets your other devices see them. You can leave them here and move them later instead.
      public static func migrateAlbumsMessage(_ p1: Int) -> String {
        return L10n.tr("Localizable", "Settings.ICloudBackupAndSync.MigrateAlbumsMessage", p1, fallback: "%d of your albums are stored only on this device. Moving them to iCloud lets your other devices see them. You can leave them here and move them later instead.")
      }
      /// Keep on This Device
      public static let migrateAlbumsSkip = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.MigrateAlbumsSkip", fallback: "Keep on This Device")
      /// Move your albums to iCloud?
      public static let migrateAlbumsTitle = L10n.tr("Localizable", "Settings.ICloudBackupAndSync.MigrateAlbumsTitle", fallback: "Move your albums to iCloud?")
    }
  }
  public enum SettingsView {
    /// ./Encamera/Settings/SettingsView.swift
    public static let unknownError = L10n.tr("Localizable", "SettingsView.UnknownError", fallback: "Unknown error")
    public enum SectionHeader {
      /// ABOUT
      public static let about = L10n.tr("Localizable", "SettingsView.SectionHeader.About", fallback: "ABOUT")
      /// APPEARANCE
      public static let appearance = L10n.tr("Localizable", "SettingsView.SectionHeader.Appearance", fallback: "APPEARANCE")
      /// CAMERA & PLAYBACK
      public static let cameraAndPlayback = L10n.tr("Localizable", "SettingsView.SectionHeader.CameraAndPlayback", fallback: "CAMERA & PLAYBACK")
      /// DANGER ZONE
      public static let dangerZone = L10n.tr("Localizable", "SettingsView.SectionHeader.DangerZone", fallback: "DANGER ZONE")
      /// DEBUG
      public static let debug = L10n.tr("Localizable", "SettingsView.SectionHeader.Debug", fallback: "DEBUG")
      /// HELP & FEEDBACK
      public static let helpAndFeedback = L10n.tr("Localizable", "SettingsView.SectionHeader.HelpAndFeedback", fallback: "HELP & FEEDBACK")
      /// PREMIUM
      public static let premiumPlan = L10n.tr("Localizable", "SettingsView.SectionHeader.PremiumPlan", fallback: "PREMIUM")
      /// SECURITY & PRIVACY
      public static let securityAndPrivacy = L10n.tr("Localizable", "SettingsView.SectionHeader.SecurityAndPrivacy", fallback: "SECURITY & PRIVACY")
      /// STORAGE
      public static let storage = L10n.tr("Localizable", "SettingsView.SectionHeader.Storage", fallback: "STORAGE")
    }
  }
  public enum SplashScreen {
    /// Secure Your Memories
    public static let subline = L10n.tr("Localizable", "SplashScreen.Subline", fallback: "Secure Your Memories")
  }
  public enum StorageInsights {
    /// Downloaded from iCloud
    public static let cachedCloud = L10n.tr("Localizable", "StorageInsights.CachedCloud", fallback: "Downloaded from iCloud")
    /// %@ can be freed
    public static func canBeFreed(_ p1: Any) -> String {
      return L10n.tr("Localizable", "StorageInsights.CanBeFreed", String(describing: p1), fallback: "%@ can be freed")
    }
    /// Free Up %@
    public static func clearUp(_ p1: Any) -> String {
      return L10n.tr("Localizable", "StorageInsights.ClearUp", String(describing: p1), fallback: "Free Up %@")
    }
    /// Photos and videos in iCloud albums will show up here.
    public static let cloudEmptySubtitle = L10n.tr("Localizable", "StorageInsights.CloudEmptySubtitle", fallback: "Photos and videos in iCloud albums will show up here.")
    /// Nothing in iCloud yet
    public static let cloudEmptyTitle = L10n.tr("Localizable", "StorageInsights.CloudEmptyTitle", fallback: "Nothing in iCloud yet")
    /// Photos you take or import will show up here.
    public static let emptySubtitle = L10n.tr("Localizable", "StorageInsights.EmptySubtitle", fallback: "Photos you take or import will show up here.")
    /// Nothing stored on this device yet
    public static let emptyTitle = L10n.tr("Localizable", "StorageInsights.EmptyTitle", fallback: "Nothing stored on this device yet")
    /// Couldn't measure storage
    public static let errorTitle = L10n.tr("Localizable", "StorageInsights.ErrorTitle", fallback: "Couldn't measure storage")
    /// %@ is now available. Your photos and videos are untouched.
    public static func freedMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "StorageInsights.FreedMessage", String(describing: p1), fallback: "%@ is now available. Your photos and videos are untouched.")
    }
    /// Space freed
    public static let freedTitle = L10n.tr("Localizable", "StorageInsights.FreedTitle", fallback: "Space freed")
    /// Freeing up space…
    public static let freeing = L10n.tr("Localizable", "StorageInsights.Freeing", fallback: "Freeing up space…")
    /// ./Encamera/Settings/StorageInsightsView.swift - Free up space action
    public static let freeUpSpace = L10n.tr("Localizable", "StorageInsights.FreeUpSpace", fallback: "Free Up Space")
    /// Free Up Space
    public static let freeUpSpaceConfirm = L10n.tr("Localizable", "StorageInsights.FreeUpSpaceConfirm", fallback: "Free Up Space")
    /// Some downloaded copies couldn't be removed. Nothing was deleted from your photos or videos.
    public static let freeUpSpaceFailedMessage = L10n.tr("Localizable", "StorageInsights.FreeUpSpaceFailedMessage", fallback: "Some downloaded copies couldn't be removed. Nothing was deleted from your photos or videos.")
    /// Couldn't free up space
    public static let freeUpSpaceFailedTitle = L10n.tr("Localizable", "StorageInsights.FreeUpSpaceFailedTitle", fallback: "Couldn't free up space")
    /// This removes downloaded copies of media that is also stored in iCloud. None of your photos or videos are deleted — anything you open next will download again from iCloud.
    public static let freeUpSpaceMessage = L10n.tr("Localizable", "StorageInsights.FreeUpSpaceMessage", fallback: "This removes downloaded copies of media that is also stored in iCloud. None of your photos or videos are deleted — anything you open next will download again from iCloud.")
    /// Free up %@?
    public static func freeUpSpaceTitle(_ p1: Any) -> String {
      return L10n.tr("Localizable", "StorageInsights.FreeUpSpaceTitle", String(describing: p1), fallback: "Free up %@?")
    }
    /// Unavailable
    public static let iCloudUnavailable = L10n.tr("Localizable", "StorageInsights.ICloudUnavailable", fallback: "Unavailable")
    /// Sign in to iCloud to see how much is stored there.
    public static let iCloudUnavailableCaption = L10n.tr("Localizable", "StorageInsights.ICloudUnavailableCaption", fallback: "Sign in to iCloud to see how much is stored there.")
    /// Album indexes
    public static let indexes = L10n.tr("Localizable", "StorageInsights.Indexes", fallback: "Album indexes")
    /// In iCloud
    public static let inICloud = L10n.tr("Localizable", "StorageInsights.InICloud", fallback: "In iCloud")
    /// %d legacy iCloud Drive album(s) are managed by iOS; their downloaded copies aren't included here.
    public static func legacyFootnote(_ p1: Int) -> String {
      return L10n.tr("Localizable", "StorageInsights.LegacyFootnote", p1, fallback: "%d legacy iCloud Drive album(s) are managed by iOS; their downloaded copies aren't included here.")
    }
    /// Measuring…
    public static let measuring = L10n.tr("Localizable", "StorageInsights.Measuring", fallback: "Measuring…")
    /// None can be freed
    public static let nothingToFree = L10n.tr("Localizable", "StorageInsights.NothingToFree", fallback: "None can be freed")
    /// On this device
    public static let onThisDevice = L10n.tr("Localizable", "StorageInsights.OnThisDevice", fallback: "On this device")
    /// Photos
    public static let photos = L10n.tr("Localizable", "StorageInsights.Photos", fallback: "Photos")
    /// Can Be Freed
    public static let reclaimable = L10n.tr("Localizable", "StorageInsights.Reclaimable", fallback: "Can Be Freed")
    /// Try Again
    public static let retry = L10n.tr("Localizable", "StorageInsights.Retry", fallback: "Try Again")
    /// Encamera Storage
    public static let settingsRow = L10n.tr("Localizable", "StorageInsights.SettingsRow", fallback: "Encamera Storage")
    /// Thumbnails
    public static let thumbnails = L10n.tr("Localizable", "StorageInsights.Thumbnails", fallback: "Thumbnails")
    /// ./Encamera/Settings/StorageInsightsView.swift - Storage Insights screen
    public static let title = L10n.tr("Localizable", "StorageInsights.Title", fallback: "Storage")
    /// Videos
    public static let videos = L10n.tr("Localizable", "StorageInsights.Videos", fallback: "Videos")
  }
  public enum StorageOption {
    /// %@
    public static func storage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "StorageOption.Storage", String(describing: p1), fallback: "%@")
    }
  }
  public enum StorageType {
    /// iCloud Drive
    public static let iCloudDriveLegacyLocationName = L10n.tr("Localizable", "StorageType.ICloudDriveLegacyLocationName", fallback: "iCloud Drive")
    /// iCloud Drive (Legacy)
    public static let iCloudDriveLegacyTitle = L10n.tr("Localizable", "StorageType.ICloudDriveLegacyTitle", fallback: "iCloud Drive (Legacy)")
    /// Save to iCloud
    public static let saveToICloud = L10n.tr("Localizable", "StorageType.SaveToICloud", fallback: "Save to iCloud")
  }
  public enum SyncStatusBar {
    /// Checking iCloud for changes
    public static let checking = L10n.tr("Localizable", "SyncStatusBar.Checking", fallback: "Checking iCloud for changes")
    /// %d items could not be uploaded
    public static func stalled(_ p1: Int) -> String {
      return L10n.tr("Localizable", "SyncStatusBar.Stalled", p1, fallback: "%d items could not be uploaded")
    }
    /// iCloud storage is full. Free up space to keep syncing.
    public static let storageFull = L10n.tr("Localizable", "SyncStatusBar.StorageFull", fallback: "iCloud storage is full. Free up space to keep syncing.")
    /// iCloud storage is full. %d items are waiting to upload.
    public static func storageFullStalled(_ p1: Int) -> String {
      return L10n.tr("Localizable", "SyncStatusBar.StorageFullStalled", p1, fallback: "iCloud storage is full. %d items are waiting to upload.")
    }
    /// ./Encamera/Components/SyncStatusBar.swift
    public static let title = L10n.tr("Localizable", "SyncStatusBar.Title", fallback: "iCloud")
    /// Can't reach iCloud
    public static let unreachable = L10n.tr("Localizable", "SyncStatusBar.Unreachable", fallback: "Can't reach iCloud")
    /// Uploading %d of %d to iCloud
    public static func uploading(_ p1: Int, _ p2: Int) -> String {
      return L10n.tr("Localizable", "SyncStatusBar.Uploading", p1, p2, fallback: "Uploading %d of %d to iCloud")
    }
    /// iCloud synced
    public static let upToDate = L10n.tr("Localizable", "SyncStatusBar.UpToDate", fallback: "iCloud synced")
  }
  public enum TaskDetailCard {
    /// Please grant access to your Photos library in Settings to delete imported photos.
    public static let grantAccessMessage = L10n.tr("Localizable", "TaskDetailCard.GrantAccessMessage", fallback: "Please grant access to your Photos library in Settings to delete imported photos.")
    /// Limited Photo Access
    public static let limitedAccessInfo = L10n.tr("Localizable", "TaskDetailCard.LimitedAccessInfo", fallback: "Limited Photo Access")
    /// With limited photo access, only photos you've selected can be deleted. To delete all imported photos, please grant full Photos library access in Settings.
    public static let limitedAccessMessage = L10n.tr("Localizable", "TaskDetailCard.LimitedAccessMessage", fallback: "With limited photo access, only photos you've selected can be deleted. To delete all imported photos, please grant full Photos library access in Settings.")
    /// ./Encamera/Components/ImportProgress/TaskDetailCard.swift
    public static let photoLibraryAccessRequired = L10n.tr("Localizable", "TaskDetailCard.PhotoLibraryAccessRequired", fallback: "Photos Access Needed")
    /// Canceled
    public static let statusCancelled = L10n.tr("Localizable", "TaskDetailCard.StatusCancelled", fallback: "Canceled")
  }
  public enum VerticalPaywall {
    /// Annual
    public static let annualPlanName = L10n.tr("Localizable", "VerticalPaywall.annualPlanName", fallback: "Annual")
    /// Billed monthly
    public static let billedMonthly = L10n.tr("Localizable", "VerticalPaywall.billedMonthly", fallback: "Billed monthly")
    /// Lifetime
    public static let lifetimePlanName = L10n.tr("Localizable", "VerticalPaywall.lifetimePlanName", fallback: "Lifetime")
    /// Monthly
    public static let monthlyPlanName = L10n.tr("Localizable", "VerticalPaywall.monthlyPlanName", fallback: "Monthly")
    /// %@ / month
    public static func monthlyPriceSubtext(_ p1: Any) -> String {
      return L10n.tr("Localizable", "VerticalPaywall.monthlyPriceSubtext", String(describing: p1), fallback: "%@ / month")
    }
    /// No payment due now
    public static let noPaymentDueNow = L10n.tr("Localizable", "VerticalPaywall.noPaymentDueNow", fallback: "No payment due now")
    /// Pay once, access forever
    public static let payOnceAccessForever = L10n.tr("Localizable", "VerticalPaywall.payOnceAccessForever", fallback: "Pay once, access forever")
    /// Start Free Trial
    public static let startFreeTrial = L10n.tr("Localizable", "VerticalPaywall.startFreeTrial", fallback: "Start Free Trial")
    /// Keep all your photos and videos in Encamera with unlimited, automatic encryption.
    public static let subtitle = L10n.tr("Localizable", "VerticalPaywall.subtitle", fallback: "Keep all your photos and videos in Encamera with unlimited, automatic encryption.")
    /// ./Encamera/Store/VerticalPaywall/VerticalPaywallView.swift - Vertical paywall layout (ENC-282)
    public static let title = L10n.tr("Localizable", "VerticalPaywall.title", fallback: "Encrypt Everything")
  }
  public enum ZipExport {
    /// Cancel
    public static let cancel = L10n.tr("Localizable", "ZipExport.Cancel", fallback: "Cancel")
    /// Close
    public static let close = L10n.tr("Localizable", "ZipExport.Close", fallback: "Close")
    /// Zip file ready!
    public static let complete = L10n.tr("Localizable", "ZipExport.Complete", fallback: "Zip file ready!")
    /// Compressing files…
    public static let compressing = L10n.tr("Localizable", "ZipExport.Compressing", fallback: "Compressing files…")
    /// Confirm Password
    public static let confirmPassword = L10n.tr("Localizable", "ZipExport.ConfirmPassword", fallback: "Confirm Password")
    /// Continue
    public static let `continue` = L10n.tr("Localizable", "ZipExport.Continue", fallback: "Continue")
    /// Decrypting %@ of %@…
    public static func decrypting(_ p1: Any, _ p2: Any) -> String {
      return L10n.tr("Localizable", "ZipExport.Decrypting", String(describing: p1), String(describing: p2), fallback: "Decrypting %@ of %@…")
    }
    /// Enter Password
    public static let enterPassword = L10n.tr("Localizable", "ZipExport.EnterPassword", fallback: "Enter Password")
    /// Error creating zip: %@
    public static func error(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ZipExport.Error", String(describing: p1), fallback: "Error creating zip: %@")
    }
    /// Keep your device unlocked until this finishes.
    public static let keepPhoneOpen = L10n.tr("Localizable", "ZipExport.KeepPhoneOpen", fallback: "Keep your device unlocked until this finishes.")
    /// Passwords do not match
    public static let passwordMismatch = L10n.tr("Localizable", "ZipExport.PasswordMismatch", fallback: "Passwords do not match")
    /// Zip file password
    public static let passwordPlaceholder = L10n.tr("Localizable", "ZipExport.PasswordPlaceholder", fallback: "Zip file password")
    /// Preparing Encrypted Zip
    public static let preparing = L10n.tr("Localizable", "ZipExport.Preparing", fallback: "Preparing Encrypted Zip")
    /// ZipExport - Encrypted Zip Export Feature
    public static let shareDecrypted = L10n.tr("Localizable", "ZipExport.ShareDecrypted", fallback: "Share Decrypted")
    /// Share as Encrypted Zip
    public static let shareEncryptedZip = L10n.tr("Localizable", "ZipExport.ShareEncryptedZip", fallback: "Share as Encrypted Zip")
    /// Share Zip
    public static let shareZip = L10n.tr("Localizable", "ZipExport.ShareZip", fallback: "Share Zip")
  }
  public enum ZipExportError {
    /// Export was interrupted because Encamera was in the background too long. Please return to Encamera and try again.
    public static let backgroundTimeExpired = L10n.tr("Localizable", "ZipExportError.BackgroundTimeExpired", fallback: "Export was interrupted because Encamera was in the background too long. Please return to Encamera and try again.")
    /// Failed to decrypt media: %@
    public static func decryptionFailed(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ZipExportError.DecryptionFailed", String(describing: p1), fallback: "Failed to decrypt media: %@")
    }
    /// Failed to create export directory: %@
    public static func directoryCreationFailed(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ZipExportError.DirectoryCreationFailed", String(describing: p1), fallback: "Failed to create export directory: %@")
    }
    /// Password cannot be empty.
    public static let emptyPassword = L10n.tr("Localizable", "ZipExportError.EmptyPassword", fallback: "Password cannot be empty.")
    /// ZipExport Error Messages
    public static let noMediaToExport = L10n.tr("Localizable", "ZipExportError.NoMediaToExport", fallback: "No media selected for export.")
    /// Failed to create zip file: %@
    public static func zipCreationFailed(_ p1: Any) -> String {
      return L10n.tr("Localizable", "ZipExportError.ZipCreationFailed", String(describing: p1), fallback: "Failed to create zip file: %@")
    }
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
