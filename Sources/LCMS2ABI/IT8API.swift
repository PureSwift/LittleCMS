import CLCMS2
import LittleCMS

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// CGATS.17 / IT8 measurement files.
//
// A sheet is a header of keyword-value properties, a list of sample
// names, and a table of patches; a file may hold several sheets.  The
// format is 1990s text with the quirks that implies — comments, quoted
// strings, hexadecimal and binary numbers, line continuation through
// includes — and the parser here is a port of the reference's, symbol
// for symbol, so that a file it accepts is accepted here and one it
// rejects is rejected with the same message.  The strings the API hands
// out live as long as the sheet, in an arena freed with it.

private let maxID = 128
private let maxStr = 1024
private let maxTables = 255
private let maxInclude = 20
private let defaultDoubleFormat = "%.10g"
private let directoryCharacter = UInt8(ascii: "/")

private enum Symbol {
    case undefined, inum, dnum, ident, string, comment, eoln, eof, synError
    case beginData, beginDataFormat, endData, endDataFormat, keyword, dataFormatID, include
    case domainMax, domainMin, lut1DSize, lut1DInputRange, lut3DSize, lut3DInputRange
    case lutInVideoRange, lutOutVideoRange, title
}

private enum WriteMode {
    case uncooked, stringify, hexadecimal, binary, pair
}

/// One property.  The strings are C strings in the sheet's arena, since
/// the API hands them out and a caller keeps the pointer.
private final class KeyValue {
    var keyword: UnsafeMutablePointer<CChar>
    var subkey: UnsafeMutablePointer<CChar>?
    var value: UnsafeMutablePointer<CChar>?
    var writeAs: WriteMode
    /// The reference's `NextSubkey` chain: the entries hanging off this
    /// one as sub-properties, in the order added.
    var subkeys: [KeyValue] = []

    init(keyword: UnsafeMutablePointer<CChar>, subkey: UnsafeMutablePointer<CChar>?, value: UnsafeMutablePointer<CChar>?, writeAs: WriteMode) {
        self.keyword = keyword
        self.subkey = subkey
        self.value = value
        self.writeAs = writeAs
    }
}

/// A list of properties in insertion order, with the reference's
/// lookup rules.
private final class KeyList {
    var entries: [KeyValue] = []

    /// `IsAvailableOnList`: the first entry with the key — comments
    /// never match — and, when a subkey is asked, the sub-property with
    /// that subkey hanging off it.  `last` is the reference's LastPtr:
    /// the last node visited, which is where a new sub-property attaches.
    func find(_ key: UnsafePointer<CChar>, _ subkey: UnsafePointer<CChar>?) -> (found: KeyValue?, last: KeyValue?) {
        var last: KeyValue? = entries.first
        var p: KeyValue?
        if key[0] != UInt8(ascii: "#") {
            for entry in entries {
                last = entry
                if cmsstrcasecmp(key, entry.keyword) == 0 {
                    p = entry
                    break
                }
            }
        } else {
            last = entries.last
        }
        guard let p else { return (nil, last) }
        guard let subkey else { return (p, last) }
        // The chain starts at the key node itself, whose own subkey may
        // match when it was added as a pair.
        for entry in [p] + p.subkeys {
            guard let s = entry.subkey else { continue }
            last = entry
            if cmsstrcasecmp(subkey, s) == 0 { return (entry, last) }
        }
        return (nil, last)
    }
}

private final class IT8Table {
    var sheetType: [CChar] = [0]
    var nSamples = 0
    var nPatches = 0
    var sampleID = 0
    let header = KeyList()
    /// The sample names, as the C array cmsIT8EnumDataFormat hands out.
    var dataFormat: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    /// nSamples × nPatches C strings, row-major.
    var data: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
}

private struct FileContext {
    var fileName: [CChar] = [CChar](repeating: 0, count: Int(cmsMAX_PATH))
    var stream: UnsafeMutablePointer<FILE>?
}

private let it8Keywords: [(String, Symbol)] = [
    ("$INCLUDE", .include), (".INCLUDE", .include),
    ("BEGIN_DATA", .beginData), ("BEGIN_DATA_FORMAT", .beginDataFormat),
    ("DATA_FORMAT_IDENTIFIER", .dataFormatID),
    ("END_DATA", .endData), ("END_DATA_FORMAT", .endDataFormat),
    ("KEYWORD", .keyword),
]

private let cubeKeywords: [(String, Symbol)] = [
    ("DOMAIN_MAX", .domainMax), ("DOMAIN_MIN", .domainMin),
    ("LUT_1D_SIZE", .lut1DSize), ("LUT_1D_INPUT_RANGE", .lut1DInputRange),
    ("LUT_3D_SIZE", .lut3DSize), ("LUT_3D_INPUT_RANGE", .lut3DInputRange),
    ("LUT_IN_VIDEO_RANGE", .lutInVideoRange), ("LUT_OUT_VIDEO_RANGE", .lutOutVideoRange),
    ("TITLE", .title),
]

private let predefinedProperties: [(String, WriteMode)] = [
    ("NUMBER_OF_FIELDS", .uncooked), ("NUMBER_OF_SETS", .uncooked),
    ("ORIGINATOR", .stringify), ("FILE_DESCRIPTOR", .stringify), ("CREATED", .stringify),
    ("DESCRIPTOR", .stringify), ("DIFFUSE_GEOMETRY", .stringify), ("MANUFACTURER", .stringify),
    ("MANUFACTURE", .stringify), ("PROD_DATE", .stringify), ("SERIAL", .stringify),
    ("MATERIAL", .stringify), ("INSTRUMENTATION", .stringify), ("MEASUREMENT_SOURCE", .stringify),
    ("PRINT_CONDITIONS", .stringify), ("SAMPLE_BACKING", .stringify), ("CHISQ_DOF", .stringify),
    ("MEASUREMENT_GEOMETRY", .stringify), ("FILTER", .stringify), ("POLARIZATION", .stringify),
    ("WEIGHTING_FUNCTION", .pair), ("COMPUTATIONAL_PARAMETER", .pair),
    ("TARGET_TYPE", .stringify), ("COLORANT", .stringify), ("TABLE_DESCRIPTOR", .stringify),
    ("TABLE_NAME", .stringify),
]

private let predefinedSampleIDs: [String] = [
    "SAMPLE_ID", "STRING", "CMYK_C", "CMYK_M", "CMYK_Y", "CMYK_K", "D_RED", "D_GREEN", "D_BLUE",
    "D_VIS", "D_MAJOR_FILTER", "RGB_R", "RGB_G", "RGB_B", "SPECTRAL_NM", "SPECTRAL_PCT",
    "SPECTRAL_DEC", "XYZ_X", "XYZ_Y", "XYZ_Z", "XYY_X", "XYY_Y", "XYY_CAPY", "LAB_L", "LAB_A",
    "LAB_B", "LAB_C", "LAB_H", "LAB_DE", "LAB_DE_94", "LAB_DE_CMC", "LAB_DE_2000", "MEAN_DE",
    "STDEV_X", "STDEV_Y", "STDEV_Z", "STDEV_L", "STDEV_A", "STDEV_B", "STDEV_DE", "CHI_SQD_PAR",
]

/// The sheet: tables, the lexer's state, and the arena.
final class IT8Box {
    let context: cmsContext?
    fileprivate var tables: [IT8Table] = []
    fileprivate var nTable = 0
    fileprivate var isCube = false

    // The lexer.
    fileprivate var sy: Symbol = .undefined
    fileprivate var ch: Int32 = 32
    fileprivate var inum: Int32 = 0
    fileprivate var dnum: Double = 0
    fileprivate var id: [UInt8] = []
    fileprivate var str: [UInt8] = []

    fileprivate let validKeywords = KeyList()
    fileprivate let validSampleID = KeyList()

    /// The text being parsed when it came from memory, and the cursor.
    fileprivate var memoryBlock: [UInt8] = []
    fileprivate var sourceIndex = 0
    fileprivate var lineno: Int32 = 1
    fileprivate var fileStack: [FileContext] = [FileContext()]
    fileprivate var includeSP = 0
    fileprivate var doubleFormatter: [CChar] = Array(defaultDoubleFormat.utf8CString)

    /// Every C string and array handed out or held, freed with the sheet.
    fileprivate var arena: [UnsafeMutableRawPointer] = []

    init(context: cmsContext?) {
        self.context = context
    }

    deinit {
        for block in arena { _cmsFree(context, block) }
    }

    /// A copy of the bytes as a C string in the arena.
    fileprivate func allocString(_ bytes: [UInt8]) -> UnsafeMutablePointer<CChar>? {
        guard let raw = _cmsMallocZero(context, cmsUInt32Number(bytes.count + 1)) else { return nil }
        let p = raw.assumingMemoryBound(to: CChar.self)
        for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
        arena.append(raw)
        return p
    }

