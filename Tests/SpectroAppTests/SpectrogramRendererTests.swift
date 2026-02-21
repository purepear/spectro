import CoreGraphics
import XCTest
@testable import SpectroApp

final class SpectrogramRendererTests: XCTestCase {
    func testPaletteEndpoints() {
        let low = SpectrogramPalette.color(for: 0)
        let high = SpectrogramPalette.color(for: 1)

        XCTAssertEqual(low.r, 0)
        XCTAssertEqual(low.g, 0)
        XCTAssertEqual(low.b, 0)

        XCTAssertEqual(high.r, 255)
        XCTAssertEqual(high.g, 255)
        XCTAssertEqual(high.b, 245)
    }

    func testRendererProducesExpectedDimensions() {
        let image = SpectrogramRenderer.render(
            decibelsByColumn: [0, 0, 0, 0],
            columns: 2,
            bins: 2,
            sampleRate: 2,
            minFrequency: 0,
            maxFrequency: 1,
            minDecibels: -120,
            maxDecibels: 0,
            imageHeight: 3
        )

        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 2)
        XCTAssertEqual(image?.height, 3)
    }

    func testRendererMapsMinAndMaxDecibelsToPaletteExtremes() {
        let minDB: Float = -120
        let maxDB: Float = 0

        guard
            let minImage = SpectrogramRenderer.render(
                decibelsByColumn: [minDB, minDB],
                columns: 1,
                bins: 2,
                sampleRate: 2,
                minFrequency: 0,
                maxFrequency: 1,
                minDecibels: minDB,
                maxDecibels: maxDB,
                imageHeight: 1
            ),
            let maxImage = SpectrogramRenderer.render(
                decibelsByColumn: [maxDB, maxDB],
                columns: 1,
                bins: 2,
                sampleRate: 2,
                minFrequency: 0,
                maxFrequency: 1,
                minDecibels: minDB,
                maxDecibels: maxDB,
                imageHeight: 1
            )
        else {
            XCTFail("Expected renderer to produce 1x1 images.")
            return
        }

        let minPixel = pixelRGBA(image: minImage, x: 0, y: 0)
        let maxPixel = pixelRGBA(image: maxImage, x: 0, y: 0)

        let low = SpectrogramPalette.color(for: 0)
        let high = SpectrogramPalette.color(for: 1)

        XCTAssertEqual(minPixel.r, low.r)
        XCTAssertEqual(minPixel.g, low.g)
        XCTAssertEqual(minPixel.b, low.b)
        XCTAssertEqual(minPixel.a, 255)

        XCTAssertEqual(maxPixel.r, high.r)
        XCTAssertEqual(maxPixel.g, high.g)
        XCTAssertEqual(maxPixel.b, high.b)
        XCTAssertEqual(maxPixel.a, 255)
    }

    private func pixelRGBA(image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard
            x >= 0, y >= 0, x < image.width, y < image.height,
            let data = image.dataProvider?.data
        else {
            return (0, 0, 0, 0)
        }

        let bytes = CFDataGetBytePtr(data)!
        let bytesPerPixel = image.bitsPerPixel / 8
        let offset = y * image.bytesPerRow + x * bytesPerPixel

        return (
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3]
        )
    }
}
