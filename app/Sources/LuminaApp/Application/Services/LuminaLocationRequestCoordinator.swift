import CoreLocation
import Foundation

@MainActor
final class LuminaLocationRequestCoordinator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationRequest: (id: UUID, continuation: CheckedContinuation<CLAuthorizationStatus, Error>)?
    private var locationRequest: (id: UUID, continuation: CheckedContinuation<CLLocation, Error>)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocation {
        try Task.checkCancellation()
        guard CLLocationManager.locationServicesEnabled() else {
            throw AppToolError.permissionDenied("定位服务未开启。请在系统设置中打开定位服务后重试。")
        }
        let status = manager.authorizationStatus
        let authorizedStatus: CLAuthorizationStatus
        if status == .notDetermined {
            authorizedStatus = try await requestAuthorization()
        } else {
            authorizedStatus = status
        }
        switch authorizedStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            try Task.checkCancellation()
            return try await requestLocation()
        case .denied, .restricted:
            throw AppToolError.permissionDenied("定位权限已被拒绝。请在系统设置中允许 Lumina 使用位置后重试。")
        case .notDetermined:
            throw AppToolError.permissionDenied("定位权限尚未完成授权，请稍后重试。")
        @unknown default:
            throw AppToolError.permissionDenied("当前系统无法确认定位权限，请检查设置后重试。")
        }
    }

    private func requestAuthorization() async throws -> CLAuthorizationStatus {
        let result: Result<CLAuthorizationStatus, Error> = await LuminaPermissionTimingRecorder.shared.recordMainActorValue {
            do { return .success(try await waitForAuthorization()) }
            catch { return .failure(error) }
        }
        return try result.get()
    }

    private func waitForAuthorization() async throws -> CLAuthorizationStatus {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let status = try await withCheckedThrowingContinuation { continuation in
                authorizationRequest = (id, continuation)
                // The manager can become authorized between the initial check and registration.
                if manager.authorizationStatus == .notDetermined {
                    manager.requestWhenInUseAuthorization()
                } else {
                    finishAuthorization(.success(manager.authorizationStatus))
                }
            }
            try Task.checkCancellation()
            return status
        } onCancel: {
            Task { @MainActor in
                guard self.authorizationRequest?.id == id else { return }
                self.finishAuthorization(.failure(CancellationError()))
            }
        }
    }

    private func requestLocation() async throws -> CLLocation {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let location = try await withCheckedThrowingContinuation { continuation in
                locationRequest = (id, continuation)
                manager.requestLocation()
            }
            try Task.checkCancellation()
            return location
        } onCancel: {
            Task { @MainActor in
                guard self.locationRequest?.id == id else { return }
                self.manager.stopUpdatingLocation()
                self.finishLocation(.failure(CancellationError()))
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = self.manager.authorizationStatus
            // CLLocationManager sends an initial callback before the user makes a choice.
            guard status != .notDetermined else { return }
            finishAuthorization(.success(status))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let location = locations.last {
                finishLocation(.success(location))
            } else {
                finishLocation(.failure(AppToolError.unavailable("没有获取到当前位置，请稍后重试。")))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            finishLocation(.failure(error))
        }
    }

    private func finishAuthorization(_ result: Result<CLAuthorizationStatus, Error>) {
        let request = authorizationRequest
        authorizationRequest = nil
        request?.continuation.resume(with: result)
    }

    private func finishLocation(_ result: Result<CLLocation, Error>) {
        let request = locationRequest
        locationRequest = nil
        request?.continuation.resume(with: result)
    }
}
