import AppKit

// The menu bar readout (M-Q3 to M-Q5): the fan symbol and two small lines,
// temperature above fan speed. ToolkitMenuBar shows it as the image of the
// app's one menu bar item while the helper is approved and the readout is on.
// One template image, so the system tints it for the menu bar's appearance
// and for the highlighted state.
enum FanMenuBarImage {
    static func make(temperature: String, speed: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let top = NSAttributedString(string: temperature, attributes: attributes)
        let bottom = NSAttributedString(string: speed, attributes: attributes)
        // Wide enough for four digits, so the item does not change width as
        // the readings change.
        let widest = NSAttributedString(string: "0000rpm", attributes: attributes)
        let textWidth = ceil(max(top.size().width, bottom.size().width, widest.size().width))
        let symbol = NSImage(systemSymbolName: "fan", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        let symbolSize = symbol?.size ?? .zero
        let height: CGFloat = 22, gap: CGFloat = 4
        let textLeft = ceil(symbolSize.width) + gap
        let image = NSImage(size: NSSize(width: textLeft + textWidth, height: height), flipped: false) { _ in
            symbol?.draw(in: NSRect(x: 0, y: (height - symbolSize.height) / 2,
                                    width: symbolSize.width, height: symbolSize.height))
            top.draw(at: NSPoint(x: textLeft + (textWidth - top.size().width) / 2, y: height / 2 - 0.5))
            bottom.draw(at: NSPoint(x: textLeft + (textWidth - bottom.size().width) / 2, y: 0.5))
            return true
        }
        image.isTemplate = true
        return image
    }
}
