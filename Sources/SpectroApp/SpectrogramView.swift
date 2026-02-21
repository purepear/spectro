import Foundation
import SwiftUI

struct SpectrogramView: View {
    let result: SpectrogramResult

    private let yAxisWidth: CGFloat = 78
    private let legendWidth: CGFloat = 62

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(result.fileName)
                .font(.headline)

            VStack(alignment: .leading, spacing: 2) {
                Text(metadataLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let horizontalSpacing: CGFloat = 8
                let timeAxisHeight: CGFloat = 30
                let plotWidth = max(180, proxy.size.width - yAxisWidth - legendWidth - (horizontalSpacing * 2))
                let plotHeight = max(160, proxy.size.height - timeAxisHeight - 8)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: horizontalSpacing) {
                        FrequencyAxisView(
                            ticks: frequencyTicks,
                            minFrequency: result.minFrequency,
                            maxFrequency: result.maxFrequency,
                            height: plotHeight
                        )
                        .frame(width: yAxisWidth)

                        ZStack(alignment: .topLeading) {
                            Image(decorative: result.image, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .frame(
                                    width: plotWidth,
                                    height: plotHeight
                                )
                                .border(Color.secondary.opacity(0.6), width: 1)

                            FrequencyGridOverlay(
                                ticks: frequencyTicks,
                                minFrequency: result.minFrequency,
                                maxFrequency: result.maxFrequency
                            )
                            .frame(
                                width: plotWidth,
                                height: plotHeight
                            )
                        }

                        SpectrogramLegendView(
                            minDecibels: result.minDecibels,
                            maxDecibels: result.maxDecibels,
                            height: plotHeight
                        )
                        .frame(width: legendWidth)
                    }

                    TimeAxisView(duration: result.duration, width: plotWidth)
                        .padding(.leading, yAxisWidth + horizontalSpacing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var metadataLine: String {
        var parts: [String] = []
        parts.append("Format: \(result.sourceContainerFormat)")
        parts.append("Codec: \(result.sourceCodec)")
        if let bitRate = result.sourceBitRate, bitRate > 0 {
            parts.append("Bitrate: \(formatBitRate(bitRate))")
        }
        parts.append("Sample rate: \(formatSampleRate(result.sampleRate))")
        parts.append("Channels: \(result.sourceChannelCount)")
        return parts.joined(separator: " • ")
    }

    private var frequencyTicks: [Double] {
        linearFrequencyTicks(minFrequency: result.minFrequency, maxFrequency: result.maxFrequency, targetCount: 7)
    }

    private func formatSampleRate(_ sampleRate: Double) -> String {
        String(format: "%.1f kHz", sampleRate / 1000)
    }

    private func formatBitRate(_ bitRate: Double) -> String {
        String(format: "%.0f kbps", bitRate / 1000.0)
    }

}

private struct FrequencyAxisView: View {
    let ticks: [Double]
    let minFrequency: Double
    let maxFrequency: Double
    let height: CGFloat

    var body: some View {
        ZStack {
            ForEach(ticks, id: \.self) { tick in
                let y = frequencyYPosition(
                    frequency: tick,
                    minFrequency: minFrequency,
                    maxFrequency: maxFrequency,
                    height: height
                )

                HStack(spacing: 6) {
                    Text(formatFrequency(tick))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.8))
                        .frame(width: 6, height: 1)
                }
                .position(x: 39, y: y)
            }
        }
        .frame(height: height)
    }

    private func formatFrequency(_ frequency: Double) -> String {
        if frequency >= 1000 {
            let khz = frequency / 1000
            if abs(khz.rounded() - khz) < 0.01 {
                return "\(Int(khz.rounded())) kHz"
            }
            return String(format: "%.1f kHz", khz)
        }

        return "\(Int(frequency.rounded())) Hz"
    }
}

private struct FrequencyGridOverlay: View {
    let ticks: [Double]
    let minFrequency: Double
    let maxFrequency: Double

