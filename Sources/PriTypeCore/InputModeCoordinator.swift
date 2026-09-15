import Foundation

/// Coordinates PriType-owned language toggles.
///
/// Custom toggle keys must not select the real macOS ABC input source. Doing so
/// hands the active text session to another input source and reintroduces
/// first-key races. This coordinator keeps the custom toggle path inside
/// PriType: key monitor -> controller -> composer.
///
/// macOS "Caps Lock으로 입력 소스 전환" is NOT a reason to refuse a custom toggle:
/// Caps Lock switches between the two registered PriType modes and reaches the
/// composer through `PriTypeInputController.setValue(_:forTag:)`, the custom key
/// reaches it through `performPriTypeModeTransition`, and both converge on the
/// same `HangulComposer.inputMode`. The only policy left here is that an active
/// controller must exist (otherwise a lone composer flip would desync the next
/// activation's first key).
public final class InputModeCoordinator: @unchecked Sendable {
    public static let shared = InputModeCoordinator()

    public enum ToggleSource: Sendable {
        case customKey
        case iokitFallback
    }

    private init() {}

    public func requestToggle(source: ToggleSource) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.requestToggle(source: source)
            }
            return
        }

        guard let controller = PriTypeInputController.sharedController else {
            DebugLogger.log("InputModeCoordinator: ignored custom toggle because no active controller exists")
            return
        }

        controller.performPriTypeModeTransition(source: source)
    }
}
