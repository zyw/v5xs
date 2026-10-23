import AppKit

@MainActor
enum StatusAnimal {
    private struct Sheet {
        let name: String
        let frameWidth: Int
        let frameHeight: Int
        let count: Int
    }

    private struct Pose {
        let rise: CGFloat
        let fore: NSPoint
        let hind: NSPoint
        let tail: CGFloat
    }

    private static let poses: [Pose] = [
        Pose(rise: 0, fore: NSPoint(x: 9, y: 4), hind: NSPoint(x: 27, y: 4), tail: 0),
        Pose(rise: 0.5, fore: NSPoint(x: 6, y: 7), hind: NSPoint(x: 30, y: 4), tail: 1),
        Pose(rise: 1, fore: NSPoint(x: 4, y: 10), hind: NSPoint(x: 31, y: 8), tail: 1.5),
        Pose(rise: 1, fore: NSPoint(x: 4, y: 8), hind: NSPoint(x: 31, y: 11), tail: 0),
        Pose(rise: 0.5, fore: NSPoint(x: 7, y: 4), hind: NSPoint(x: 29, y: 10), tail: -1),
        Pose(rise: 0, fore: NSPoint(x: 11, y: 4), hind: NSPoint(x: 29, y: 4), tail: -0.5)
    ]

    private static let frames: [String: [NSImage]] = Dictionary(
        uniqueKeysWithValues: Animal.allCases.map { ($0.rawValue, makeFrames(for: $0)) }
    )

    static func image(animal: Animal, frame: Int) -> NSImage {
        let images = frames[animal.rawValue]!
        return images[frame % images.count]
    }

    private static func sheet(for animal: Animal) -> Sheet? {
        switch animal {
        case .cat: Sheet(name: "cat", frameWidth: 126, frameHeight: 77, count: 5)
        case .rabbit: Sheet(name: "rabbit", frameWidth: 43, frameHeight: 36, count: 5)
        case .dog: Sheet(name: "dog", frameWidth: 60, frameHeight: 36, count: 9)
        case .horse: Sheet(name: "horse", frameWidth: 58, frameHeight: 36, count: 6)
        case .dinosaur: Sheet(name: "dinosaur", frameWidth: 51, frameHeight: 36, count: 7)
        case .frog: Sheet(name: "frog", frameWidth: 49, frameHeight: 36, count: 5)
        case .chicken: Sheet(name: "chicken", frameWidth: 37, frameHeight: 36, count: 5)
        case .duck: Sheet(name: "duck", frameWidth: 41, frameHeight: 36, count: 6)
        case .fish: Sheet(name: "fish", frameWidth: 61, frameHeight: 36, count: 5)
        case .fox: nil
        }
    }

    private static func makeFrames(for animal: Animal) -> [NSImage] {
        if let sheet = sheet(for: animal),
           let source = NSImage(contentsOfFile: Bundle.main.path(
                forResource: sheet.name, ofType: "png", inDirectory: "Animals"
           ) ?? "Resources/Animals/\(sheet.name).png") {
            return (0..<sheet.count).map { sprite(source: source, sheet: sheet, index: $0) }
        }
        return poses.map { draw(animal: animal, pose: $0) }
    }

