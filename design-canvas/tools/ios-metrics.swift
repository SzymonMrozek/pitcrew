// Prints UIKit's semantic colors and Dynamic Type metrics, the values `Apple.swift` holds.
//
//   xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator ios-metrics.swift -o ios-metrics
//   xcrun simctl spawn booted "$PWD/ios-metrics"

import UIKit
let names: [(String, UIColor)] = [
 ("label", .label), ("secondaryLabel", .secondaryLabel), ("tertiaryLabel", .tertiaryLabel), ("quaternaryLabel", .quaternaryLabel),
 ("systemBackground", .systemBackground), ("secondarySystemBackground", .secondarySystemBackground), ("tertiarySystemBackground", .tertiarySystemBackground),
 ("systemGroupedBackground", .systemGroupedBackground), ("secondarySystemGroupedBackground", .secondarySystemGroupedBackground), ("tertiarySystemGroupedBackground", .tertiarySystemGroupedBackground),
 ("separator", .separator), ("opaqueSeparator", .opaqueSeparator), ("systemFill", .systemFill), ("secondarySystemFill", .secondarySystemFill), ("tertiarySystemFill", .tertiarySystemFill),
 ("systemBlue", .systemBlue), ("systemRed", .systemRed), ("systemGreen", .systemGreen), ("systemOrange", .systemOrange), ("systemYellow", .systemYellow),
 ("systemPink", .systemPink), ("systemPurple", .systemPurple), ("systemTeal", .systemTeal), ("systemIndigo", .systemIndigo), ("systemCyan", .systemCyan), ("systemMint", .systemMint), ("systemBrown", .systemBrown),
 ("systemGray", .systemGray), ("systemGray2", .systemGray2), ("systemGray3", .systemGray3), ("systemGray4", .systemGray4), ("systemGray5", .systemGray5), ("systemGray6", .systemGray6),
 ("tint", .tintColor), ("link", .link), ("placeholderText", .placeholderText),
]
func hex(_ c: UIColor, _ style: UIUserInterfaceStyle) -> String {
  let r = c.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
  var a: CGFloat = 0, b: CGFloat = 0, g: CGFloat = 0, al: CGFloat = 0
  r.getRed(&a, green: &g, blue: &b, alpha: &al)
  let v = [a, g, b, al].map { Int((min(max($0,0),1) * 255).rounded()) }
  return String(format: "#%02X%02X%02X", v[0], v[1], v[2]) + (v[3] == 255 ? "" : String(format: "%02X", v[3]))
}
for (n, c) in names { print("\(n) \(hex(c, .light)) \(hex(c, .dark))") }
for style in [UIFont.TextStyle.largeTitle, .title1, .title2, .title3, .headline, .body, .callout, .subheadline, .footnote, .caption1, .caption2] {
  let f = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
  let traits = f.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
  let tracking = f.fontDescriptor.object(forKey: UIFontDescriptor.AttributeName(rawValue: "NSCTFontTrackAttribute"))
  print("font \(style.rawValue) size \(f.pointSize) lineHeight \(f.lineHeight) ascender \(f.ascender) descender \(f.descender) leading \(f.leading) weight \(traits?[.weight] ?? 0) name \(f.fontName) track \(String(describing: tracking))")
}
