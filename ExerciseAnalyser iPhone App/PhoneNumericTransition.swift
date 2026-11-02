import SwiftUI

struct PhoneNumericTransition<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let animateDigits = !reduceMotion && scenePhase == .active
        content
            .contentTransition(animateDigits ? .numericText() : .identity)
            .animation(animateDigits ? .easeInOut(duration: 0.3) : nil, value: value)
            .id(animateDigits)
            .transaction { transaction in
                if !animateDigits {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}
