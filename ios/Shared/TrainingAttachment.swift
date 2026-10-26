import Foundation

/// Training screens travel from the reader to the app on the offer's verdict notification (Oct 26), as an attachment
/// with its thumbnail hidden. The reader must not write to Photos itself: loading Photos inside the ~50 MB broadcast
/// extension got it killed on the first offer (Oct 25). A named pasteboard didn't arrive on this install either
/// ("0 saved, 0 waiting", Oct 26); notifications are how offers already reach the app.
enum TrainingAttachment {
    static let identifier = "training-screen"
    /// userInfo key: the file name the screen gets in Photos ("__APP_NAME__ <time> <app>.jpg").
    static let nameKey = "trainingName"
}
