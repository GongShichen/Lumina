import LuminaAgentClient
import Foundation

#if canImport(CoreLocation)
import CoreLocation
#endif

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(WeatherKit)
import WeatherKit
#endif

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(HealthKit)
import HealthKit
#endif

enum LuminaWeatherHealthExecutor {
    static func currentWeather(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(WeatherKit) && canImport(CoreLocation)
        let location = CLLocation(
            latitude: arguments.number("latitude") ?? 37.3349,
            longitude: arguments.number("longitude") ?? -122.0090
        )
        let weather = try await WeatherService.shared.weather(for: location)
        let current = weather.currentWeather
        let summary = "当前天气：\(current.condition.description)，温度 \(current.temperature.formatted())。"
        return result("weather.current", status: .succeeded, message: "\(summary)\n\nWeather data by Apple Weather.", output: [
            "condition": .string(current.condition.description),
            "temperature": .string(current.temperature.formatted()),
            "attribution": .string("Weather data by Apple Weather")
        ])
        #else
        return result("weather.current", status: .failed, message: "当前平台没有可用的 WeatherKit。", output: ["unavailable": .bool(true)])
        #endif
    }

    static func forecastWeather(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(WeatherKit) && canImport(CoreLocation)
        let location = CLLocation(
            latitude: arguments.number("latitude") ?? 37.3349,
            longitude: arguments.number("longitude") ?? -122.0090
        )
        let days = max(1, min(10, Int(arguments.number("days") ?? 3)))
        let weather = try await WeatherService.shared.weather(for: location)
        let daily = weather.dailyForecast.prefix(days).map { forecast in
            "\(forecast.date.formatted(date: .abbreviated, time: .omitted))：\(forecast.condition.description)，\(forecast.highTemperature.formatted()) / \(forecast.lowTemperature.formatted())"
        }
        let summary = daily.isEmpty ? "没有拿到天气预报。" : daily.joined(separator: "\n")
        return result("weather.forecast", status: .succeeded, message: "\(summary)\n\nWeather data by Apple Weather.", output: [
            "days": .array(daily.map(LuminaJSONValue.string)),
            "attribution": .string("Weather data by Apple Weather")
        ])
        #else
        return result("weather.forecast", status: .failed, message: "当前平台没有可用的 WeatherKit。", output: ["unavailable": .bool(true)])
        #endif
    }

    static func healthSummary(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            return result("health.summary", status: .failed, message: "当前设备不支持 HealthKit。", output: ["unavailable": .bool(true)])
        }
        let store = HKHealthStore()
        let types = healthReadTypes()
        try await LuminaPermissionTimingRecorder.shared.record {
            try await store.requestAuthorization(toShare: [], read: types)
        }
        let end = date(arguments.string("endDateISO")) ?? Date()
        let start = date(arguments.string("startDateISO")) ?? Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end.addingTimeInterval(-86_400)
        var output: [String: LuminaJSONValue] = [
            "startDateISO": .string(iso(start)),
            "endDateISO": .string(iso(end))
        ]
        if let steps = try await quantitySum(.stepCount, unit: .count(), store: store, start: start, end: end) {
            output["steps"] = .number(steps)
        }
        if let distance = try await quantitySum(.distanceWalkingRunning, unit: .meter(), store: store, start: start, end: end) {
            output["walkingRunningDistanceMeters"] = .number(distance)
        }
        if let energy = try await quantitySum(.activeEnergyBurned, unit: .kilocalorie(), store: store, start: start, end: end) {
            output["activeEnergyKcal"] = .number(energy)
        }
        if let flights = try await quantitySum(.flightsClimbed, unit: .count(), store: store, start: start, end: end) {
            output["flightsClimbed"] = .number(flights)
        }
        if let heart = try await quantityAverage(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), store: store, start: start, end: end) {
            output["averageHeartRateBPM"] = .number(heart)
        }
        let summary = "已读取 HealthKit 健康摘要。不会自动保存到本地记忆。"
        return result("health.summary", status: .succeeded, message: summary, output: output)
        #else
        return result("health.summary", status: .failed, message: "当前平台没有可用的 HealthKit。", output: ["unavailable": .bool(true)])
        #endif
    }

    static func healthSamples(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        #if os(iOS) && !targetEnvironment(macCatalyst) && canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            return result("health.query_samples", status: .failed, message: "当前设备不支持 HealthKit。", output: ["unavailable": .bool(true)])
        }
        let store = HKHealthStore()
        let types = healthReadTypes()
        try await LuminaPermissionTimingRecorder.shared.record {
            try await store.requestAuthorization(toShare: [], read: types)
        }
        let metric = arguments.string("metric") ?? "steps"
        let end = date(arguments.string("endDateISO")) ?? Date()
        let start = date(arguments.string("startDateISO")) ?? Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end.addingTimeInterval(-86_400)
        let value: Double?
        switch metric {
        case "heartRate":
            value = try await quantityAverage(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), store: store, start: start, end: end)
        case "activeEnergy":
            value = try await quantitySum(.activeEnergyBurned, unit: .kilocalorie(), store: store, start: start, end: end)
        case "distance":
            value = try await quantitySum(.distanceWalkingRunning, unit: .meter(), store: store, start: start, end: end)
        default:
            value = try await quantitySum(.stepCount, unit: .count(), store: store, start: start, end: end)
        }
        guard let value else {
            return result("health.query_samples", status: .succeeded, message: "没有读取到 \(metric) 数据。", output: ["metric": .string(metric), "samples": .array([])])
        }
        return result("health.query_samples", status: .succeeded, message: "\(metric)：\(value)", output: ["metric": .string(metric), "value": .number(value)])
        #else
        return result("health.query_samples", status: .failed, message: "当前平台没有可用的 HealthKit。", output: ["unavailable": .bool(true)])
        #endif
    }

    private static func result(_ tool: String, status: LuminaToolResultStatus, message: String, output: [String: LuminaJSONValue]) -> LuminaToolResult {
        LuminaToolResult(
            callID: UUID(),
            toolName: tool,
            status: status,
            output: output.merging(["summary": .string(message)]) { current, _ in current },
            content: [.markdown(message)],
            errorMessage: status == .failed ? message : nil
        )
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(HealthKit)
private func healthReadTypes() -> Set<HKObjectType> {
    [
        HKObjectType.quantityType(forIdentifier: .stepCount),
        HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning),
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
        HKObjectType.quantityType(forIdentifier: .flightsClimbed),
        HKObjectType.quantityType(forIdentifier: .heartRate),
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
        HKObjectType.workoutType()
    ].compactMap { $0 }.reduce(into: Set<HKObjectType>()) { $0.insert($1) }
}

private func quantitySum(
    _ identifier: HKQuantityTypeIdentifier,
    unit: HKUnit,
    store: HKHealthStore,
    start: Date,
    end: Date
) async throws -> Double? {
    guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
    return try await withCheckedThrowingContinuation { continuation in
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            }
        }
        store.execute(query)
    }
}

private func quantityAverage(
    _ identifier: HKQuantityTypeIdentifier,
    unit: HKUnit,
    store: HKHealthStore,
    start: Date,
    end: Date
) async throws -> Double? {
    guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
    return try await withCheckedThrowingContinuation { continuation in
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage) { _, statistics, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: statistics?.averageQuantity()?.doubleValue(for: unit))
            }
        }
        store.execute(query)
    }
}
#endif
