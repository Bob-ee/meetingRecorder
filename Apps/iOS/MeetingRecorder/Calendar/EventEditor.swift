import EventKitUI
import SwiftUI

/// The system's "New Event" sheet, filled in from a draft. Using it rather than our own form means the user
/// picks the calendar, alerts and invitees the way they do everywhere else — and the app never needs to read
/// their calendar to offer that.
struct EventEditor: UIViewControllerRepresentable {
    let draft: EventDraft
    /// Called once the event has been saved.
    let onAdded: () -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = CalendarService.shared.store
        controller.event = CalendarService.shared.event(from: draft)
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        private let editor: EventEditor
        init(_ editor: EventEditor) { self.editor = editor }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            if action == .saved { editor.onAdded() }
            editor.dismiss()
        }
    }
}
