import Foundation

// A synthesizable subset of Verilog, turned into a word-level `Netlist`.
//
// Supported: several modules with instances, buses up to 64 bits, wire / reg / memories,
// parameters, assign, always @(posedge clk), always @(*), if / else / case, the usual
// operators, bit and part selects, concatenation, and the gate primitives.

enum Verilog {
    static func synthesize(_ source: String) -> Result<Netlist, VerilogError> {
        do {
            var parser = Parser(tokens: try tokenize(source))
            let modules = try parser.parseFile()
            return .success(try Elaborator(modules).run())
        } catch let e as VerilogError {
            return .failure(e)
        } catch {
            return .failure(VerilogError(message: "Something went wrong reading this code.", line: 1))
        }
    }
}

// MARK: - Tokens

private enum Tok: Equatable {
    case ident(String)
    case number(UInt64, Int?)     // value, declared width
    case sym(String)
    case eof

    var text: String {
        switch self {
        case .ident(let s): return s
        case .number(let v, _): return String(v)
        case .sym(let s): return s
        case .eof: return "end of file"
        }
    }
}

private struct Token {
    let tok: Tok
    let line: Int
}

private func tokenize(_ source: String) throws -> [Token] {
    let chars = Array(source)
    var tokens: [Token] = []
    var i = 0
    var line = 1

    func isIdentStart(_ c: Character) -> Bool { c == "_" || c == "$" || (c.isASCII && c.isLetter) }
    func isIdentBody(_ c: Character) -> Bool { c == "_" || c == "$" || (c.isASCII && (c.isLetter || c.isNumber)) }
    func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    while i < chars.count {
        let c = chars[i]
        if c == "\n" { line += 1; i += 1; continue }
        if c.isWhitespace { i += 1; continue }

        // Compiler directives such as `default_nettype and `timescale don't affect the hardware.
        if c == "`" {
            while i < chars.count, chars[i] != "\n" { i += 1 }
            continue
        }
        if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
            while i < chars.count, chars[i] != "\n" { i += 1 }
            continue
        }
        if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
            let start = line
            i += 2
            var closed = false
            while i < chars.count {
                if chars[i] == "\n" { line += 1 }
                if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" { i += 2; closed = true; break }
                i += 1
            }
            if !closed { throw VerilogError(message: "This /* comment is never closed with */.", line: start) }
            continue
        }
        if c == "\"" {
            throw VerilogError(message: "Text strings only exist in simulation, not on a chip.", line: line)
        }

        if isIdentStart(c) {
            var s = ""
            while i < chars.count, isIdentBody(chars[i]) { s.append(chars[i]); i += 1 }
            tokens.append(Token(tok: .ident(s), line: line))
            continue
        }

        if isDigit(c) || (c == "'" && i + 1 < chars.count && "bBoOdDhHsS".contains(chars[i + 1])) {
            var size = ""
            while i < chars.count, isDigit(chars[i]) || chars[i] == "_" {
                if chars[i] != "_" { size.append(chars[i]) }
                i += 1
            }
            guard i < chars.count, chars[i] == "'" else {
                guard let value = UInt64(size) else {
                    throw VerilogError(message: "That number is too big. Values go up to 64 bits.", line: line)
                }
                tokens.append(Token(tok: .number(value, nil), line: line))
                continue
            }
            i += 1
            if i < chars.count, "sS".contains(chars[i]) { i += 1 }
            guard i < chars.count, let radix = ["b": 2, "o": 8, "d": 10, "h": 16][String(chars[i]).lowercased()] else {
                throw VerilogError(message: "A sized number looks like 8'hFF, 4'b1010 or 3'd5.", line: line)
            }
            i += 1
            while i < chars.count, chars[i] == " " { i += 1 }
            var digits = ""
            while i < chars.count, isIdentBody(chars[i]) || chars[i] == "?" {
                let d = chars[i]
                if d != "_" { digits.append("xXzZ?".contains(d) ? "0" : d) }
                i += 1
            }
            guard let value = UInt64(digits, radix: radix) else {
                throw VerilogError(message: "‘\(digits)’ isn't a valid base-\(radix) number.", line: line)
            }
            var width: Int? = nil
            if !size.isEmpty {
                guard let w = Int(size), w >= 1, w <= 64 else {
                    throw VerilogError(message: "Numbers can be 1 to 64 bits wide.", line: line)
                }
                width = w
            }
            tokens.append(Token(tok: .number(width.map { value & mask($0) } ?? value, width), line: line))
            continue
        }

        if i + 2 < chars.count {
            let three = String(chars[i...i + 2])
            if let mapped = ["<<<": "<<", ">>>": ">>", "===": "==", "!==": "!="][three] {
                tokens.append(Token(tok: .sym(mapped), line: line))
                i += 3
                continue
            }
        }
        if i + 1 < chars.count {
            let two = String([c, chars[i + 1]])
            if ["<=", ">=", "==", "!=", "&&", "||", "<<", ">>", "~^", "^~", "~&", "~|"].contains(two) {
                tokens.append(Token(tok: .sym(two == "^~" ? "~^" : two), line: line))
                i += 2
                continue
            }
        }
        if "()[]{},;=~!&|^?:.#@+-*/%<>".contains(c) {
            tokens.append(Token(tok: .sym(String(c)), line: line))
            i += 1
            continue
        }
        throw VerilogError(message: "‘\(c)’ isn't something Verilog understands.", line: line)
    }
    tokens.append(Token(tok: .eof, line: line))
    return tokens
}

// MARK: - Syntax tree

private indirect enum Expr {
    case ref(String, Int)
    case num(UInt64, Int?)
    case unary(String, Expr, Int)
    case binary(String, Expr, Expr, Int)
    case ternary(Expr, Expr, Expr, Int)
    case index(String, Expr, Int)            // name[i]: one bit, or one word of a memory
    case range(String, Expr, Expr, Int)      // name[hi:lo]
    case concat([Expr], Int)
    case replicate(Expr, Expr, Int)
}

private enum LValue {
    case whole(String)
    case bit(String, Expr)
    case part(String, Expr, Expr)

    var name: String {
        switch self {
        case .whole(let n), .bit(let n, _), .part(let n, _, _): return n
        }
    }
}

private indirect enum Stmt {
    case empty
    case block([Stmt])
    case assign(LValue, Expr, Bool, Int)                 // target, value, blocking, line
    case ifElse(Expr, Stmt, Stmt?)
    case caseOf(Expr, [([Expr], Stmt)], Stmt?, Int)

    var targets: [String] {
        switch self {
        case .empty: return []
        case .block(let list): return list.flatMap { $0.targets }
        case .assign(let lv, _, _, _): return [lv.name]
        case .ifElse(_, let a, let b): return a.targets + (b?.targets ?? [])
        case .caseOf(_, let items, let fallback, _): return items.flatMap { $0.1.targets } + (fallback?.targets ?? [])
        }
    }
}

