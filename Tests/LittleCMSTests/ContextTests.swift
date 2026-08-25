import LittleCMSCore
import Testing

@Suite
struct ContextTests {
    @Test
    func aFreshContextCarriesTheReferenceDefaults() {
        let context = Context()
        #expect(context.chunks.adaptationState == 1.0)
        #expect(context.chunks.alarmCodes.count == 16)
        #expect(Array(context.chunks.alarmCodes.prefix(3)) == [0x7F00, 0x7F00, 0x7F00])
        #expect(context.chunks.alarmCodes.dropFirst(3).allSatisfy { $0 == 0 })
    }

    /// What `cmsDupContext` promises: the copy takes the original's
    /// settings and then stops hearing about it.
    @Test
    func duplicatingSnapshotsRatherThanSharing() {
        let original = Context()
        original.update { $0.adaptationState = 0.25 }
        original.update { $0.alarmCodes[0] = 0x1234 }

        let copy = Context(copying: original)
        #expect(copy.chunks.adaptationState == 0.25)
        #expect(copy.chunks.alarmCodes[0] == 0x1234)

        original.update { $0.adaptationState = 0.75 }
        original.update { $0.alarmCodes[0] = 0xFFFF }

        #expect(copy.chunks.adaptationState == 0.25)
        #expect(copy.chunks.alarmCodes[0] == 0x1234)

        // And the copy does not write back into the original either.
        copy.update { $0.adaptationState = 0.5 }
        #expect(original.chunks.adaptationState == 0.75)
    }

    @Test
    func contextsAreIndependentOfTheGlobalOne() {
        let context = Context()
        context.update { $0.adaptationState = 0.1 }
        #expect(Context.global.chunks.adaptationState != 0.1)
    }

    /// A context is shared state, and the API lets several threads reach
    /// it.  Run under the thread sanitizer this is the check that the
    /// lock is really doing something.
    @Test
    func concurrentReadersAndWritersDoNotRace() async {
        let context = Context()

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for round in 0..<500 {
                        context.update { chunks in
                            chunks.adaptationState = Double(worker) / 8.0
                            chunks.alarmCodes[worker] = UInt16(round % 65535)
                        }
                        _ = context.chunks.alarmCodes.count
                    }
                }
            }
        }

        // Whatever won, the shape has to have survived.
        #expect(context.chunks.alarmCodes.count == 16)
        #expect(context.chunks.adaptationState >= 0.0)
    }
}

@Suite
struct AllocationPolicyTests {
    @Test
    func theLimitsAreTheReferences() {
        #expect(AllocationPolicy.maximumAllocation == 512 * 1024 * 1024)
        #expect(!AllocationPolicy.allows(size: 0))
        #expect(AllocationPolicy.allows(size: 1))
        #expect(AllocationPolicy.allows(size: 512 * 1024 * 1024))
        #expect(!AllocationPolicy.allows(size: 512 * 1024 * 1024 + 1))

        // Reallocation admits zero where allocation refuses it.
        #expect(AllocationPolicy.allowsReallocation(size: 0))
    }

    /// The array checks exist to catch a product that wrapped, which is
    /// how a malformed profile asks for a table that cannot exist.
    @Test
    func arraySizingRefusesOverflow() {
        #expect(AllocationPolicy.arraySize(count: 0, size: 0) == nil)
        #expect(AllocationPolicy.arraySize(count: 16, size: 0) == nil)
        #expect(AllocationPolicy.arraySize(count: 0, size: 16) == nil)
        #expect(AllocationPolicy.arraySize(count: 1024, size: 1024) == UInt32(1_048_576))

        // 65536 * 65536 wraps to exactly zero.
        #expect(AllocationPolicy.arraySize(count: 65536, size: 65536) == nil)
        // 65537 * 65537 wraps to something small and plausible.
        #expect(AllocationPolicy.arraySize(count: 65537, size: 65537) == nil)
        #expect(AllocationPolicy.arraySize(count: .max, size: 2) == nil)
        #expect(AllocationPolicy.arraySize(count: 2, size: .max) == nil)
        // Fits, but past the ceiling.
        #expect(AllocationPolicy.arraySize(count: 1024, size: 1024 * 1024) == nil)
    }
}
