import SwiftUI

/// A number with a text field and a stepper. The value is clamped to `range`.
struct NumberRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = "pt"

    var body: some View {
        LabeledRow(title) {
            TextField(title, value: clamped, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Text(unit).foregroundColor(.secondary).frame(minWidth: 18, alignment: .leading)
            Stepper(title, value: clamped, in: range, step: step).labelsHidden()
        }
    }

    private var clamped: Binding<Double> {
        Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) })
    }
}

/// A part of 1 (for example 0.5) shown and edited as a percentage (50 %).
struct PercentRow: View {
    let title: String
    @Binding var fraction: Double
    /// In percent.
    let range: ClosedRange<Double>
    var step: Double = 5

    var body: some View {
        NumberRow(title: title, value: Binding(get: { fraction * 100 }, set: { fraction = $0 / 100 }),
                  range: range, step: step, unit: "%")
    }
}

/// A slider with its current value as text.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let label: (Double) -> String

    var body: some View {
        LabeledRow(title) {
            Slider(value: rounded, in: range)
                .labelsHidden()
            .frame(minWidth: 160, maxWidth: 240)
            Text(label(value))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    /// A continuous slider without tick marks; the stored value is rounded to `step`.
    private var rounded: Binding<Double> {
        Binding(get: { value }, set: { new in
            guard let step, step > 0 else { value = new; return }
            let snapped = ((new / step).rounded() * step * 1000).rounded() / 1000
            value = min(max(snapped, range.lowerBound), range.upperBound)
        })
    }
}

/// Title on the left, controls on the right. Works the same on macOS 13 and later.
struct LabeledRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            content
        }
    }
}

/// Small grey text under a control.
struct Note: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Same as `@State`. The macOS 27 SDK also declares `State` as a macro whose plugin ships only
/// with Xcode, so `@State` does not compile with the Command Line Tools. The alias names the
/// property wrapper directly.
typealias ViewState = SwiftUI.State
