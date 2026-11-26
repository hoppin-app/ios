// make_store_shots.swift — App Store preview images from the raw screenshots.
//
//   swift scripts/make_store_shots.swift
//
// Reads docs/app-store/screenshots/<n>-*.png (1284 × 2778, iPhone 14 Plus simulator)
// and writes a caption over the screenshot in a phone frame, on the website's
// colours, once per App Store Connect slot:
//   docs/app-store/screenshots/store/6.3-inch/  1206 × 2622  (required: "iPhone with
//                                     Dynamic Island, medium display")
//   docs/app-store/screenshots/store/6.9-inch/  1320 × 2868
//   docs/app-store/screenshots/store/6.5-inch/  1284 × 2778
// and the two optional iOS 27 marketing images (they go under "Header and
// Search Results", not under the screenshots):
//   docs/app-store/screenshots/store/header/   3840 × 1646  (product page header, 21:9)
//   docs/app-store/screenshots/store/search/   3840 × 2560  (search results card, 3:2)
// A slot refuses any other size ("File dimensions are invalid"). Output is
// opaque: App Store Connect refuses screenshots with an alpha channel.
//
// The Bluetooth caption stays at "over Bluetooth" until docs/testing/FINAL_TESTING.md §10
// (a message carried through a middle phone) has passed on real phones.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
// The screenshots live in the docs repo, next to ios/ in the hoppin parent checkout.
let source = root.deletingLastPathComponent().appendingPathComponent("docs/app-store/screenshots")
let output = source.appendingPathComponent("store")

/// The raw screenshots' size, which fixes the screen's shape inside the frame.
let screenshotSize = CGSize(width: 1284, height: 2778)

/// Everything is laid out at this width in points and scaled to each slot.
let layoutWidth: CGFloat = 1284

struct Target {
    let folder: String
    let pixels: CGSize
}

let targets = [
    // The slot App Store Connect asks for first ("iPhone with Dynamic Island,
    // medium display": 6.1" and 6.3", iPhone 17 / 16 Pro).
    Target(folder: "6.3-inch", pixels: CGSize(width: 1206, height: 2622)),
    Target(folder: "6.9-inch", pixels: CGSize(width: 1320, height: 2868)),
    Target(folder: "6.5-inch", pixels: CGSize(width: 1284, height: 2778)),
]

// The website's tokens (website/app/globals.css) and the lava trail's colours.
let canvasColor = Color(red: 0.965, green: 0.965, blue: 0.973)   // #f6f6f8
let ink = Color(red: 0.071, green: 0.071, blue: 0.086)          // #121216
let muted = Color(red: 0.353, green: 0.353, blue: 0.400)        // #5a5a66
let accent = Color(red: 0.353, green: 0.247, blue: 0.812)       // #5a3fcf
let coral = Color(red: 1.0, green: 0.45, blue: 0.32)

struct Slide {
    let file: String
    let title: String
    let subtitle: String
    /// Where the two glows sit, as fractions of the canvas, so the set doesn't
    /// look stamped out of one mould.
    let violetAt: UnitPoint
    let coralAt: UnitPoint
}

let slides: [Slide] = [
    Slide(file: "1-chats", title: "Private chat that\nfinds a way",
          subtitle: "Encrypted on your iPhone,\nbefore it goes anywhere.",
          violetAt: UnitPoint(x: 0.85, y: 0.42), coralAt: UnitPoint(x: 0.1, y: 0.86)),
    Slide(file: "2-direct", title: "Phone to phone.\nNo server in between.",
          subtitle: "On the same Wi-Fi, messages go\nstraight to the other phone.",
          violetAt: UnitPoint(x: 0.15, y: 0.45), coralAt: UnitPoint(x: 0.9, y: 0.8)),
    Slide(file: "3-bluetooth", title: "No signal?\nTexts go over Bluetooth.",
          subtitle: "Sealed, so only the person\nit's for can read it.",
          violetAt: UnitPoint(x: 0.88, y: 0.5), coralAt: UnitPoint(x: 0.12, y: 0.78)),
    Slide(file: "4-group", title: "Groups only the\nmembers can read",
          subtitle: "Up to 32 people,\nend-to-end encrypted.",
          violetAt: UnitPoint(x: 0.12, y: 0.4), coralAt: UnitPoint(x: 0.88, y: 0.85)),
    Slide(file: "5-relay-data", title: "See what our\nserver never sees",
          subtitle: "Your messages, contacts and keys\nstay on your iPhone.",
          violetAt: UnitPoint(x: 0.85, y: 0.45), coralAt: UnitPoint(x: 0.15, y: 0.82)),
]