    fileprivate func allocString(_ s: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
        allocString(Array(UnsafeBufferPointer(start: UnsafeRawPointer(s).assumingMemoryBound(to: UInt8.self), count: strlen(s))))
    }

    /// An array of `count` C-string slots in the arena.
    fileprivate func allocPointers(_ count: Int) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
        guard let raw = _cmsMallocZero(context, cmsUInt32Number(max(count, 1) * MemoryLayout<UnsafeMutablePointer<CChar>?>.stride))
        else { return nil }
        arena.append(raw)
        return raw.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
    }

    fileprivate var table: IT8Table {
        if nTable >= tables.count {
            synError("Table \(nTable) out of sequence")
            return tables[0]
        }
        return tables[nTable]
    }

    /// `SynError`: reports with the file and line, and leaves the lexer
    /// in the error state.
    @discardableResult
    fileprivate func synError(_ text: String) -> Bool {
        let file = fileStack[includeSP].fileName.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        sy = .synError
        report(cmsUInt32Number(cmsERROR_CORRUPTION_DETECTED), "\(file): Line \(lineno), \(text)", to: context)
        return false
    }

    /// The double as the sheet's formatter prints it.
    fileprivate func formatDouble(_ v: Double) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 1024)
        let n = withVaList([v]) { vsnprintf(&buffer, 1023, doubleFormatter, $0) }
        if n < 0 { return [] }
        return buffer.prefix(min(Int(n), 1023)).map { UInt8(bitPattern: $0) }
    }
}

@inline(__always)
private func it8(_ h: cmsHANDLE?) -> IT8Box? {
    guard let h else { return nil }
    return Unmanaged<IT8Box>.fromOpaque(h).takeUnretainedValue()
}

@inline(__always)
private func cstr(_ s: String) -> [UInt8] { Array(s.utf8) }

// -- character classes -------------------------------------------------------------

@inline(__always) private func isSeparator(_ c: Int32) -> Bool { c == 32 || c == 9 }
@inline(__always) private func isMiddle(_ c: Int32) -> Bool {
    !isSeparator(c) && c != Int32(UInt8(ascii: "#")) && c != Int32(UInt8(ascii: "\"")) && c != Int32(UInt8(ascii: "'")) && c > 32 && c < 127
}
@inline(__always) private func isDigit(_ c: Int32) -> Bool { c >= 48 && c <= 57 }
@inline(__always) private func isAlnum(_ c: Int32) -> Bool {
    isDigit(c) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
}
@inline(__always) private func isIdChar(_ c: Int32) -> Bool { isAlnum(c) || isMiddle(c) }
@inline(__always) private func isFirstIdChar(_ c: Int32) -> Bool { c != Int32(UInt8(ascii: "-")) && !isDigit(c) && isMiddle(c) }
@inline(__always) private func isXDigit(_ c: Int32) -> Bool {
    isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
}
@inline(__always) private func toUpper(_ c: Int32) -> Int32 { (c >= 97 && c <= 122) ? c - 32 : c }

// -- the lexer ----------------------------------------------------------------------

extension IT8Box {
    fileprivate func nextCh() {
        if let stream = fileStack[includeSP].stream {
            ch = fgetc(stream)
            if feof(stream) != 0 {
                if includeSP > 0 {
                    fclose(stream)
                    includeSP -= 1
                    ch = 32
                } else {
                    ch = 0
                }
            }
        } else {
            if sourceIndex < memoryBlock.count {
                ch = Int32(memoryBlock[sourceIndex])
                if ch != 0 { sourceIndex += 1 }
            } else {
                ch = 0
            }
        }
    }

    /// The keyword tables are searched by binary search in the
    /// reference, which needs them sorted; a linear case-insensitive
    /// search gives the same answer.
    fileprivate func keyword(_ identifier: [UInt8]) -> Symbol {
        let table = isCube ? cubeKeywords : it8Keywords
        let idText = identifier + [0]
        return idText.withUnsafeBufferPointer { idp -> Symbol in
            let idc = UnsafeRawPointer(idp.baseAddress!).assumingMemoryBound(to: CChar.self)
            for (name, symbol) in table where cmsstrcasecmp(idc, name) == 0 {
                return symbol
            }
            return .undefined
        }
    }

    private static func xpow10(_ n: Int32) -> Double { pow(10, Double(n)) }

    fileprivate func readReal(_ start: Int32) {
        dnum = Double(start)
        while isDigit(ch) {
            dnum = dnum * 10.0 + Double(ch - 48)
            nextCh()
        }
        if ch == Int32(UInt8(ascii: ".")) {
            var frac = 0.0
            var prec: Int32 = 0
            nextCh()
            while isDigit(ch) {
                frac = frac * 10.0 + Double(ch - 48)
                prec += 1
                nextCh()
            }
            dnum = dnum + (frac / IT8Box.xpow10(prec))
        }
        if toUpper(ch) == Int32(UInt8(ascii: "E")) {
            nextCh()
            var sgn: Int32 = 1
            if ch == Int32(UInt8(ascii: "-")) {
                sgn = -1
                nextCh()
            } else if ch == Int32(UInt8(ascii: "+")) {
                sgn = 1
                nextCh()
            }
            var e: Int32 = 0
            while isDigit(ch) {
                let digit = ch - 48
                if Double(e) * 10.0 + Double(digit) < 2147483647.0 {
                    e = e * 10 + digit
                }
                nextCh()
            }
            e = sgn * e
            dnum = dnum * IT8Box.xpow10(e)
        }
    }

    fileprivate func inStringSymbol() {
        while isSeparator(ch) { nextCh() }
        if ch == Int32(UInt8(ascii: "'")) || ch == Int32(UInt8(ascii: "\"")) {
            let sng = ch
            str.removeAll(keepingCapacity: true)
            nextCh()
            while ch != sng {
                if ch == 10 || ch == 13 || ch == 0 { break }
                str.append(UInt8(truncatingIfNeeded: ch))
                nextCh()
            }
            sy = .string
            nextCh()
        } else {
            synError("String expected")
        }
    }

    fileprivate func inSymbol() {
        repeat {
            while isSeparator(ch) { nextCh() }

            if isFirstIdChar(ch) {
                id.removeAll(keepingCapacity: true)
                repeat {
                    id.append(UInt8(truncatingIfNeeded: ch))
                    nextCh()
                } while isIdChar(ch)
                let key = keyword(id)
                sy = key == .undefined ? .ident : key
            } else if isDigit(ch) || ch == Int32(UInt8(ascii: ".")) || ch == Int32(UInt8(ascii: "-")) || ch == Int32(UInt8(ascii: "+")) {
                var sign: Int32 = 1
                if ch == Int32(UInt8(ascii: "-")) {
                    sign = -1
                    nextCh()
                } else if ch == Int32(UInt8(ascii: "+")) {
                    sign = 1
                    nextCh()
                }
                inum = 0
                sy = .inum

                if ch == Int32(UInt8(ascii: "0")) {
                    nextCh()
                    if toUpper(ch) == Int32(UInt8(ascii: "X")) {
                        nextCh()
                        while isXDigit(ch) {
                            let c = toUpper(ch)
                            let j: Int32 = (c >= 65 && c <= 70) ? c - 65 + 10 : c - 48
                            if Double(inum) * 16.0 + Double(j) > 2147483647.0 {
                                synError("Invalid hexadecimal number")
                                return
                            }
                            inum = inum * 16 + j
                            nextCh()
                        }
                        return
                    }
                    if toUpper(ch) == Int32(UInt8(ascii: "B")) {
                        nextCh()
                        while ch == 48 || ch == 49 {
                            let j = ch - 48
                            if Double(inum) * 2.0 + Double(j) > 2147483647.0 {
                                synError("Invalid binary number")
                                return
                            }
                            inum = inum * 2 + j
                            nextCh()
                        }
                        return
                    }
                }

                while isDigit(ch) {
                    let digit = ch - 48
                    if Double(inum) * 10.0 + Double(digit) > 2147483647.0 {
                        readReal(inum)
                        sy = .dnum
                        dnum *= Double(sign)
                        return
                    }
                    inum = inum * 10 + digit
                    nextCh()
                }
                if ch == Int32(UInt8(ascii: ".")) {
                    readReal(inum)
                    sy = .dnum
                    dnum *= Double(sign)
                    return
                }
                inum *= sign

                // A number running into letters is an identifier after all.
                if isIdChar(ch) {
                    id = sy == .inum ? cstr(String(inum)) : formatDouble(dnum)
                    repeat {
                        id.append(UInt8(truncatingIfNeeded: ch))
                        nextCh()
                    } while isIdChar(ch)
                    sy = .ident
                }
                return
            } else {
                switch ch {
                case 0x1a, 0, -1:
                    sy = .eof
                case 13:
                    nextCh()
                    if ch == 10 { nextCh() }
                    sy = .eoln
                    lineno += 1
                case 10:
                    nextCh()
                    sy = .eoln
                    lineno += 1
                case Int32(UInt8(ascii: "#")):
                    nextCh()
                    while ch != 0 && ch != 10 && ch != 13 { nextCh() }
                    sy = .comment
                case Int32(UInt8(ascii: "'")), Int32(UInt8(ascii: "\"")):
                    inStringSymbol()
                default:
                    synError("Unrecognized character: 0x\(String(ch, radix: 16))")
                    return
                }
            }
        } while sy == .comment

        if sy == .include {
            if includeSP >= maxInclude - 1 {
                synError("Too many recursion levels")
                return
            }
            inStringSymbol()
            if !check(.string, "Filename expected") { return }

            var nested = includeSP + 1 < fileStack.count ? fileStack[includeSP + 1] : FileContext()
            let base = fileStack[includeSP].fileName
            guard let path = IT8Box.buildAbsolutePath(str, base: base) else {
                synError("File path too long")
                return
            }
            nested.fileName = path
            nested.stream = path.withUnsafeBufferPointer { fopen($0.baseAddress!, "rt") }
            if nested.stream == nil {
                let name = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                synError("File \(name) not found")
                return
            }
            if includeSP + 1 < fileStack.count {
                fileStack[includeSP + 1] = nested
            } else {
                fileStack.append(nested)
            }
            includeSP += 1
            ch = 32
            inSymbol()
        }
    }