private enum Direction { case input, output, none }

private struct Decl {
    var dir: Direction
    var isReg: Bool
    var range: (Expr, Expr)?
    var memory: (Expr, Expr)?
    var line: Int
}

private struct Always {
    let clock: String?        // nil for a combinational block
    let body: Stmt
    let line: Int
}

private struct Instance {
    let module: String
    let name: String
    let named: [(String, Expr?)]
    let positional: [Expr]
    let line: Int
}

private struct ModuleAST {
    let name: String
    let line: Int
    var ports: [String] = []
    var decls: [String: Decl] = [:]
    var order: [String] = []
    var assigns: [(LValue, Expr, Int)] = []
    var always: [Always] = []
    var instances: [Instance] = []
    var params: [(String, Expr)] = []

    mutating func declare(_ name: String, _ decl: Decl) throws {
        if var existing = decls[name] {
            // `output x;` followed by `reg [7:0] x;` describes one signal.
            guard existing.dir != .none, decl.dir == .none, !existing.isReg || !decl.isReg else {
                throw VerilogError(message: "‘\(name)’ is declared twice.", line: decl.line)
            }
            existing.isReg = existing.isReg || decl.isReg
            if existing.range == nil { existing.range = decl.range }
            decls[name] = existing
        } else {
            decls[name] = decl
            order.append(name)
        }
    }
}

private let primitives: [String: String] = [
    "and": "&", "or": "|", "xor": "^", "nand": "&", "nor": "|", "xnor": "^", "not": "~", "buf": "",
]

private let reserved: Set<String> = [
    "module", "endmodule", "input", "output", "inout", "wire", "reg", "logic", "assign", "always", "always_ff",
    "always_comb", "always_latch", "initial", "begin", "end", "if", "else", "case", "casez", "casex", "endcase",
    "default", "posedge", "negedge", "parameter", "localparam", "integer", "genvar", "generate", "endgenerate",
    "function", "endfunction", "task", "endtask", "for", "while", "repeat", "signed", "or",
]

// MARK: - Parser

private struct Parser {
    let tokens: [Token]
    var pos = 0

    init(tokens: [Token]) { self.tokens = tokens }

    var peek: Token { tokens[pos] }
    var previousLine: Int { pos > 0 ? tokens[pos - 1].line : peek.line }

    @discardableResult
    mutating func advance() -> Token {
        let t = tokens[pos]
        if pos < tokens.count - 1 { pos += 1 }
        return t
    }

    func fail(_ message: String, _ line: Int? = nil) -> VerilogError {
        VerilogError(message: message, line: line ?? peek.line)
    }

    mutating func accept(_ s: String) -> Bool {
        if peek.tok == .sym(s) { advance(); return true }
        return false
    }

    mutating func acceptWord(_ s: String) -> Bool {
        if peek.tok == .ident(s) { advance(); return true }
        return false
    }

    mutating func expect(_ s: String) throws {
        if accept(s) { return }
        if s == ";" { throw fail("Missing ‘;’ at the end of this line.", previousLine) }
        throw fail("Expected ‘\(s)’ but found ‘\(peek.tok.text)’.")
    }

    mutating func name(_ what: String) throws -> String {
        if case .ident(let s) = peek.tok, !reserved.contains(s) {
            if s.hasPrefix("$") { throw fail("‘\(s)’ only exists in simulation, not on a chip.") }
            advance()
            return s
        }
        throw fail("Expected \(what) but found ‘\(peek.tok.text)’.")
    }

    mutating func range() throws -> (Expr, Expr) {
        try expect("[")
        let hi = try expression()
        guard accept(":") else { throw fail("A bus range looks like [7:0].") }
        let lo = try expression()
        try expect("]")
        return (hi, lo)
    }

    mutating func parseFile() throws -> [ModuleAST] {
        var modules: [ModuleAST] = []
        while peek.tok != .eof { modules.append(try parseModule()) }
        if modules.isEmpty { throw fail("A chip starts with the keyword ‘module’.") }
        return modules
    }

    // MARK: Module

    mutating func parseModule() throws -> ModuleAST {
        let start = peek.line
        guard acceptWord("module") else { throw fail("A chip starts with the keyword ‘module’.") }
        var m = ModuleAST(name: try name("a module name"), line: start)

        if accept("#") {
            try expect("(")
            repeat {
                _ = acceptWord("parameter")
                if peek.tok == .sym("[") { _ = try range() }
                let n = try name("a parameter name")
                try expect("=")
                m.params.append((n, try expression()))
            } while accept(",")
            try expect(")")
        }

        if accept("("), !accept(")") {
            var dir = Direction.none
            var isReg = false
            var bus: (Expr, Expr)? = nil
            repeat {
                if case .ident(let k) = peek.tok, ["input", "output", "inout"].contains(k) {
                    if k == "inout" { throw fail("‘inout’ pins aren't supported. Use a separate input and output.") }
                    advance()
                    dir = k == "input" ? .input : .output
                    isReg = false
                    bus = nil
                    if !acceptWord("wire"), acceptWord("reg") || acceptWord("logic") { isReg = true }
                    if acceptWord("signed") { throw fail("Signed numbers aren't supported yet. Everything is unsigned.") }
                    if peek.tok == .sym("[") { bus = try range() }
                }
                let line = peek.line
                let port = try name("a port name")
                m.ports.append(port)
                if dir != .none {
                    try m.declare(port, Decl(dir: dir, isReg: isReg, range: bus, memory: nil, line: line))
                }
            } while accept(",")
            try expect(")")
        }
        try expect(";")

        body: while true {
            let t = peek
            guard case .ident(let word) = t.tok else {
                if t.tok == .eof { throw fail("The module is never closed. Add ‘endmodule’ at the bottom.", t.line) }
                throw fail("‘\(t.tok.text)’ doesn't belong here. Try a wire, an assign, or an always block.", t.line)
            }
            switch word {
            case "endmodule":
                advance()
                break body
            case "input", "output", "wire", "reg", "logic":
                advance()
                var dir = Direction.none
                var isReg = word == "reg" || word == "logic"
                if word == "input" { dir = .input }
                if word == "output" { dir = .output }
                if dir != .none, !acceptWord("wire"), acceptWord("reg") || acceptWord("logic") { isReg = true }
                if acceptWord("signed") { throw fail("Signed numbers aren't supported yet. Everything is unsigned.") }
                let bus = peek.tok == .sym("[") ? try range() : nil
                repeat {
                    let line = peek.line
                    let n = try name("a signal name")
                    let memory = peek.tok == .sym("[") ? try range() : nil
                    if memory != nil, !isReg || dir != .none {
                        throw fail("A memory is declared like: reg [7:0] ram [15:0];", line)
                    }
                    try m.declare(n, Decl(dir: dir, isReg: isReg, range: bus, memory: memory, line: line))
                    if accept("=") {
                        let value = try expression()
                        // A reg's "= 0" is only a simulation start value; registers here always start at 0.
                        if !isReg { m.assigns.append((.whole(n), value, line)) }
                    }
                } while accept(",")
                try expect(";")
            case "assign":
                advance()
                repeat {
                    let line = peek.line
                    let target = try lvalue()
                    guard accept("=") else { throw fail("An assign needs ‘=’, like: assign y = a & b;") }
                    m.assigns.append((target, try expression(), line))
                } while accept(",")
                try expect(";")
            case "parameter", "localparam":
                advance()
                if peek.tok == .sym("[") { _ = try range() }
                repeat {
                    let n = try name("a parameter name")
                    try expect("=")
                    m.params.append((n, try expression()))
                } while accept(",")
                try expect(";")
            case "always", "always_ff", "always_comb":
                m.always.append(try always())
            case "initial":
                throw fail("‘initial’ blocks only exist in simulation. Registers here start at 0; use a reset to set them.", t.line)
            case "always_latch", "integer", "genvar", "generate", "function", "task", "for", "inout":
                throw fail("‘\(word)’ isn't supported in this app yet.", t.line)
            default:
                if let op = primitives[word] {
                    advance()
                    try gate(word, op, line: t.line, into: &m)
                } else if !reserved.contains(word), pos + 1 < tokens.count,
                          { if case .ident(let n) = tokens[pos + 1].tok { return !reserved.contains(n) }; return tokens[pos + 1].tok == .sym("#") }() {
                    m.instances.append(try instance())
                } else {
                    throw fail("‘\(word)’ doesn't belong here. Try a wire, an assign, or an always block.", t.line)
                }
            }
        }
        return m
    }

