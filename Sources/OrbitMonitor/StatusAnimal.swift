import AppKit

@MainActor
enum StatusAnimal {
    /// 一张横向拼接的雪碧图。
    ///
    /// 两种排布都要支持：
    /// * 等宽帧（老资源）：只给 `frameWidth` + `count`；
    /// * 不等宽帧（新资源）：给 `frameOffsets`，每帧边界按实测空白处切，
    ///   因为画师导出的帧间距不同，强制等分会把动物切掉。代价是帧宽不齐，
    ///   所以这里以「每帧自身宽度」为单位做居中缩放，而不是按统一帧宽。
    private struct Sheet {
        let name: String
        let frameHeight: Int
        let count: Int
        /// 等宽帧用。不等宽时为 0。
        let frameWidth: Int
        /// 不等宽帧的起始 x 坐标（升序，数量 = count + 1 表示右边界）。
        let frameOffsets: [Int]

        init(name: String, frameWidth: Int, frameHeight: Int, count: Int) {
            self.name = name
            self.frameWidth = frameWidth
            self.frameHeight = frameHeight
            self.count = count
            self.frameOffsets = []
        }

        init(name: String, frameHeight: Int, frameOffsets: [Int]) {
            self.name = name
            self.frameWidth = 0
            self.frameHeight = frameHeight
            self.count = max(frameOffsets.count - 1, 0)
            self.frameOffsets = frameOffsets
        }

        /// 第 `index` 帧在原图里的 x 起点与宽度。
        func frameRect(_ index: Int) -> (x: Int, width: Int) {
            if frameOffsets.isEmpty {
                return (index * frameWidth, frameWidth)
            }
            let start = frameOffsets[index]
            return (start, frameOffsets[index + 1] - start)
        }
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

    /// 暂停动画时显示的静态图标（应用 Logo 剪影，与动物形象无关）。
    ///
    /// 暂停后仍显示当前动物的某一帧会让人误以为「动画坏了」；
    /// 换成 Logo 能明确表达「已暂停」这个状态。
    /// 加载失败时回落到当前动物的静止帧，保证菜单栏不会出现空白图标。
    static func paused(animal: Animal) -> NSImage {
        if let image = pausedIcon() { return image }
        return image(animal: animal, frame: 0)
    }

    private static let pausedIconCache: NSImage? = {
        let path = Bundle.main.path(forResource: "PausedIcon", ofType: "png")
            ?? "Resources/PausedIcon.png"
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        // 菜单栏图标按 size 实际显示，这里给 22pt 的逻辑尺寸。
        image.size = NSSize(width: 22, height: 19)
        // template 让系统按菜单栏明暗自动着色（浅色栏显示黑、深色栏显示白）。
        image.isTemplate = true
        return image
    }()

    private static func pausedIcon() -> NSImage? { pausedIconCache }

    /// 雪碧图清单。帧边界由 scripts/slice-animal-sheet.py 实测空白列得出，
    /// 不要凭视觉估算——估错会把动物的腿或尾巴切掉。
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
        // 以下五张为不等宽帧（帧间距不匀），边界取自实测空白列。
        case .tabbing:
            Sheet(name: "tabbing", frameHeight: 77,
                  frameOffsets: [0, 115, 266, 412, 557, 683])
        case .bolt:
            Sheet(name: "bolt", frameHeight: 77,
                  frameOffsets: [0, 104, 234, 375, 499, 601])
        case .dragon:
            Sheet(name: "dragon", frameHeight: 77,
                  frameOffsets: [0, 146, 317, 490, 641, 790])
        case .panda:
            Sheet(name: "panda", frameHeight: 77,
                  frameOffsets: [0, 140, 308, 478, 634, 767])
        case .tiger:
            Sheet(name: "tiger", frameHeight: 77,
                  frameOffsets: [0, 149, 320, 486, 642, 792])
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
        let (sourceX, sourceWidth) = sheet.frameRect(index)
        let image = NSImage(size: NSSize(width: 34, height: 22), flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            // 每帧按**自身宽度**缩放后居中，而不是按统一帧宽：
            // 不等宽雪碧图里较窄的帧（如起跳姿势）若按最大帧宽算会显得偏小。
            let scale = min(32 / CGFloat(sourceWidth), 20 / CGFloat(sheet.frameHeight))
            let width = CGFloat(sourceWidth) * scale
            let height = CGFloat(sheet.frameHeight) * scale
            source.draw(
                in: NSRect(x: (34 - width) / 2, y: (22 - height) / 2, width: width, height: height),
                from: NSRect(x: sourceX, y: 0,
                             width: sourceWidth, height: sheet.frameHeight),
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
        default:
            break
        }
        ears.fill()

        let muzzle = NSBezierPath()
        muzzle.move(to: NSPoint(x: 6, y: 13))
        muzzle.line(to: NSPoint(x: 4, y: 11.5))
        muzzle.line(to: NSPoint(x: 7, y: 10.5))
        muzzle.close()
        muzzle.fill()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: 7.7, y: 13.1, width: 0.9, height: 0.9)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}