    private static func sprite(source: NSImage, sheet: Sheet, index: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 34, height: 22), flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            let scale = min(32 / CGFloat(sheet.frameWidth), 20 / CGFloat(sheet.frameHeight))
            let width = CGFloat(sheet.frameWidth) * scale
            let height = CGFloat(sheet.frameHeight) * scale
            source.draw(
                in: NSRect(x: (34 - width) / 2, y: (22 - height) / 2, width: width, height: height),
                from: NSRect(x: index * sheet.frameWidth, y: 0,
                             width: sheet.frameWidth, height: sheet.frameHeight),
                operation: .sourceOver, fraction: 1
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(animal: Animal, pose: Pose) -> NSImage {
        let image = NSImage(size: NSSize(width: 34, height: 22), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let transform = NSAffineTransform()
            transform.translateX(by: 0, yBy: pose.rise)
            transform.concat()

            // Far limbs sit behind the body during each stride.
            limb(from: NSPoint(x: 16, y: 10), through: NSPoint(x: 12, y: 7),
                 to: NSPoint(x: pose.fore.x + 2, y: pose.fore.y + 1), width: 1.6)
            limb(from: NSPoint(x: 23, y: 10), through: NSPoint(x: 27, y: 7),
                 to: NSPoint(x: pose.hind.x - 2, y: pose.hind.y + 1), width: 1.7)

            tail(animal: animal, sway: pose.tail)

            let body = NSBezierPath()
            body.move(to: NSPoint(x: 11, y: 11))
            body.curve(to: NSPoint(x: 18, y: 15.5),
                       controlPoint1: NSPoint(x: 12, y: 14), controlPoint2: NSPoint(x: 15, y: 16))
            body.curve(to: NSPoint(x: 26, y: 11),
                       controlPoint1: NSPoint(x: 23, y: 15.5), controlPoint2: NSPoint(x: 27, y: 13.5))
            body.curve(to: NSPoint(x: 19, y: 8.5),
                       controlPoint1: NSPoint(x: 27, y: 8.5), controlPoint2: NSPoint(x: 23, y: 8.2))
            body.curve(to: NSPoint(x: 11, y: 11),
                       controlPoint1: NSPoint(x: 14, y: 8.5), controlPoint2: NSPoint(x: 12, y: 9))
            body.fill()

            limb(from: NSPoint(x: 14, y: 10), through: NSPoint(x: 11, y: 7.5),
                 to: pose.fore, width: 2.1)
            limb(from: NSPoint(x: 23, y: 10), through: NSPoint(x: 26, y: 7.5),
                 to: pose.hind, width: 2.3)
            head(animal: animal)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func limb(from start: NSPoint, through knee: NSPoint, to paw: NSPoint, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: knee)
        path.line(to: paw)
        path.line(to: NSPoint(x: paw.x - 1.4, y: paw.y - 0.2))
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func tail(animal: Animal, sway: CGFloat) {
        switch animal {
        case .cat:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 25, y: 12))
            path.curve(to: NSPoint(x: 32, y: 18 + sway),
                       controlPoint1: NSPoint(x: 30, y: 12), controlPoint2: NSPoint(x: 30, y: 19 + sway))
            path.lineWidth = 2.2
            path.lineCapStyle = .round
            path.stroke()
        case .rabbit:
            NSBezierPath(ovalIn: NSRect(x: 25, y: 12 + sway * 0.4, width: 4, height: 4)).fill()
        case .fox:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 24, y: 12))
            path.curve(to: NSPoint(x: 32, y: 18 + sway),
                       controlPoint1: NSPoint(x: 29, y: 15), controlPoint2: NSPoint(x: 30, y: 18 + sway))
            path.curve(to: NSPoint(x: 29, y: 11 + sway),
                       controlPoint1: NSPoint(x: 33, y: 15 + sway), controlPoint2: NSPoint(x: 32, y: 12 + sway))
            path.close()
            path.fill()
        default:
            break
        }
    }

    private static func head(animal: Animal) {
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 14, y: 13))
        head.curve(to: NSPoint(x: 7, y: 15),
                   controlPoint1: NSPoint(x: 12, y: 17), controlPoint2: NSPoint(x: 8, y: 17))
        head.curve(to: NSPoint(x: 5, y: 11.5),
                   controlPoint1: NSPoint(x: 5, y: 14), controlPoint2: NSPoint(x: 5, y: 12.5))
        head.curve(to: NSPoint(x: 15, y: 10),
                   controlPoint1: NSPoint(x: 8, y: 9), controlPoint2: NSPoint(x: 13, y: 9))
        head.close()
        head.fill()

        let ears = NSBezierPath()
        switch animal {
        case .cat:
            ears.move(to: NSPoint(x: 7, y: 15))
            ears.line(to: NSPoint(x: 6, y: 19))
            ears.line(to: NSPoint(x: 10, y: 16))
            ears.move(to: NSPoint(x: 11, y: 16))
            ears.line(to: NSPoint(x: 13, y: 19))
            ears.line(to: NSPoint(x: 13, y: 14))
        case .rabbit:
            ears.move(to: NSPoint(x: 8, y: 16))
            ears.curve(to: NSPoint(x: 8, y: 22),
                       controlPoint1: NSPoint(x: 6, y: 21), controlPoint2: NSPoint(x: 7, y: 22))
            ears.line(to: NSPoint(x: 10, y: 16))
            ears.move(to: NSPoint(x: 11, y: 16))
            ears.curve(to: NSPoint(x: 13, y: 21),
                       controlPoint1: NSPoint(x: 11, y: 22), controlPoint2: NSPoint(x: 13, y: 22))
            ears.line(to: NSPoint(x: 13, y: 15))
        case .fox:
            ears.move(to: NSPoint(x: 7, y: 15))
            ears.line(to: NSPoint(x: 5, y: 20))
            ears.line(to: NSPoint(x: 11, y: 16))
            ears.move(to: NSPoint(x: 11, y: 16))
            ears.line(to: NSPoint(x: 13, y: 19))
            ears.line(to: NSPoint(x: 14, y: 14))
        default:
            break
        }
        ears.fill()

        let muzzle = NSBezierPath()
        muzzle.move(to: NSPoint(x: 6, y: 13))
        muzzle.line(to: NSPoint(x: animal == .fox ? 2.5 : 4, y: 11.5))
        muzzle.line(to: NSPoint(x: 7, y: 10.5))
        muzzle.close()
        muzzle.fill()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: 7.7, y: 13.1, width: 0.9, height: 0.9)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}
