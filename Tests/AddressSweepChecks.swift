import Foundation

@main
enum AddressSweepChecks {
    static func main() {
        let plan = SweepRoute.plan
        let routes = Set(plan)
        let bytes = Set(0...255)
        precondition(routes.count == plan.count, "duplicate routes")
        precondition(Set(plan.map(\.address)) == bytes, "missing diagnostic address")

        let kLine = bytes.subtracting([0xF1])
        let can = bytes.subtracting([0x00])
        for mode in [SweepRoute.Mode.tp16, .tp20] {
            precondition(Set(plan.filter { $0.mode == mode }.map(\.address)) == can)
        }
        for rate in SweepRate.allCases {
            precondition(Set(plan.filter { $0.mode == .fast(rate) }.map(\.address)) == kLine)
            for address in kLine {
                precondition(routes.contains(SweepRoute(address: address, mode: .slow(rate, initByte: address))))
            }
            precondition(routes.contains(SweepRoute(address: 0x28, mode: .slow(rate, initByte: 0x83))))
        }
        precondition(!plan.contains { $0.rate != nil && $0.address == 0xF1 })
        let firstFastPass = plan.prefix { $0 != SweepRoute(address: 0x00, mode: .fast(.standard)) }
        precondition([0x05, 0x09, 0x46].allSatisfy { address in firstFastPass.contains { $0.address == address } })

        func framed(_ bytes: [Int]) -> [Int] { bytes + [bytes.reduce(0, +) & 0xFF] }
        let data = [0x5A, 0x9B] + "7L6 937 049 N".utf8.map(Int.init)
        let frame = framed([0x80 + data.count, 0xF1, 0xFE] + data)
        precondition(SweepReply.kwpData(frame, from: 0xFE) == data)
        precondition(SweepReply.kwpData(framed([0x80, 0xF1, 0xFE, data.count] + data), from: 0xFE) == data)
        precondition(SweepReply.kwpData(frame, from: 0xFD) == nil)
        precondition(SweepReply.kwpData(Array(frame.dropLast()), from: 0xFE) == nil)
        precondition(SweepReply.kwpData(framed([0x82, 0xFE, 0xF1, 0x1A, 0x9B]), from: 0xFE) == nil)
        var reply = SweepReply()
        reply.inspect([Response(bytes: [0x7F, 0x1A, 0x78], errors: [])], option: 0x9B)
        precondition(reply.evidence != nil && reply.payload == nil)
        reply.inspect([Response(bytes: data, errors: [])], option: 0x9B)
        precondition(reply.module == .onboardSupply)
        precondition(Dtc.identifyModule("3D0-909-135 N".utf8.map(Int.init)) == .kessy)
        precondition(Dtc.identifyModule("unknown ECU".utf8.map(Int.init)) == nil)
        let traced: [(DtcModule, Int, String)] = [
            (.climate, 0x98, "7L5907040AF "),
            (.seatAdjustment, 0xA1, "7L0959760   "),
            (.onboardSupply, 0xA4, "7L5937049C  "),
            (.wipers, 0xA6, "7L0955119F  "),
            (.kessy, 0xC4, "3D0909135K  "),
        ]
        for (module, address, number) in traced {
            let payload = number.utf8.map { Int($0) }
            precondition(module.isBase && module.fastInitTargets.first == address)
            precondition(module.matchesIdentification(payload))
            var found = SweepReply(kLineAddress: address)
            found.inspect([Response(bytes: [0x5A, 0x9B] + payload, errors: [])], option: 0x9B)
            precondition(found.module == module)
        }
        // The seat component's part number alone cannot distinguish the two sides.
        let seat = "7L0959760   Sitzverstellung".utf8.map { Int($0) }
        precondition(Dtc.identifyModule(seat, kLineAddress: 0xA2) == nil)
        precondition(Dtc.identifyModule(seat) == nil)
        precondition(!DtcModule.seatDriver.isBase && !DtcModule.seatPassenger.isBase)
        precondition(DtcModule.wipers.fastInitTargets.contains(0x68))
        precondition(!DtcModule.onboardSupply.matchesIdentification("7L5937049CA".utf8.map(Int.init)))
        print("Verified \(plan.count) unique routes, 256 diagnostic address values, KWP reply validation and ECU identification.")
    }
}