/// The screenshot in a thin black bezel, like the website's `.device`.
struct Phone: View {
    let screen: NSImage
    let width: CGFloat

    var body: some View {
        let bezel = width * 0.026
        let screenWidth = width - bezel * 2
        let screenHeight = screenWidth * screenshotSize.height / screenshotSize.width
        // An iPhone 14 Plus screen corner is 53.3 pt of a 428 pt width.
        let screenRadius = screenWidth * 53.3 / 428

        Image(nsImage: screen)
            .resizable()
            .interpolation(.high)
            .frame(width: screenWidth, height: screenHeight)
            .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))
            .padding(bezel)
            .background(
                RoundedRectangle(cornerRadius: screenRadius + bezel, style: .continuous)
                    .fill(Color(red: 0.047, green: 0.047, blue: 0.059))
            )
            .overlay(
                RoundedRectangle(cornerRadius: screenRadius + bezel, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 2)
            )
            .shadow(color: ink.opacity(0.18), radius: 70, x: 0, y: 50)
            .shadow(color: accent.opacity(0.12), radius: 24, x: 0, y: 10)
    }
}

struct StoreShot: View {
    let slide: Slide
    let screen: NSImage
    /// The canvas in layout points.
    let canvas: CGSize

    var body: some View {
        ZStack(alignment: .top) {
            canvasColor

            glow(accent.opacity(0.30), diameter: 1300, at: slide.violetAt)
            glow(coral.opacity(0.20), diameter: 1100, at: slide.coralAt)

            VStack(spacing: 0) {
                Text(slide.title)
                    .font(.system(size: 104, weight: .bold))
                    .tracking(-2.2)
                    .lineSpacing(-6)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ink)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 96)

                Text(slide.subtitle)
                    .font(.system(size: 50, weight: .regular))
                    .lineSpacing(8)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(muted)
                    .padding(.top, 34)

                Spacer(minLength: 0)

                Phone(screen: screen, width: 880)
                    .padding(.bottom, 110)
            }
            .padding(.top, 230)
            .frame(width: canvas.width, height: canvas.height)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }

    private func glow(_ color: Color, diameter: CGFloat, at point: UnitPoint) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .blur(radius: 220)
            .position(x: canvas.width * point.x, y: canvas.height * point.y)
            .frame(width: canvas.width, height: canvas.height)
    }
}

