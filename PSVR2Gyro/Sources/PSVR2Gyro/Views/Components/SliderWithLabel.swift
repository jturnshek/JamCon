import SwiftUI

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