    /// `BuildAbsolutePath`: the include as given when absolute, else
    /// against the directory of the including file.
    private static func buildAbsolutePath(_ relative: [UInt8], base: [CChar]) -> [CChar]? {
        let maxLen = Int(cmsMAX_PATH) - 1
        if let first = relative.first, first == directoryCharacter {
            var out = relative.prefix(maxLen - 1).map { CChar(bitPattern: $0) }
            out.append(0)
            return out + [CChar](repeating: 0, count: Int(cmsMAX_PATH) - out.count)
        }
        var buffer = Array(base.prefix(maxLen))
        while buffer.count < maxLen { buffer.append(0) }
        buffer[maxLen - 1] = 0
        guard let tail = buffer.lastIndex(of: CChar(bitPattern: directoryCharacter)) else { return nil }
        if tail >= maxLen { return nil }
        var out = Array(buffer[0...tail])
        for b in relative.prefix(maxLen - tail - 2) { out.append(CChar(bitPattern: b)) }
        out.append(0)
        while out.count < Int(cmsMAX_PATH) { out.append(0) }
        return out
    }

    @discardableResult
    fileprivate func check(_ symbol: Symbol, _ error: String) -> Bool {
        if sy != symbol {
            return synError(error.contains("%") ? "**** CORRUPTED FORMAT STRING ***" : error)
        }
        return true
    }

    fileprivate func checkEOLN() -> Bool {
        if !check(.eoln, "Expected separator") { return false }
        while sy == .eoln { inSymbol() }
        return true
    }

    fileprivate func skip(_ symbol: Symbol) {
        if sy == symbol && sy != .eof && sy != .synError { inSymbol() }
    }

    fileprivate func skipEOLN() {
        while sy == .eoln { inSymbol() }
    }

    /// The current symbol as text, or the error.
    fileprivate func getVal(_ max: Int, _ errorTitle: String) -> [UInt8]? {
        switch sy {
        case .eoln: return []
        case .ident: return Array(id.prefix(max - 1))
        case .inum: return cstr(String(inum))
        case .dnum: return Array(formatDouble(dnum).prefix(max - 1))
        case .string: return Array(str.prefix(max - 1))
        default:
            synError(errorTitle)
            return nil
        }
    }
}

/// `ParseFloatNumber`: the reference's own number reader for stored
/// values, which handles sign, fraction and exponent and nothing else.
private func parseFloatNumber(_ buffer: UnsafePointer<CChar>?) -> Double {
    guard var p = buffer else { return 0.0 }
    var dnum = 0.0
    var sign = 1.0
    if p.pointee == CChar(UInt8(ascii: "-")) || p.pointee == CChar(UInt8(ascii: "+")) {
        sign = p.pointee == CChar(UInt8(ascii: "-")) ? -1 : 1
        p += 1
    }
    @inline(__always) func digit(_ c: CChar) -> Bool { c >= 48 && c <= 57 }
    while p.pointee != 0 && digit(p.pointee) {
        dnum = dnum * 10.0 + Double(p.pointee - 48)
        p += 1
    }
    if p.pointee == CChar(UInt8(ascii: ".")) {
        var frac = 0.0
        var prec: Int32 = 0
        p += 1
        while p.pointee != 0 && digit(p.pointee) {
            frac = frac * 10.0 + Double(p.pointee - 48)
            prec += 1
            p += 1
        }
        dnum = dnum + (frac / pow(10, Double(prec)))
    }
    if p.pointee != 0 && (p.pointee == CChar(UInt8(ascii: "E")) || p.pointee == CChar(UInt8(ascii: "e"))) {
        p += 1
        var sgn: Int32 = 1
        if p.pointee == CChar(UInt8(ascii: "-")) {
            sgn = -1
            p += 1
        } else if p.pointee == CChar(UInt8(ascii: "+")) {
            sgn = 1
            p += 1
        }
        var e: Int32 = 0
        while p.pointee != 0 && digit(p.pointee) {
            let d = Int32(p.pointee - 48)
            if Double(e) * 10.0 + Double(d) < 2147483647.0 {
                e = e * 10 + d
            }
            p += 1
        }
        e = sgn * e
        dnum = dnum * pow(10, Double(e))
    }
    return sign * dnum
}

/// `satoi`: atoi clamped to the reference's bounds.
private func satoi(_ b: UnsafePointer<CChar>?) -> Int32 {
    guard let b else { return 0 }
    let n = atoi(b)
    if n > 0x7ffffff0 { return 0x7ffffff0 }
    if n < -0x7ffffff0 { return -0x7ffffff0 }
    return n
}

// -- properties and tables ---------------------------------------------------------------

extension IT8Box {
    /// `AddToList`: replaces the value of an entry already present, or
    /// appends one — as a sub-property hanging off the key node when a
    /// subkey is given.  The two count keys may not be given twice.
    @discardableResult
    fileprivate func addToList(
        _ list: KeyList, _ key: UnsafePointer<CChar>, _ subkey: UnsafePointer<CChar>?,
        _ value: UnsafePointer<CChar>?, _ writeAs: WriteMode
    ) -> KeyValue? {
        let (found, last) = list.find(key, subkey)
        let p: KeyValue
        if let found {
            if cmsstrcasecmp(key, "NUMBER_OF_FIELDS") == 0 || cmsstrcasecmp(key, "NUMBER_OF_SETS") == 0 {
                synError("duplicate key <\(String(cString: key))>")
                return nil
            }
            p = found
        } else {
            guard let keyword = allocString(key) else {
                synError("AddToList: out of memory")
                return nil
            }
            let sub = subkey.flatMap { allocString($0) }
            p = KeyValue(keyword: keyword, subkey: sub, value: nil, writeAs: writeAs)
            if subkey != nil, let last {
                last.subkeys.append(p)
            }
            list.entries.append(p)
        }
        p.writeAs = writeAs
        p.value = value.flatMap { allocString($0) }
        return p
    }

    fileprivate func addAvailableProperty(_ key: UnsafePointer<CChar>, _ writeAs: WriteMode) -> KeyValue? {
        addToList(validKeywords, key, nil, nil, writeAs)
    }

    fileprivate func addAvailableSampleID(_ key: UnsafePointer<CChar>) -> KeyValue? {
        addToList(validSampleID, key, nil, nil, .uncooked)
    }

    fileprivate func allocTable() -> Bool {
        if tables.count >= maxTables - 1 { return false }
        tables.append(IT8Table())
        return true
    }

    fileprivate func property(_ key: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
        table.header.find(key, nil).found?.value
    }

    fileprivate func allocateDataFormat() -> Bool {
        let t = table
        if t.dataFormat != nil { return true }
        t.nSamples = Int(satoi(property("NUMBER_OF_FIELDS")))
        if t.nSamples <= 0 || t.nSamples > 0x7ffe {
            synError("Wrong NUMBER_OF_FIELDS")
            return false
        }
        guard let slots = allocPointers(t.nSamples + 1) else {
            synError("Unable to allocate dataFormat array")
            return false
        }
        t.dataFormat = slots
        return true
    }

    fileprivate func dataFormat(_ n: Int) -> UnsafeMutablePointer<CChar>? {
        table.dataFormat?[n]
    }

    fileprivate func setDataFormat(_ n: Int, _ label: UnsafePointer<CChar>) -> Bool {
        let t = table
        if t.dataFormat == nil {
            if !allocateDataFormat() { return false }
        }
        if n >= t.nSamples {
            synError("More than NUMBER_OF_FIELDS fields.")
            return false
        }
        if let format = t.dataFormat {
            guard let copy = allocString(label) else { return false }
            format[n] = copy
        }
        return true
    }

