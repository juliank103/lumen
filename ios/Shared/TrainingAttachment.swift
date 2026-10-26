import Foundation

/// Training screens travel from the reader to the app as an attachment (thumbnail hidden) on their own silent
/// notification, sent right after the offer's verdict. The reader must not write to Photos itself: loading Photos inside
/// the ~50 MB broadcast extension got it killed on the first offer (Oct 25). A named pasteboard didn't arrive on this
/// install either ("0 saved, 0 waiting", Oct 26). Riding on the verdict itself worked for a shift, then verdicts stopped
/// coming with the switch on (Oct 27) — so never on the verdict.
enum TrainingAttachment {
    static let identifier = "training-screen"
    /// The silent notification carrying a screen: this + the offer's notification id.
    static let requestPrefix = "training-"
    /// userInfo key: the file name the screen gets in Photos ("__APP_NAME__ <time> <app>.jpg").
    static let nameKey = "trainingName"
}
