import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Textextraktion aus Word (.docx) und PowerPoint (.pptx) ohne externe Bibliotheken.
public enum OOXMLExtractor {
    public enum OOXMLError: Error, Equatable {
        case missingContent(String)
        case unreadable(String)
    }

    // MARK: - Word

    public static func extractDocx(_ data: Data) throws -> ExtractedDocument {
        let zip: ZipArchive
        do { zip = try ZipArchive(data: data) } catch { throw OOXMLError.unreadable("Die Word-Datei ist beschädigt oder kein gültiges DOCX.") }
        guard let documentXML = try? zip.data(for: "word/document.xml") else {
            throw OOXMLError.missingContent("In der Word-Datei wurde kein Dokumentinhalt gefunden.")
        }
        var headingStyles: [String: Int] = [:]
        if let stylesXML = try? zip.data(for: "word/styles.xml") {
            headingStyles = WordStylesParser.parse(stylesXML)
        }
        let parser = WordDocumentParser(headingStyles: headingStyles)
        let xml = XMLParser(data: documentXML)
        xml.delegate = parser
        guard xml.parse() else { throw OOXMLError.unreadable("Der Inhalt der Word-Datei konnte nicht gelesen werden.") }
        return ExtractedDocument(blocks: parser.blocks, pageCount: parser.page)
    }

    // MARK: - PowerPoint

    public static func extractPptx(_ data: Data, includeNotes: Bool = true) throws -> ExtractedDocument {
        let zip: ZipArchive
        do { zip = try ZipArchive(data: data) } catch { throw OOXMLError.unreadable("Die PowerPoint-Datei ist beschädigt oder kein gültiges PPTX.") }
        let slidePaths = orderedSlidePaths(zip)
        guard !slidePaths.isEmpty else { throw OOXMLError.missingContent("In der Präsentation wurden keine Folien gefunden.") }
        var blocks: [ExtractedBlock] = []
        for (index, path) in slidePaths.enumerated() {
            let page = index + 1
            guard let slideXML = try? zip.data(for: path) else { continue }
            let parser = SlideParser()
            let xml = XMLParser(data: slideXML)
            xml.delegate = parser
            _ = xml.parse()
            let title = parser.title.trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(ExtractedBlock(kind: .heading(2), text: title.isEmpty ? "Folie \(page)" : title, page: page))
            for paragraph in parser.paragraphs where !paragraph.text.isEmpty {
                blocks.append(ExtractedBlock(kind: paragraph.level > 0 ? .listItem : .paragraph, text: paragraph.text, page: page))
            }
            if includeNotes, let notesPath = notesPath(forSlide: path, zip: zip), let notesXML = try? zip.data(for: notesPath) {
                let notes = SlideParser()
                let nx = XMLParser(data: notesXML)
                nx.delegate = notes
                _ = nx.parse()
                let text = notes.paragraphs.map(\.text).filter { !$0.isEmpty && Int($0) == nil }.joined(separator: " ")
                if text.count > 15 { blocks.append(ExtractedBlock(kind: .note, text: text, page: page)) }
            }
        }
        return ExtractedDocument(blocks: blocks, pageCount: slidePaths.count)
    }

    static func orderedSlidePaths(_ zip: ZipArchive) -> [String] {
        // Reihenfolge laut presentation.xml (sldIdLst) und Beziehungen
        if let presentation = try? zip.data(for: "ppt/presentation.xml"),
           let rels = try? zip.data(for: "ppt/_rels/presentation.xml.rels") {
            let ids = AttributeCollector.collect(presentation, element: "p:sldId", attribute: "r:id")
            let targets = RelationshipParser.parse(rels)
            let paths = ids.compactMap { id -> String? in
                guard let target = targets[id]?.target else { return nil }
                return target.hasPrefix("/") ? String(target.dropFirst()) : "ppt/" + target
            }.filter { zip.entry($0) != nil }
            if !paths.isEmpty { return paths }
        }
        return zip.entries.map(\.path)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { slideNumber($0) < slideNumber($1) }
    }

    static func slideNumber(_ path: String) -> Int {
        Int(path.replacingOccurrences(of: "ppt/slides/slide", with: "").replacingOccurrences(of: ".xml", with: "")) ?? 0
    }

    static func notesPath(forSlide path: String, zip: ZipArchive) -> String? {
        let fileName = (path as NSString).lastPathComponent
        let relsPath = "ppt/slides/_rels/\(fileName).rels"
        guard let rels = try? zip.data(for: relsPath) else { return nil }
        for (_, rel) in RelationshipParser.parse(rels) where rel.type.hasSuffix("/notesSlide") {
            let target = rel.target.replacingOccurrences(of: "../", with: "ppt/")
            return target
        }
        return nil
    }
}

// MARK: - XML-Parser

/// Erkennt Überschriften-Formatvorlagen (auch deutsche Namen wie "Überschrift 1").
final class WordStylesParser: NSObject, XMLParserDelegate {
    private var result: [String: Int] = [:]
    private var currentID: String?
    private var currentOutline: Int?