    fileprivate func allocateDataSet() -> Bool {
        let t = table
        if t.data != nil { return true }
        t.nSamples = Int(satoi(property("NUMBER_OF_FIELDS")))
        t.nPatches = Int(satoi(property("NUMBER_OF_SETS")))
        if t.nSamples < 0 || t.nSamples > 0x7ffe || t.nPatches < 0 || t.nPatches > 0x7ffe
            || t.nPatches * t.nSamples > 200000
        {
            synError("AllocateDataSet: too much data")
            return false
        }
        guard let slots = allocPointers((t.nSamples + 1) * (t.nPatches + 1)) else {
            synError("AllocateDataSet: Unable to allocate data array")
            return false
        }
        t.data = slots
        return true
    }

    fileprivate func getData(_ nSet: Int, _ nField: Int) -> UnsafeMutablePointer<CChar>? {
        let t = table
        if nSet < 0 || nSet >= t.nPatches || nField < 0 || nField >= t.nSamples { return nil }
        guard let data = t.data else { return nil }
        return data[nSet * t.nSamples + nField]
    }

    fileprivate func setData(_ nSet: Int, _ nField: Int, _ value: UnsafePointer<CChar>) -> Bool {
        let t = table
        if t.data == nil {
            if !allocateDataSet() { return false }
        }
        guard let data = t.data else { return false }
        if nSet > t.nPatches || nSet < 0 {
            return synError("Patch \(nSet) out of range, there are \(t.nPatches) patches")
        }
        if nField > t.nSamples || nField < 0 {
            return synError("Sample \(nField) out of range, there are \(t.nSamples) samples")
        }
        guard let copy = allocString(value) else { return false }
        data[nSet * t.nSamples + nField] = copy
        return true
    }
}

// -- writing --------------------------------------------------------------------------

/// Where a save goes: a file, or memory (counting first, then writing).
private final class SaveStream {
    var stream: UnsafeMutablePointer<FILE>?
    var base: UnsafeMutablePointer<UInt8>?
    var used = 0
    var max = 0

    func write(_ text: UnsafePointer<CChar>?) {
        let bytes: UnsafeBufferPointer<UInt8>
        if let text {
            bytes = UnsafeBufferPointer(start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self), count: strlen(text))
        } else {
            bytes = UnsafeBufferPointer(start: nil, count: 0)
        }
        write(bytes: text == nil ? [32] : Array(bytes))
    }

    func write(_ text: String) { write(bytes: Array(text.utf8)) }

    func write(bytes: [UInt8]) {
        let len = bytes.count
        used += len
        if let stream {
            if fwrite(bytes, 1, len, stream) != len {
                report(cmsUInt32Number(cmsERROR_WRITE), "Write to file error in CGATS parser", to: nil)
            }
        } else if let base {
            if used > max {
                report(cmsUInt32Number(cmsERROR_WRITE), "Write to memory overflows in CGATS parser", to: nil)
                return
            }
            (base + (used - len)).update(from: bytes, count: len)
        }
    }
}

/// `satob`: a value as binary digits.
private func binaryText(_ v: UnsafePointer<CChar>?) -> String {
    guard let v else { return "0" }
    let x = UInt32(bitPattern: atoi(v))
    return String(x, radix: 2)
}

extension IT8Box {
    fileprivate func writeHeader(_ fp: SaveStream) {
        let t = table
        fp.write(t.sheetType.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        fp.write("\n")

        for p in t.header.entries {
            if p.keyword[0] == CChar(UInt8(ascii: "#")) {
                fp.write("#\n# ")
                if let value = p.value {
                    var q = value
                    while q.pointee != 0 {
                        fp.write(bytes: [UInt8(bitPattern: q.pointee)])
                        if q.pointee == 10 { fp.write("# ") }
                        q += 1
                    }
                }
                fp.write("\n#\n")
                continue
            }

            if validKeywords.find(p.keyword, nil).found == nil {
                _ = addAvailableProperty(p.keyword, .uncooked)
            }

            fp.write(p.keyword)
            if let value = p.value {
                switch p.writeAs {
                case .uncooked:
                    fp.write("\t"); fp.write(value)
                case .stringify:
                    fp.write("\t\""); fp.write(value); fp.write("\"")
                case .hexadecimal:
                    fp.write("\t0x" + String(UInt32(bitPattern: satoi(value)), radix: 16, uppercase: true))
                case .binary:
                    fp.write("\t0b" + binaryText(value))
                case .pair:
                    fp.write("\t\""); fp.write(p.subkey); fp.write(","); fp.write(value); fp.write("\"")
                }
            }
            fp.write("\n")
        }
    }

    fileprivate func writeDataFormat(_ fp: SaveStream) {
        let t = table
        guard let format = t.dataFormat else { return }
        fp.write("BEGIN_DATA_FORMAT\n")
        fp.write(" ")
        let nSamples = Int(satoi(property("NUMBER_OF_FIELDS")))
        if nSamples <= t.nSamples {
            for i in 0..<nSamples {
                fp.write(format[i])
                fp.write(i == nSamples - 1 ? "\n" : "\t")
            }
        }
        fp.write("END_DATA_FORMAT\n")
    }

    fileprivate func writeData(_ fp: SaveStream) {
        let t = table
        guard let data = t.data else { return }
        fp.write("BEGIN_DATA\n")
        let nPatches = Int(satoi(property("NUMBER_OF_SETS")))
        if nPatches <= t.nPatches {
            for i in 0..<nPatches {
                fp.write(" ")
                for j in 0..<t.nSamples {
                    if let ptr = data[i * t.nSamples + j] {
                        if strchr(ptr, 32) != nil {
                            fp.write("\""); fp.write(ptr); fp.write("\"")
                        } else {
                            fp.write(ptr)
                        }
                    } else {
                        fp.write("\"\"")
                    }
                    fp.write(j == t.nSamples - 1 ? "\n" : "\t")
                }
            }
        }
        fp.write("END_DATA\n")
    }
}

// -- parsing ---------------------------------------------------------------------------

extension IT8Box {
    fileprivate func dataFormatSection() -> Bool {
        var iField = 0
        let t = table
        inSymbol()
        _ = checkEOLN()
        while sy != .endDataFormat && sy != .eoln && sy != .eof && sy != .synError {
            if sy != .ident {
                return synError("Sample type expected")
            }
            let ok = (id + [0]).withUnsafeBufferPointer {
                setDataFormat(iField, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self))
            }
            if !ok { return false }
            iField += 1
            inSymbol()
            skipEOLN()
        }
        skipEOLN()
        skip(.endDataFormat)
        skipEOLN()
        if iField != t.nSamples {
            synError("Count mismatch. NUMBER_OF_FIELDS was \(t.nSamples), found \(iField)\n")
        }
        return true
    }

