import Foundation

public enum ReleaseNotesMarkdown {
    public struct Block {
        public enum Kind: Equatable {
            case heading(Int)
            case paragraph
            case quote
            case bullet(depth: Int)
            case number(Int, depth: Int)
            case code
            case rule
        }

        public let kind: Kind
        public let content: AttributedString
    }

    public static func parse(_ source: String) -> [Block] {
        guard let document = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        ) else {
            return [Block(kind: .paragraph, content: AttributedString(source))]
        }

        var blocks: [Block] = []
        var start: AttributedString.Index?
        var end: AttributedString.Index?
        var identity: Int?
        var kind: Block.Kind = .paragraph

        for run in document.runs {
            let components = run.presentationIntent?.components ?? []
            let nextIdentity = components.first?.identity
            if let start, let end, identity != nextIdentity {
                blocks.append(Block(kind: kind, content: AttributedString(document[start..<end])))
            }
            if start == nil || identity != nextIdentity {
                start = run.range.lowerBound
                identity = nextIdentity
                kind = blockKind(components)
            }
            end = run.range.upperBound
        }
        if let start, let end {
            blocks.append(Block(kind: kind, content: AttributedString(document[start..<end])))
        }
        return blocks
    }

    private static func blockKind(_ components: [PresentationIntent.IntentType]) -> Block.Kind {
        var ordinal = 1
        var listDepth = 0
        var ordered: Bool?
        var quote = false
        var sawListItem = false
        for component in components {
            switch component.kind {
            case .header(let level): return .heading(level)
            case .codeBlock: return .code
            case .thematicBreak: return .rule
            case .blockQuote: quote = true
            case .listItem(let item):
                if !sawListItem { ordinal = item }
                sawListItem = true
            case .orderedList:
                if ordered == nil { ordered = true }
                listDepth += 1
            case .unorderedList:
                if ordered == nil { ordered = false }
                listDepth += 1
            default: break
            }
        }
        if quote { return .quote }
        if listDepth > 0 {
            return ordered == true
                ? .number(ordinal, depth: listDepth - 1)
                : .bullet(depth: listDepth - 1)
        }
        return .paragraph
    }
}