    mutating func gate(_ keyword: String, _ op: String, line: Int, into m: inout ModuleAST) throws {
        if case .ident(let s) = peek.tok, !reserved.contains(s) { advance() }   // optional instance name
        try expect("(")
        let outLine = peek.line
        let out = try lvalue()
        var ins: [Expr] = []
        while accept(",") { ins.append(try expression()) }
        try expect(")")
        try expect(";")

        let value: Expr
        if keyword == "not" || keyword == "buf" {
            guard ins.count == 1 else { throw fail("‘\(keyword)’ takes one output and one input: \(keyword)(y, a);", line) }
            value = keyword == "not" ? .unary("~", ins[0], line) : ins[0]
        } else {
            guard ins.count >= 2 else {
                throw fail("‘\(keyword)’ needs an output and at least two inputs: \(keyword)(y, a, b);", line)
            }
            let folded = ins.dropFirst().reduce(ins[0]) { .binary(op, $0, $1, line) }
            if ins.count == 2, keyword == "xnor" {
                value = .binary("~^", ins[0], ins[1], line)
            } else if ins.count == 2, keyword == "nand" || keyword == "nor" {
                value = .binary(keyword == "nand" ? "~&" : "~|", ins[0], ins[1], line)
            } else {
                value = ["nand", "nor", "xnor"].contains(keyword) ? .unary("~", folded, line) : folded
            }
        }
        m.assigns.append((out, value, outLine))
    }

    mutating func instance() throws -> Instance {
        let line = peek.line
        let module = advance().tok.text
        if accept("#") { throw fail("Parameter overrides on an instance aren't supported yet.") }
        let inst = try name("a name for this instance")
        try expect("(")
        var named: [(String, Expr?)] = []
        var positional: [Expr] = []
        if !accept(")") {
            if peek.tok == .sym(".") {
                repeat {
                    try expect(".")
                    let port = try name("a port name")
                    try expect("(")
                    let value: Expr? = peek.tok == .sym(")") ? nil : try expression()
                    try expect(")")
                    named.append((port, value))
                } while accept(",")
            } else {
                repeat { positional.append(try expression()) } while accept(",")
            }
            try expect(")")
        }
        try expect(";")
        return Instance(module: module, name: inst, named: named, positional: positional, line: line)
    }

    mutating func always() throws -> Always {
        let line = peek.line
        let keyword = advance().tok.text
        var clock: String? = nil
        if keyword != "always_comb" {
            guard accept("@") else { throw fail("‘always’ needs a trigger, like @(posedge clk) or @(*).") }
            if !accept("*") {
                try expect("(")
                if !accept("*") {
                    repeat {
                        if acceptWord("posedge") || acceptWord("negedge") {
                            let n = try name("a clock name")
                            if clock == nil { clock = n }
                        } else {
                            _ = try name("a signal name")
                        }
                    } while accept(",") || acceptWord("or")
                }
                try expect(")")
            }
        }
        return Always(clock: clock, body: try statement(), line: line)
    }

    // MARK: Statements

    mutating func statement() throws -> Stmt {
        let t = peek
        if accept(";") { return .empty }
        guard case .ident(let word) = t.tok else {
            throw fail("Expected a statement but found ‘\(t.tok.text)’.")
        }
        switch word {
        case "begin":
            advance()
            if accept(":") { _ = try name("a block label") }
            var list: [Stmt] = []
            while peek.tok != .ident("end") {
                if peek.tok == .eof || peek.tok == .ident("endmodule") {
                    throw fail("This ‘begin’ has no matching ‘end’.", t.line)
                }
                list.append(try statement())
            }
            advance()
            return .block(list)
        case "if":
            advance()
            try expect("(")
            let condition = try expression()
            try expect(")")
            let then = try statement()
            let otherwise: Stmt? = acceptWord("else") ? try statement() : nil
            return .ifElse(condition, then, otherwise)
        case "case", "casez", "casex":
            advance()
            try expect("(")
            let subject = try expression()
            try expect(")")
            var items: [([Expr], Stmt)] = []
            var fallback: Stmt? = nil
            while !acceptWord("endcase") {
                if peek.tok == .eof || peek.tok == .ident("endmodule") {
                    throw fail("This ‘case’ has no matching ‘endcase’.", t.line)
                }
                if acceptWord("default") {
                    _ = accept(":")
                    fallback = try statement()
                } else {
                    var values = [try expression()]
                    while accept(",") { values.append(try expression()) }
                    guard accept(":") else { throw fail("Each case needs a ‘:’ after its value, like 2'b01: …") }
                    items.append((values, try statement()))
                }
            }
            return .caseOf(subject, items, fallback, t.line)
        case "for", "while", "repeat", "forever":
            throw fail("Loops aren't supported in this app yet.")
        default:
            let target = try lvalue()
            let blocking: Bool
            if accept("<=") {
                blocking = false
            } else if accept("=") {
                blocking = true
            } else {
                throw fail("Expected ‘<=’ or ‘=’ after ‘\(target.name)’.")
            }
            let value = try expression()
            try expect(";")
            return .assign(target, value, blocking, t.line)
        }
    }