    fileprivate func dataSection() -> Bool {
        var iField = 0
        var iSet = 0
        let t = table
        inSymbol()
        _ = checkEOLN()
        if t.data == nil {
            if !allocateDataSet() { return false }
        }
        while sy != .endData && sy != .eof && sy != .synError {
            if iField >= t.nSamples {
                iField = 0
                iSet += 1
            }
            if sy != .endData && sy != .eof && sy != .synError {
                let text: [UInt8]
                switch sy {
                case .ident: text = id
                case .string: text = str
                default:
                    guard let v = getVal(255, "Sample data expected") else { return false }
                    text = v
                }
                let ok = (text + [0]).withUnsafeBufferPointer {
                    setData(iSet, iField, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self))
                }
                if !ok { return false }
                iField += 1
                inSymbol()
                skipEOLN()
            }
        }
        skipEOLN()
        skip(.endData)
        skipEOLN()
        if iSet + 1 != t.nPatches {
            return synError("Count mismatch. NUMBER_OF_SETS was \(t.nPatches), found \(iSet + 1)\n")
        }
        return true
    }

    fileprivate func headerSection() -> Bool {
        while sy != .eof && sy != .synError && sy != .beginDataFormat && sy != .beginData {
            switch sy {
            case .keyword:
                inSymbol()
                guard let buffer = getVal(maxStr - 1, "Keyword expected") else { return false }
                let ok = (buffer + [0]).withUnsafeBufferPointer {
                    addAvailableProperty(UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), .uncooked) != nil
                }
                if !ok { return false }
                inSymbol()

            case .dataFormatID:
                inSymbol()
                guard let buffer = getVal(maxStr - 1, "Keyword expected") else { return false }
                let ok = (buffer + [0]).withUnsafeBufferPointer {
                    addAvailableSampleID(UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self)) != nil
                }
                if !ok { return false }
                inSymbol()

            case .ident:
                let varName: [CChar] = id.prefix(maxID - 1).map { CChar(bitPattern: $0) } + [0]
                let key: KeyValue? = varName.withUnsafeBufferPointer { vp -> KeyValue? in
                    let v = vp.baseAddress!
                    if let found = validKeywords.find(v, nil).found { return found }
                    return addAvailableProperty(v, .uncooked)
                }
                guard let key else { return false }
                inSymbol()
                guard let buffer = getVal(maxStr - 1, "Property data expected") else { return false }
                let bufferC = buffer + [0]

                if key.writeAs != .pair {
                    let mode: WriteMode = sy == .string ? .stringify : .uncooked
                    let ok = varName.withUnsafeBufferPointer { vp in
                        bufferC.withUnsafeBufferPointer { bp in
                            addToList(
                                table.header,
                                vp.baseAddress!, nil,
                                UnsafeRawPointer(bp.baseAddress!).assumingMemoryBound(to: CChar.self), mode
                            ) != nil
                        }
                    }
                    if !ok { return false }
                } else {
                    let name = String(decoding: buffer, as: UTF8.self)
                    let varText = String(decoding: varName.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if sy != .string {
                        return synError("Invalid value '\(name)' for property '\(varText)'.")
                    }
                    // "sub,value; sub,value; ..." — each pair trimmed of
                    // spaces around the comma and at the ends.
                    for pair in name.split(separator: ";", omittingEmptySubsequences: false) {
                        guard let comma = pair.lastIndex(of: ",") else {
                            return synError("Invalid value for property '\(varText)'.")
                        }
                        var subkey = String(pair[pair.startIndex..<comma])
                        var value = String(pair[pair.index(after: comma)...])
                        while subkey.hasSuffix(" ") { subkey.removeLast() }
                        while value.hasSuffix(" ") { value.removeLast() }
                        while subkey.hasPrefix(" ") { subkey.removeFirst() }
                        while value.hasPrefix(" ") { value.removeFirst() }
                        if subkey.isEmpty || value.isEmpty {
                            return synError("Invalid value for property '\(varText)'.")
                        }
                        varName.withUnsafeBufferPointer { vp in
                            subkey.withCString { sp in
                                value.withCString { valp in
                                    _ = addToList(table.header, vp.baseAddress!, sp, valp, .pair)
                                }
                            }
                        }
                    }
                }
                inSymbol()

            case .eoln:
                break

            default:
                return synError("expected keyword or identifier")
            }
            skipEOLN()
        }
        return true
    }

    /// The first line is the sheet type, taken raw to the end of line.
    fileprivate func readType() -> [CChar] {
        var out: [CChar] = []
        var cnt = 0
        while isSeparator(ch) { nextCh() }
        while ch != 13 && ch != 10 && ch != 9 && ch != 0 {
            if cnt < maxStr { out.append(CChar(truncatingIfNeeded: ch)) }
            cnt += 1
            nextCh()
        }
        out.append(0)
        return out
    }

    fileprivate func setSheetType(_ type: [UInt8]) {
        var t = type.prefix(maxStr - 1).map { CChar(bitPattern: $0) }
        t.append(0)
        table.sheetType = t
    }

    fileprivate func parseIT8(noSheet: Bool) -> Bool {
        if !noSheet {
            tables[0].sheetType = readType()
        }
        inSymbol()
        skipEOLN()
        while sy != .eof && sy != .synError {
            switch sy {
            case .beginDataFormat:
                if !dataFormatSection() { return false }
            case .beginData:
                if !dataSection() { return false }
                if sy != .eof && sy != .synError {
                    if !allocTable() { return false }
                    nTable = tables.count - 1
                    // The next sheet's type follows, when it does not
                    // begin with a keyword.
                    if !noSheet {
                        if sy == .ident {
                            while isSeparator(ch) { nextCh() }
                            if ch == 10 || ch == 13 {
                                setSheetType(id)
                                inSymbol()
                            } else {
                                setSheetType([])
                            }
                        } else if sy == .string {
                            setSheetType(str)
                            inSymbol()
                        }
                    }
                }
            case .eoln:
                skipEOLN()
            default:
                if !headerSection() { return false }
            }
        }
        return sy != .synError
    }

    /// Finds the SAMPLE_ID column, and rewrites any LABEL column's values
    /// as "label table type" for the tables they name.
    fileprivate func cookPointers() {
        let oldTable = nTable
        for j in 0..<tables.count {
            let t = tables[j]
            t.sampleID = 0
            nTable = j
            for idField in 0..<t.nSamples {
                guard let format = t.dataFormat else {
                    synError("Undefined DATA_FORMAT")
                    return
                }
                guard let fld = format[idField] else { continue }
                if cmsstrcasecmp(fld, "SAMPLE_ID") == 0 {
                    t.sampleID = idField
                }
                if cmsstrcasecmp(fld, "LABEL") == 0 || fld[0] == CChar(UInt8(ascii: "$")) {
                    for i in 0..<t.nPatches {
                        guard let label = getData(i, idField) else { continue }
                        for k in 0..<tables.count {
                            if let p = tables[k].header.find(label, nil).found {
                                let type = p.value.map { String(cString: $0) } ?? "(null)"
                                let text = "\(String(cString: label)) \(k) \(type)"
                                _ = text.withCString { setData(i, idField, $0) }
                            }
                        }
                    }
                }
            }
        }
        nTable = oldTable
    }
}

/// `IsMyBlock`: whether the first line looks like a sheet type — up to
/// two words, printable, unquoted.  The word count is the answer, so the
/// caller knows whether there is a type line to skip.
private func isMyBlock(_ buffer: UnsafeBufferPointer<UInt8>) -> Int {
    var words = 1, space = 0, quot = 0
    var n = buffer.count
    if n < 10 { return 0 }
    if n > 132 { n = 132 }
    for i in 1..<n {
        switch buffer[i] {
        case 10, 13:
            return (quot == 1 || words > 2) ? 0 : words
        case 9, 32:
            if quot == 0 && space == 0 { space = 1 }
        case UInt8(ascii: "\""):
            quot = quot == 0 ? 1 : 0
        default:
            if buffer[i] < 32 { return 0 }
            if buffer[i] > 127 { return 0 }
            words += space
            space = 0
        }
    }
    return 0
}

private func isMyFile(_ fileName: UnsafePointer<CChar>) -> Int {
    guard let fp = fopen(fileName, "rt") else {
        report(cmsUInt32Number(cmsERROR_FILE), "File '\(String(cString: fileName))' not found", to: nil)
        return 0
    }
    var buffer = [UInt8](repeating: 0, count: 133)
    let size = fread(&buffer, 1, 132, fp)
    if fclose(fp) != 0 { return 0 }
    return buffer.withUnsafeBufferPointer { isMyBlock(UnsafeBufferPointer(rebasing: $0[0..<size])) }
}

// -- the API -----------------------------------------------------------------------------

@c @implementation
public func cmsIT8Alloc(_ ContextID: cmsContext?) -> cmsHANDLE? {
    let box = IT8Box(context: ContextID)
    _ = box.allocTable()
    box.setSheetType(cstr("CGATS.17"))
    for (name, mode) in predefinedProperties {
        _ = name.withCString { box.addAvailableProperty($0, mode) }
    }
    for name in predefinedSampleIDs {
        _ = name.withCString { box.addAvailableSampleID($0) }
    }
    return Unmanaged.passRetained(box).toOpaque()
}

@c @implementation
public func cmsIT8Free(_ hIT8: cmsHANDLE?) {
    guard let hIT8 else { return }
    let box = Unmanaged<IT8Box>.fromOpaque(hIT8).takeRetainedValue()
    for f in box.fileStack where f.stream != nil { fclose(f.stream) }
    // The arena is released with the box.
    _ = box
}

@c @implementation
public func cmsIT8TableCount(_ hIT8: cmsHANDLE?) -> cmsUInt32Number {
    cmsUInt32Number(it8(hIT8)?.tables.count ?? 0)
}

@c @implementation
public func cmsIT8SetTable(_ hIT8: cmsHANDLE?, _ nTable: cmsUInt32Number) -> cmsInt32Number {
    guard let box = it8(hIT8) else { return -1 }
    let n = Int(nTable)
    if n >= box.tables.count {
        if n == box.tables.count {
            if !box.allocTable() {
                box.synError("Too many tables")
                return -1
            }
        } else {
            box.synError("Table \(n) is out of sequence")
            return -1
        }
    }
    box.nTable = n
    return cmsInt32Number(n)
}

@c @implementation
public func cmsIT8GetSheetType(_ hIT8: cmsHANDLE?) -> UnsafePointer<CChar>? {
    guard let box = it8(hIT8) else { return nil }
    // Handed out as a C string that lives as long as the table does.
    let t = box.table
    return t.sheetType.withUnsafeBufferPointer { box.allocString(UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self)) }
        .map { UnsafePointer($0) }
}

