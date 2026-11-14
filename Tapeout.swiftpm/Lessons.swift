import Foundation

struct Lesson: Identifiable {
    let id: Int
    let title: String
    let concept: String      // Markdown
    let goal: String         // Markdown
    let starter: String
    let hint: String         // Markdown
    let solution: String
    /// The behaviour the chip must have. `nil` means free build.
    let expected: (([String: Bool]) -> [String: Bool])?
    let inputs: [String]
    let outputs: [String]
    /// An extra goal beyond correct logic, such as using a tool or meeting a timing target.
    /// Returns what is still left to do, or `nil` once it is met.
    var requirement: (@MainActor (AppModel) -> String?)? = nil
    /// The floorplan the lesson starts with.
    var density: Density = .normal
}

enum Lessons {
    static let all: [Lesson] = [
        Lesson(
            id: 0,
            title: "Your first wire",
            concept: "A chip is described as a **module**: a box with pins. `input` pins bring signals in, `output` pins send them out. `assign` connects things with a wire that is *always* live, not a line of code that runs once.",
            goal: "Connect the output `y` straight to the input `a`.",
            starter: """
            module wire_up(
              input a,
              output y
            );
              // Connect y to a
              assign y = ;
            endmodule
            """,
            hint: "Finish the line: `assign y = a;`",
            solution: """
            module wire_up(
              input a,
              output y
            );
              assign y = a;
            endmodule
            """,
            expected: { ["y": $0["a"]!] },
            inputs: ["a"], outputs: ["y"]
        ),
        Lesson(
            id: 1,
            title: "The inverter",
            concept: "The simplest gate flips its input: 1 becomes 0, 0 becomes 1. In Verilog that's the `~` operator. On silicon it's just two transistors, and every other gate is built from the same idea.",
            goal: "Make `y` the opposite of `a`.",
            starter: """
            module inverter(
              input a,
              output y
            );
              assign y = a;
            endmodule
            """,
            hint: "Put `~` in front of `a`: `assign y = ~a;`",
            solution: """
            module inverter(
              input a,
              output y
            );
              assign y = ~a;
            endmodule
            """,
            expected: { ["y": !$0["a"]!] },
            inputs: ["a"], outputs: ["y"]
        ),
        Lesson(
            id: 2,
            title: "AND: both or nothing",
            concept: "An AND gate outputs 1 only when *every* input is 1. Write it with `&`. Its siblings are `|` (OR: at least one) and `^` (XOR: exactly one).",
            goal: "Light `y` only when both `a` and `b` are on.",
            starter: """
            module both(
              input a,
              input b,
              output y
            );
              assign y = a;
            endmodule
            """,
            hint: "`assign y = a & b;`",
            solution: """
            module both(
              input a,
              input b,
              output y
            );
              assign y = a & b;
            endmodule
            """,
            expected: { ["y": $0["a"]! && $0["b"]!] },
            inputs: ["a", "b"], outputs: ["y"]
        ),
        Lesson(
            id: 3,
            title: "Spot the difference",
            concept: "XOR is 1 when its inputs *differ*. Verilog has `^` for it, but this time build it from simpler gates so you can watch them work together: *(a or b) and not (a and b)*.",
            goal: "Make `y` turn on when exactly one of `a`, `b` is on, using only `&`, `|` and `~`.",
            starter: """
            module differ(
              input a,
              input b,
              output y
            );
              wire either = a | b;
              wire both   = a & b;

              assign y = either;
            endmodule
            """,
            hint: "`either` is right except when both are on. Rule that case out: `assign y = either & ~both;`",
            solution: """
            module differ(
              input a,
              input b,
              output y
            );
              wire either = a | b;
              wire both   = a & b;

              assign y = either & ~both;
            endmodule
            """,
            expected: { ["y": $0["a"]! != $0["b"]!] },
            inputs: ["a", "b"], outputs: ["y"]
        ),
        Lesson(
            id: 4,
            title: "Half adder",
            concept: "This is where chips start doing maths. Adding two bits gives a `sum` bit and a `carry` bit: 1 + 1 = 10 in binary. The sum is 1 when the inputs differ. The carry is 1 when both are 1.",
            goal: "Add `a` and `b`. Drive both `sum` and `carry`.",
            starter: """
            module half_adder(
              input a,
              input b,
              output sum,
              output carry
            );
              assign sum   = a;
              assign carry = b;
            endmodule
            """,
            hint: "\"Differ\" is XOR and \"both\" is AND: `sum = a ^ b` and `carry = a & b`.",
            solution: """
            module half_adder(
              input a,
              input b,
              output sum,
              output carry
            );
              assign sum   = a ^ b;
              assign carry = a & b;
            endmodule
            """,
            expected: { ["sum": $0["a"]! != $0["b"]!, "carry": $0["a"]! && $0["b"]!] },
            inputs: ["a", "b"], outputs: ["sum", "carry"]
        ),
        Lesson(
            id: 5,
            title: "The multiplexer",
            concept: "A mux is a signal-controlled switch: `sel` picks which input reaches the output. It is how a chip makes choices. Verilog writes it as `sel ? b : a`, read as *if sel then b, else a*.",
            goal: "Send `a` to `y` when `sel` is 0, and `b` when `sel` is 1.",
            starter: """
            module mux2(
              input a,
              input b,
              input sel,
              output y
            );
              assign y = a;
            endmodule
            """,
            hint: "`assign y = sel ? b : a;`",
            solution: """
            module mux2(
              input a,
              input b,
              input sel,
              output y
            );
              assign y = sel ? b : a;
            endmodule
            """,
            expected: { ["y": $0["sel"]! ? $0["b"]! : $0["a"]!] },
            inputs: ["a", "b", "sel"], outputs: ["y"]
        ),
        Lesson(
            id: 6,
            title: "Full adder",
            concept: "A full adder also accepts a carry *in*, so adders can be chained to add numbers of any width. Every processor is built on rows of these. Name the shared pieces with `wire` so they are built once and reused.",
            goal: "Add `a`, `b` and `cin`. Drive `sum` and `cout`.",
            starter: """
            module full_adder(
              input a,
              input b,
              input cin,
              output sum,
              output cout
            );
              wire ab = a ^ b;

              assign sum  = ab;
              assign cout = a & b;
            endmodule
            """,
            hint: "`sum = ab ^ cin`. A carry leaves when a and b are both 1, *or* when they differ and a carry came in: `cout = (a & b) | (ab & cin)`.",
            solution: """
            module full_adder(
              input a,
              input b,
              input cin,
              output sum,
              output cout
            );
              wire ab = a ^ b;

              assign sum  = ab ^ cin;
              assign cout = (a & b) | (ab & cin);
            endmodule
            """,
            expected: {
                let n = [$0["a"]!, $0["b"]!, $0["cin"]!].filter { $0 }.count
                return ["sum": n % 2 == 1, "cout": n >= 2]
            },
            inputs: ["a", "b", "cin"], outputs: ["sum", "cout"]
        ),
        Lesson(
            id: 7,
            title: "Reading a waveform",
            concept: "A **waveform** plots every signal against time. The simulator steps through each input combination, and because real gates take time to switch, outputs settle a moment *after* the inputs change. Sometimes they flicker on the way there: that is a **glitch**.",
            goal: "Open **Waves** under the chip. Tap the timeline to move the cursor, then set the radix to **Dec** and watch `out` count how many inputs are on.",
            starter: """
            module full_adder(
              input a,
              input b,
              input cin,
              output cout,
              output sum
            );
              wire ab = a ^ b;

              assign sum  = ab ^ cin;
              assign cout = (a & b) | (ab & cin);
            endmodule
            """,
            hint: "`out` groups `cout` and `sum` into one 2-bit number. Zoom in near a step to see `sum` arrive later than `ab`.",
            solution: """
            module full_adder(
              input a,
              input b,
              input cin,
              output cout,
              output sum
            );
              wire ab = a ^ b;

              assign sum  = ab ^ cin;
              assign cout = (a & b) | (ab & cin);
            endmodule
            """,
            expected: {
                let n = [$0["a"]!, $0["b"]!, $0["cin"]!].filter { $0 }.count
                return ["sum": n % 2 == 1, "cout": n >= 2]
            },
            inputs: ["a", "b", "cin"], outputs: ["cout", "sum"],
            requirement: { model in
                if !model.actions.contains("wave.cursor") { return "Tap the waveform to place the cursor" }
                if !model.actions.contains("wave.radix") { return "Switch the radix to Dec" }
                return nil
            }
        ),
        Lesson(
            id: 8,
            title: "Follow the signal",
            concept: "When one output is wrong you don't inspect the whole chip. You trace its **cone of influence**: only the logic that can affect it. Tap any gate or pin in the **Schematic** and everything outside its cone fades away. The line that builds it lights up in your code too.",
            goal: "`gt` should be 1 only when `a` is 1 and `b` is 0, but it's wrong. Trace it in the Schematic, find the bug, and fix it.",
            starter: """
            module compare(
              input a,
              input b,
              output eq,
              output gt,
              output lt
            );
              wire nb = ~b;
              wire na = ~a;

              assign eq = a ~^ b;
              assign gt = a | nb;
              assign lt = na & b;
            endmodule
            """,
            hint: "The cone shows an OR gate feeding `gt`. \"a *and* not b\" needs `&`.",
            solution: """
            module compare(
              input a,
              input b,
              output eq,
              output gt,
              output lt
            );
              wire nb = ~b;
              wire na = ~a;

              assign eq = a ~^ b;
              assign gt = a & nb;
              assign lt = na & b;
            endmodule
            """,
            expected: { ["eq": $0["a"]! == $0["b"]!, "gt": $0["a"]! && !$0["b"]!, "lt": !$0["a"]! && $0["b"]!] },
            inputs: ["a", "b"], outputs: ["eq", "gt", "lt"],
            requirement: { model in
                model.actions.contains("probe.select") ? nil : "Tap a gate or pin in the Schematic to trace it"
            }
        ),
        Lesson(
            id: 9,
            title: "The critical path",
            concept: "Every gate a signal passes through costs time. The slowest route from an input to an output is the **critical path**, and it sets how fast the whole chip can run. A long chain of gates is slow. A balanced tree does the same job sooner.",
            goal: "This 4-input AND has a delay of 6. Open **Timing**, highlight the critical path, then regroup the logic to bring the delay down to 4.",
            starter: """
            module all_four(
              input a,
              input b,
              input c,
              input d,
              output y
            );
              assign y = ((a & b) & c) & d;
            endmodule
            """,
            hint: "Pair the inputs first so both pairs switch at the same time: `(a & b) & (c & d)`.",
            solution: """
            module all_four(
              input a,
              input b,
              input c,
              input d,
              output y
            );
              assign y = (a & b) & (c & d);
            endmodule
            """,
            expected: { ["y": $0["a"]! && $0["b"]! && $0["c"]! && $0["d"]!] },
            inputs: ["a", "b", "c", "d"], outputs: ["y"],
            requirement: { model in
                guard let delay = model.analysis?.criticalDelay else { return nil }
                return delay <= 4 ? nil : "Delay is \(delay). Get it to 4 or less"
            }
        ),
        Lesson(
            id: 10,
            title: "Metal layers",
            concept: "Underneath, a chip is flat shapes stacked in layers. Here a wire leaves a cell on **M1**, crosses the channel on **M2**, and enters the next cell on **M3**, joined by **vias**. Giving each layer one job is what stops wires from colliding.",
            goal: "Switch the view to **Layout**. Hide a layer to see what it carries, then turn on the **Ruler** and measure the gap between two wires.",
            starter: """
            module half_adder(
              input a,
              input b,
              output sum,
              output carry
            );
              assign sum   = a ^ b;
              assign carry = a & b;
            endmodule
            """,
            hint: "With the Ruler on, tap two points. It snaps to the edges of nearby shapes.",
            solution: """
            module half_adder(
              input a,
              input b,
              output sum,
              output carry
            );
              assign sum   = a ^ b;
              assign carry = a & b;
            endmodule
            """,
            expected: { ["sum": $0["a"]! != $0["b"]!, "carry": $0["a"]! && $0["b"]!] },
            inputs: ["a", "b"], outputs: ["sum", "carry"],
            requirement: { model in
                if !model.actions.contains("layout.layer") { return "Hide a layer in the Layout view" }
                if !model.actions.contains("layout.ruler") { return "Measure a distance with the Ruler" }
                return nil
            }
        ),
        Lesson(
            id: 11,
            title: "Design rules",
            concept: "A factory can only print shapes so small and so close together. **Design rule checks** (DRC) flag every spot that breaks those limits, and a chip can't be built until the list is empty. The usual fix is to give the router more room, at the cost of a bigger chip.",
            goal: "This chip packs its wires too tightly. Open **Checks**, tap a violation to jump to it, then loosen the **Floorplan** in Layout until the chip is clean.",
            starter: """
            module any_pair(
              input a,
              input b,
              input c,
              input d,
              input e,
              input f,
              output y
            );
              assign y = (a & b) | (c & d) | (e & f);
            endmodule
            """,
            hint: "Turn on the Congestion overlay to see the crowded channel, then change Floorplan from Compact to Normal.",
            solution: """
            module any_pair(
              input a,
              input b,
              input c,
              input d,
              input e,
              input f,
              output y
            );
              assign y = (a & b) | (c & d) | (e & f);
            endmodule
            """,
            expected: { ($0["a"]! && $0["b"]!) || ($0["c"]! && $0["d"]!) || ($0["e"]! && $0["f"]!) ? ["y": true] : ["y": false] },
            inputs: ["a", "b", "c", "d", "e", "f"], outputs: ["y"],
            requirement: { model in
                if !model.actions.contains("checks.jump") { return "Tap a violation in Checks" }
                let count = model.checks.filter { $0.isRule }.count
                return count == 0 ? nil : "\(count) rule violation\(count == 1 ? "" : "s") left"
            },
            density: .compact
        ),
        Lesson(
            id: 12,
            title: "Free build",
            concept: "The bench is yours. Add ports, declare wires, and combine `~ & | ^ ?:` or the gate primitives `and`, `or`, `not`, `xor`, `nand`, `nor`. Every tool is live: waveforms, timing, layout and checks update as you type.",
            goal: "Design anything. Try a majority vote, or a 1-bit comparator.",
            starter: """
            module majority(
              input a,
              input b,
              input c,
              output y
            );
              // 1 when at least two inputs are 1
              assign y = (a & b) | (b & c) | (a & c);
            endmodule
            """,
            hint: "For a comparator, try three outputs: `eq = a ~^ b`, `gt = a & ~b`, `lt = ~a & b`.",
            solution: "",
            expected: nil,
            inputs: [], outputs: []
        ),
    ]
}