    mutating func lvalue() throws -> LValue {
        if peek.tok == .sym("{") { throw fail("Assigning to a {concatenation} isn't supported yet. Assign each part separately.") }
        let n = try name("the signal to assign")
        if accept("[") {
            let a = try expression()
            if accept(":") {
                let b = try expression()
                try expect("]")
                return .part(n, a, b)
            }
            try expect("]")
            return .bit(n, a)
        }
        return .whole(n)
    }

    // MARK: Expressions (lowest precedence first)

    private static let levels: [Set<String>] = [
        ["||"], ["&&"], ["|"], ["^", "~^"], ["&"], ["==", "!="], ["<", "<=", ">", ">="], ["<<", ">>"],
        ["+", "-"], ["*", "/", "%"],
    ]

    mutating func expression() throws -> Expr {
        let condition = try binary(0)
        if peek.tok == .sym("?") {
            let line = advance().line
            let a = try expression()
            guard accept(":") else { throw fail("A ‘?’ needs a matching ‘:’, like: sel ? b : a") }
            return .ternary(condition, a, try expression(), line)
        }
        return condition
    }

    mutating func binary(_ level: Int) throws -> Expr {
        guard level < Parser.levels.count else { return try unary() }
        var lhs = try binary(level + 1)
        while case .sym(let s) = peek.tok, Parser.levels[level].contains(s) {
            let line = advance().line
            lhs = .binary(s, lhs, try binary(level + 1), line)
        }
        return lhs
    }

    mutating func unary() throws -> Expr {
        if case .sym(let s) = peek.tok, ["~", "!", "-", "+", "&", "|", "^", "~&", "~|", "~^"].contains(s) {
            let line = advance().line
            return .unary(s, try unary(), line)
        }
        let t = peek
        switch t.tok {
        case .number(let value, let width):
            advance()
            return .num(value, width)
        case .ident(let s) where !reserved.contains(s):
            if s.hasPrefix("$") { throw fail("‘\(s)’ only exists in simulation, not on a chip.") }
            advance()
            if accept("[") {
                let a = try expression()
                if accept(":") {
                    let b = try expression()
                    try expect("]")
                    return .range(s, a, b, t.line)
                }
                try expect("]")
                return .index(s, a, t.line)
            }
            return .ref(s, t.line)
        case .sym("("):
            advance()
            let e = try expression()
            try expect(")")
            return e
        case .sym("{"):
            advance()
            let first = try expression()
            if accept("{") {
                var inner = [try expression()]
                while accept(",") { inner.append(try expression()) }
                try expect("}")
                try expect("}")
                return .replicate(first, .concat(inner, t.line), t.line)
            }
            var items = [first]
            while accept(",") { items.append(try expression()) }
            try expect("}")
            return .concat(items, t.line)
        case .sym(";"), .eof:
            throw fail("This expression is unfinished.", previousLine)
        default:
            throw fail("Expected a signal name or a number but found ‘\(t.tok.text)’.", t.line)
        }
    }
}

// MARK: - Elaboration (syntax tree -> netlist)

private struct Val {
    let sig: Signal
    let width: Int
}

/// One instance of a module. Instances are flattened into a single netlist.
private final class Scope {
    let ast: ModuleAST
    let parent: Scope?
    let depth: Int
    var params: [String: UInt64] = [:]
    var widths: [String: Int] = [:]
    var lsb: [String: Int] = [:]
    var memIndex: [String: Int] = [:]
    var portExprs: [String: Expr] = [:]                       // input port -> expression in the parent
    var instanceOutputs: [String: (Scope, String)] = [:]      // local wire -> (child, child's output port)
    var pieces: [String: [(hi: Int, lo: Int, expr: Expr, line: Int)]] = [:]
    var regs: [String: Int] = [:]                             // clocked reg -> its flip-flop cell
    var combBlock: [String: Int] = [:]                        // reg driven by a combinational always block
    var combDone: Set<Int> = []
    var memo: [String: Val] = [:]
    var resolving: Set<String> = []
    var overrides: [String: Val]? = nil                       // values assigned so far in a combinational block
    var children: [Scope] = []

    init(ast: ModuleAST, parent: Scope?) {
        self.ast = ast
        self.parent = parent
        depth = (parent?.depth ?? 0) + 1
    }
}

private final class Elaborator {
    let order: [ModuleAST]
    let modules: [String: ModuleAST]
    var gates: [Gate] = []
    var gateLines: [Int] = []
    var gateNames: [Int: String] = [:]
    var existing: [Gate: Signal] = [:]     // identical cells are built once
    var memories: [Memory] = []
    var clock: String?
    var line = 0