@c @implementation
public func cmsIT8SetSheetType(_ hIT8: cmsHANDLE?, _ Type: UnsafePointer<CChar>?) -> cmsBool {
    guard let box = it8(hIT8), let Type else { return 0 }
    box.setSheetType(Array(UnsafeBufferPointer(start: UnsafeRawPointer(Type).assumingMemoryBound(to: UInt8.self), count: strlen(Type))))
    return 1
}

@c @implementation
public func cmsIT8SetComment(_ hIT8: cmsHANDLE?, _ Val: UnsafePointer<CChar>?) -> cmsBool {
    guard let box = it8(hIT8), let Val, Val[0] != 0 else { return 0 }
    return box.addToList(box.table.header, "# ", nil, Val, .uncooked) != nil ? 1 : 0
}

@c @implementation
public func cmsIT8SetPropertyStr(_ hIT8: cmsHANDLE?, _ Key: UnsafePointer<CChar>?, _ Val: UnsafePointer<CChar>?) -> cmsBool {
    guard let box = it8(hIT8), let Key, let Val, Val[0] != 0 else { return 0 }
    return box.addToList(box.table.header, Key, nil, Val, .stringify) != nil ? 1 : 0
}

@c @implementation
public func cmsIT8SetPropertyDbl(_ hIT8: cmsHANDLE?, _ cProp: UnsafePointer<CChar>?, _ Val: cmsFloat64Number) -> cmsBool {
    guard let box = it8(hIT8), let cProp else { return 0 }
    let text = box.formatDouble(Val) + [0]
    return text.withUnsafeBufferPointer {
        box.addToList(box.table.header, cProp, nil, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), .uncooked) != nil ? 1 : 0
    }
}

@c @implementation
public func cmsIT8SetPropertyHex(_ hIT8: cmsHANDLE?, _ cProp: UnsafePointer<CChar>?, _ Val: cmsUInt32Number) -> cmsBool {
    guard let box = it8(hIT8), let cProp else { return 0 }
    return String(Val).withCString { box.addToList(box.table.header, cProp, nil, $0, .hexadecimal) != nil ? 1 : 0 }
}

@c @implementation
public func cmsIT8SetPropertyUncooked(_ hIT8: cmsHANDLE?, _ Key: UnsafePointer<CChar>?, _ Buffer: UnsafePointer<CChar>?) -> cmsBool {
    guard let box = it8(hIT8), let Key else { return 0 }
    return box.addToList(box.table.header, Key, nil, Buffer, .uncooked) != nil ? 1 : 0
}

@c @implementation
public func cmsIT8SetPropertyMulti(
    _ hIT8: cmsHANDLE?, _ Key: UnsafePointer<CChar>?, _ SubKey: UnsafePointer<CChar>?, _ Buffer: UnsafePointer<CChar>?
) -> cmsBool {
    guard let box = it8(hIT8), let Key else { return 0 }
    return box.addToList(box.table.header, Key, SubKey, Buffer, .pair) != nil ? 1 : 0
}

@c @implementation
public func cmsIT8GetProperty(_ hIT8: cmsHANDLE?, _ Key: UnsafePointer<CChar>?) -> UnsafePointer<CChar>? {
    guard let box = it8(hIT8), let Key else { return nil }
    return box.table.header.find(Key, nil).found?.value.map { UnsafePointer($0) }
}

@c @implementation
public func cmsIT8GetPropertyDbl(_ hIT8: cmsHANDLE?, _ cProp: UnsafePointer<CChar>?) -> cmsFloat64Number {
    guard let v = cmsIT8GetProperty(hIT8, cProp) else { return 0.0 }
    return parseFloatNumber(v)
}

@c @implementation
public func cmsIT8GetPropertyMulti(
    _ hIT8: cmsHANDLE?, _ Key: UnsafePointer<CChar>?, _ SubKey: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
    guard let box = it8(hIT8), let Key else { return nil }
    return box.table.header.find(Key, SubKey).found?.value.map { UnsafePointer($0) }
}

@c @implementation
public func cmsIT8SetDataFormat(_ h: cmsHANDLE?, _ n: cmsInt32Number, _ Sample: UnsafePointer<CChar>?) -> cmsBool {
    guard let box = it8(h), let Sample else { return 0 }
    return box.setDataFormat(Int(n), Sample) ? 1 : 0
}

@c @implementation
public func cmsIT8SaveToFile(_ hIT8: cmsHANDLE?, _ cFileName: UnsafePointer<CChar>?) -> cmsBool {
    guard let box = it8(hIT8), let cFileName else { return 0 }
    let sd = SaveStream()
    guard let stream = fopen(cFileName, "wt") else { return 0 }
    sd.stream = stream

    for i in 0..<box.tables.count {
        if cmsIT8SetTable(hIT8, cmsUInt32Number(i)) < 0 {
            fclose(stream)
            return 0
        }
        let t = box.table
        if t.data == nil || t.dataFormat == nil {
            fclose(stream)
            return 0
        }
        box.writeHeader(sd)
        box.writeDataFormat(sd)
        box.writeData(sd)
    }
    if fclose(stream) != 0 { return 0 }
    return 1
}

@c @implementation
public func cmsIT8SaveToMem(_ hIT8: cmsHANDLE?, _ MemPtr: UnsafeMutableRawPointer?, _ BytesNeeded: UnsafeMutablePointer<cmsUInt32Number>?) -> cmsBool {
    guard let box = it8(hIT8), let BytesNeeded else { return 0 }
    let sd = SaveStream()
    sd.base = MemPtr?.assumingMemoryBound(to: UInt8.self)
    if sd.base != nil && BytesNeeded.pointee > 0 {
        sd.max = Int(BytesNeeded.pointee) - 1
    } else {
        sd.max = 0
    }
    for i in 0..<box.tables.count {
        _ = cmsIT8SetTable(hIT8, cmsUInt32Number(i))
        box.writeHeader(sd)
        box.writeDataFormat(sd)
        box.writeData(sd)
    }
    // The terminator, counted but written only when there is room.
    if let base = sd.base, sd.used <= sd.max { base[sd.used] = 0 }
    sd.used += 1
    BytesNeeded.pointee = cmsUInt32Number(sd.used)
    return 1
}

@c @implementation
public func cmsIT8LoadFromMem(_ ContextID: cmsContext?, _ Ptr: UnsafeRawPointer?, _ len: cmsUInt32Number) -> cmsHANDLE? {
    guard let Ptr, len != 0 else { return nil }
    let bytes = UnsafeBufferPointer(start: Ptr.assumingMemoryBound(to: UInt8.self), count: Int(len))
    let type = isMyBlock(bytes)
    if type == 0 { return nil }

    guard let handle = cmsIT8Alloc(ContextID), let box = it8(handle) else { return nil }
    // strncpy semantics: the block ends at the first NUL, or at len.
    var block = Array(bytes)
    if let nul = block.firstIndex(of: 0) { block = Array(block[0..<nul]) }
    box.memoryBlock = block
    box.sourceIndex = 0
    box.fileStack[0].fileName = [CChar](repeating: 0, count: Int(cmsMAX_PATH))

    if !box.parseIT8(noSheet: type - 1 != 0) {
        cmsIT8Free(handle)
        return nil
    }
    box.cookPointers()
    box.nTable = 0
    box.memoryBlock = []
    return handle
}

@c @implementation
public func cmsIT8LoadFromFile(_ ContextID: cmsContext?, _ cFileName: UnsafePointer<CChar>?) -> cmsHANDLE? {
    guard let cFileName else { return nil }
    let type = isMyFile(cFileName)
    if type == 0 { return nil }

    guard let handle = cmsIT8Alloc(ContextID), let box = it8(handle) else { return nil }
    guard let stream = fopen(cFileName, "rt") else {
        cmsIT8Free(handle)
        return nil
    }
    box.fileStack[0].stream = stream
    var name = Array(UnsafeBufferPointer(start: cFileName, count: min(strlen(cFileName), Int(cmsMAX_PATH) - 1)))
    while name.count < Int(cmsMAX_PATH) { name.append(0) }
    box.fileStack[0].fileName = name

    if !box.parseIT8(noSheet: type - 1 != 0) {
        fclose(stream)
        box.fileStack[0].stream = nil
        cmsIT8Free(handle)
        return nil
    }
    box.cookPointers()
    box.nTable = 0
    box.fileStack[0].stream = nil
    if fclose(stream) != 0 {
        cmsIT8Free(handle)
        return nil
    }
    return handle
}

@c @implementation
public func cmsIT8EnumDataFormat(_ hIT8: cmsHANDLE?, _ SampleNames: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>?) -> cmsInt32Number {
    guard let box = it8(hIT8) else { return 0 }
    let t = box.table
    SampleNames?.pointee = t.dataFormat
    return cmsInt32Number(t.nSamples)
}