    static func parse(_ data: Data) -> [String: Int] {
        let p = WordStylesParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        _ = xml.parse()
        return p.result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "w:style":
            currentID = attributeDict["w:styleId"]
            currentOutline = nil
        case "w:name":
            guard let id = currentID, let name = attributeDict["w:val"]?.lowercased() else { return }
            if let level = Self.level(fromName: name) { result[id] = level }
        case "w:outlineLvl":
            if let id = currentID, let v = attributeDict["w:val"].flatMap(Int.init), v < 9 { result[id] = min(v + 1, 3) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:style" { currentID = nil }
    }

    static func level(fromName name: String) -> Int? {
        if name == "title" || name == "titel" { return 1 }
        for prefix in ["heading ", "überschrift ", "berschrift "] where name.hasPrefix(prefix) {
            if let n = Int(name.dropFirst(prefix.count)) { return min(max(n, 1), 3) }
        }
        return nil
    }
}

final class WordDocumentParser: NSObject, XMLParserDelegate {
    let headingStyles: [String: Int]
    var blocks: [ExtractedBlock] = []
    /// Word speichert gerenderte Seitenumbrüche (genauer) und manuelle Umbrüche; gezählt wird bevorzugt Erstere.
    private var renderedBreaks = 0
    private var explicitBreaks = 0
    var page: Int { 1 + (renderedBreaks > 0 ? renderedBreaks : explicitBreaks) }

    private var inParagraph = false
    private var inText = false
    private var text = ""
    private var styleLevel: Int?
    private var outlineLevel: Int?
    private var isList = false
    private var tableDepth = 0
    private var rowCells: [String] = []
    private var cellText = ""
    private var paragraphStartPage = 1

    init(headingStyles: [String: Int]) {
        self.headingStyles = headingStyles
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "w:p":
            inParagraph = true
            text = ""
            styleLevel = nil
            outlineLevel = nil
            isList = false
            paragraphStartPage = page
        case "w:pStyle":
            if let v = attributeDict["w:val"] {
                styleLevel = headingStyles[v] ?? WordStylesParser.level(fromName: v.lowercased().replacingOccurrences(of: "heading", with: "heading "))
            }
        case "w:outlineLvl":
            if let v = attributeDict["w:val"].flatMap(Int.init), v < 9 { outlineLevel = min(v + 1, 3) }
        case "w:numPr":
            isList = true
        case "w:t":
            inText = true
        case "w:tab":
            if inParagraph { text += " " }
        case "w:br":
            if attributeDict["w:type"] == "page" {
                explicitBreaks += 1
                if text.isEmpty { paragraphStartPage = page }
            } else if inParagraph {
                text += " "
            }
        case "w:lastRenderedPageBreak":
            renderedBreaks += 1
            if text.isEmpty { paragraphStartPage = page }
        case "w:tbl":
            tableDepth += 1
        case "w:tr":
            rowCells = []
        case "w:tc":
            cellText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "w:t":
            inText = false
        case "w:p":
            inParagraph = false
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            if tableDepth > 0 {
                cellText += (cellText.isEmpty ? "" : " ") + clean
                return
            }
            if let level = styleLevel ?? outlineLevel {
                blocks.append(ExtractedBlock(kind: .heading(level), text: clean, page: paragraphStartPage))
            } else if isList {
                blocks.append(ExtractedBlock(kind: .listItem, text: clean, page: paragraphStartPage))
            } else {
                blocks.append(ExtractedBlock(kind: .paragraph, text: clean, page: paragraphStartPage))
            }
        case "w:tc":
            rowCells.append(cellText)
        case "w:tr":
            let row = rowCells.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !row.isEmpty { blocks.append(ExtractedBlock(kind: .tableRow, text: row.joined(separator: " | "), page: page)) }
        case "w:tbl":
            tableDepth = max(0, tableDepth - 1)
        default:
            break
        }
    }
}

final class SlideParser: NSObject, XMLParserDelegate {
    struct Paragraph { var text: String; var level: Int }

    var title = ""
    var paragraphs: [Paragraph] = []

    private var shapeIsTitle = false
    private var shapeIsSlideNumber = false
    private var inText = false
    private var current = ""
    private var currentLevel = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "p:sp":
            shapeIsTitle = false
            shapeIsSlideNumber = false
        case "p:ph":
            let type = attributeDict["type"] ?? ""
            shapeIsTitle = type == "title" || type == "ctrTitle"
            shapeIsSlideNumber = type == "sldNum" || type == "dt" || type == "ftr"
        case "a:p":
            current = ""
            currentLevel = 0
        case "a:pPr":
            currentLevel = attributeDict["lvl"].flatMap(Int.init) ?? 0
        case "a:t":
            inText = true
        case "a:br":
            current += " "
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "a:t":
            inText = false
        case "a:p":
            let clean = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !shapeIsSlideNumber else { return }
            if shapeIsTitle {
                title += (title.isEmpty ? "" : " ") + clean
            } else {
                paragraphs.append(Paragraph(text: clean, level: currentLevel))
            }
        default:
            break
        }
    }
}

final class RelationshipParser: NSObject, XMLParserDelegate {
    struct Relationship { var target: String; var type: String }
    private var result: [String: Relationship] = [:]

    static func parse(_ data: Data) -> [String: Relationship] {
        let p = RelationshipParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        _ = xml.parse()
        return p.result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Relationship", let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        result[id] = Relationship(target: target, type: attributeDict["Type"] ?? "")
    }
}

final class AttributeCollector: NSObject, XMLParserDelegate {
    private let element: String
    private let attribute: String
    private var values: [String] = []

    init(element: String, attribute: String) {
        self.element = element
        self.attribute = attribute
    }

    static func collect(_ data: Data, element: String, attribute: String) -> [String] {
        let p = AttributeCollector(element: element, attribute: attribute)
        let xml = XMLParser(data: data)
        xml.delegate = p
        _ = xml.parse()
        return p.values
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == element, let v = attributeDict[attribute] { values.append(v) }
    }
}
