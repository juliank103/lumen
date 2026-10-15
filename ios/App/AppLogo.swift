import SwiftUI
import UIKit

/// The delivery app as a small app-icon-style logo (user, Oct 14: logos instead of names on the Offers page).
/// Uses an image named `logo-doordash` / `logo-uber_eats` / `logo-grubhub` when one is added to the asset catalog;
/// otherwise a brand-colored stand-in with the app's initials.
struct AppLogo: View {
    let platform: String
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let image = UIImage(named: "logo-" + platform) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    style.background
                    Text(style.mark)
                        .font(.system(size: size * (style.mark.count > 2 ? 0.3 : 0.4), weight: .black, design: .rounded))
                        .foregroundStyle(style.foreground)
                        .minimumScaleFactor(0.5)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityLabel(Theme.appName(platform))
    }

    private var style: (background: Color, foreground: Color, mark: String) {
        switch platform {
        case "doordash": return (Color(red: 1.0, green: 0.19, blue: 0.03), .white, "DD")
        case "uber_eats": return (Color(red: 0.02, green: 0.76, blue: 0.40), .black, "Eats")
        case "grubhub": return (Color(red: 1.0, green: 0.50, blue: 0.0), .white, "GH")
        default: return (Theme.purple, .white, String(platform.prefix(2)).uppercased())
        }
    }
}