@c @implementation
public func cmsIT8EnumProperties(_ hIT8: cmsHANDLE?, _ PropertyNames: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>?) -> cmsUInt32Number {
    guard let box = it8(hIT8) else { return 0 }
    let entries = box.table.header.entries
    let props = box.allocPointers(entries.count)
    if let props {
        for (i, p) in entries.enumerated() { props[i] = p.keyword }
    }
    PropertyNames?.pointee = props
    return cmsUInt32Number(entries.count)
}

@c @implementation
public func cmsIT8EnumPropertyMulti(
    _ hIT8: cmsHANDLE?, _ cProp: UnsafePointer<CChar>?,
    _ SubpropertyNames: UnsafeMutablePointer<UnsafeMutablePointer<UnsafePointer<CChar>?>?>?
) -> cmsUInt32Number {
    guard let box = it8(hIT8), let cProp else { return 0 }
    guard let p = box.table.header.find(cProp, nil).found else {
        SubpropertyNames?.pointee = nil
        return 0
    }
    let chain = [p] + p.subkeys
    let n = chain.filter { $0.subkey != nil }.count
    let props = box.allocPointers(n)
    if let props {
        // The reference hands out the key node's own subkey for every
        // slot — a slip it has always had, and what a caller sees.
        let out = UnsafeMutableRawPointer(props).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        for i in 0..<n { out[i] = p.subkey.map { UnsafePointer($0) } }
    }
    SubpropertyNames?.pointee = props.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: UnsafePointer<CChar>?.self) }
    return cmsUInt32Number(n)
}

extension IT8Box {
    fileprivate func locatePatch(_ patch: UnsafePointer<CChar>) -> Int {
        let t = table
        for i in 0..<t.nPatches {
            if let data = getData(i, t.sampleID), cmsstrcasecmp(data, patch) == 0 { return i }
        }
        return -1
    }

    fileprivate func locateEmptyPatch() -> Int {
        let t = table
        for i in 0..<t.nPatches where getData(i, t.sampleID) == nil { return i }
        return -1
    }

    fileprivate func locateSample(_ sample: UnsafePointer<CChar>) -> Int {
        let t = table
        for i in 0..<t.nSamples {
            if let fld = dataFormat(i), cmsstrcasecmp(fld, sample) == 0 { return i }
        }
        return -1
    }
}

@c @implementation
public func cmsIT8FindDataFormat(_ hIT8: cmsHANDLE?, _ cSample: UnsafePointer<CChar>?) -> cmsInt32Number {
    guard let box = it8(hIT8), let cSample else { return -1 }
    return cmsInt32Number(box.locateSample(cSample))
}

@c @implementation
public func cmsIT8GetDataRowCol(_ hIT8: cmsHANDLE?, _ row: cmsInt32Number, _ col: cmsInt32Number) -> UnsafePointer<CChar>? {
    guard let box = it8(hIT8) else { return nil }
    return box.getData(Int(row), Int(col)).map { UnsafePointer($0) }
}

@c @implementation
public func cmsIT8GetDataRowColDbl(_ hIT8: cmsHANDLE?, _ row: cmsInt32Number, _ col: cmsInt32Number) -> cmsFloat64Number {
    guard let buffer = cmsIT8GetDataRowCol(hIT8, row, col) else { return 0.0 }
    return parseFloatNumber(buffer)
}

@c @implementation
public func cmsIT8SetDataRowCol(_ hIT8: cmsHANDLE?, _ row: cmsInt32Number, _ col: cmsInt32Number, _ Val: UnsafePointer<CChar>?) -> cmsBool {
    guard let box = it8(hIT8), let Val else { return 0 }
    return box.setData(Int(row), Int(col), Val) ? 1 : 0
}

@c @implementation
public func cmsIT8SetDataRowColDbl(_ hIT8: cmsHANDLE?, _ row: cmsInt32Number, _ col: cmsInt32Number, _ Val: cmsFloat64Number) -> cmsBool {
    guard let box = it8(hIT8) else { return 0 }
    let text = Array(box.formatDouble(Val).prefix(255)) + [0]
    return text.withUnsafeBufferPointer {
        box.setData(Int(row), Int(col), UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self)) ? 1 : 0
    }
}

@c @implementation
public func cmsIT8GetData(_ hIT8: cmsHANDLE?, _ cPatch: UnsafePointer<CChar>?, _ cSample: UnsafePointer<CChar>?) -> UnsafePointer<CChar>? {
    guard let box = it8(hIT8), let cPatch, let cSample else { return nil }
    let iField = box.locateSample(cSample)
    if iField < 0 { return nil }
    let iSet = box.locatePatch(cPatch)
    if iSet < 0 { return nil }
    return box.getData(iSet, iField).map { UnsafePointer($0) }
}

@c @implementation
public func cmsIT8GetDataDbl(_ it8: cmsHANDLE?, _ cPatch: UnsafePointer<CChar>?, _ cSample: UnsafePointer<CChar>?) -> cmsFloat64Number {
    parseFloatNumber(cmsIT8GetData(it8, cPatch, cSample))
}

@c @implementation
public func cmsIT8SetData(_ hIT8: cmsHANDLE?, _ cPatch: UnsafePointer<CChar>?, _ cSample: UnsafePointer<CChar>?, _ Val: UnsafePointer<CChar>?) -> cmsBool {
    guard let box = it8(hIT8), let cPatch, let cSample, let Val else { return 0 }
    let t = box.table
    var iField = box.locateSample(cSample)
    if iField < 0 { return 0 }

    if t.nPatches == 0 {
        if !box.allocateDataFormat() { return 0 }
        if !box.allocateDataSet() { return 0 }
        box.cookPointers()
    }

    let iSet: Int
    if cmsstrcasecmp(cSample, "SAMPLE_ID") == 0 {
        iSet = box.locateEmptyPatch()
        if iSet < 0 {
            return box.synError("Couldn't add more patches '\(String(cString: cPatch))'\n") ? 1 : 0
        }
        iField = t.sampleID
    } else {
        iSet = box.locatePatch(cPatch)
        if iSet < 0 { return 0 }
    }
    return box.setData(iSet, iField, Val) ? 1 : 0
}

@c @implementation
public func cmsIT8SetDataDbl(_ hIT8: cmsHANDLE?, _ cPatch: UnsafePointer<CChar>?, _ cSample: UnsafePointer<CChar>?, _ Val: cmsFloat64Number) -> cmsBool {
    guard let box = it8(hIT8) else { return 0 }
    let text = Array(box.formatDouble(Val).prefix(255)) + [0]
    return text.withUnsafeBufferPointer {
        cmsIT8SetData(hIT8, cPatch, cSample, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self))
    }
}

@c @implementation
public func cmsIT8GetPatchName(_ hIT8: cmsHANDLE?, _ nPatch: cmsInt32Number, _ buffer: UnsafeMutablePointer<CChar>?) -> UnsafePointer<CChar>? {
    guard let box = it8(hIT8) else { return nil }
    guard let data = box.getData(Int(nPatch), box.table.sampleID) else { return nil }
    guard let buffer else { return UnsafePointer(data) }
    strncpy(buffer, data, maxStr - 1)
    buffer[maxStr - 1] = 0
    return UnsafePointer(buffer)
}

@c @implementation
public func cmsIT8GetPatchByName(_ hIT8: cmsHANDLE?, _ cPatch: UnsafePointer<CChar>?) -> cmsInt32Number {
    guard let box = it8(hIT8), let cPatch else { return -1 }
    return cmsInt32Number(box.locatePatch(cPatch))
}

@c @implementation
public func cmsIT8SetTableByLabel(
    _ hIT8: cmsHANDLE?, _ cSet: UnsafePointer<CChar>?, _ cField: UnsafePointer<CChar>?, _ ExpectedType: UnsafePointer<CChar>?
) -> cmsInt32Number {
    var field = cField
    if let f = field, f[0] == 0 { field = nil }
    let fieldName = field.map { String(cString: $0) } ?? "LABEL"
    guard let labelFld = fieldName.withCString({ cmsIT8GetData(hIT8, cSet, $0) }) else { return -1 }

    // "%255s %u %255s": three whitespace-separated words, the middle a number.
    let parts = String(cString: labelFld).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
    guard parts.count >= 3, let nTable = UInt32(parts[1]) else { return -1 }
    let type = String(parts[2].prefix(255))

    if let ExpectedType, ExpectedType[0] != 0 {
        if type.withCString({ cmsstrcasecmp($0, ExpectedType) }) != 0 { return -1 }
    }
    return cmsIT8SetTable(hIT8, nTable)
}

@c @implementation
public func cmsIT8SetIndexColumn(_ hIT8: cmsHANDLE?, _ cSample: UnsafePointer<CChar>?) -> cmsBool {
    guard let box = it8(hIT8), let cSample else { return 0 }
    let pos = box.locateSample(cSample)
    if pos == -1 { return 0 }
    box.tables[box.nTable].sampleID = pos
    return 1
}