    init(_ modules: [ModuleAST]) {
        order = modules
        self.modules = Dictionary(modules.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func fail(_ message: String, _ at: Int? = nil) -> VerilogError {
        VerilogError(message: message, line: at ?? line)
    }

    func run() throws -> Netlist {
        let used = Set(order.flatMap { $0.instances.map { $0.module } })
        guard let top = order.first(where: { !used.contains($0.name) }) else {
            throw fail("Every module is used inside another, so there is no top-level chip.", order[0].line)
        }
        let scope = Scope(ast: top, parent: nil)
        try setup(scope)

        var inputs: [String] = [], outputs: [String] = [], widths: [String: Int] = [:]
        for port in top.ports {
            if top.decls[port]?.dir == .input { inputs.append(port) } else { outputs.append(port) }
            widths[port] = scope.widths[port]
        }
        var drivers: [String: Signal] = [:]
        for out in outputs {
            line = top.decls[out]!.line
            drivers[out] = try signal(scope, out, line).sig
        }
        try finalize(scope)

        // Keep only what can reach an output, the way real synthesis prunes dead logic.
        var live: Set<Int> = [], liveMemories: Set<Int> = []
        var stack: [Int] = []
        func visit(_ s: Signal) {
            if case .gate(let id) = s, live.insert(id).inserted { stack.append(id) }
        }
        drivers.values.forEach(visit)
        while let id = stack.popLast() {
            gates[id].inputs.forEach(visit)
            if case .memRead(let m) = gates[id].kind, liveMemories.insert(m).inserted {
                for port in memories[m].writes { visit(port.enable); visit(port.address); visit(port.data) }
            }
        }
        var renumber: [Int: Int] = [:]
        for g in gates where live.contains(g.id) { renumber[g.id] = renumber.count }
        let memoryOrder = liveMemories.sorted()
        func remap(_ s: Signal) -> Signal {
            if case .gate(let id) = s { return .gate(renumber[id] ?? 0) }
            return s
        }
        var names: [Signal: String] = [:], lines: [Signal: Int] = [:]
        for input in inputs {
            names[.input(input)] = input
            lines[.input(input)] = top.decls[input]?.line
        }
        var kept: [Gate] = []
        for g in gates where live.contains(g.id) {
            var kind = g.kind
            if case .memRead(let m) = kind { kind = .memRead(memoryOrder.firstIndex(of: m) ?? 0) }
            let id = renumber[g.id]!
            kept.append(Gate(id: id, kind: kind, inputs: g.inputs.map(remap), width: g.width))
            lines[.gate(id)] = gateLines[g.id]
            if let name = gateNames[g.id] { names[.gate(id)] = name }
        }
        let keptMemories = memoryOrder.map { m -> Memory in
            var memory = memories[m]
            memory.writes = memory.writes.map { WritePort(enable: remap($0.enable), address: remap($0.address), data: remap($0.data)) }
            return memory
        }
        let hasState = kept.contains { $0.kind == .dff } || !keptMemories.isEmpty
        return Netlist(name: top.name, inputs: inputs, outputs: outputs, widths: widths,
                       drivers: drivers.mapValues(remap), gates: kept, memories: keptMemories,
                       clock: hasState ? clock : nil, names: names, lines: lines)
    }

    // MARK: Setup: declarations, drivers, registers, instances

    func setup(_ s: Scope) throws {
        let ast = s.ast
        if s.depth > 12 { throw fail("Modules are nested too deeply. Does ‘\(ast.name)’ contain itself?", ast.line) }
        for (n, e) in ast.params { s.params[n] = try constant(e, s) }
        for port in ast.ports where ast.decls[port] == nil || ast.decls[port]?.dir == Direction.none {
            throw fail("Port ‘\(port)’ needs a direction: is it an input or an output?", ast.line)
        }
        for n in ast.order {
            let d = ast.decls[n]!
            line = d.line
            if let (a, b) = d.range {
                let hi = Int(truncatingIfNeeded: try constant(a, s)), lo = Int(truncatingIfNeeded: try constant(b, s))
                guard abs(hi - lo) < 64 else { throw fail("Buses can be up to 64 bits wide.") }
                s.widths[n] = abs(hi - lo) + 1
                s.lsb[n] = min(hi, lo)
            } else {
                s.widths[n] = 1
                s.lsb[n] = 0
            }
            if let (a, b) = d.memory {
                let hi = Int(truncatingIfNeeded: try constant(a, s)), lo = Int(truncatingIfNeeded: try constant(b, s))
                guard abs(hi - lo) < 4096 else { throw fail("Memories can hold up to 4096 words here.") }
                s.memIndex[n] = memories.count
                memories.append(Memory(name: n, width: s.widths[n]!, depth: abs(hi - lo) + 1))
            }
        }

        for (target, value, at) in ast.assigns {
            let n = target.name
            line = at
            guard let d = ast.decls[n] else { throw fail("‘\(n)’ isn't declared. Add ‘wire \(n);’ first.") }
            if d.dir == .input { throw fail("‘\(n)’ is an input. Its value comes from outside the chip, so it can't be assigned.") }
            if d.isReg { throw fail("‘\(n)’ is a reg. Drive it from an always block, or declare it as a wire.") }
            let (hi, lo) = try bounds(target, s)
            if s.pieces[n, default: []].contains(where: { $0.lo <= hi && lo <= $0.hi }) {
                throw fail("‘\(n)’ is driven twice. A wire can only have one driver.")
            }
            s.pieces[n, default: []].append((hi, lo, value, at))
        }

        for (index, block) in ast.always.enumerated() {
            line = block.line
            var seen: Set<String> = []
            for target in block.body.targets where seen.insert(target).inserted {
                guard let d = ast.decls[target] else { throw fail("‘\(target)’ isn't declared. Add ‘reg \(target);’ first.") }
                guard d.isReg else { throw fail("‘\(target)’ is assigned in an always block, so it must be declared as a reg.") }
                if s.memIndex[target] != nil {
                    if block.clock == nil { throw fail("A memory can only be written on a clock edge.") }
                    continue
                }
                if s.regs[target] != nil || s.combBlock[target] != nil {
                    throw fail("‘\(target)’ is assigned in more than one always block.")
                }
                if block.clock != nil {
                    s.regs[target] = gates.count
                    gateNames[gates.count] = target
                    gateLines.append(d.line)
                    gates.append(Gate(id: gates.count, kind: .dff, inputs: [.const(0)], width: s.widths[target]!))
                } else {
                    s.combBlock[target] = index
                }
            }
            if let name = block.clock {
                let root = try clockRoot(s, name)
                if let clock, clock != root {
                    throw fail("This chip uses two clocks (‘\(clock)’ and ‘\(root)’). Only one clock is supported.")
                }
                clock = root
            }
        }

        for inst in ast.instances {
            line = inst.line
            guard let child = modules[inst.module] else { throw fail("There is no module called ‘\(inst.module)’.") }
            let cs = Scope(ast: child, parent: s)
            var connections = inst.named
            if !inst.positional.isEmpty {
                guard inst.positional.count <= child.ports.count else {
                    throw fail("‘\(inst.module)’ only has \(child.ports.count) ports.")
                }
                connections = zip(child.ports, inst.positional).map { ($0, Optional($1)) }
            }
            for (port, value) in connections {
                guard let d = child.decls[port], d.dir != .none else {
                    throw fail("‘\(inst.module)’ has no port called ‘\(port)’.")
                }
                guard let value else { continue }
                if d.dir == .input {
                    cs.portExprs[port] = value
                } else {
                    guard case .ref(let net, _) = value else {
                        throw fail("Connect the output ‘\(port)’ to a plain wire name.")
                    }
                    guard let local = ast.decls[net] else { throw fail("‘\(net)’ isn't declared. Add ‘wire \(net);’ first.") }
                    if local.dir == .input || local.isReg || s.pieces[net] != nil || s.instanceOutputs[net] != nil {
                        throw fail("‘\(net)’ can't be driven by ‘\(inst.name)’: it already has a driver.")
                    }
                    s.instanceOutputs[net] = (cs, port)
                }
            }
            s.children.append(cs)
            try setup(cs)
        }
    }

    /// Follows a clock back to the top-level pin it comes from.
    func clockRoot(_ s: Scope, _ name: String) throws -> String {
        guard let d = s.ast.decls[name] else { throw fail("The clock ‘\(name)’ isn't declared.") }
        if d.dir == .input {
            guard let parent = s.parent else { return name }
            if case .ref(let outer, _)? = s.portExprs[name] { return try clockRoot(parent, outer) }
        } else if let pieces = s.pieces[name], pieces.count == 1, case .ref(let source, _) = pieces[0].expr {
            return try clockRoot(s, source)
        }
        throw fail("A clock has to come straight from an input pin. Gated or generated clocks aren't supported.")
    }

    func bounds(_ target: LValue, _ s: Scope) throws -> (hi: Int, lo: Int) {
        let n = target.name
        guard let w = s.widths[n] else { throw fail("‘\(n)’ isn't declared.") }
        let base = s.lsb[n] ?? 0
        var hi = w - 1, lo = 0
        switch target {
        case .whole:
            break
        case .bit(_, let i):
            guard let c = try? constant(i, s) else { throw fail("Assigning to a bit chosen by another signal isn't supported yet.") }
            hi = Int(truncatingIfNeeded: c) - base
            lo = hi
        case .part(_, let a, let b):
            let x = Int(truncatingIfNeeded: try constant(a, s)) - base, y = Int(truncatingIfNeeded: try constant(b, s)) - base
            hi = max(x, y)
            lo = min(x, y)
        }
        guard lo >= 0, hi < w else { throw fail("‘\(n)’ is only \(w) bit\(w == 1 ? "" : "s") wide.") }
        return (hi, lo)
    }

    // MARK: Resolving names

    func signal(_ s: Scope, _ name: String, _ at: Int) throws -> Val {
        if let assigned = s.overrides?[name] { return assigned }
        if let done = s.memo[name] { return done }
        guard let d = s.ast.decls[name], let w = s.widths[name] else {
            throw fail("‘\(name)’ isn't declared. Is it a typo, or a missing wire?", at)
        }
        if s.memIndex[name] != nil { throw fail("‘\(name)’ is a memory. Pick one word with \(name)[address].", at) }
        guard s.resolving.insert(name).inserted else {
            throw fail("‘\(name)’ depends on itself. That's a combinational loop, and the signal could never settle.", d.line)
        }
        defer { s.resolving.remove(name) }
        let outerLine = line
        defer { line = outerLine }

        var value: Val
        if d.dir == .input {
            if let parent = s.parent {
                if let e = s.portExprs[name] {
                    value = fit(try build(e, parent, w), w)
                } else {
                    value = Val(sig: .const(0), width: w)
                }
            } else {
                value = Val(sig: .input(name), width: w)
            }
        } else if let id = s.regs[name] {
            value = Val(sig: .gate(id), width: w)
        } else if let block = s.combBlock[name] {
            try runCombinational(s, block)
            guard let result = s.memo[name] else { throw fail("‘\(name)’ is never assigned.", d.line) }
            value = result
        } else if let (child, port) = s.instanceOutputs[name] {
            value = fit(try signal(child, port, at), w)
        } else if let pieces = s.pieces[name]?.sorted(by: { $0.hi > $1.hi }) {
            if pieces.count == 1, pieces[0].hi == w - 1, pieces[0].lo == 0 {
                line = pieces[0].line
                value = fit(try build(pieces[0].expr, s, w), w)
            } else {
                var next = w - 1
                var parts: [Val] = []
                for p in pieces {
                    line = p.line
                    guard p.hi == next else { throw fail("Bits [\(next):\(p.hi + 1)] of ‘\(name)’ are never driven.") }
                    let pw = p.hi - p.lo + 1
                    parts.append(fit(try build(p.expr, s, pw), pw))
                    next = p.lo - 1
                }
                guard next == -1 else { throw fail("Bits [\(next):0] of ‘\(name)’ are never driven.") }
                value = concat(parts)
            }
        } else if d.isReg {
            throw fail("‘\(name)’ is a reg that is never assigned in an always block.", d.line)
        } else if d.dir == .output {
            throw fail("Output ‘\(name)’ isn't driven yet. Add: assign \(name) = …;", s.parent == nil ? at : d.line)
        } else {
            throw fail("‘\(name)’ is used but nothing drives it.", at)
        }
        if case .gate(let id) = value.sig, gateNames[id] == nil { gateNames[id] = name }
        s.memo[name] = value
        return value
    }

    func constant(_ e: Expr, _ s: Scope) throws -> UInt64 {
        switch e {
        case .num(let v, _): return v
        case .ref(let n, let at):
            if let p = s.params[n] { return p }
            throw fail("‘\(n)’ needs to be a constant here.", at)
        case .unary("-", let x, _): return 0 &- (try constant(x, s))
        case .unary("~", let x, _): return ~(try constant(x, s))
        case .binary(let op, let l, let r, let at):
            let a = try constant(l, s), b = try constant(r, s)
            switch op {
            case "+": return a &+ b
            case "-": return a &- b
            case "*": return a &* b
            case "/": return b == 0 ? 0 : a / b
            case "%": return b == 0 ? 0 : a % b
            case "<<": return b >= 64 ? 0 : a << b
            case ">>": return b >= 64 ? 0 : a >> b
            default: throw fail("This needs to be a constant.", at)
            }
        default:
            throw fail("This needs to be a constant.")
        }
    }

    /// The width an expression has on its own, before its surroundings widen it.
    func selfWidth(_ e: Expr, _ s: Scope) throws -> Int {
        switch e {
        case .num(let v, let w): return w ?? max(64 - v.leadingZeroBitCount, 1)
        case .ref(let n, let at):
            if let w = s.widths[n] { return w }
            if let p = s.params[n] { return max(64 - p.leadingZeroBitCount, 1) }
            throw fail("‘\(n)’ isn't declared. Is it a typo, or a missing wire?", at)
        case .unary(let op, let x, _): return op == "~" || op == "-" || op == "+" ? try selfWidth(x, s) : 1
        case .binary(let op, let l, let r, _):
            switch op {
            case "&&", "||", "==", "!=", "<", "<=", ">", ">=": return 1
            case "<<", ">>": return try selfWidth(l, s)
            default: return max(try selfWidth(l, s), try selfWidth(r, s))
            }
        case .ternary(_, let a, let b, _): return max(try selfWidth(a, s), try selfWidth(b, s))
        case .index(let n, _, _): return s.memIndex[n].map { memories[$0].width } ?? 1
        case .range(_, let a, let b, _):
            return abs(Int(truncatingIfNeeded: try constant(a, s)) - Int(truncatingIfNeeded: try constant(b, s))) + 1
        case .concat(let items, _): return try items.reduce(0) { $0 + (try selfWidth($1, s)) }
        case .replicate(let count, let x, _): return Int(truncatingIfNeeded: try constant(count, s)) * (try selfWidth(x, s))
        }
    }

    // MARK: Building expressions

    func fit(_ v: Val, _ width: Int) -> Val {
        guard v.width > width else { return Val(sig: v.sig, width: width) }
        return Val(sig: make(.slice(width - 1, 0), [v.sig], width), width: width)
    }

    func bool(_ v: Val) -> Val {
        v.width == 1 ? v : Val(sig: make(.redOr, [v.sig], 1), width: 1)
    }

    func concat(_ parts: [Val]) -> Val {
        if parts.count == 1 { return parts[0] }
        let total = parts.reduce(0) { $0 + $1.width }
        return Val(sig: make(.concat(parts.map { $0.width }), parts.map { $0.sig }, total), width: total)
    }

    private static let kinds: [String: GateKind] = [
        "&": .and, "|": .or, "^": .xor, "~^": .xnor, "~&": .nand, "~|": .nor,
        "+": .add, "-": .sub, "*": .mul, "/": .div, "%": .mod,
        "==": .eq, "!=": .ne, "<": .lt, "<=": .le, ">": .gt, ">=": .ge, "<<": .shl, ">>": .shr,
    ]

    /// Builds the cells for an expression. `context` is the width its surroundings need.
    func build(_ e: Expr, _ s: Scope, _ context: Int) throws -> Val {
        func sized(_ w: Int, _ at: Int) throws -> Int {
            guard w <= 64 else { throw fail("This value would be \(w) bits wide. The limit is 64.", at) }
            return max(w, 1)
        }
        switch e {
        case .num(let v, let w):
            let width = w ?? max(64 - v.leadingZeroBitCount, 1)
            return Val(sig: .const(v & mask(width)), width: width)

        case .ref(let n, let at):
            if s.ast.decls[n] == nil, let p = s.params[n] {
                return Val(sig: .const(p), width: max(64 - p.leadingZeroBitCount, 1))
            }
            return try signal(s, n, at)

        case .index(let n, let i, let at):
            if let m = s.memIndex[n] {
                let address = try build(i, s, 0)
                return Val(sig: make(.memRead(m), [address.sig], memories[m].width), width: memories[m].width)
            }
            let x = try signal(s, n, at)
            if let c = try? constant(i, s) {
                let bit = Int(truncatingIfNeeded: c) - (s.lsb[n] ?? 0)
                guard bit >= 0, bit < x.width else { throw fail("‘\(n)’ has no bit \(c). It is \(x.width) wide.", at) }
                return Val(sig: make(.slice(bit, bit), [x.sig], 1), width: 1)
            }
            let shifted = make(.shr, [x.sig, try build(i, s, 0).sig], x.width)
            return Val(sig: make(.slice(0, 0), [shifted], 1), width: 1)

        case .range(let n, let a, let b, let at):
            let x = try signal(s, n, at)
            let base = s.lsb[n] ?? 0
            let p = Int(truncatingIfNeeded: try constant(a, s)) - base, q = Int(truncatingIfNeeded: try constant(b, s)) - base
            let hi = max(p, q), lo = min(p, q)
            guard lo >= 0, hi < x.width else { throw fail("‘\(n)’ is only \(x.width) bits wide.", at) }
            return Val(sig: make(.slice(hi, lo), [x.sig], hi - lo + 1), width: hi - lo + 1)

        case .concat(let items, let at):
            let parts = try items.map { try build($0, s, 0) }
            _ = try sized(parts.reduce(0) { $0 + $1.width }, at)
            return concat(parts)

        case .replicate(let count, let x, let at):
            let n = Int(truncatingIfNeeded: try constant(count, s))
            let part = try build(x, s, 0)
            guard n >= 1 else { throw fail("A repeat count must be at least 1.", at) }
            _ = try sized(n * part.width, at)
            return concat(Array(repeating: part, count: n))

        case .unary(let op, let x, let at):
            switch op {
            case "~":
                let w = try sized(max(context, try selfWidth(x, s)), at)
                return Val(sig: make(.not, [try build(x, s, w).sig], w), width: w)
            case "-":
                let w = try sized(max(context, try selfWidth(x, s)), at)
                return Val(sig: make(.sub, [.const(0), try build(x, s, w).sig], w), width: w)
            case "+":
                return try build(x, s, context)
            case "!":
                return Val(sig: make(.not, [bool(try build(x, s, 0)).sig], 1), width: 1)
            default:
                let v = try build(x, s, 0)
                var reduced = v.sig
                if v.width > 1 {
                    let kind: GateKind = op.hasSuffix("&") ? .redAnd(v.width) : op.hasSuffix("|") ? .redOr : .redXor
                    reduced = make(kind, [v.sig], 1)
                }
                return Val(sig: op.hasPrefix("~") ? make(.not, [reduced], 1) : reduced, width: 1)
            }

        case .binary(let op, let l, let r, let at):
            switch op {
            case "&&", "||":
                let a = bool(try build(l, s, 0)), b = bool(try build(r, s, 0))
                return Val(sig: make(op == "&&" ? .and : .or, [a.sig, b.sig], 1), width: 1)
            case "==", "!=", "<", "<=", ">", ">=":
                let w = try sized(max(try selfWidth(l, s), try selfWidth(r, s)), at)
                let a = try build(l, s, w), b = try build(r, s, w)
                var kind = Elaborator.kinds[op]!
                if w == 1, op == "==" { kind = .xnor }
                if w == 1, op == "!=" { kind = .xor }
                return Val(sig: make(kind, [a.sig, b.sig], 1), width: 1)
            case "<<", ">>":
                let w = try sized(max(context, try selfWidth(l, s)), at)
                let a = try build(l, s, w), b = try build(r, s, 0)
                return Val(sig: make(Elaborator.kinds[op]!, [a.sig, b.sig], w), width: w)
            default:
                let w = try sized(max(context, try selfWidth(l, s), try selfWidth(r, s)), at)
                let a = try build(l, s, w), b = try build(r, s, w)
                return Val(sig: make(Elaborator.kinds[op]!, [a.sig, b.sig], w), width: w)
            }

        case .ternary(let c, let a, let b, let at):
            let condition = bool(try build(c, s, 0))
            let w = try sized(max(context, try selfWidth(a, s), try selfWidth(b, s)), at)
            let x = try build(a, s, w), y = try build(b, s, w)
            return Val(sig: make(.mux, [condition.sig, x.sig, y.sig], w), width: w)
        }
    }

    /// Creates a cell, folding away constants so the chip only holds real logic.
    func make(_ kind: GateKind, _ ins: [Signal], _ width: Int) -> Signal {
        func constant(_ s: Signal) -> UInt64? {
            if case .const(let c) = s { return c }
            return nil
        }
        let consts = ins.map(constant)
        if !kind.isState, consts.allSatisfy({ $0 != nil }) {
            return .const(kind.eval(consts.map { $0! }, width: width))
        }
        let full = mask(width)
        switch kind {
        case .buf:
            return ins[0]
        case .and, .or, .xor:
            let (a, b) = (ins[0], ins[1])
            if a == b { return kind == .xor ? .const(0) : a }
            for (c, other) in [(consts[0], b), (consts[1], a)] {
                guard let c else { continue }
                switch kind {
                case .and:
                    if c & full == 0 { return .const(0) }
                    if c & full == full { return other }
                case .or:
                    if c & full == 0 { return other }
                    if c & full == full { return .const(full) }
                default:
                    if c & full == 0 { return other }
                    if c & full == full { return make(.not, [other], width) }
                }
            }
        case .nand, .nor, .xnor:
            if width == 1, consts[0] != nil || consts[1] != nil || ins[0] == ins[1] {
                let base: GateKind = kind == .nand ? .and : kind == .nor ? .or : .xor
                return make(.not, [make(base, ins, width)], width)
            }
        case .mux:
            if let c = consts[0] { return c != 0 ? ins[1] : ins[2] }
            if ins[1] == ins[2] { return ins[1] }
            if width == 1, consts[1] != nil || consts[2] != nil {
                let hi = make(.and, [ins[0], ins[1]], 1)
                let lo = make(.and, [make(.not, [ins[0]], 1), ins[2]], 1)
                return make(.or, [hi, lo], 1)
            }
        case .add:
            if consts[0] == 0 { return ins[1] }
            if consts[1] == 0 { return ins[0] }
        case .sub, .shl, .shr:
            if consts[1] == 0 { return ins[0] }
        case .slice(let hi, let lo):
            if case .gate(let id) = ins[0], case .slice(_, let inner) = gates[id].kind {
                return make(.slice(hi + inner, lo + inner), gates[id].inputs, width)
            }
        default:
            break
        }
        let key = Gate(id: -1, kind: kind, inputs: ins, width: width)
        if let s = existing[key] { return s }
        let s = Signal.gate(gates.count)
        gates.append(Gate(id: gates.count, kind: kind, inputs: ins, width: width))
        gateLines.append(line)
        existing[key] = s
        return s
    }

    // MARK: Always blocks

    /// Walks a block of statements, tracking the value each reg ends up with.
    func exec(_ stmt: Stmt, _ s: Scope, path: Signal, comb: Bool, env: inout [String: Val]) throws {
        switch stmt {
        case .empty:
            return
        case .block(let list):
            for inner in list { try exec(inner, s, path: path, comb: comb, env: &env) }

        case .assign(let target, let value, let blocking, let at):
            line = at
            if comb { s.overrides = env }
            let n = target.name
            if let m = s.memIndex[n] {
                guard case .bit(_, let address) = target else {
                    throw fail("Write one word of ‘\(n)’ at a time: \(n)[address] <= value;")
                }
                let a = try build(address, s, 0)
                let d = fit(try build(value, s, memories[m].width), memories[m].width)
                memories[m].writes.append(WritePort(enable: path, address: a.sig, data: d.sig))
                return
            }
            if !comb, blocking {
                throw fail("Use ‘<=’ inside a clocked always block, so every register updates together.")
            }
            guard let w = s.widths[n] else { throw fail("‘\(n)’ isn't declared.") }
            switch target {
            case .whole:
                env[n] = fit(try build(value, s, w), w)
            case .bit, .part:
                let (hi, lo) = try bounds(target, s)
                let piece = fit(try build(value, s, hi - lo + 1), hi - lo + 1)
                let current = try env[n] ?? hold(n, s, comb: comb)
                var parts: [Val] = []
                if hi < w - 1 { parts.append(Val(sig: make(.slice(w - 1, hi + 1), [current.sig], w - 1 - hi), width: w - 1 - hi)) }
                parts.append(piece)
                if lo > 0 { parts.append(Val(sig: make(.slice(lo - 1, 0), [current.sig], lo), width: lo)) }
                env[n] = concat(parts)
            }
            if comb { s.overrides = env }

        case .ifElse(let c, let then, let otherwise):
            if comb { s.overrides = env }
            let condition = bool(try build(c, s, 0))
            if case .const(let k) = condition.sig {
                if k != 0 {
                    try exec(then, s, path: path, comb: comb, env: &env)
                } else if let otherwise {
                    try exec(otherwise, s, path: path, comb: comb, env: &env)
                }
                return
            }
            let before = env
            var taken = before
            try exec(then, s, path: make(.and, [path, condition.sig], 1), comb: comb, env: &taken)
            var skipped = before
            if let otherwise {
                if comb { s.overrides = before }
                let inverse = make(.not, [condition.sig], 1)
                try exec(otherwise, s, path: make(.and, [path, inverse], 1), comb: comb, env: &skipped)
            }
            var merged = before
            for n in Set(taken.keys).union(skipped.keys) {
                let a = try taken[n] ?? hold(n, s, comb: comb), b = try skipped[n] ?? hold(n, s, comb: comb)
                let w = s.widths[n] ?? a.width
                merged[n] = a.sig == b.sig ? a : Val(sig: make(.mux, [condition.sig, a.sig, b.sig], w), width: w)
            }
            env = merged
            if comb { s.overrides = env }

        case .caseOf(let subject, let items, let fallback, let at):
            // A case is a chain of if / else if comparisons.
            var chain: Stmt = fallback ?? .empty
            for (values, body) in items.reversed() {
                let test = values.dropFirst().reduce(Expr.binary("==", subject, values[0], at)) {
                    .binary("||", $0, .binary("==", subject, $1, at), at)
                }
                chain = .ifElse(test, body, chain)
            }
            try exec(chain, s, path: path, comb: comb, env: &env)
        }
    }

    /// The value a reg keeps when a branch doesn't assign it.
    func hold(_ name: String, _ s: Scope, comb: Bool) throws -> Val {
        if !comb, let id = s.regs[name] { return Val(sig: .gate(id), width: s.widths[name] ?? 1) }
        throw fail("‘\(name)’ isn't assigned on every path through this block. Remembering the old value would need a latch; give it a default first.")
    }

    func runCombinational(_ s: Scope, _ index: Int) throws {
        if s.combDone.contains(index) { return }
        let block = s.ast.always[index]
        guard s.resolving.insert("#\(index)").inserted else {
            throw fail("This always block reads a value it hasn't assigned yet. That's a combinational loop.", block.line)
        }
        defer { s.resolving.remove("#\(index)") }
        let outer = s.overrides
        s.overrides = [:]
        var env: [String: Val] = [:]
        defer { s.overrides = outer }
        try exec(block.body, s, path: .const(1), comb: true, env: &env)
        s.overrides = outer
        for target in Set(block.body.targets) where s.combBlock[target] == index {
            guard let value = env[target] else { throw fail("‘\(target)’ is never assigned.", block.line) }
            if case .gate(let id) = value.sig, gateNames[id] == nil { gateNames[id] = target }
            s.memo[target] = value
        }
        s.combDone.insert(index)
    }

    /// Fills in each register's next value, and builds anything not yet visited so its mistakes are reported.
    func finalize(_ s: Scope) throws {
        for (index, block) in s.ast.always.enumerated() {
            if block.clock != nil {
                var env: [String: Val] = [:]
                try exec(block.body, s, path: .const(1), comb: false, env: &env)
                for (n, value) in env {
                    if let id = s.regs[n] { gates[id].inputs = [value.sig] }
                }
            } else {
                try runCombinational(s, index)
            }
        }
        for (n, pieces) in s.pieces.sorted(by: { $0.value[0].line < $1.value[0].line }) {
            _ = try signal(s, n, pieces[0].line)
        }
        for child in s.children { try finalize(child) }
    }
}