    var body: some View {
        Canvas { context, size in
            for tick in ticks {
                let y = frequencyYPosition(
                    frequency: tick,
                    minFrequency: minFrequency,
                    maxFrequency: maxFrequency,
                    height: size.height
                )

                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(.white.opacity(0.10)), lineWidth: 0.8)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct TimeAxisView: View {
    let duration: TimeInterval
    let width: CGFloat

    private let tickCount = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.65))
                .frame(width: width, height: 1)

            ForEach(0..<tickCount, id: \.self) { index in
                let fraction = Double(index) / Double(max(1, tickCount - 1))
                let x = clampedTickX(width: width, fraction: fraction)

                VStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.65))
                        .frame(width: 1, height: 6)

                    Text(formatTime(duration * fraction))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .position(x: x, y: 14)
            }
        }
        .frame(width: width, height: 30)
    }

    private func clampedTickX(width: CGFloat, fraction: Double) -> CGFloat {
        let raw = width * CGFloat(fraction)
        return min(max(raw, 14), width - 14)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct SpectrogramLegendView: View {
    let minDecibels: Float
    let maxDecibels: Float
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(LinearGradient(gradient: SpectrogramPalette.legendGradient, startPoint: .top, endPoint: .bottom))
                .frame(width: 18, height: height)
                .border(Color.secondary.opacity(0.6), width: 1)

            ForEach(decibelTicks, id: \.self) { tick in
                let y = decibelYPosition(tick)

                HStack(spacing: 6) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.8))
                        .frame(width: 5, height: 1)

                    Text("\(Int(tick.rounded())) dB")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .position(x: 40, y: y)
            }
        }
        .frame(height: height)
    }

    private var decibelTicks: [Float] {
        var values: [Float] = []
        var current = Int(maxDecibels.rounded())

        while Float(current) >= minDecibels {
            values.append(Float(current))
            current -= 20
        }

        if values.last != minDecibels {
            values.append(minDecibels)
        }

        return values
    }

    private func decibelYPosition(_ decibels: Float) -> CGFloat {
        let span = max(0.001, maxDecibels - minDecibels)
        let normalized = CGFloat((maxDecibels - decibels) / span)
        return normalized * height
    }
}

private func frequencyYPosition(
    frequency: Double,
    minFrequency: Double,
    maxFrequency: Double,
    height: CGFloat
) -> CGFloat {
    let minHz = max(0, minFrequency)
    let maxHz = max(maxFrequency, minHz + 1)
    let clamped = min(maxHz, max(minHz, frequency))
    let normalized = (clamped - minHz) / max(0.0001, maxHz - minHz)
    return (1 - CGFloat(normalized)) * height
}

private func linearFrequencyTicks(minFrequency: Double, maxFrequency: Double, targetCount: Int) -> [Double] {
    guard maxFrequency > minFrequency else { return [minFrequency] }

    let span = maxFrequency - minFrequency
    let roughStep = span / Double(Swift.max(2, targetCount))
    let step = niceStep(for: roughStep)

    var ticks: [Double] = []
    var value = ceil(minFrequency / step) * step
    if value > minFrequency {
        ticks.append(minFrequency)
    }

    while value < maxFrequency {
        ticks.append(value)
        value += step
    }

    ticks.append(maxFrequency)
    return deduplicatedSorted(ticks)
}

private func niceStep(for roughStep: Double) -> Double {
    guard roughStep > 0 else { return 1000 }

    let exponent = floor(log10(roughStep))
    let base = pow(10.0, exponent)
    let fraction = roughStep / base

    let niceFraction: Double
    if fraction <= 1 {
        niceFraction = 1
    } else if fraction <= 2 {
        niceFraction = 2
    } else if fraction <= 5 {
        niceFraction = 5
    } else {
        niceFraction = 10
    }

    return niceFraction * base
}

private func deduplicatedSorted(_ values: [Double]) -> [Double] {
    var output: [Double] = []
    let sorted = values.sorted()
    for value in sorted {
        if let last = output.last, abs(last - value) < 0.5 {
            continue
        }
        output.append(value)
    }
    return output
}