@c @implementation
public func cmsIT8DefineDblFormat(_ hIT8: cmsHANDLE?, _ Formatter: UnsafePointer<CChar>?) {
    guard let box = it8(hIT8) else { return }
    if let Formatter {
        var f = Array(UnsafeBufferPointer(start: Formatter, count: min(strlen(Formatter), maxID - 1)))
        f.append(0)
        box.doubleFormatter = f
    } else {
        box.doubleFormatter = Array(defaultDoubleFormat.utf8CString)
    }
}

// -- .cube files ----------------------------------------------------------------------

extension IT8Box {
    /// `n` numbers on the current line, then the end of it.
    fileprivate func readNumbers(_ n: Int, into arr: inout [Double]) -> Bool {
        for i in 0..<n {
            if sy == .inum {
                arr[i] = Double(inum)
            } else if sy == .dnum {
                arr[i] = dnum
            } else {
                return synError("Number expected")
            }
            inSymbol()
        }
        return checkEOLN()
    }

    /// The Adobe .cube grammar: a title, domain bounds, an optional 1-D
    /// shaper table and a 3-D table, with the numbers normalised into the
    /// domain.  The 3-D table is stored blue-fastest and lands in the CLUT
    /// with the channels reversed, as the reference does it.
    fileprivate func parseCube(
        shaper: inout UnsafeMutablePointer<cmsStage>?, clut: inout UnsafeMutablePointer<cmsStage>?, title: inout [UInt8]
    ) -> Bool {
        var domainMin = [0.0, 0.0, 0.0]
        var domainMax = [1.0, 1.0, 1.0]
        var check01 = [0.0, 1.0]
        var shaperSize = 0
        var lutSize = 0

        inSymbol()
        while sy != .eof && sy != .synError {
            switch sy {
            case .title:
                inSymbol()
                if !check(.string, "Title string expected") { return false }
                title = Array(str.prefix(maxStr - 1))
                inSymbol()
            case .domainMin:
                inSymbol()
                if !readNumbers(3, into: &domainMin) { return false }
            case .domainMax:
                inSymbol()
                if !readNumbers(3, into: &domainMax) { return false }
            case .lut1DSize:
                inSymbol()
                if !check(.inum, "Shaper size expected") { return false }
                shaperSize = Int(inum)
                if shaperSize < 2 || shaperSize > 65536 {
                    return synError("LUT_1D_SIZE '\(shaperSize)' is out of bounds")
                }
                inSymbol()
            case .lut3DSize:
                inSymbol()
                if !check(.inum, "LUT size expected") { return false }
                lutSize = Int(inum)
                inSymbol()
            case .lut1DInputRange, .lut3DInputRange:
                inSymbol()
                if !readNumbers(2, into: &check01) { return false }
                if check01[0] != 0 || check01[1] != 1.0 {
                    return synError("Unsupported format")
                }
            case .eoln:
                inSymbol()
            case .inum, .dnum:
                if shaperSize > 0 {
                    var shapers = [cmsFloat32Number](repeating: 0, count: 3 * shaperSize)
                    var nums = [0.0, 0.0, 0.0]
                    for i in 0..<shaperSize {
                        if !readNumbers(3, into: &nums) { return false }
                        shapers[i] = cmsFloat32Number((nums[0] - domainMin[0]) / (domainMax[0] - domainMin[0]))
                        shapers[i + shaperSize] = cmsFloat32Number((nums[1] - domainMin[1]) / (domainMax[1] - domainMin[1]))
                        shapers[i + 2 * shaperSize] = cmsFloat32Number((nums[2] - domainMin[2]) / (domainMax[2] - domainMin[2]))
                    }
                    var curves: [UnsafeMutablePointer<cmsToneCurve>?] = [nil, nil, nil]
                    for i in 0..<3 {
                        curves[i] = shapers.withUnsafeBufferPointer {
                            cmsBuildTabulatedToneCurveFloat(context, cmsUInt32Number(shaperSize), $0.baseAddress! + i * shaperSize)
                        }
                        if curves[i] == nil { return false }
                    }
                    shaper = cmsStageAllocToneCurves(context, 3, &curves)
                    for c in curves { cmsFreeToneCurve(c) }
                }
                if lutSize > 0 {
                    // 65 is the largest the usual authoring tools produce.
                    if lutSize < 2 || lutSize > 65 {
                        return synError("LUT size '\(lutSize)' is not allowed")
                    }
                    let nodes = lutSize * lutSize * lutSize
                    var table = [cmsFloat32Number](repeating: 0, count: nodes * 3)
                    var nums = [0.0, 0.0, 0.0]
                    for i in 0..<nodes {
                        if !readNumbers(3, into: &nums) { return false }
                        table[i * 3 + 2] = cmsFloat32Number((nums[0] - domainMin[0]) / (domainMax[0] - domainMin[0]))
                        table[i * 3 + 1] = cmsFloat32Number((nums[1] - domainMin[1]) / (domainMax[1] - domainMin[1]))
                        table[i * 3 + 0] = cmsFloat32Number((nums[2] - domainMin[2]) / (domainMax[2] - domainMin[2]))
                    }
                    clut = cmsStageAllocCLutFloat(context, cmsUInt32Number(lutSize), 3, 3, &table)
                }
                if !check(.eof, "Extra symbols found in file") { return false }
            default:
                // Including the video-range keywords, which are not supported.
                return synError("Unsupported format")
            }
        }
        return true
    }
}

/// A devicelink built from a .cube file: RGB to RGB, with the file's
/// title as its description.
@c @implementation
public func cmsCreateDeviceLinkFromCubeFileTHR(_ ContextID: cmsContext?, _ cFileName: UnsafePointer<CChar>?) -> cmsHPROFILE? {
    guard let cFileName, let handle = cmsIT8Alloc(ContextID), let cube = it8(handle) else { return nil }
    defer { cmsIT8Free(handle) }
    cube.isCube = true

    guard let stream = fopen(cFileName, "rt") else { return nil }
    cube.fileStack[0].stream = stream
    var name = Array(UnsafeBufferPointer(start: cFileName, count: min(strlen(cFileName), Int(cmsMAX_PATH) - 1)))
    while name.count < Int(cmsMAX_PATH) { name.append(0) }
    cube.fileStack[0].fileName = name

    var shaper: UnsafeMutablePointer<cmsStage>?
    var clut: UnsafeMutablePointer<cmsStage>?
    var title: [UInt8] = []
    let parsed = cube.parseCube(shaper: &shaper, clut: &clut, title: &title)
    // The stream is the parser's; a failure part way leaves the stages
    // for the release below.
    guard parsed else {
        if let s = shaper { cmsStageFree(s) }
        if let c = clut { cmsStageFree(c) }
        return nil
    }

    guard let hProfile = cmsCreateProfilePlaceholder(ContextID) else {
        if let s = shaper { cmsStageFree(s) }
        if let c = clut { cmsStageFree(c) }
        return nil
    }
    cmsSetProfileVersion(hProfile, 4.4)
    cmsSetDeviceClass(hProfile, cmsSigLinkClass)
    cmsSetColorSpace(hProfile, cmsSigRgbData)
    cmsSetPCS(hProfile, cmsSigRgbData)
    cmsSetHeaderRenderingIntent(hProfile, cmsUInt32Number(INTENT_PERCEPTUAL))

    guard let pipeline = cmsPipelineAlloc(ContextID, 3, 3) else {
        if let s = shaper { cmsStageFree(s) }
        if let c = clut { cmsStageFree(c) }
        return hProfile
    }
    defer { cmsPipelineFree(pipeline) }
    if let s = shaper, cmsPipelineInsertStage(pipeline, cmsAT_BEGIN, s) == 0 {
        if let c = clut { cmsStageFree(c) }
        return hProfile
    }
    if let c = clut, cmsPipelineInsertStage(pipeline, cmsAT_END, c) == 0 {
        return hProfile
    }

    guard let description = cmsMLUalloc(ContextID, 1) else { return hProfile }
    defer { cmsMLUfree(description) }
    let titleC = title + [0]
    let ok = titleC.withUnsafeBufferPointer {
        cmsMLUsetUTF8(description, cmsNoLanguage, cmsNoCountry, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self)) != 0
    }
    if !ok { return hProfile }
    if cmsWriteTag(hProfile, cmsSigProfileDescriptionTag, description) == 0 { return hProfile }
    _ = cmsWriteTag(hProfile, cmsSigAToB0Tag, pipeline)
    return hProfile
}

@c @implementation
public func cmsCreateDeviceLinkFromCubeFile(_ cFileName: UnsafePointer<CChar>?) -> cmsHPROFILE? {
    cmsCreateDeviceLinkFromCubeFileTHR(nil, cFileName)
}
