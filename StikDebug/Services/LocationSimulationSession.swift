import Foundation
import CoreLocation
import Combine

final class LocationSimulationSession: ObservableObject {
    static let shared = LocationSimulationSession()

    @Published private(set) var isActive = false
    @Published var isSendingCommand = false
    var preventsConnectionChanges: Bool { isActive || isSendingCommand }
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D]?
    private var resendTimer: Timer?
    private let resendGate = LocationResendGate()
    private var routeID: UUID?

    private init() {}

    func start(at coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        if !isActive {
            isActive = true
            BackgroundAudioManager.shared.requestStart()
        }
    }

    func startResending(at coordinate: CLLocationCoordinate2D, _ operation: @escaping (UUID) -> Void) {
        start(at: coordinate)
        resendTimer?.invalidate()
        let token = resendGate.replace()
        let timer = Timer(timeInterval: 4, repeats: true) { _ in operation(token) }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    func startRoute(at coordinate: CLLocationCoordinate2D, coordinates: [CLLocationCoordinate2D]) -> UUID {
        let routeID = UUID()
        self.routeID = routeID
        routeCoordinates = coordinates
        start(at: coordinate)
        return routeID
    }

    func isCurrentRoute(_ routeID: UUID) -> Bool {
        self.routeID == routeID
    }

    func clearRoute() {
        routeID = nil
        routeCoordinates = nil
    }

    func isCurrentResend(_ token: UUID) -> Bool { resendGate.isCurrent(token) }

    func pauseResending() {
        resendGate.invalidate()
        resendTimer?.invalidate()
        resendTimer = nil
    }

    func updateCoordinate(_ coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }

    func stop() {
        pauseResending()
        clearRoute()
        guard isActive else { return }
        isActive = false
        coordinate = nil
        BackgroundAudioManager.shared.requestStop()
    }
}
