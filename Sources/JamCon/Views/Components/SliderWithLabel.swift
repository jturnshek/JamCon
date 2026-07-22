import SwiftUI

enum NumericSettingNormalizer {
    static func normalize(
        _ value: Double,
        in range: ClosedRange<Double>,
        step: Double
    ) -> Double {
        guard value.isFinite else { return range.lowerBound }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard step.isFinite, step > 0 else { return clamped }

        let stepCount = ((clamped - range.lowerBound) / step).rounded()
        let stepped = range.lowerBound + stepCount * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}

/// Slider paired with a validated, directly editable numeric value.
struct PreciseSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    var suffix = ""
    var fieldWidth: CGFloat = 62

    @State private var draft = ""
    @FocusState private var fieldIsFocused: Bool

    private var normalizedBinding: Binding<Double> {
        Binding(
            get: { value },
            set: {
                value = NumericSettingNormalizer.normalize($0, in: range, step: step)
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: normalizedBinding, in: range, step: step)

            TextField("Value", text: $draft)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: fieldWidth)
                .focused($fieldIsFocused)
                .onSubmit(commitDraft)

            if !suffix.isEmpty {
                Text(suffix)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 18, alignment: .leading)
            }
        }
        .onAppear(perform: synchronizeDraft)
        .onChange(of: value) { _, _ in
            if !fieldIsFocused {
                synchronizeDraft()
            }
        }
        .onChange(of: fieldIsFocused) { _, focused in
            if !focused {
                commitDraft()
            }
        }
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        let parseable = decimalSeparator == "."
            ? trimmed
            : trimmed.replacingOccurrences(of: decimalSeparator, with: ".")

        guard let parsed = Double(parseable), parsed.isFinite else {
            synchronizeDraft()
            return
        }
        value = NumericSettingNormalizer.normalize(parsed, in: range, step: step)
        synchronizeDraft()
    }

    private func synchronizeDraft() {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        draft = formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// Reusable slider component with label and formatted value display
struct SliderWithLabel: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var sliderWidth: CGFloat = 200
    var valueWidth: CGFloat = 50

    var body: some View {
        LabeledContent(label) {
            HStack {
                Slider(value: $value, in: range)
                    .frame(width: sliderWidth)
                Text(String(format: format, value))
                    .monospacedDigit()
                    .frame(width: valueWidth)
            }
        }
    }
}

/// Integer variant of SliderWithLabel
struct IntSliderWithLabel: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var sliderWidth: CGFloat = 200
    var valueWidth: CGFloat = 30

    private var doubleBinding: Binding<Double> {
        Binding(
            get: { Double(value) },
            set: { value = Int($0) }
        )
    }

    var body: some View {
        LabeledContent(label) {
            HStack {
                Slider(value: doubleBinding, in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                    .frame(width: sliderWidth)
                Text("\(value)")
                    .monospacedDigit()
                    .frame(width: valueWidth)
            }
        }
    }
}
