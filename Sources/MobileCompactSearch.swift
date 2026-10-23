import SwiftUI

/// UIKit owns the iOS 26 header-search morph; older iOS keeps native toolbar search.
struct MobileCompactSearch: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.searchToolbarBehavior(.minimize) }
        else { content }
    }
}
