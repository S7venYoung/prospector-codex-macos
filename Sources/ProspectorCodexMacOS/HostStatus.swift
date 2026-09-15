import Foundation

struct HostStatus {
    let unixTime: UInt32
    let temperatureDeciC: Int32
    let weatherCode: UInt32
    let observedAt: UInt32
}

enum HostStatusReader {
    static func read() -> HostStatus? {
        let defaults = UserDefaults.standard
        let clockEnabled = defaults.object(forKey: "prospector.syncClock") == nil || defaults.bool(forKey: "prospector.syncClock")
        let weatherEnabled = defaults.object(forKey: "prospector.syncWeather") == nil || defaults.bool(forKey: "prospector.syncWeather")
        guard clockEnabled || weatherEnabled else { return nil }
        let now = UInt32(Date().timeIntervalSince1970)
        guard weatherEnabled else {
            return HostStatus(unixTime: now, temperatureDeciC: 0, weatherCode: 255, observedAt: now)
        }
        let latitude = defaults.string(forKey: "prospector.weatherLatitude").flatMap(Double.init) ?? 31.2304
        let longitude = defaults.string(forKey: "prospector.weatherLongitude").flatMap(Double.init) ?? 121.4737
        let weather = WeatherClient.fetch(latitude: latitude, longitude: longitude)
        return HostStatus(unixTime: now, temperatureDeciC: weather.temperatureDeciC,
                          weatherCode: weather.code, observedAt: now)
    }
}

private enum WeatherClient {
    struct Reading { let temperatureDeciC: Int32; let code: UInt32 }

    static func fetch(latitude: Double, longitude: Double) -> Reading {
        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else {
            return Reading(temperatureDeciC: 0, code: 255)
        }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
        ]
        guard let url = components.url else { return Reading(temperatureDeciC: 0, code: 255) }
        let semaphore = DispatchSemaphore(value: 0)
        var result = Reading(temperatureDeciC: 0, code: 255)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let temperature = current["temperature_2m"] as? Double,
                  let code = current["weather_code"] as? NSNumber else { return }
            result = Reading(temperatureDeciC: Int32((temperature * 10).rounded()), code: code.uint32Value)
        }.resume()
        _ = semaphore.wait(timeout: .now() + 8)
        return result
    }
}