/// Redraws into an opaque RGB bitmap of exactly `pixels` and writes a PNG with
/// no alpha channel.
func writeOpaquePNG(_ image: CGImage, pixels: CGSize, to url: URL) throws {
    let width = Int(pixels.width), height = Int(pixels.height)
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.setFillColor(CGColor(red: 0.965, green: 0.965, blue: 0.973, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let flat = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, flat, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

// MARK: - Header and search results (optional, iOS 27+)

/// A wide marketing image: a caption over a row of phones that run off the
/// bottom edge. Everything is centred, because the header and the search
/// card crop the image differently.
struct Banner {
    let file: String
    let pixels: CGSize
    let title: String
    let subtitle: String
    let titleSize: CGFloat
    let textTop: CGFloat
    let phonesTop: CGFloat
    /// Left to right; the middle one is drawn larger and higher.
    let screens: [String]
    let centreWidth: CGFloat
    let sideWidth: CGFloat
    let spacing: CGFloat
}

let banners: [Banner] = [
    // Product page header: 21:9.
    Banner(file: "header/header-3840x1646", pixels: CGSize(width: 3840, height: 1646),
           title: "Private chat that finds a way",
           subtitle: "Encrypted on your iPhone, then sent by whichever road is open.",
           titleSize: 196, textTop: 150, phonesTop: 610,
           screens: ["4-group", "2-direct", "1-chats", "3-bluetooth", "5-relay-data"],
           centreWidth: 560, sideWidth: 470, spacing: 70),
    // Search results card: 3:2, the largest size allowed.
    Banner(file: "search/search-results-3840x2560", pixels: CGSize(width: 3840, height: 2560),
           title: "Private chat that finds a way",
           subtitle: "Same Wi-Fi, the internet, or Bluetooth when there's no signal.",
           titleSize: 220, textTop: 170, phonesTop: 720,
           screens: ["2-direct", "1-chats", "3-bluetooth"],
           centreWidth: 860, sideWidth: 760, spacing: 90),
]

struct BannerView: View {
    let banner: Banner
    let screens: [NSImage]

    var body: some View {
        let size = banner.pixels
        let centre = screens.count / 2

        ZStack(alignment: .top) {
            canvasColor

            Circle().fill(accent.opacity(0.30))
                .frame(width: size.height * 1.3, height: size.height * 1.3)
                .blur(radius: size.height * 0.2)
                .position(x: size.width * 0.18, y: size.height * 0.7)
            Circle().fill(coral.opacity(0.20))
                .frame(width: size.height * 1.1, height: size.height * 1.1)
                .blur(radius: size.height * 0.2)
                .position(x: size.width * 0.84, y: size.height * 0.8)
            Circle().fill(accent.opacity(0.18))
                .frame(width: size.height * 0.9, height: size.height * 0.9)
                .blur(radius: size.height * 0.18)
                .position(x: size.width * 0.5, y: size.height * 0.95)

            VStack(spacing: 0) {
                Text(banner.title)
                    .font(.system(size: banner.titleSize, weight: .bold))
                    .tracking(-banner.titleSize * 0.021)
                    .foregroundStyle(ink)
                Text(banner.subtitle)
                    .font(.system(size: banner.titleSize * 0.44, weight: .regular))
                    .foregroundStyle(muted)
                    .padding(.top, banner.titleSize * 0.2)
            }
            .multilineTextAlignment(.center)
            .padding(.top, banner.textTop)

            HStack(alignment: .top, spacing: banner.spacing) {
                ForEach(screens.indices, id: \.self) { i in
                    Phone(screen: screens[i],
                          width: i == centre ? banner.centreWidth : banner.sideWidth)
                        .padding(.top, i == centre ? 0 : banner.centreWidth * 0.16)
                }
            }
            .padding(.top, banner.phonesTop)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
    }
}

MainActor.assumeIsolated {
    do {
        for target in targets {
            let folder = output.appendingPathComponent(target.folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let canvas = CGSize(width: layoutWidth,
                                height: layoutWidth * target.pixels.height / target.pixels.width)
            for slide in slides {
                let input = source.appendingPathComponent("\(slide.file).png")
                guard let screen = NSImage(contentsOf: input) else {
                    print("missing \(input.path)")
                    exit(1)
                }
                let renderer = ImageRenderer(content: StoreShot(slide: slide, screen: screen, canvas: canvas))
                renderer.scale = target.pixels.width / layoutWidth
                renderer.proposedSize = ProposedViewSize(canvas)
                guard let image = renderer.cgImage else {
                    print("could not render \(slide.file)")
                    exit(1)
                }
                let url = folder.appendingPathComponent("\(slide.file).png")
                try writeOpaquePNG(image, pixels: target.pixels, to: url)
                print("wrote \(target.folder)/\(slide.file).png (\(Int(target.pixels.width)) × \(Int(target.pixels.height)))")
            }
        }
        for banner in banners {
            let screens = try banner.screens.map { name -> NSImage in
                let input = source.appendingPathComponent("\(name).png")
                guard let image = NSImage(contentsOf: input) else {
                    throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: input.path])
                }
                return image
            }
            let url = output.appendingPathComponent("\(banner.file).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let renderer = ImageRenderer(content: BannerView(banner: banner, screens: screens))
            renderer.scale = 1
            renderer.proposedSize = ProposedViewSize(banner.pixels)
            guard let image = renderer.cgImage else {
                print("could not render \(banner.file)")
                exit(1)
            }
            try writeOpaquePNG(image, pixels: banner.pixels, to: url)
            print("wrote \(banner.file).png (\(Int(banner.pixels.width)) × \(Int(banner.pixels.height)))")
        }
    } catch {
        print("failed: \(error)")
        exit(1)
    }
}
