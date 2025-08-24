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
  /// Plural format key: "%#@image_count@"
  public static func imageS(_ p1: Int) -> String {
    return L10n.tr("Localizable", "%@ Image(s)", p1, fallback: "Plural format key: \"%#@image_count@\"")
  }
  /// ./EncameraCore/Utils/SettingsManager.swift
  public static func mustBeSet(_ p1: Any) -> String {
    return L10n.tr("Localizable", "%@ must be set", String(describing: p1), fallback: "%@ must be set")
  }
  /// Plural format key: "%#@photo_count@"
  public static func photoSLeft(_ p1: Int) -> String {
    return L10n.tr("Localizable", "%@ Photo(s) Left", p1, fallback: "Plural format key: \"%#@photo_count@\"")
  }
  /// Plural format key: "%#@video_count@"
  public static func videoS(_ p1: Int) -> String {
    return L10n.tr("Localizable", "%@ Video(s)", p1, fallback: "Plural format key: \"%#@video_count@\"")
  }
  /// ./Encamera/Store/PurchaseUpgradeOptionsListView.swift
  public static func purchased(_ p1: Any) -> String {
    return L10n.tr("Localizable", "**Purchased: %@**", String(describing: p1), fallback: "**Purchased: %@**")
  }
  /// A key with this name already exists.
  public static let aKeyWithThisNameAlreadyExists = L10n.tr("Localizable", "A key with this name already exists.", fallback: "A key with this name already exists.")
  /// ./Encamera/Camera/AlertError.swift
  public static let accept = L10n.tr("Localizable", "Accept", fallback: "Accept")
  /// Active
  public static let active = L10n.tr("Localizable", "Active", fallback: "Active")
  /// ./Encamera/KeyManagement/AlbumList.swift
  public static let addExistingKey = L10n.tr("Localizable", "Add Existing Key", fallback: "Add Existing Key")
  /// ./Encamera/KeyManagement/KeyOperationCell.swift
  public static let addKey = L10n.tr("Localizable", "Add Key", fallback: "Add Key")
  /// Add Permissions
  public static let addPermissions = L10n.tr("Localizable", "Add Permissions", fallback: "Add Permissions")
  /// Add Photos
  public static let addPhotos = L10n.tr("Localizable", "AddPhotos", fallback: "Add Photos")
  /// ADD PHOTOS TO THIS ALBUM
  public static let addPhotosToThisAlbum = L10n.tr("Localizable", "AddPhotosToThisAlbum", fallback: "ADD PHOTOS TO THIS ALBUM")
  /// An album with that name already exists.
  public static let albumExistsError = L10n.tr("Localizable", "AlbumExistsError", fallback: "An album with that name already exists.")
  /// Album Name
  public static let albumName = L10n.tr("Localizable", "AlbumName", fallback: "Album Name")
  /// Album name must be longer than 1 character
  public static let albumNameInvalid = L10n.tr("Localizable", "AlbumNameInvalid", fallback: "Album name must be longer than 1 character")
  /// AlbumManager
  public static let albumNotFoundAtSourceLocation = L10n.tr("Localizable", "AlbumNotFoundAtSourceLocation", fallback: "Could not find the album at the source location. Use the Files app to ensure that it exists.")
  /// AlbumGrid
  public static let albumsTitle = L10n.tr("Localizable", "AlbumsTitle", fallback: "Albums")
  /// Are you sure you want to erase ALL ENCAMERA DATA?
  /// 
  /// THIS WILL ERASE:
  /// 
  /// • ALL your stored keys 🔑
  /// • Your password 🔐
  /// • App settings 🎛
  /// • MEDIA YOU HAVE STORED LOCALLY OR ON iCLOUD
  /// 
  /// You can create a backup of your keys from the key management screen.
  /// 
  /// The app will quit after erase is finished.
  public static let allDataExplanation = L10n.tr("Localizable", "allDataExplanation", fallback: "Are you sure you want to erase ALL ENCAMERA DATA?\n\nTHIS WILL ERASE:\n\n• ALL your stored keys 🔑\n• Your password 🔐\n• App settings 🎛\n• MEDIA YOU HAVE STORED LOCALLY OR ON iCLOUD\n\nYou can create a backup of your keys from the key management screen.\n\nThe app will quit after erase is finished.")
  /// Are you sure you want to erase ALL app data?
  /// 
  /// THIS WILL ERASE:
  /// 
  /// • ALL your stored keys 🔑
  /// • Your password 🔐
  /// • App settings 🎛
  /// 
  /// THIS WILL NOT ERASE:
  /// 
  /// • Media you have stored locally or on iCloud
  /// 
  /// You can create a backup of your keys from the key management screen.
  /// 
  /// The app will quit after erase is finished.
  /// 
  /// 
  public static let appDataExplanation = L10n.tr("Localizable", "appDataExplanation", fallback: "Are you sure you want to erase ALL app data?\n\nTHIS WILL ERASE:\n\n• ALL your stored keys 🔑\n• Your password 🔐\n• App settings 🎛\n\nTHIS WILL NOT ERASE:\n\n• Media you have stored locally or on iCloud\n\nYou can create a backup of your keys from the key management screen.\n\nThe app will quit after erase is finished.\n\n")
  /// Passcode Options
  public static let authenticationMethod = L10n.tr("Localizable", "AuthenticationMethod", fallback: "Passcode Options")
  /// Back to album
  public static let backToAlbum = L10n.tr("Localizable", "Back to album", fallback: "Back to album")
  /// Back Up Key
  public static let backUpKey = L10n.tr("Localizable", "Back Up Key", fallback: "Back Up Key")
  /// Backup Keys
  public static let backupKeys = L10n.tr("Localizable", "Backup Keys", fallback: "Backup Keys")
  /// If you lose your key, it is impossible to recover your data. Back up your keys to a password manager after you create them, or save them to iCloud.
  public static let backUpKeysExplanation = L10n.tr("Localizable", "BackUpKeysExplanation", fallback: "If you lose your key, it is impossible to recover your data. Back up your keys to a password manager after you create them, or save them to iCloud.")
  /// Back up those keys!
  public static let backUpKeysHeader = L10n.tr("Localizable", "BackUpKeysHeader", fallback: "Back up those keys!")
  /// Biometrics failed
  public static let biometricsFailed = L10n.tr("Localizable", "Biometrics failed", fallback: "Biometrics failed")
  /// Biometrics unavailable
  public static let biometricsUnavailable = L10n.tr("Localizable", "Biometrics unavailable", fallback: "Biometrics unavailable")
  /// Buy once. Use forever.
  public static let buyOnceUseForever = L10n.tr("Localizable", "BuyOnceUseForever", fallback: "Buy once. Use forever.")
  /// Cancel
  public static let cancel = L10n.tr("Localizable", "Cancel", fallback: "Cancel")
  /// ShareViewController.swift
  public static let cannotHandleMedia = L10n.tr("Localizable", "Cannot handle media", fallback: "Cannot handle media")
  /// You cannot clear your passcode. You must have Face ID enabled in order to do this.
  public static let cannotClearMessage = L10n.tr("Localizable", "CannotClearMessage", fallback: "You cannot clear your passcode. You must have Face ID enabled in order to do this.")
  /// Cannot Clear Alert
  public static let cannotClearTitle = L10n.tr("Localizable", "CannotClearTitle", fallback: "Cannot Clear")
  /// Change Authentication Method
  public static let changeAuthenticationMethod = L10n.tr("Localizable", "Change Authentication Method", fallback: "Change Authentication Method")
  /// I Want to Choose Another Destination Album
  public static let changeKeyAlbum = L10n.tr("Localizable", "Change Key Album", fallback: "I Want to Choose Another Destination Album")
  /// Change Password
  public static let changePassword = L10n.tr("Localizable", "Change Password", fallback: "Change Password")
  /// Change Passcode
  public static let changePasscode = L10n.tr("Localizable", "ChangePasscode", fallback: "Change Passcode")
  /// Check that the same key that was used to encrypt this media is set as the active key.
  public static let checkThatTheSameKeyThatWasUsedToEncryptThisMediaIsSetAsTheActiveKey = L10n.tr("Localizable", "Check that the same key that was used to encrypt this media is set as the active key.", fallback: "Check that the same key that was used to encrypt this media is set as the active key.")
  /// Choose your login method
  public static let chooseYourLoginMethod = L10n.tr("Localizable", "Choose your login method", fallback: "Choose your login method")
  /// Choose your storage
  public static let chooseYourStorage = L10n.tr("Localizable", "ChooseYourStorage", fallback: "Choose your storage")
  /// Choose where to securely save your images from now on.
  public static let chooseYourStorageDescription = L10n.tr("Localizable", "ChooseYourStorageDescription", fallback: "Choose where to securely save your images from now on.")
  /// Clear
  public static let clear = L10n.tr("Localizable", "Clear", fallback: "Clear")
  /// Authentication Method View
  public static let clearPassword = L10n.tr("Localizable", "Clear Password", fallback: "Clear Password")
  /// Clear saved password/PIN
  public static let clearSavedPasswordPIN = L10n.tr("Localizable", "Clear saved password/PIN", fallback: "Clear saved password/PIN")
  /// Close
  public static let close = L10n.tr("Localizable", "Close", fallback: "Close")
  /// Confirm 6-Digit PIN
  public static let confirm6DigitPIN = L10n.tr("Localizable", "Confirm 6-Digit PIN", fallback: "Confirm 6-Digit PIN")
  /// Confirm adding key
  public static let confirmAddingKey = L10n.tr("Localizable", "Confirm adding key", fallback: "Confirm adding key")
  /// Confirm Pin Code
  public static let confirmPinCode = L10n.tr("Localizable", "ConfirmPinCode", fallback: "Confirm Pin Code")
  /// Confirm Storage
  public static let confirmStorage = L10n.tr("Localizable", "ConfirmStorage", fallback: "Confirm Storage")
  /// ./Encamera/Tutorial/ChooseStorageModal.swift
  public static let congratulations = L10n.tr("Localizable", "Congratulations!", fallback: "Congratulations!")
  /// Continue
  public static let `continue` = L10n.tr("Localizable", "Continue", fallback: "Continue")
  /// Picture taken overlay
  public static let coolPicture = L10n.tr("Localizable", "CoolPicture", fallback: "That's a cool picture!")
  /// Copied to Clipboard
  public static let copiedToClipboard = L10n.tr("Localizable", "Copied to Clipboard", fallback: "Copied to Clipboard")
  /// Copy Phrase to Clipboard
  public static let copyPhrase = L10n.tr("Localizable", "CopyPhrase", fallback: "Copy Phrase to Clipboard")
  /// Write down or copy these words in the right order and save them somewhere safe.
  /// 
  /// This phrase is used to generate the encryption key that encrypts your media.
  /// 
  /// It's important to save this key in case you lose your device.
  public static let copyPhraseInstructions = L10n.tr("Localizable", "CopyPhraseInstructions", fallback: "Write down or copy these words in the right order and save them somewhere safe.\n\nThis phrase is used to generate the encryption key that encrypts your media.\n\nIt's important to save this key in case you lose your device.")
  /// ./EncameraCore/Utils/KeyManager.swift
  public static let couldNotDeleteKeychainItems = L10n.tr("Localizable", "Could not delete keychain items.", fallback: "Could not delete keychain items.")
  /// Could not rename album.
  public static let couldNotRenameAlbumError = L10n.tr("Localizable", "CouldNotRenameAlbumError", fallback: "Could not rename album.")
  /// Create an unlimited number of keys.
  public static let createAnUnlimitedNumberOfKeys = L10n.tr("Localizable", "Create an unlimited number of keys.", fallback: "Create an unlimited number of keys.")
  /// ./Encamera/KeyManagement/KeyInformation.swift
  public static func created(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Created %@", String(describing: p1), fallback: "Created %@")
  }
  /// Create First Album
  public static let createFirstAlbum = L10n.tr("Localizable", "CreateFirstAlbum", fallback: "Create First Album")
  /// Create New Album
  public static let createNewAlbum = L10n.tr("Localizable", "CreateNewAlbum", fallback: "Create New Album")
  /// Creation Date: %@
  public static func creationDate(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Creation Date: %@", String(describing: p1), fallback: "Creation Date: %@")
  }
  /// Current Password
  public static let currentPassword = L10n.tr("Localizable", "Current Password", fallback: "Current Password")
  /// ./Encamera/ImageViewing/MovieViewing.swift
  public static let decrypting = L10n.tr("Localizable", "Decrypting...", fallback: "Decrypting...")
  /// Decryption error: %@
  public static func decryptionError(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Decryption error: %@", String(describing: p1), fallback: "Decryption error: %@")
  }
  /// ./EncameraCore/Constants/AppConstants.swift
  public static let defaultAlbumName = L10n.tr("Localizable", "DefaultAlbumName", fallback: "My Album")
  /// Delete
  public static let delete = L10n.tr("Localizable", "Delete", fallback: "Delete")
  /// Delete Album?
  public static let deleteAlbumQuestion = L10n.tr("Localizable", "Delete Album question", fallback: "Delete Album?")
  /// Delete All Associated Data?
  public static let deleteAllAssociatedData = L10n.tr("Localizable", "Delete All Associated Data?", fallback: "Delete All Associated Data?")
  /// Delete Media & Key
  public static let deleteAllKeyData = L10n.tr("Localizable", "Delete All Key Data", fallback: "Delete Media & Key")
  /// Delete Everything
  public static let deleteEverything = L10n.tr("Localizable", "Delete Everything", fallback: "Delete Everything")
  /// ./Encamera/ImageViewing/GalleryHorizontalScrollView.swift
  public static let deleteThisImage = L10n.tr("Localizable", "Delete this image?", fallback: "Delete this image?")
  /// Delete Album
  public static let deleteAlbum = L10n.tr("Localizable", "DeleteAlbum", fallback: "Delete Album")
  /// Do you want to delete this album and all media associated with it forever?
  public static let deleteAlbumForever = L10n.tr("Localizable", "DeleteAlbumForever", fallback: "Do you want to delete this album and all media associated with it forever?")
  /// Delete Images?
  public static let deleteImported = L10n.tr("Localizable", "DeleteImported", fallback: "Delete Images?")
  /// Deletion Error
  public static let deletionError = L10n.tr("Localizable", "Deletion Error", fallback: "Deletion Error")
  /// Do you want to delete this key forever? All media will remain saved.
  public static let doYouWantToDeleteThisKeyForeverAllMediaWillRemainSaved = L10n.tr("Localizable", "Do you want to delete this key forever? All media will remain saved.", fallback: "Do you want to delete this key forever? All media will remain saved.")
  /// Done
  public static let done = L10n.tr("Localizable", "Done", fallback: "Done")
  /// Done!
  public static let doneOnboarding = L10n.tr("Localizable", "DoneOnboarding", fallback: "Done!")
  /// Do you remember your passcode?
  public static let doYouRememberYourPin = L10n.tr("Localizable", "DoYouRememberYourPin", fallback: "Do you remember your passcode?")
  /// If you don't, you can set a new one by going to 'Change Passcode'
  public static let doYouRememberYourPinSubtitle = L10n.tr("Localizable", "DoYouRememberYourPinSubtitle", fallback: "If you don't, you can set a new one by going to 'Change Passcode'")
  /// Are you done importing images?
  public static let doYouWantToDeleteNotImported = L10n.tr("Localizable", "DoYouWantToDeleteNotImported", fallback: "Are you done importing images?")
  /// Import Pictures
  public static let emptyAlbumImportPhotosActionTitle = L10n.tr("Localizable", "EmptyAlbumImportPhotosActionTitle", fallback: "Import Pictures")
  /// Secure your pics
  public static let emptyAlbumImportPhotosHeading = L10n.tr("Localizable", "EmptyAlbumImportPhotosHeading", fallback: "Secure your pics")
  /// Import pictures from your camera roll
  public static let emptyAlbumImportPhotosSubtitle = L10n.tr("Localizable", "EmptyAlbumImportPhotosSubtitle", fallback: "Import pictures from your camera roll")
  /// Take a picture
  public static let emptyAlbumTakeAPictureActionTitle = L10n.tr("Localizable", "EmptyAlbumTakeAPictureActionTitle", fallback: "Take a picture")
  /// Create a new memory
  public static let emptyAlbumTakeAPictureHeading = L10n.tr("Localizable", "EmptyAlbumTakeAPictureHeading", fallback: "Create a new memory")
  /// Open your camera and take a pic
  public static let emptyAlbumTakeAPictureSubtitle = L10n.tr("Localizable", "EmptyAlbumTakeAPictureSubtitle", fallback: "Open your camera and take a pic")
  /// Enable %@
  public static func enable(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Enable %@", String(describing: p1), fallback: "Enable %@")
  }
  /// Enable %@ to quickly and securely gain access to the app.
  public static func enableToQuicklyAndSecurelyGainAccessToTheApp(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Enable %@ to quickly and securely gain access to the app.", String(describing: p1), fallback: "Enable %@ to quickly and securely gain access to the app.")
  }
  /// Enable Face ID
  public static let enableFaceID = L10n.tr("Localizable", "Enable Face ID", fallback: "Enable Face ID")
  /// Encamera encrypts everything, keeping your media safe from unwanted eyes.
  public static let encameraEncryptsAllDataItCreatesKeepingYourDataSafeFromThePryingEyesOfAIMediaAnalysisAndOtherViolationsOfPrivacy = L10n.tr("Localizable", "Encamera encrypts all data it creates, keeping your data safe from the prying eyes of AI, media analysis, and other violations of privacy.", fallback: "Encamera encrypts everything, keeping your media safe from unwanted eyes.")
  /// Open Source
  public static let encameraIsOpenSource = L10n.tr("Localizable", "EncameraIsOpenSource", fallback: "Open Source")
  /// ./Encamera/Styles/ViewModifiers/ButtonViewModifier.swift
  public static let encryptEverything = L10n.tr("Localizable", "Encrypt Everything", fallback: "Encrypt Everything")
  /// Encrypting
  public static let encrypting = L10n.tr("Localizable", "Encrypting", fallback: "Encrypting")
  /// Encryption Key
  public static let encryptionKey = L10n.tr("Localizable", "Encryption Key", fallback: "Encryption Key")
  /// Your media is safely secured behind a key and stored locally on your device or iCloud
  public static let encryptionExplanation = L10n.tr("Localizable", "EncryptionExplanation", fallback: "Your media is safely secured behind a key and stored locally on your device or iCloud")
  /// Enter Promo Code
  public static let enterPromoCode = L10n.tr("Localizable", "Enter Promo Code", fallback: "Enter Promo Code")
  /// Enter Key Phrase
  public static let enterKeyPhrase = L10n.tr("Localizable", "EnterKeyPhrase", fallback: "Enter Key Phrase")
  /// Enter the key phrase you want to import. Separate each word with a space.
  public static let enterKeyPhraseDescription = L10n.tr("Localizable", "EnterKeyPhraseDescription", fallback: "Enter the key phrase you want to import. Separate each word with a space.")
  /// Enter Password
  public static let enterPassword = L10n.tr("Localizable", "EnterPassword", fallback: "Enter Password")
  /// Enter your password
  public static let enterYourPassword = L10n.tr("Localizable", "EnterYourPassword", fallback: "Enter your password")
  /// Erase
  public static let erase = L10n.tr("Localizable", "Erase", fallback: "Erase")
  /// Erase All Data
  public static let eraseAllData = L10n.tr("Localizable", "Erase All Data", fallback: "Erase All Data")
  /// Erase App Data
  public static let eraseAppData = L10n.tr("Localizable", "Erase App Data", fallback: "Erase App Data")
  /// Erase Device Data
  public static let eraseDeviceData = L10n.tr("Localizable", "Erase Device Data", fallback: "Erase Device Data")
  /// Erase keychain data
  public static let eraseKeychainData = L10n.tr("Localizable", "Erase keychain data", fallback: "Erase keychain data")
  /// Erasing in %@
  public static func erasingIn(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Erasing in %@", String(describing: p1), fallback: "Erasing in %@")
  }
  /// Error clearing keychain
  public static let errorClearingKeychain = L10n.tr("Localizable", "Error clearing keychain", fallback: "Error clearing keychain")
  /// Error coding keychain data.
  public static let errorCodingKeychainData = L10n.tr("Localizable", "Error coding keychain data.", fallback: "Error coding keychain data.")
  /// Error deleting all files
  public static let errorDeletingAllFiles = L10n.tr("Localizable", "Error deleting all files", fallback: "Error deleting all files")
  /// ./Encamera/KeyManagement/KeyEntry.swift
  public static let errorSavingKey = L10n.tr("Localizable", "Error saving key", fallback: "Error saving key")
  /// Error importing key phrase
  public static let errorImportingKeyPhrase = L10n.tr("Localizable", "ErrorImportingKeyPhrase", fallback: "Error importing key phrase")
  /// Error saving password
  public static let errorSavingPassword = L10n.tr("Localizable", "ErrorSavingPassword", fallback: "Error saving password")
  /// Face ID
  public static let faceID = L10n.tr("Localizable", "Face ID", fallback: "Face ID")
  /// Failed to save password
  public static let failedToSavePassword = L10n.tr("Localizable", "FailedToSavePassword", fallback: "Failed to save password")
  /// ./Encamera/Styles/ViewModifiers/PurchaseOptionViewModifier.swift
  public static let familyShareable = L10n.tr("Localizable", "Family Shareable", fallback: "Family Shareable")
  /// Fast and convenient
  public static let fastAndConvenient = L10n.tr("Localizable", "Fast and convenient", fallback: "Fast and convenient")
  /// ./Encamera/Settings/SettingsView.swift
  public static let feedbackRequest = L10n.tr("Localizable", "FeedbackRequest", fallback: "Because Encamera does not track user behavior in any way, and collects no information about you, the user, we rely on your feedback to help us improve the app.")
  /// Let's secure some media
  public static let finishedOnboardingSubtitle = L10n.tr("Localizable", "FinishedOnboardingSubtitle", fallback: "Let's secure some media")
  /// You are ready to use Encamera!
  public static let finishedOnboardingTitle = L10n.tr("Localizable", "FinishedOnboardingTitle", fallback: "You are ready to use Encamera!")
  /// You are ready to use
  /// Encamera!
  public static let finishedReadyToUseEncamera = L10n.tr("Localizable", "FinishedReadyToUseEncamera", fallback: "You are ready to use\nEncamera!")
  /// Let's create your first album
  public static let finishedSubtitle = L10n.tr("Localizable", "FinishedSubtitle", fallback: "Let's create your first album")
  /// Finish Importing Media
  public static let finishImportingMedia = L10n.tr("Localizable", "FinishImportingMedia", fallback: "Finish Importing Media")
  /// Follow @encamera_app on Twitter
  public static let followUs = L10n.tr("Localizable", "FollowUs", fallback: "Follow @encamera_app on Twitter")
  /// Free Trial
  public static let freeTrial = L10n.tr("Localizable", "Free Trial", fallback: "Free Trial")
  /// 7 days free, then %@
  public static func freeTrialTerms(_ p1: Any) -> String {
    return L10n.tr("Localizable", "FreeTrialTerms", String(describing: p1), fallback: "7 days free, then %@")
  }
  /// TweetToShareView.swift
  public static let getOneYearFree = L10n.tr("Localizable", "GetOneYearFree", fallback: "Get 1 Year Free!")
  /// Get Premium
  public static let getPremium = L10n.tr("Localizable", "GetPremium", fallback: "Get Premium")
  /// Halloween Sale!
  public static let getPremiumPromoText = L10n.tr("Localizable", "GetPremiumPromoText", fallback: "Halloween Sale!")
  /// Let's Start
  public static let getStartedButtonText = L10n.tr("Localizable", "GetStartedButtonText", fallback: "Let's Start")
  /// ./Encamera/ImageViewing/GalleryGridView.swift
  public static let hide = L10n.tr("Localizable", "Hide", fallback: "Hide")
  /// ./Encamera/Settings/PromptToErase.swift
  public static let holdToErase = L10n.tr("Localizable", "Hold to erase", fallback: "Hold to erase")
  /// Hold to reveal
  public static let holdToReveal = L10n.tr("Localizable", "Hold to reveal", fallback: "Hold to reveal")
  /// I'm Done
  public static let iAmDone = L10n.tr("Localizable", "IAmDone", fallback: "I'm Done")
  /// ./EncameraCore/Models/StorageType.swift
  public static let iCloud = L10n.tr("Localizable", "iCloud", fallback: "iCloud")
  /// iCloud storage & backup
  public static let iCloudStorageFeatureRowTitle = L10n.tr("Localizable", "iCloudStorageFeatureRowTitle", fallback: "iCloud storage & backup")
  /// I Forgot
  public static let iForgot = L10n.tr("Localizable", "IForgot", fallback: "I Forgot")
  /// IMAGE SAVED TO ALBUM
  public static let imageSavedToAlbum = L10n.tr("Localizable", "ImageSavedToAlbum", fallback: "IMAGE SAVED TO ALBUM")
  /// Import
  public static let `import` = L10n.tr("Localizable", "Import", fallback: "Import")
  /// Import from Files
  public static let importFromFiles = L10n.tr("Localizable", "Import from files", fallback: "Import from Files")
  /// Import from Photos
  public static let importFromPhotos = L10n.tr("Localizable", "Import from photos", fallback: "Import from Photos")
  /// Importing... Please wait
  public static let importingPleaseWait = L10n.tr("Localizable", "ImportingPleaseWait", fallback: "Importing... Please wait")
  /// Import Key Phrase
  public static let importKeyPhrase = L10n.tr("Localizable", "ImportKeyPhrase", fallback: "Import Key Phrase")
  /// Import the selected images to your currently active key album
  public static let importSelectedImages = L10n.tr("Localizable", "ImportSelectedImages", fallback: "Import the selected images to your currently active key album")
  /// I'm Sure
  public static let imSure = L10n.tr("Localizable", "ImSure", fallback: "I'm Sure")
  /// Wrong PIN Code. Please try again.
  public static let incorrectPinCode = L10n.tr("Localizable", "IncorrectPinCode", fallback: "Wrong PIN Code. Please try again.")
  /// Add Encamera to your lock screen to quickly take pictures
  public static let installWidgetBody = L10n.tr("Localizable", "InstallWidgetBody", fallback: "Add Encamera to your lock screen to quickly take pictures")
  /// Add Widget
  public static let installWidgetButtonText = L10n.tr("Localizable", "InstallWidgetButtonText", fallback: "Add Widget")
  /// Install Lock Screen Widget
  public static let installWidgetTitle = L10n.tr("Localizable", "InstallWidgetTitle", fallback: "Install Lock Screen Widget")
  /// Your media is safely secured behind a key and stored locally on your device or iCloud.
  public static let introStorageExplanation = L10n.tr("Localizable", "IntroStorageExplanation", fallback: "Your media is safely secured behind a key and stored locally on your device or iCloud.")
  /// Invalid Password
  public static let invalidPassword = L10n.tr("Localizable", "Invalid Password", fallback: "Invalid Password")
  /// I Remember my Passcode
  public static let iRemember = L10n.tr("Localizable", "IRemember", fallback: "I Remember my Passcode")
  /// Join Telegram Group
  public static let joinTelegramGroup = L10n.tr("Localizable", "Join Telegram Group", fallback: "Join Telegram Group")
  /// Keep your encrypted data safe by using %@.
  public static func keepYourEncryptedDataSafeByUsing(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Keep your encrypted data safe by using %@.", String(describing: p1), fallback: "Keep your encrypted data safe by using %@.")
  }
  /// Key Entry
  public static let keyEntry = L10n.tr("Localizable", "Key Entry", fallback: "Key Entry")
  /// Key Info
  public static let keyInfo = L10n.tr("Localizable", "Key Info", fallback: "Key Info")
  /// Key length: %@
  public static func keyLength(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Key length: %@", String(describing: p1), fallback: "Key length: %@")
  }
  /// Key Management
  public static let keyManagement = L10n.tr("Localizable", "Key Management", fallback: "Key Management")
  /// Key name is invalid, must be more than two characters
  public static let keyNameIsInvalidMustBeMoreThanTwoCharacters = L10n.tr("Localizable", "Key name is invalid, must be more than two characters", fallback: "Key name is invalid, must be more than two characters")
  /// ./Encamera/KeyManagement/AddExchangedKeyConfirmation.swift
  public static func keyName(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Key Name: %@", String(describing: p1), fallback: "Key Name: %@")
  }
  /// Key not found.
  public static let keyNotFound = L10n.tr("Localizable", "Key not found.", fallback: "Key not found.")
  /// Key-Based Encryption
  public static let keyBasedEncryption = L10n.tr("Localizable", "KeyBasedEncryption", fallback: "Key-Based Encryption")
  /// Keys
  public static let keys = L10n.tr("Localizable", "Keys", fallback: "Keys")
  /// Non explicabo officia aut odit ex eum ipsum libero.
  public static let keyTutorialText = L10n.tr("Localizable", "KeyTutorialText", fallback: "Non explicabo officia aut odit ex eum ipsum libero.")
  /// All of your files are encrypted
  public static let keyTutorialTitle = L10n.tr("Localizable", "KeyTutorialTitle", fallback: "All of your files are encrypted")
  /// Leave a Review
  public static let leaveAReview = L10n.tr("Localizable", "Leave a Review", fallback: "Leave a Review")
  /// Let's give your
  /// album a name
  public static let letsGiveYourAlbumAName = L10n.tr("Localizable", "LetsGiveYourAlbumAName", fallback: "Let's give your\nalbum a name")
  /// Let's go!
  public static let letsGo = L10n.tr("Localizable", "LetsGo", fallback: "Let's go!")
  /// Local
  public static let local = L10n.tr("Localizable", "Local", fallback: "Local")
  /// Choose how you want to access your private albums.
  public static let loginMethodDescription = L10n.tr("Localizable", "LoginMethodDescription", fallback: "Choose how you want to access your private albums.")
  /// Make sure you remember your pin code!
  public static let makeSureYouRememberYourPin = L10n.tr("Localizable", "MakeSureYouRememberYourPin", fallback: "Make sure you remember your pin code!")
  /// ./Encamera/CameraView/CameraView.swift
  public static let missingCameraAccess = L10n.tr("Localizable", "Missing camera access", fallback: "Missing camera access")
  /// ./Encamera/AuthenticationView/AuthenticationView.swift
  public static let missingPassword = L10n.tr("Localizable", "Missing password", fallback: "Missing password")
  /// Upgrade to premium to unlock unlimited photos
  public static let modalUpgradeText = L10n.tr("Localizable", "ModalUpgradeText", fallback: "Upgrade to premium to unlock unlimited photos")
  /// MOST POPULAR
  public static let mostPopular = L10n.tr("Localizable", "MostPopular", fallback: "MOST POPULAR")
  /// Change Storage
  public static let moveAlbumStorage = L10n.tr("Localizable", "MoveAlbumStorage", fallback: "Change Storage")
  /// Could not load or decrypt movie. It may not be able to be downloaded. If this media is on iCloud, make sure you are able to download files with your current Internet connection. Error: %@
  public static func movieDecryptionError(_ p1: Any) -> String {
    return L10n.tr("Localizable", "MovieDecryptionError", String(describing: p1), fallback: "Could not load or decrypt movie. It may not be able to be downloaded. If this media is on iCloud, make sure you are able to download files with your current Internet connection. Error: %@")
  }
  /// You can have multiple keys for different purposes, e.g. one named "Documents" and another "Personal".
  public static let multipleKeysForMultiplePurposesExplanation = L10n.tr("Localizable", "MultipleKeysForMultiplePurposesExplanation", fallback: "You can have multiple keys for different purposes, e.g. one named \"Documents\" and another \"Personal\".")
  /// New Album
  public static let newAlbum = L10n.tr("Localizable", "New Album", fallback: "New Album")
  /// Set the name for this encrypted photo album.
  public static let newAlbumSubheading = L10n.tr("Localizable", "New Album Subheading", fallback: "Set the name for this encrypted photo album.")
  /// New Password
  public static let newPassword = L10n.tr("Localizable", "New Password", fallback: "New Password")
  /// ./Encamera/Onboarding/MainOnboardingView.swift
  public static let next = L10n.tr("Localizable", "Next", fallback: "Next")
  /// No
  public static let no = L10n.tr("Localizable", "No", fallback: "No")
  /// No file access available.
  public static let noFileAccessAvailable = L10n.tr("Localizable", "No file access available.", fallback: "No file access available.")
  /// ./EncameraCore/Utils/DataStorageUserDefaultsSetting.swift
  public static let noICloudAccountFoundOnThisDevice = L10n.tr("Localizable", "No iCloud account found on this device.", fallback: "No iCloud account found on this device.")
  /// ./Encamera/ImageViewing/PhotoInfoView.swift
  public static let noInfoAvailable = L10n.tr("Localizable", "No info available", fallback: "No info available")
  /// ./Encamera/ImageViewing/ImageViewing.swift
  public static let noKeyAvailable = L10n.tr("Localizable", "No key available.", fallback: "No key available.")
  /// ./Encamera/EncameraApp.swift
  public static let noPrivateKeyOrMediaFound = L10n.tr("Localizable", "No private key or media found.", fallback: "No private key or media found.")
  /// No Album
  public static let noAlbum = L10n.tr("Localizable", "NoAlbum", fallback: "No Album")
  /// No Album Selected. You must select an album to save photos to.
  public static let noAlbumSelected = L10n.tr("Localizable", "NoAlbumSelected", fallback: "No Album Selected. You must select an album to save photos to.")
  /// No commitment, cancel anytime
  public static let noCommitmentCancelAnytime = L10n.tr("Localizable", "NoCommitmentCancelAnytime", fallback: "No commitment, cancel anytime")
  /// None
  public static let `none` = L10n.tr("Localizable", "None", fallback: "None")
  /// Not authenticated for this operation.
  public static let notAuthenticatedForThisOperation = L10n.tr("Localizable", "Not authenticated for this operation.", fallback: "Not authenticated for this operation.")
  /// ./EncameraCore/Utils/PasswordValidator.swift
  public static let notDetermined = L10n.tr("Localizable", "Not determined.", fallback: "Not determined.")
  /// I'm Not Done
  public static let notDoneYet = L10n.tr("Localizable", "NotDoneYet", fallback: "I'm Not Done")
  /// All media is encrypted before saving. Nobody can view your files except you.
  public static let notificationBannerBody = L10n.tr("Localizable", "NotificationBannerBody", fallback: "All media is encrypted before saving. Nobody can view your files except you.")
  /// Notification Banners
  public static let notificationBannerTitle = L10n.tr("Localizable", "NotificationBannerTitle", fallback: "Secured with Encryption")
  /// Notifications
  public static let notificationListTitle = L10n.tr("Localizable", "NotificationListTitle", fallback: "Notifications")
  /// Nobody can access your data except you.
  public static let noTrackingExplanation = L10n.tr("Localizable", "NoTrackingExplanation", fallback: "Nobody can access your data except you.")
  /// Your Data is Secure
  public static let noTrackingOnboardingExplanation = L10n.tr("Localizable", "NoTrackingOnboardingExplanation", fallback: "Your Data is Secure")
  /// OK
  public static let ok = L10n.tr("Localizable", "OK", fallback: "OK")
  /// Privacy-First Camera
  public static let onboardingIntroHeadingText1 = L10n.tr("Localizable", "OnboardingIntroHeadingText1", fallback: "Privacy-First Camera")
  /// Encamera encrypts everything, keeping your media safe from unwanted eyes.
  public static let onboardingIntroSubheadingText = L10n.tr("Localizable", "OnboardingIntroSubheadingText", fallback: "Encamera encrypts everything, keeping your media safe from unwanted eyes.")
  /// Camera access
  public static let onboardingPermissionsCameraAccess = L10n.tr("Localizable", "OnboardingPermissionsCameraAccess", fallback: "Camera access")
  /// Needed to take photos
  public static let onboardingPermissionsCameraAccessSubheading = L10n.tr("Localizable", "OnboardingPermissionsCameraAccessSubheading", fallback: "Needed to take photos")
  /// Microphone access
  public static let onboardingPermissionsMicrophoneAccess = L10n.tr("Localizable", "OnboardingPermissionsMicrophoneAccess", fallback: "Microphone access")
  /// Needed only for videos
  public static let onboardingPermissionsMicrophoneAccessSubheading = L10n.tr("Localizable", "OnboardingPermissionsMicrophoneAccessSubheading", fallback: "Needed only for videos")
  /// You will need to give permissions to use the camera & microphone in order to access the app
  public static let onboardingPermissionsSubheading = L10n.tr("Localizable", "OnboardingPermissionsSubheading", fallback: "You will need to give permissions to use the camera & microphone in order to access the app")
  /// Permissions
  public static let onboardingPermissionsTitle = L10n.tr("Localizable", "OnboardingPermissionsTitle", fallback: "Permissions")
  /// One-Time Purchase
  public static let oneTimePurchase = L10n.tr("Localizable", "One-Time Purchase", fallback: "One-Time Purchase")
  /// Open Source
  public static let openSource = L10n.tr("Localizable", "Open Source", fallback: "Open Source")
  /// Open Settings
  public static let openSettings = L10n.tr("Localizable", "OpenSettings", fallback: "Open Settings")
  /// Encamera's core functionality is open sourced, meaning you can see the code that's making your photos safe.
  public static let openSourceExplanation = L10n.tr("Localizable", "OpenSourceExplanation", fallback: "Encamera's core functionality is open sourced, meaning you can see the code that's making your photos safe.")
  /// Go to Settings
  public static let openSystemSettings = L10n.tr("Localizable", "OpenSystemSettings", fallback: "Go to Settings")
  /// Or
  public static let or = L10n.tr("Localizable", "Or", fallback: "Or")
  /// Are you sure you want to overwrite your current key phrase? You will not be able to access any media encrypted with the current key phrase.
  public static let overwriteAreYouSure = L10n.tr("Localizable", "OverwriteAreYouSure", fallback: "Are you sure you want to overwrite your current key phrase? You will not be able to access any media encrypted with the current key phrase.")
  /// Overwrite Key Phrase?
  public static let overwriteKeyPhrase = L10n.tr("Localizable", "OverwriteKeyPhrase", fallback: "Overwrite Key Phrase?")
  /// Password
  public static let password = L10n.tr("Localizable", "Password", fallback: "Password")
  /// Password incorrect
  public static let passwordIncorrect = L10n.tr("Localizable", "Password incorrect", fallback: "Password incorrect")
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
  /// Password successfully changed
  public static let passwordSuccessfullyChanged = L10n.tr("Localizable", "Password successfully changed", fallback: "Password successfully changed")
  /// Passwords do not match
  public static let passwordMismatch = L10n.tr("Localizable", "PasswordMismatch", fallback: "Passwords do not match")
  /// Passwords do not match.
  public static let passwordsDoNotMatch = L10n.tr("Localizable", "Passwords do not match.", fallback: "Passwords do not match.")
  /// Password Set Successfully
  public static let passwordSetSuccessfully = L10n.tr("Localizable", "PasswordSetSuccessfully", fallback: "Password Set Successfully")
  /// Your new password has been saved
  public static let passwordSetSuccessMessage = L10n.tr("Localizable", "PasswordSetSuccessMessage", fallback: "Your new password has been saved")
  /// Paste the private key here.
  public static let pasteThePrivateKeyHere = L10n.tr("Localizable", "Paste the private key here.", fallback: "Paste the private key here.")
  /// You must enable camera permissions to continue. Open the settings app to do this.
  public static let permissionsNeededText = L10n.tr("Localizable", "PermissionsNeededText", fallback: "You must enable camera permissions to continue. Open the settings app to do this.")
  /// Camera Permissions Needed
  public static let permissionsNeededTitle = L10n.tr("Localizable", "PermissionsNeededTitle", fallback: "Camera Permissions Needed")
  /// ./Encamera/CameraView/CameraModePicker.swift
  public static let photo = L10n.tr("Localizable", "PHOTO", fallback: "PHOTO")
  /// Photo limit reached
  public static let photoLimitReached = L10n.tr("Localizable", "Photo limit reached", fallback: "Photo limit reached")
  /// PIN doesn't match. Please try again.
  public static let pinCodeDoesNotMatch = L10n.tr("Localizable", "PinCodeDoesNotMatch", fallback: "PIN doesn't match. Please try again.")
  /// Too many attempts. Please wait for %@
  public static func pinCodeLockTryAgainIn(_ p1: Any) -> String {
    return L10n.tr("Localizable", "PinCodeLockTryAgainIn", String(describing: p1), fallback: "Too many attempts. Please wait for %@")
  }
  /// Pincodes are not the same
  public static let pinCodeMismatch = L10n.tr("Localizable", "PinCodeMismatch", fallback: "Pincodes are not the same")
  /// Pin successfully changed
  public static let pinSuccessfullyChanged = L10n.tr("Localizable", "PinSuccessfullyChanged", fallback: "Pin successfully changed")
  /// PIN is too short. It must be at least %@ digits.
  public static func pinTooShort(_ p1: Any) -> String {
    return L10n.tr("Localizable", "PinTooShort", String(describing: p1), fallback: "PIN is too short. It must be at least %@ digits.")
  }
  /// Please select a storage location.
  public static let pleaseSelectAStorageLocation = L10n.tr("Localizable", "Please select a storage location.", fallback: "Please select a storage location.")
  /// Please enter a name for the album
  public static let pleaseEnterAnAlbumName = L10n.tr("Localizable", "PleaseEnterAnAlbumName", fallback: "Please enter a name for the album")
  /// premium
  public static let premium = L10n.tr("Localizable", "premium", fallback: "premium")
  /// Unlimited albums and iCloud storage
  public static let premiumUnlockTheseBenefits = L10n.tr("Localizable", "PremiumUnlockTheseBenefits", fallback: "Unlimited albums and iCloud storage")
  /// Privacy Policy
  public static let privacyPolicy = L10n.tr("Localizable", "Privacy Policy", fallback: "Privacy Policy")
  /// ./Encamera/Onboarding/OnboardingView.swift
  public static let profileSetup = L10n.tr("Localizable", "ProfileSetup", fallback: "PROFILE SETUP")
  /// 60 days free, then %@
  public static func promoFreeTrialTerms(_ p1: Any) -> String {
    return L10n.tr("Localizable", "PromoFreeTrialTerms", String(describing: p1), fallback: "60 days free, then %@")
  }
  /// Unlimited albums and iCloud storage
  ///  and TWO MONTHS FREE
  public static let promoPremiumUnlockTheseBenefits = L10n.tr("Localizable", "PromoPremiumUnlockTheseBenefits", fallback: "Unlimited albums and iCloud storage\n and TWO MONTHS FREE")
  /// Purchase
  public static let purchaseProduct = L10n.tr("Localizable", "PurchaseProduct", fallback: "Purchase")
  /// Widget
  public static let quicklyTakePictures = L10n.tr("Localizable", "QuicklyTakePictures", fallback: "Quickly take pictures and video.")
  /// Recovery Phrase Copied!
  public static let recoveryPhraseCopied = L10n.tr("Localizable", "RecoveryPhraseCopied", fallback: "Recovery Phrase Copied!")
  /// This will remove your passcode. You will only be able to use Face ID to get into the app. Continue?
  public static let removePasscode = L10n.tr("Localizable", "RemovePasscode", fallback: "This will remove your passcode. You will only be able to use Face ID to get into the app. Continue?")
  /// Rename
  public static let rename = L10n.tr("Localizable", "Rename", fallback: "Rename")
  /// Repeat Password
  public static let repeatPassword = L10n.tr("Localizable", "RepeatPassword", fallback: "Repeat Password")
  /// Repeat your password to confirm.
  public static let repeatPasswordSubtitle = L10n.tr("Localizable", "repeatPasswordSubtitle", fallback: "Repeat your password to confirm.")
  /// Repeat Pin Code
  public static let repeatPinCode = L10n.tr("Localizable", "RepeatPinCode", fallback: "Repeat Pin Code")
  /// Repeat your Pin code to confirm.
  public static let repeatPinCodeSubtitle = L10n.tr("Localizable", "RepeatPinCodeSubtitle", fallback: "Repeat your Pin code to confirm.")
  /// Restore Purchases
  public static let restorePurchases = L10n.tr("Localizable", "Restore Purchases", fallback: "Restore Purchases")
  /// Roadmap & Feature Requests
  public static let roadmap = L10n.tr("Localizable", "Roadmap", fallback: "Roadmap & Feature Requests")
  /// Save
  public static let save = L10n.tr("Localizable", "Save", fallback: "Save")
  /// Save Key
  public static let saveKey = L10n.tr("Localizable", "Save Key", fallback: "Save Key")
  /// Save Key to iCloud
  public static let saveKeyToICloud = L10n.tr("Localizable", "Save Key to iCloud", fallback: "Save Key to iCloud")
  /// Save this media?
  public static let saveThisMedia = L10n.tr("Localizable", "Save this media?", fallback: "Save this media?")
  /// SAVE %@
  public static func saveAmount(_ p1: Any) -> String {
    return L10n.tr("Localizable", "SaveAmount %@ $@", String(describing: p1), fallback: "SAVE %@")
  }
  /// Saved to Device
  public static let savedToDevice = L10n.tr("Localizable", "Saved to Device", fallback: "Saved to Device")
  /// Saved to iCloud
  public static let savedToICloud = L10n.tr("Localizable", "Saved to iCloud", fallback: "Saved to iCloud")
  /// Save to this device
  public static let saveLocally = L10n.tr("Localizable", "SaveLocally", fallback: "Save to this device")
  /// Save PIN Code
  public static let savePinCode = L10n.tr("Localizable", "SavePinCode", fallback: "Save PIN Code")
  /// Save to iCloud Drive
  public static let saveToiCloudDrive = L10n.tr("Localizable", "SaveToiCloudDrive", fallback: "Save to iCloud Drive")
  /// Scan with Encamera app
  public static let scanWithEncameraApp = L10n.tr("Localizable", "Scan with Encamera app", fallback: "Scan with Encamera app")
  /// See the photos that belong to a key by tapping the 
  public static let seeThePhotosThatBelongToAKeyByTappingThe = L10n.tr("Localizable", "See the photos that belong to a key by tapping the ", fallback: "See the photos that belong to a key by tapping the ")
  /// Select a place to keep media for this key.
  public static let selectAPlaceToKeepMediaForThisKey = L10n.tr("Localizable", "Select a place to keep media for this key.", fallback: "Select a place to keep media for this key.")
  /// ./Encamera/MediaImport/MediaImportView.swift
  public static let selectAll = L10n.tr("Localizable", "Select All", fallback: "Select All")
  /// Please select a method
  public static let selectLoginMethod = L10n.tr("Localizable", "Select Login Method", fallback: "Please select a method")
  /// Select Storage
  public static let selectStorage = L10n.tr("Localizable", "Select Storage", fallback: "Select Storage")
  /// Select an Option
  public static let selectAnOption = L10n.tr("Localizable", "SelectAnOption", fallback: "Select an Option")
  /// Select a Product
  public static let selectProduct = L10n.tr("Localizable", "SelectProduct", fallback: "Select a Product")
  /// PIN Code Setting
  public static let set6DigitPIN = L10n.tr("Localizable", "Set 6-Digit PIN", fallback: "Set 6-Digit PIN")
  /// Set as Active Key
  public static let setAsActiveKey = L10n.tr("Localizable", "Set as Active Key", fallback: "Set as Active Key")
  /// Set Password
  public static let setPassword = L10n.tr("Localizable", "Set Password", fallback: "Set Password")
  /// Set a password to access the app. Be sure to store it in a safe place – you cannot recover it later.
  public static let setAPasswordWarning = L10n.tr("Localizable", "SetAPasswordWarning", fallback: "Set a password to access the app. Be sure to store it in a safe place – you cannot recover it later.")
  /// This password will be used to securely access the app. Make sure you remember it!
  public static let setPasswordSubtitle = L10n.tr("Localizable", "setPasswordSubtitle", fallback: "This password will be used to securely access the app. Make sure you remember it!")
  /// Set Pin Code
  public static let setPinCode = L10n.tr("Localizable", "SetPinCode", fallback: "Set Pin Code")
  /// This pin will be used to securely access the app. Make sure you remember it!
  public static let setPinCodeSubtitle = L10n.tr("Localizable", "SetPinCodeSubtitle", fallback: "This pin will be used to securely access the app. Make sure you remember it!")
  /// Settings
  public static let settings = L10n.tr("Localizable", "Settings", fallback: "Settings")
  /// Face ID is Disabled
  public static let settingsFaceIdDisabled = L10n.tr("Localizable", "SettingsFaceIdDisabled", fallback: "Face ID is Disabled")
  /// You have disabled Face ID for Encamera. Enable it in Settings to login with Face ID.
  public static let settingsFaceIdOpenSettings = L10n.tr("Localizable", "SettingsFaceIdOpenSettings", fallback: "You have disabled Face ID for Encamera. Enable it in Settings to login with Face ID.")
  /// Share
  public static let share = L10n.tr("Localizable", "Share", fallback: "Share")
  /// Share Decrypted
  public static let shareDecrypted = L10n.tr("Localizable", "Share Decrypted", fallback: "Share Decrypted")
  /// Share Encrypted
  public static let shareEncrypted = L10n.tr("Localizable", "Share Encrypted", fallback: "Share Encrypted")
  /// Share Image
  public static let shareImage = L10n.tr("Localizable", "Share Image", fallback: "Share Image")
  /// Share Key
  public static let shareKey = L10n.tr("Localizable", "Share Key", fallback: "Share Key")
  /// Share this image?
  public static let shareThisImage = L10n.tr("Localizable", "Share this image?", fallback: "Share this image?")
  /// ./Encamera/ShareHandling/ShareHandling.swift
  public static let sharedMedia = L10n.tr("Localizable", "Shared Media", fallback: "Shared Media")
  /// ./Encamera/KeyManagement/KeyExchange.swift
  public static let shareKeyExplanation = L10n.tr("Localizable", "ShareKeyExplanation", fallback: "Share your encryption key with someone you trust.\n\nSharing it with them means they can decrypt any media you share with them that is encrypted with this key.")
  /// Skip for now
  public static let skipForNow = L10n.tr("Localizable", "Skip for now", fallback: "Skip for now")
  /// ./Encamera/Store/PurchaseUpgradeView.swift
  public static let startTrialOffer = L10n.tr("Localizable", "Start trial offer", fallback: "Start free trial")
  /// Where do you want to store your media? Each key will store data in its own directory once encrypted.
  public static let storageLocationOnboarding = L10n.tr("Localizable", "Storage location onboarding", fallback: "Where do you want to store your media? Each key will store data in its own directory once encrypted.")
  /// Storage Settings
  public static let storageSettings = L10n.tr("Localizable", "Storage Settings", fallback: "Storage Settings")
  /// Encamera does not store media to your camera roll. All encrypted media are stored either on this app or on iCloud, depending on your storage choice.
  public static let storageExplanation = L10n.tr("Localizable", "StorageExplanation", fallback: "Encamera does not store media to your camera roll. All encrypted media are stored either on this app or on iCloud, depending on your storage choice.")
  /// Where are my photos stored?
  public static let storageExplanationHeader = L10n.tr("Localizable", "StorageExplanationHeader", fallback: "Where are my photos stored?")
  /// Where do you want to store media for files encrypted with this key?
  /// Each key will store data in its own directory.
  /// 
  public static let storageSettingsSubheading = L10n.tr("Localizable", "StorageSettingsSubheading", fallback: "Where do you want to store media for files encrypted with this key?\nEach key will store data in its own directory.\n")
  /// Subscribe
  public static let subscribe = L10n.tr("Localizable", "Subscribe", fallback: "Subscribe")
  /// ./Encamera/Store/SubscriptionOptionView.swift
  public static let subscribed = L10n.tr("Localizable", "Subscribed", fallback: "Subscribed")
  /// Subscription
  public static let subscription = L10n.tr("Localizable", "Subscription", fallback: "Subscription")
  /// Support privacy-focused development.
  public static let supportPrivacyFocusedDevelopment = L10n.tr("Localizable", "Support privacy-focused development.", fallback: "Support privacy-focused development.")
  /// Take a Photo!
  public static let takeAPhoto = L10n.tr("Localizable", "Take a Photo!", fallback: "Take a Photo!")
  /// Take another photo
  public static let takeAnotherPhoto = L10n.tr("Localizable", "TakeAnotherPhoto", fallback: "Take another photo")
  /// Give us your feedback and get 3 months for free
  public static let takeSurveyBody = L10n.tr("Localizable", "TakeSurveyBody", fallback: "Give us your feedback and get 3 months for free")
  /// Take Survey
  public static let takeSurveyButtonText = L10n.tr("Localizable", "TakeSurveyButtonText", fallback: "Take Survey")
  /// Want 3 Months Free?
  public static let takeSurveyTitle = L10n.tr("Localizable", "TakeSurveyTitle", fallback: "Want 3 Months Free?")
  /// TAKE YOUR FIRST PICTURE
  public static let takeYourFirstPicture = L10n.tr("Localizable", "TakeYourFirstPicture", fallback: "TAKE YOUR FIRST PICTURE")
  /// Tap the 
  public static let tapThe = L10n.tr("Localizable", "Tap the ", fallback: "Tap the ")
  /// Tap to Upgrade
  public static let tapToUpgrade = L10n.tr("Localizable", "Tap to Upgrade", fallback: "Tap to Upgrade")
  /// Tap to Tweet!
  public static let tapToTweet = L10n.tr("Localizable", "TapToTweet", fallback: "Tap to Tweet!")
  /// Get early access to beta features and give feedback
  public static let telegramGroupJoinBody = L10n.tr("Localizable", "TelegramGroupJoinBody", fallback: "Get early access to beta features and give feedback")
  /// Join Group
  public static let telegramGroupJoinButtonText = L10n.tr("Localizable", "TelegramGroupJoinButtonText", fallback: "Join Group")
  /// Join Telegram Group
  public static let telegramGroupJoinTitle = L10n.tr("Localizable", "TelegramGroupJoinTitle", fallback: "Join Telegram Group")
  /// Terms of Use
  public static let termsOfUse = L10n.tr("Localizable", "Terms of Use", fallback: "Terms of Use")
  /// Here is a test of the string translation
  public static let test = L10n.tr("Localizable", "Test", fallback: "Here is a test of the string translation")
  /// Thank you for your support!
  public static let thankYouForYourSupport = L10n.tr("Localizable", "Thank you for your support!", fallback: "Thank you for your support!")
  /// Thanks for purchasing a lifetime license!
  public static let thanksForPurchasingLifetime = L10n.tr("Localizable", "ThanksForPurchasingLifetime", fallback: "Thanks for purchasing a lifetime license!")
  /// You rock and you will unlock new benefits soon.
  public static let thanksForPurchasingLifetimeSubtitle = L10n.tr("Localizable", "ThanksForPurchasingLifetimeSubtitle", fallback: "You rock and you will unlock new benefits soon.")
  /// ./Encamera/ImageViewing/DecryptErrorExplanation.swift
  public static let theMediaYouTriedToOpenCouldNotBeDecrypted = L10n.tr("Localizable", "The media you tried to open could not be decrypted.", fallback: "The media you tried to open could not be decrypted.")
  /// This will save the media to your library.
  public static let thisWillSaveTheMediaToYourLibrary = L10n.tr("Localizable", "This will save the media to your library.", fallback: "This will save the media to your library.")
  /// ./EncameraCore/Utils/AuthManager.swift
  public static let touchID = L10n.tr("Localizable", "Touch ID", fallback: "Touch ID")
  /// Get 100%% off the $9.99 yearly subscription fee!
  /// 
  ///  You only need to do two things:
  /// 1. Follow @encamera_app
  /// 2. Tap the link below to tweet about Encamera
  public static let tweetToRedeemOfferExplanation = L10n.tr("Localizable", "TweetToRedeemOfferExplanation", fallback: "Get 100%% off the $9.99 yearly subscription fee!\n\n You only need to do two things:\n1. Follow @encamera_app\n2. Tap the link below to tweet about Encamera")
  /// Unlimited albums for your memories
  public static let unlimitedAlbumsFeatureRowTitle = L10n.tr("Localizable", "UnlimitedAlbumsFeatureRowTitle", fallback: "Unlimited albums for your memories")
  /// ./Encamera/Store/SubscriptionView.swift
  public static let unlimitedStorageFeatureRowTitle = L10n.tr("Localizable", "UnlimitedStorageFeatureRowTitle", fallback: "Unlimited storage for photos & videos")
  /// Unlock
  public static let unlock = L10n.tr("Localizable", "Unlock", fallback: "Unlock")
  /// Unlock with %@
  public static func unlockWith(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Unlock with %@", String(describing: p1), fallback: "Unlock with %@")
  }
  /// Unlock Unlimited for Free!
  public static let unlockUnlimitedForFree = L10n.tr("Localizable", "UnlockUnlimitedForFree", fallback: "Unlock Unlimited for Free!")
  /// Unlock
  public static let unlockWithPin = L10n.tr("Localizable", "UnlockWithPin", fallback: "Unlock")
  /// Upgrade to Premium
  public static let upgradeToPremium = L10n.tr("Localizable", "Upgrade to Premium", fallback: "Upgrade to Premium")
  /// ./Encamera/InAppPurchase/PurchasePhotoSubscriptionOverlay.swift
  public static let upgradeToViewUnlimitedPhotos = L10n.tr("Localizable", "Upgrade to view unlimited photos", fallback: "Upgrade to view unlimited photos")
  /// Upgrade Today!
  public static let upgradeToday = L10n.tr("Localizable", "Upgrade Today!", fallback: "Upgrade Today!")
  /// Use %@?
  public static func use(_ p1: Any) -> String {
    return L10n.tr("Localizable", "Use %@?", String(describing: p1), fallback: "Use %@?")
  }
  /// Face ID
  public static let useFaceID = L10n.tr("Localizable", "Use Face ID", fallback: "Use Face ID")
  /// Use Passcode instead
  public static let usePasscodeInstead = L10n.tr("Localizable", "Use Passcode instead", fallback: "Use Passcode instead")
  /// Use Password
  public static let usePassword = L10n.tr("Localizable", "Use Password", fallback: "Use Password")
  /// Use the built-in camera to take photos and videos.
  public static let useCameraToTakePhotos = L10n.tr("Localizable", "UseCameraToTakePhotos", fallback: "Use the built-in camera to take photos and videos.")
  /// VIDEO
  public static let video = L10n.tr("Localizable", "VIDEO", fallback: "VIDEO")
  /// View unlimited photos for each key.
  public static let viewUnlimitedPhotosForEachKey = L10n.tr("Localizable", "View unlimited photos for each key.", fallback: "View unlimited photos for each key.")
  /// View Albums
  public static let viewAlbums = L10n.tr("Localizable", "ViewAlbums", fallback: "View Albums")
  /// View in Files App
  public static let viewInFiles = L10n.tr("Localizable", "ViewInFiles", fallback: "View in Files App")
  /// ./Encamera/AuthenticationView/PasswordEntry.swift
  public static let welcomeBack = L10n.tr("Localizable", "WelcomeBack", fallback: "Welcome back!")
  /// What is Encamera?
  public static let whatIsEncamera = L10n.tr("Localizable", "What is Encamera?", fallback: "What is Encamera?")
  /// Where do you want to save this key's media?
  public static let whereDoYouWantToSaveThisKeySMedia = L10n.tr("Localizable", "Where do you want to save this key's media?", fallback: "Where do you want to save this key's media?")
  /// You will find all of your photos and videos grouped in the "Albums"
  public static let whereToFindYourPictures = L10n.tr("Localizable", "WhereToFindYourPictures", fallback: "You will find all of your photos and videos grouped in the \"Albums\"")
  /// Why Encrypt Media?
  public static let whyEncryptMedia = L10n.tr("Localizable", "Why Encrypt Media?", fallback: "Why Encrypt Media?")
  /// Yes
  public static let yes = L10n.tr("Localizable", "Yes", fallback: "Yes")
  /// You have an existing password for this device.
  public static let youHaveAnExistingPasswordForThisDevice = L10n.tr("Localizable", "You have an existing password for this device.", fallback: "You have an existing password for this device.")
  /// You took your first photo! 📸 🥳
  public static let youTookYourFirstPhoto📸🥳 = L10n.tr("Localizable", "You took your first photo! 📸 🥳", fallback: "You took your first photo! 📸 🥳")
  /// Your Keys
  public static let yourKeys = L10n.tr("Localizable", "Your Keys", fallback: "Your Keys")
  /// Key Backup
  public static let yourRecoveryPhrase = L10n.tr("Localizable", "YourRecoveryPhrase", fallback: "Key Backup")
  /// Afterwards, you will be sent a promo code via DM that you can redeem in the app.
  public static let youWillBeSentAPromoCode = L10n.tr("Localizable", "YouWillBeSentAPromoCode", fallback: "Afterwards, you will be sent a promo code via DM that you can redeem in the app.")
  public enum AlbumDetailView {
    /// Add your first image
    public static let addFirstImage = L10n.tr("Localizable", "AlbumDetailView.AddFirstImage", fallback: "Add your first image")
    /// Import an image from your album or open the camera and take a new picture for this album
    public static let addFirstImageSubtitle = L10n.tr("Localizable", "AlbumDetailView.AddFirstImageSubtitle", fallback: "Import an image from your album or open the camera and take a new picture for this album")
    /// Album Cover
    public static let albumCoverMenuTitle = L10n.tr("Localizable", "AlbumDetailView.AlbumCoverMenuTitle", fallback: "Album Cover")
    /// Confirm Delete
    public static let confirmDeletion = L10n.tr("Localizable", "AlbumDetailView.ConfirmDeletion", fallback: "Confirm Delete")
    /// Cover image disabled
    public static let coverImageRemovedToast = L10n.tr("Localizable", "AlbumDetailView.CoverImageRemovedToast", fallback: "Cover image disabled")
    /// Cover image defaults to latest image
    public static let coverImageResetToast = L10n.tr("Localizable", "AlbumDetailView.CoverImageResetToast", fallback: "Cover image defaults to latest image")
    /// Do you want to delete %@?
    public static func deleteSelectedMedia(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.DeleteSelectedMedia", String(describing: p1), fallback: "Do you want to delete %@?")
    }
    /// Are you sure you want to hide this album? You MUST remember the name of this album to access it again.
    public static let hideAlbumAlertMessage = L10n.tr("Localizable", "AlbumDetailView.HideAlbumAlertMessage", fallback: "Are you sure you want to hide this album? You MUST remember the name of this album to access it again.")
    /// Hide this album?
    public static let hideAlbumAlertTitle = L10n.tr("Localizable", "AlbumDetailView.HideAlbumAlertTitle", fallback: "Hide this album?")
    /// Hide Album
    public static let hideAlbumMenuItem = L10n.tr("Localizable", "AlbumDetailView.HideAlbumMenuItem", fallback: "Hide Album")
    /// Import Pictures
    public static let importButton = L10n.tr("Localizable", "AlbumDetailView.ImportButton", fallback: "Import Pictures")
    /// Moved %@ item%@ to %@
    public static func movedToast(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MovedToast", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "Moved %@ item%@ to %@")
    }
    /// Move Media
    public static let moveMedia = L10n.tr("Localizable", "AlbumDetailView.MoveMedia", fallback: "Move Media")
    /// Move %@ item%@ to %@?
    public static func moveMediaConfirm(_ p1: Any, _ p2: Any, _ p3: Any) -> String {
      return L10n.tr("Localizable", "AlbumDetailView.MoveMediaConfirm", String(describing: p1), String(describing: p2), String(describing: p3), fallback: "Move %@ item%@ to %@?")
    }
    /// Because you don't have a paid license to Encamera, you will only be able to view 10 images in the app. If you delete images from your photo library, you may not be able to view them without a paid license.
    public static let noLicenseDeletionWarningMessage = L10n.tr("Localizable", "AlbumDetailView.NoLicenseDeletionWarningMessage", fallback: "Because you don't have a paid license to Encamera, you will only be able to view 10 images in the app. If you delete images from your photo library, you may not be able to view them without a paid license.")
    /// I Understand
    public static let noLicenseDeletionWarningPrimaryButton = L10n.tr("Localizable", "AlbumDetailView.NoLicenseDeletionWarningPrimaryButton", fallback: "I Understand")
    /// ⚠️ Important ⚠️
    public static let noLicenseDeletionWarningTitle = L10n.tr("Localizable", "AlbumDetailView.NoLicenseDeletionWarningTitle", fallback: "⚠️ Important ⚠️")
    /// Take a New Picture
    public static let openCamera = L10n.tr("Localizable", "AlbumDetailView.OpenCamera", fallback: "Take a New Picture")
    /// Open Settings
    public static let openSettings = L10n.tr("Localizable", "AlbumDetailView.OpenSettings", fallback: "Open Settings")
    /// Do you want to delete the images from your photo library after importing them? Encamera requires permission to your photo library to do this.
    public static let photoAccessAlertMessage = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessAlertMessage", fallback: "Do you want to delete the images from your photo library after importing them? Encamera requires permission to your photo library to do this.")
    /// Delete
    public static let photoAccessAlertPrimaryButton = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessAlertPrimaryButton", fallback: "Delete")
    /// Not Now
    public static let photoAccessAlertSecondaryButton = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessAlertSecondaryButton", fallback: "Not Now")
    /// Delete After Import?
    public static let photoAccessAlertTitle = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessAlertTitle", fallback: "Delete After Import?")
    /// Photo Access Required
    public static let photoAccessRequired = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessRequired", fallback: "Photo Access Required")
    /// Please grant access to your photo library in Settings to import photos.
    public static let photoAccessSettings = L10n.tr("Localizable", "AlbumDetailView.PhotoAccessSettings", fallback: "Please grant access to your photo library in Settings to import photos.")
    /// Disable Album Cover
    public static let removeCoverImage = L10n.tr("Localizable", "AlbumDetailView.RemoveCoverImage", fallback: "Disable Album Cover")
    /// Rename Album
    public static let renameAlbum = L10n.tr("Localizable", "AlbumDetailView.RenameAlbum", fallback: "Rename Album")
    /// Default to Latest Image
    public static let resetCoverImage = L10n.tr("Localizable", "AlbumDetailView.ResetCoverImage", fallback: "Default to Latest Image")
    /// Select Media
    public static let select = L10n.tr("Localizable", "AlbumDetailView.Select", fallback: "Select Media")
  }
  public enum AlbumSelectionModal {
    /// Select an album to move %@ items to
    public static func description(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AlbumSelectionModal.Description", String(describing: p1), fallback: "Select an album to move %@ items to")
    }
    /// Move
    public static let move = L10n.tr("Localizable", "AlbumSelectionModal.Move", fallback: "Move")
    /// ./Encamera/AlbumManagement/AlbumSelectionModal.swift
    public static let title = L10n.tr("Localizable", "AlbumSelectionModal.Title", fallback: "Move to Album")
  }
  public enum Alert {
    public enum LoadingFile {
      /// Please wait...
      public static let message = L10n.tr("Localizable", "Alert.LoadingFile.Message", fallback: "Please wait...")
      /// Loading File
      public static let title = L10n.tr("Localizable", "Alert.LoadingFile.Title", fallback: "Loading File")
    }
  }
  public enum AskForReview {
    /// Ask me later
    public static let askMeLater = L10n.tr("Localizable", "AskForReview.AskMeLater", fallback: "Ask me later")
    /// Are you enjoying the app?
    public static let enjoyingTheApp = L10n.tr("Localizable", "AskForReview.EnjoyingTheApp", fallback: "Are you enjoying the app?")
  }
  public enum AuthenticationMethod {
    /// Cancel
    public static let cancel = L10n.tr("Localizable", "AuthenticationMethod.Cancel", fallback: "Cancel")
    /// Do you really want to disable %@?
    public static func confirmDisable(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationMethod.ConfirmDisable", String(describing: p1), fallback: "Do you really want to disable %@?")
    }
    /// Do you really want to disable %@?
    public static func confirmDisableFaceID(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationMethod.ConfirmDisableFaceID", String(describing: p1), fallback: "Do you really want to disable %@?")
    }
    /// Do you really want to disable %@? This will clear the password you have stored.
    public static func confirmDisablePassword(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationMethod.ConfirmDisablePassword", String(describing: p1), fallback: "Do you really want to disable %@? This will clear the password you have stored.")
    }
    /// Do you really want to disable %@? This will clear the PIN code you have stored.
    public static func confirmDisablePinCode(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationMethod.ConfirmDisablePinCode", String(describing: p1), fallback: "Do you really want to disable %@? This will clear the PIN code you have stored.")
    }
    /// Disable
    public static let disable = L10n.tr("Localizable", "AuthenticationMethod.Disable", fallback: "Disable")
    /// Disable Passcode
    public static let disableTitle = L10n.tr("Localizable", "AuthenticationMethod.DisableTitle", fallback: "Disable Passcode")
    /// %@ cannot be used with the currently selected methods. PIN and Password cannot be used together.
    public static func incompatibleDetail(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationMethod.IncompatibleDetail", String(describing: p1), fallback: "%@ cannot be used with the currently selected methods. PIN and Password cannot be used together.")
    }
    /// The selected authentication methods are incompatible.
    public static let incompatibleMessage = L10n.tr("Localizable", "AuthenticationMethod.IncompatibleMessage", fallback: "The selected authentication methods are incompatible.")
    /// Authentication Method View
    public static let multipleMethodsInfo = L10n.tr("Localizable", "AuthenticationMethod.MultipleMethodsInfo", fallback: "You can select multiple authentication methods")
    /// OK
    public static let ok = L10n.tr("Localizable", "AuthenticationMethod.OK", fallback: "OK")
    /// Tap to disable the selected method
    public static let tapToDisableBanner = L10n.tr("Localizable", "AuthenticationMethod.TapToDisableBanner", fallback: "Tap to disable the selected method")
    public enum SecurityLevel {
      /// Authentication Method Security Levels
      public static let faceID = L10n.tr("Localizable", "AuthenticationMethod.SecurityLevel.FaceID", fallback: "Low protection")
      /// Most secure option
      public static let password = L10n.tr("Localizable", "AuthenticationMethod.SecurityLevel.password", fallback: "Most secure option")
      /// Moderate protection
      public static let pinCode = L10n.tr("Localizable", "AuthenticationMethod.SecurityLevel.PinCode", fallback: "Moderate protection")
      /// Quick but less secure
      public static let pinCode4Digit = L10n.tr("Localizable", "AuthenticationMethod.SecurityLevel.pinCode4Digit", fallback: "Quick but less secure")
      /// More secure PIN code
      public static let pinCode6Digit = L10n.tr("Localizable", "AuthenticationMethod.SecurityLevel.pinCode6Digit", fallback: "More secure PIN code")
    }
    public enum TextDescription {
      /// Authentication Method Text Descriptions
      public static let faceID = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.FaceID", fallback: "Face ID")
      /// Password
      public static let password = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.Password", fallback: "Password")
      /// Pin Code
      public static let pinCode = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.PinCode", fallback: "Pin Code")
      /// Authentication Method Types
      public static let pinCode4Digit = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.pinCode4Digit", fallback: "4-digit PIN")
      /// 6-digit PIN
      public static let pinCode6Digit = L10n.tr("Localizable", "AuthenticationMethod.TextDescription.pinCode6Digit", fallback: "6-digit PIN")
    }
  }
  public enum AuthenticationView {
    /// Forgot Password? Reset App
    public static let forgotPassword = L10n.tr("Localizable", "AuthenticationView.ForgotPassword", fallback: "Forgot Password? Reset App")
    /// You can retry your password in %@
    public static func retryIn(_ p1: Any) -> String {
      return L10n.tr("Localizable", "AuthenticationView.RetryIn", String(describing: p1), fallback: "You can retry your password in %@")
    }
    /// ./Encamera/AuthenticationView/AuthenticationView.swift
    public static let tooManyAttempts = L10n.tr("Localizable", "AuthenticationView.TooManyAttempts", fallback: "Too many attempts")
  }
  public enum ChangingYourAuthenticationMethodWillRequireSettingUpANewPINOrPassword {
    /// Changing your authentication method will require setting up a new PIN or password. Would you like to continue?
    public static let wouldYouLikeToContinue = L10n.tr("Localizable", "Changing your authentication method will require setting up a new PIN or password. Would you like to continue?", fallback: "Changing your authentication method will require setting up a new PIN or password. Would you like to continue?")
  }
  public enum CustomPhotoPicker {
    /// Add
    public static let add = L10n.tr("Localizable", "CustomPhotoPicker.Add", fallback: "Add")
    /// Please grant full access to your photo library to use swipe selection. You can change this in Settings.
    public static let grantAccessMessage = L10n.tr("Localizable", "CustomPhotoPicker.GrantAccessMessage", fallback: "Please grant full access to your photo library to use swipe selection. You can change this in Settings.")
    /// Limited access. Tap here to select more photos or grant full access.
    public static let limitedAccess = L10n.tr("Localizable", "CustomPhotoPicker.LimitedAccess", fallback: "Limited access. Tap here to select more photos or grant full access.")
    /// Photo Access Required
    public static let photoAccessRequired = L10n.tr("Localizable", "CustomPhotoPicker.PhotoAccessRequired", fallback: "Photo Access Required")
    /// %@ Selected
    public static func selected(_ p1: Any) -> String {
      return L10n.tr("Localizable", "CustomPhotoPicker.Selected", String(describing: p1), fallback: "%@ Selected")
    }
    /// Select Photos
    public static let selectPhotos = L10n.tr("Localizable", "CustomPhotoPicker.SelectPhotos", fallback: "Select Photos")
    /// ./Encamera/Components/CustomPhotoPicker.swift
    public static let swipeInstruction = L10n.tr("Localizable", "CustomPhotoPicker.SwipeInstruction", fallback: "Long press & swipe to select multiple photos")
  }
  public enum EnterTheNameOfTheKeyToDeleteItForever {
    /// Enter the name of the key to delete it forever. All media will remain saved.
    public static let allMediaWillRemainSaved = L10n.tr("Localizable", "Enter the name of the key to delete it forever. All media will remain saved.", fallback: "Enter the name of the key to delete it forever. All media will remain saved.")
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
  public enum ErrorDeletingKey {
    /// ./Encamera/KeyManagement/AlbumDetailView.swift
    public static let pleaseTryAgain = L10n.tr("Localizable", "Error deleting key. Please try again.", fallback: "Error deleting key. Please try again.")
  }
  public enum ErrorDeletingKeyAndAssociatedFiles {
    /// Error deleting key and associated files. Please try again or try to delete files manually via the Files app.
    public static let pleaseTryAgainOrTryToDeleteFilesManuallyViaTheFilesApp = L10n.tr("Localizable", "Error deleting key and associated files. Please try again or try to delete files manually via the Files app.", fallback: "Error deleting key and associated files. Please try again or try to delete files manually via the Files app.")
  }
  public enum FaceIDOnlyAlert {
    /// Cancel
    public static let cancel = L10n.tr("Localizable", "FaceIDOnlyAlert.Cancel", fallback: "Cancel")
    /// Continue
    public static let `continue` = L10n.tr("Localizable", "FaceIDOnlyAlert.Continue", fallback: "Continue")
    /// Switching to Face ID only will clear your current PIN/password. You will only be able to unlock the app using Face ID.
    public static let message = L10n.tr("Localizable", "FaceIDOnlyAlert.Message", fallback: "Switching to Face ID only will clear your current PIN/password. You will only be able to unlock the app using Face ID.")
    /// Clear PIN/Password?
    public static let title = L10n.tr("Localizable", "FaceIDOnlyAlert.Title", fallback: "Clear PIN/Password?")
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
  public enum FooterView {
    /// Media Details
    public static let mediaDetails = L10n.tr("Localizable", "FooterView.MediaDetails", fallback: "Media Details")
  }
  public enum GalleryView {
    /// Album cover set
    public static let albumCoverSetToast = L10n.tr("Localizable", "GalleryView.AlbumCoverSetToast", fallback: "Album cover set")
    /// Make Album Cover
    public static let makeAlbumCover = L10n.tr("Localizable", "GalleryView.MakeAlbumCover", fallback: "Make Album Cover")
    /// Live Photo - Hold to View
    public static let playLivePhoto = L10n.tr("Localizable", "GalleryView.PlayLivePhoto", fallback: "Live Photo - Hold to View")
  }
  public enum GlobalImportProgress {
    /// Delete from Photo Library?
    public static let deleteFromPhotoLibraryAlert = L10n.tr("Localizable", "GlobalImportProgress.DeleteFromPhotoLibraryAlert", fallback: "Delete from Photo Library?")
    /// This will delete all imported photos from your Photo Library.
    public static let deleteFromPhotoLibraryMessage = L10n.tr("Localizable", "GlobalImportProgress.DeleteFromPhotoLibraryMessage", fallback: "This will delete all imported photos from your Photo Library.")
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
    /// No active imports
    public static let noActiveImports = L10n.tr("Localizable", "GlobalImportProgress.NoActiveImports", fallback: "No active imports")
  }
  public enum HideAlbumsTutorial {
    /// Keep your albums private
    public static let heading1 = L10n.tr("Localizable", "HideAlbumsTutorial.Heading1", fallback: "Keep your albums private")
    /// Access hidden albums
    public static let heading2 = L10n.tr("Localizable", "HideAlbumsTutorial.Heading2", fallback: "Access hidden albums")
    /// Remember album names
    public static let heading3 = L10n.tr("Localizable", "HideAlbumsTutorial.Heading3", fallback: "Remember album names")
    /// Hide an album
    public static let heading4 = L10n.tr("Localizable", "HideAlbumsTutorial.Heading4", fallback: "Hide an album")
    /// Encamera allows you to hide albums from the main view for extra privacy.
    public static let subheading1 = L10n.tr("Localizable", "HideAlbumsTutorial.Subheading1", fallback: "Encamera allows you to hide albums from the main view for extra privacy.")
    /// To access a hidden album, simply search for its name in the search bar.
    public static let subheading2 = L10n.tr("Localizable", "HideAlbumsTutorial.Subheading2", fallback: "To access a hidden album, simply search for its name in the search bar.")
    /// Make sure to remember the names of your hidden albums, as they won't appear in your album list.
    public static let subheading3 = L10n.tr("Localizable", "HideAlbumsTutorial.Subheading3", fallback: "Make sure to remember the names of your hidden albums, as they won't appear in your album list.")
    /// To hide an album, open it and tap the three dots menu, then select 'Hide Album'.
    public static let subheading4 = L10n.tr("Localizable", "HideAlbumsTutorial.Subheading4", fallback: "To hide an album, open it and tap the three dots menu, then select 'Hide Album'.")
    /// Hide Albums Tutorial
    public static let title = L10n.tr("Localizable", "HideAlbumsTutorial.Title", fallback: "Hide Albums")
  }
  public enum ImportTaskDetailsView {
    /// Clear All
    public static let clearAll = L10n.tr("Localizable", "ImportTaskDetailsView.ClearAll", fallback: "Clear All")
    /// Done
    public static let done = L10n.tr("Localizable", "ImportTaskDetailsView.Done", fallback: "Done")
    /// ./Encamera/Components/ImportProgress/ImportTaskDetailsView.swift
    public static let title = L10n.tr("Localizable", "ImportTaskDetailsView.Title", fallback: "Import Tasks")
  }
  public enum KeyCopiedToClipboard {
    /// Key copied to clipboard. Store this in a password manager or other secure place.
    public static let storeThisInAPasswordManagerOrOtherSecurePlace = L10n.tr("Localizable", "Key copied to clipboard. Store this in a password manager or other secure place.", fallback: "Key copied to clipboard. Store this in a password manager or other secure place.")
  }
  public enum MediaSelectionTray {
    /// Selected
    public static let itemSelected = L10n.tr("Localizable", "MediaSelectionTray.ItemSelected", fallback: "Selected")
    /// Move
    public static let moveMedia = L10n.tr("Localizable", "MediaSelectionTray.MoveMedia", fallback: "Move")
    /// ./Encamera/AlbumManagement/MediaSelectionTray.swift
    public static let moveToAlbum = L10n.tr("Localizable", "MediaSelectionTray.MoveToAlbum", fallback: "Move to Album")
    /// Select Media
    public static let selectMedia = L10n.tr("Localizable", "MediaSelectionTray.SelectMedia", fallback: "Select Media")
  }
  public enum Notification {
    /// Unknown notification identifier
    public static let unknownIdentifier = L10n.tr("Localizable", "Notification.UnknownIdentifier", fallback: "Unknown notification identifier")
    public enum ImageSaveReminder {
      /// Hope you like Encamera - This is why we need you to help us with a review. Tap here!
      public static let body = L10n.tr("Localizable", "Notification.ImageSaveReminder.Body", fallback: "Hope you like Encamera - This is why we need you to help us with a review. Tap here!")
      /// We would like your support 🙏
      public static let title = L10n.tr("Localizable", "Notification.ImageSaveReminder.Title", fallback: "We would like your support 🙏")
    }
    public enum ImageSecurityReminder {
      /// You can also save videos to your albums, not only images. Try it now and secure some!
      public static let body = L10n.tr("Localizable", "Notification.ImageSecurityReminder.Body", fallback: "You can also save videos to your albums, not only images. Try it now and secure some!")
      /// Did you know? 🤔
      public static let title = L10n.tr("Localizable", "Notification.ImageSecurityReminder.Title", fallback: "Did you know? 🤔")
    }
    public enum ImportImages {
      /// Prompting user to import more images for security.
      public static let prompt = L10n.tr("Localizable", "Notification.ImportImages.Prompt", fallback: "Prompting user to import more images for security.")
    }
    public enum InactiveUserReminder {
      /// Don't forget to secure more images by adding them to your album. Import now!
      public static let body = L10n.tr("Localizable", "Notification.InactiveUserReminder.Body", fallback: "Don't forget to secure more images by adding them to your album. Import now!")
      /// Your images might be at risk 🚨
      public static let title = L10n.tr("Localizable", "Notification.InactiveUserReminder.Title", fallback: "Your images might be at risk 🚨")
    }
    public enum Permission {
      /// Error requesting local notification permissions: %@
      public static func error(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Notification.Permission.Error", String(describing: p1), fallback: "Error requesting local notification permissions: %@")
      }
      /// Local notification permissions granted.
      public static let granted = L10n.tr("Localizable", "Notification.Permission.Granted", fallback: "Local notification permissions granted.")
      /// Error requesting remote notification permissions: %@
      public static func remoteError(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Notification.Permission.RemoteError", String(describing: p1), fallback: "Error requesting remote notification permissions: %@")
      }
    }
    public enum PremiumPage {
      /// Navigating to the premium plan purchase page.
      public static let navigation = L10n.tr("Localizable", "Notification.PremiumPage.Navigation", fallback: "Navigating to the premium plan purchase page.")
    }
    public enum PremiumReminder {
      /// Use code 'ENCAMERA20' to get a 20%% discount on any plan. Hurry up!
      public static let body = L10n.tr("Localizable", "Notification.PremiumReminder.Body", fallback: "Use code 'ENCAMERA20' to get a 20%% discount on any plan. Hurry up!")
      /// 20%% Discount - Limited time 📅
      public static let title = L10n.tr("Localizable", "Notification.PremiumReminder.Title", fallback: "20%% Discount - Limited time 📅")
    }
    public enum ReviewPage {
      /// Navigating to the review submission page.
      public static let navigation = L10n.tr("Localizable", "Notification.ReviewPage.Navigation", fallback: "Navigating to the review submission page.")
    }
    public enum Scheduling {
      /// Error scheduling notification: %@
      public static func error(_ p1: Any) -> String {
        return L10n.tr("Localizable", "Notification.Scheduling.Error", String(describing: p1), fallback: "Error scheduling notification: %@")
      }
    }
    public enum VideoSave {
      /// Showing educational content on how to save videos.
      public static let educationalContent = L10n.tr("Localizable", "Notification.VideoSave.EducationalContent", fallback: "Showing educational content on how to save videos.")
    }
    public enum WidgetReminder {
      /// Don't forget to add the widget on the lock screen and take images quickly. See how!
      public static let body = L10n.tr("Localizable", "Notification.WidgetReminder.Body", fallback: "Don't forget to add the widget on the lock screen and take images quickly. See how!")
      /// Take directly encrypted photos 📸
      public static let title = L10n.tr("Localizable", "Notification.WidgetReminder.Title", fallback: "Take directly encrypted photos 📸")
    }
    public enum WidgetSetup {
      /// Guiding user to add a widget to the lock screen.
      public static let guidance = L10n.tr("Localizable", "Notification.WidgetSetup.Guidance", fallback: "Guiding user to add a widget to the lock screen.")
    }
  }
  public enum NotificationBanner {
    public enum LeaveAReview {
      /// If you like Encamera, help us out with a review!
      public static let body = L10n.tr("Localizable", "NotificationBanner.LeaveAReview.Body", fallback: "If you like Encamera, help us out with a review!")
      /// We need your help!
      public static let title = L10n.tr("Localizable", "NotificationBanner.LeaveAReview.Title", fallback: "We need your help!")
    }
    public enum Reddit {
      /// Join the Encamera subreddit to follow the latest and give feedback
      public static let body = L10n.tr("Localizable", "NotificationBanner.Reddit.Body", fallback: "Join the Encamera subreddit to follow the latest and give feedback")
      /// Join Subreddit
      public static let button = L10n.tr("Localizable", "NotificationBanner.Reddit.Button", fallback: "Join Subreddit")
      /// Are you on Reddit?
      public static let title = L10n.tr("Localizable", "NotificationBanner.Reddit.Title", fallback: "Are you on Reddit?")
    }
  }
  public enum PhotoPickerWrapper {
    /// Continue with Limited Access
    public static let continueLimited = L10n.tr("Localizable", "PhotoPickerWrapper.ContinueLimited", fallback: "Continue with Limited Access")
    /// Enable Swipe Selection
    public static let enableSwipeSelection = L10n.tr("Localizable", "PhotoPickerWrapper.EnableSwipeSelection", fallback: "Enable Swipe Selection")
    /// Faster Import
    public static let fasterImport = L10n.tr("Localizable", "PhotoPickerWrapper.FasterImport", fallback: "Faster Import")
    /// Import photos much more quickly
    public static let fasterImportDescription = L10n.tr("Localizable", "PhotoPickerWrapper.FasterImportDescription", fallback: "Import photos much more quickly")
    /// Grant Access
    public static let grantAccess = L10n.tr("Localizable", "PhotoPickerWrapper.GrantAccess", fallback: "Grant Access")
    /// Grant full access to your photos to enable swipe-to-select multiple photos at once!
    public static let grantAccessDescription = L10n.tr("Localizable", "PhotoPickerWrapper.GrantAccessDescription", fallback: "Grant full access to your photos to enable swipe-to-select multiple photos at once!")
    /// Grant Full Access
    public static let grantFullAccess = L10n.tr("Localizable", "PhotoPickerWrapper.GrantFullAccess", fallback: "Grant Full Access")
    /// Not Now
    public static let notNow = L10n.tr("Localizable", "PhotoPickerWrapper.NotNow", fallback: "Not Now")
    /// Your photos stay encrypted and private
    public static let privacyDescription = L10n.tr("Localizable", "PhotoPickerWrapper.PrivacyDescription", fallback: "Your photos stay encrypted and private")
    /// Privacy First
    public static let privacyFirst = L10n.tr("Localizable", "PhotoPickerWrapper.PrivacyFirst", fallback: "Privacy First")
    /// Select multiple photos with a single swipe
    public static let swipeDescription = L10n.tr("Localizable", "PhotoPickerWrapper.SwipeDescription", fallback: "Select multiple photos with a single swipe")
    /// Swipe to Select
    public static let swipeToSelect = L10n.tr("Localizable", "PhotoPickerWrapper.SwipeToSelect", fallback: "Swipe to Select")
    /// You currently have limited photo access. Grant full access to enable swipe-to-select multiple photos at once, making importing much faster!
    public static let upgradeMessage = L10n.tr("Localizable", "PhotoPickerWrapper.UpgradeMessage", fallback: "You currently have limited photo access. Grant full access to enable swipe-to-select multiple photos at once, making importing much faster!")
    /// ./Encamera/Components/PhotoPickerWrapper.swift
    public static let upgradeTitle = L10n.tr("Localizable", "PhotoPickerWrapper.UpgradeTitle", fallback: "Upgrade to Full Photo Access")
    /// Upgrade to Full Access
    public static let upgradeToFullAccess = L10n.tr("Localizable", "PhotoPickerWrapper.UpgradeToFullAccess", fallback: "Upgrade to Full Access")
  }
  public enum PostPurchaseView {
    /// Maybe Later
    public static let maybeLater = L10n.tr("Localizable", "PostPurchaseView.MaybeLater", fallback: "Maybe Later")
    /// Help us with a review
    public static let reviewButton = L10n.tr("Localizable", "PostPurchaseView.ReviewButton", fallback: "Help us with a review")
    /// You are one of the early supporters of Encamera and we thank you for the support!
    public static let subtext1 = L10n.tr("Localizable", "PostPurchaseView.Subtext1", fallback: "You are one of the early supporters of Encamera and we thank you for the support!")
    /// In the meantime, we will highly appreciate if you could help us with a Review on the App Store
    public static let subtext2 = L10n.tr("Localizable", "PostPurchaseView.Subtext2", fallback: "In the meantime, we will highly appreciate if you could help us with a Review on the App Store")
    /// Thanks for your purchase!
    public static let thanksForYourPurchase = L10n.tr("Localizable", "PostPurchaseView.ThanksForYourPurchase", fallback: "Thanks for your purchase!")
  }
  public enum ProgressView {
    /// Decrypting: %.0f%%
    public static func decrypting(_ p1: Float) -> String {
      return L10n.tr("Localizable", "ProgressView.Decrypting", p1, fallback: "Decrypting: %.0f%%")
    }
    /// Downloading: %.0f%%
    public static func downloading(_ p1: Float) -> String {
      return L10n.tr("Localizable", "ProgressView.Downloading", p1, fallback: "Downloading: %.0f%%")
    }
    /// File loaded successfully
    public static let fileLoadedSuccessfully = L10n.tr("Localizable", "ProgressView.FileLoadedSuccessfully", fallback: "File loaded successfully")
    /// Starting download...
    public static let startingDownload = L10n.tr("Localizable", "ProgressView.StartingDownload", fallback: "Starting download...")
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
  public enum PurchaseView {
    /// Unlock all of these benefits:
    public static let unlockBenefits = L10n.tr("Localizable", "PurchaseView.UnlockBenefits", fallback: "Unlock all of these benefits:")
    /// Your Premium benefits:
    public static let yourBenefits = L10n.tr("Localizable", "PurchaseView.YourBenefits", fallback: "Your Premium benefits:")
    public enum BenefitModel {
      /// Backup keychain to iCloud
      public static let backupKeychain = L10n.tr("Localizable", "PurchaseView.BenefitModel.BackupKeychain", fallback: "Backup keychain to iCloud")
      /// Change app icon
      public static let changeAppIcon = L10n.tr("Localizable", "PurchaseView.BenefitModel.ChangeAppIcon", fallback: "Change app icon")
      /// Coming Soon
      public static let comingSoon = L10n.tr("Localizable", "PurchaseView.BenefitModel.ComingSoon", fallback: "Coming Soon")
      /// Hidden albums
      public static let hiddenAlbums = L10n.tr("Localizable", "PurchaseView.BenefitModel.HiddenAlbums", fallback: "Hidden albums")
      /// iCloud storage & backup
      public static let iCloudStorage = L10n.tr("Localizable", "PurchaseView.BenefitModel.iCloudStorage", fallback: "iCloud storage & backup")
      /// Unlimited albums for your memories
      public static let unlimitedAlbums = L10n.tr("Localizable", "PurchaseView.BenefitModel.UnlimitedAlbums", fallback: "Unlimited albums for your memories")
      /// Unlimited storage for photos & videos
      public static let unlimitedStorage = L10n.tr("Localizable", "PurchaseView.BenefitModel.UnlimitedStorage", fallback: "Unlimited storage for photos & videos")
    }
  }
  public enum Settings {
    /// Backup Key Phrase
    public static let backupKeyPhrase = L10n.tr("Localizable", "Settings.BackupKeyPhrase", fallback: "Backup Key Phrase")
    /// Sync Key to iCloud
    public static let backupKeyToiCloud = L10n.tr("Localizable", "Settings.BackupKeyToiCloud", fallback: "Sync Key to iCloud")
    /// Contact Support
    public static let contact = L10n.tr("Localizable", "Settings.Contact", fallback: "Contact Support")
    /// Default Storage Option
    public static let defaultStorageOption = L10n.tr("Localizable", "Settings.DefaultStorageOption", fallback: "Default Storage Option")
    /// Give Instant Feedback
    public static let giveInstantFeedback = L10n.tr("Localizable", "Settings.GiveInstantFeedback", fallback: "Give Instant Feedback")
    /// Import Key Phrase
    public static let importKeyPhrase = L10n.tr("Localizable", "Settings.ImportKeyPhrase", fallback: "Import Key Phrase")
    /// Purchases restored!
    public static let purchasesRestored = L10n.tr("Localizable", "Settings.PurchasesRestored", fallback: "Purchases restored!")
    /// Any valid purchases you made have been restored.
    public static let purchasesRestoredMessage = L10n.tr("Localizable", "Settings.PurchasesRestoredMessage", fallback: "Any valid purchases you made have been restored.")
    /// Version
    public static let version = L10n.tr("Localizable", "Settings.Version", fallback: "Version")
  }
  public enum SettingsView {
    /// ./Encamera/Settings/SettingsView.swift
    public static let unknownError = L10n.tr("Localizable", "SettingsView.UnknownError", fallback: "Unknown error")
  }
  public enum SplashScreen {
    /// Secure Your Memories
    public static let subline = L10n.tr("Localizable", "SplashScreen.Subline", fallback: "Secure Your Memories")
  }
  public enum TaskDetailCard {
    /// Created: %@
    public static func created(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskDetailCard.Created", String(describing: p1), fallback: "Created: %@")
    }
    /// Current: %@
    public static func current(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskDetailCard.Current", String(describing: p1), fallback: "Current: %@")
    }
    /// Delete From Camera Roll
    public static let deleteFromCameraRoll = L10n.tr("Localizable", "TaskDetailCard.DeleteFromCameraRoll", fallback: "Delete From Camera Roll")
    /// This will delete %@ photo(s) from your Photo Library that were imported into Encamera.
    public static func deleteMessage(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskDetailCard.DeleteMessage", String(describing: p1), fallback: "This will delete %@ photo(s) from your Photo Library that were imported into Encamera.")
    }
    /// Estimated time remaining: %@
    public static func estimatedTime(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskDetailCard.EstimatedTime", String(describing: p1), fallback: "Estimated time remaining: %@")
    }
    /// Please grant full access to your photo library in Settings to delete imported photos.
    public static let grantAccessMessage = L10n.tr("Localizable", "TaskDetailCard.GrantAccessMessage", fallback: "Please grant full access to your photo library in Settings to delete imported photos.")
    /// Pause
    public static let pause = L10n.tr("Localizable", "TaskDetailCard.Pause", fallback: "Pause")
    /// Photo Library Access Required
    public static let photoLibraryAccessRequired = L10n.tr("Localizable", "TaskDetailCard.PhotoLibraryAccessRequired", fallback: "Photo Library Access Required")
    /// Progress:
    public static let progress = L10n.tr("Localizable", "TaskDetailCard.Progress", fallback: "Progress:")
    /// Resume
    public static let resume = L10n.tr("Localizable", "TaskDetailCard.Resume", fallback: "Resume")
    /// Cancelled
    public static let statusCancelled = L10n.tr("Localizable", "TaskDetailCard.StatusCancelled", fallback: "Cancelled")
    /// Completed
    public static let statusCompleted = L10n.tr("Localizable", "TaskDetailCard.StatusCompleted", fallback: "Completed")
    /// Failed
    public static let statusFailed = L10n.tr("Localizable", "TaskDetailCard.StatusFailed", fallback: "Failed")
    /// Paused
    public static let statusPaused = L10n.tr("Localizable", "TaskDetailCard.StatusPaused", fallback: "Paused")
    /// Running
    public static let statusRunning = L10n.tr("Localizable", "TaskDetailCard.StatusRunning", fallback: "Running")
    /// Waiting
    public static let statusWaiting = L10n.tr("Localizable", "TaskDetailCard.StatusWaiting", fallback: "Waiting")
    /// ./Encamera/Components/ImportProgress/TaskDetailCard.swift
    public static func taskID(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskDetailCard.TaskID", String(describing: p1), fallback: "Task ID: %@")
    }
    /// Unknown
    public static let unknown = L10n.tr("Localizable", "TaskDetailCard.Unknown", fallback: "Unknown")
  }
  public enum TaskProgressRow {
    /// ./Encamera/Components/ImportProgress/TaskProgressRow.swift
    public static func processing(_ p1: Any) -> String {
      return L10n.tr("Localizable", "TaskProgressRow.Processing", String(describing: p1), fallback: "Processing: %@")
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
