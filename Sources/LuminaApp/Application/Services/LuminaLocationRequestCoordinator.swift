import CoreLocation
import Foundation

@MainActor
final class LuminaLocationRequestCoordinator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw AppToolError.permissionDenied("定位服务未开启。请在系统设置中打开定位服务后重试。")
        }
        let status = manager.authorizationStatus
        let authorizedStatus: CLAuthorizationStatus
        if status == .notDetermined {
            authorizedStatus = await requestAuthorization()
        } else {
            authorizedStatus = status
        }
        switch authorizedStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return try await requestLocation()
        case .denied, .restricted:
            throw AppToolError.permissionDenied("定位权限已被拒绝。请在系统设置中允许 Lumina 使用位置后重试。")
        case .notDetermined:
            throw AppToolError.permissionDenied("定位权限尚未完成授权，请稍后重试。")
        @unknown default:
            throw AppToolError.permissionDenied("当前系统无法确认定位权限，请检查设置后重试。")
        }
    }

    private func requestAuthorization() async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    private func requestLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            authorizationContinuation?.resume(returning: status)
            authorizationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let location = locations.last {
                locationContinuation?.resume(returning: location)
            } else {
                locationContinuation?.resume(throwing: AppToolError.permissionDenied("没有获取到当前位置，请稍后重试。"))
            }
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationContinuation?.resume(throwing: error)
            locationContinuation = nil
        }
    }
}
