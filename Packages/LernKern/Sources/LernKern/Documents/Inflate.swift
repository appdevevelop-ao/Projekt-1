import Foundation

/// Reiner Swift-DEFLATE-Dekoder (RFC 1951) für ZIP-Container (DOCX/PPTX).
/// Keine Abhängigkeiten, damit die Dokumentverarbeitung überall testbar ist.
public enum Inflate {
    public enum InflateError: Error, Equatable {
        case invalidBlockType
        case invalidStoredLength
        case invalidCode
        case unexpectedEnd
        case outputTooLarge
    }

    /// Dekomprimiert rohe DEFLATE-Daten (ohne zlib-Header).
    public static func decompress(_ data: [UInt8], expectedSize: Int? = nil, maxSize: Int = 200_000_000) throws -> [UInt8] {
        var reader = BitReader(data)
        var output: [UInt8] = []
        if let expectedSize, expectedSize > 0, expectedSize < maxSize { output.reserveCapacity(expectedSize) }
        var isFinal = false
        while !isFinal {
            isFinal = try reader.bits(1) == 1
            let type = try reader.bits(2)
            switch type {
            case 0:
                reader.alignToByte()
                let len = try reader.uint16()
                let nlen = try reader.uint16()
                guard len == ~nlen & 0xFFFF else { throw InflateError.invalidStoredLength }
                try reader.copyBytes(count: Int(len), into: &output)
            case 1:
                try inflateBlock(&reader, &output, literal: fixedLiteral, distance: fixedDistance, maxSize: maxSize)
            case 2:
                let (lit, dist) = try readDynamicTables(&reader)
                try inflateBlock(&reader, &output, literal: lit, distance: dist, maxSize: maxSize)
            default:
                throw InflateError.invalidBlockType
            }
            if output.count > maxSize { throw InflateError.outputTooLarge }
        }
        return output
    }

    // MARK: - Huffman

    struct Huffman {
        var counts: [Int]
        var symbols: [Int]

        init(lengths: [Int]) {
            counts = Array(repeating: 0, count: 16)
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offsets = Array(repeating: 0, count: 16)
            for i in 1..<16 { offsets[i] = offsets[i - 1] + counts[i - 1] }
            symbols = Array(repeating: 0, count: lengths.count)
            for (symbol, l) in lengths.enumerated() where l != 0 {
                symbols[offsets[l]] = symbol
                offsets[l] += 1
            }
        }

        func decode(_ reader: inout BitReader) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for len in 1..<16 {
                code |= try reader.bits(1)
                let count = counts[len]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw InflateError.invalidCode
        }
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    static let fixedLiteral: Huffman = {
        var lengths = Array(repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return Huffman(lengths: lengths)
    }()
    static let fixedDistance = Huffman(lengths: Array(repeating: 5, count: 30))

    static func readDynamicTables(_ reader: inout BitReader) throws -> (Huffman, Huffman) {
        let hlit = try reader.bits(5) + 257
        let hdist = try reader.bits(5) + 1
        let hclen = try reader.bits(4) + 4
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = Array(repeating: 0, count: 19)
        for i in 0..<hclen { codeLengths[order[i]] = try reader.bits(3) }
        let codeHuffman = Huffman(lengths: codeLengths)
        var lengths: [Int] = []
        lengths.reserveCapacity(hlit + hdist)
        while lengths.count < hlit + hdist {
            let symbol = try codeHuffman.decode(&reader)
            switch symbol {
            case 0..<16:
                lengths.append(symbol)
            case 16:
                guard let last = lengths.last else { throw InflateError.invalidCode }
                let repeatCount = 3 + (try reader.bits(2))
                lengths.append(contentsOf: Array(repeating: last, count: repeatCount))
            case 17:
                lengths.append(contentsOf: Array(repeating: 0, count: 3 + (try reader.bits(3))))
            case 18:
                lengths.append(contentsOf: Array(repeating: 0, count: 11 + (try reader.bits(7))))
            default:
                throw InflateError.invalidCode
            }
        }
        guard lengths.count == hlit + hdist else { throw InflateError.invalidCode }
        return (Huffman(lengths: Array(lengths[0..<hlit])), Huffman(lengths: Array(lengths[hlit...])))
    }

    static func inflateBlock(_ reader: inout BitReader, _ output: inout [UInt8], literal: Huffman, distance: Huffman, maxSize: Int) throws {
        while true {
            let symbol = try literal.decode(&reader)
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let li = symbol - 257
                guard li < lengthBase.count else { throw InflateError.invalidCode }
                let length = lengthBase[li] + (try reader.bits(lengthExtra[li]))
                let di = try distance.decode(&reader)
                guard di < distBase.count else { throw InflateError.invalidCode }
                let dist = distBase[di] + (try reader.bits(distExtra[di]))
                guard dist <= output.count else { throw InflateError.invalidCode }
                let start = output.count - dist
                for i in 0..<length { output.append(output[start + i]) }
                if output.count > maxSize { throw InflateError.outputTooLarge }
            }
        }
    }

    // MARK: - Bit-Leser

    struct BitReader {
        let data: [UInt8]
        var position = 0
        var bitBuffer = 0
        var bitCount = 0

        init(_ data: [UInt8]) { self.data = data }

        mutating func bits(_ count: Int) throws -> Int {
            if count == 0 { return 0 }
            while bitCount < count {
                guard position < data.count else { throw InflateError.unexpectedEnd }
                bitBuffer |= Int(data[position]) << bitCount
                position += 1
                bitCount += 8
            }
            let value = bitBuffer & ((1 << count) - 1)
            bitBuffer >>= count
            bitCount -= count
            return value
        }

        mutating func alignToByte() {
            bitBuffer = 0
            bitCount = 0
        }

        mutating func uint16() throws -> Int {
            guard position + 2 <= data.count else { throw InflateError.unexpectedEnd }
            let v = Int(data[position]) | Int(data[position + 1]) << 8
            position += 2
            return v
        }

        mutating func copyBytes(count: Int, into output: inout [UInt8]) throws {
            guard position + count <= data.count else { throw InflateError.unexpectedEnd }
            output.append(contentsOf: data[position..<position + count])
            position += count
        }
    }
}
