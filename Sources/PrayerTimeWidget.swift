import AppKit
import CoreLocation
import PockKit

enum PrayerTimeKeys {
    static let method = "PrayerTimeWidget.method"
    static let language = "PrayerTimeWidget.language"
    static let locationMode = "PrayerTimeWidget.locationMode"
    static let manualLatitude = "PrayerTimeWidget.manualLatitude"
    static let manualLongitude = "PrayerTimeWidget.manualLongitude"
    static let defaultIqamaMinutes = "PrayerTimeWidget.defaultIqamaMinutes"
    static let maghribIqamaMinutes = "PrayerTimeWidget.maghribIqamaMinutes"
    static let scheduleCache = "PrayerTimeWidget.cachedSchedule"
    static let locationCache = "PrayerTimeWidget.cachedLocation"
}

extension Notification.Name {
    static let prayerTimeWidgetPreferencesChanged = Notification.Name("PrayerTimeWidget.preferencesChanged")
}

enum PrayerLanguage: String {
    case arabic = "ar"
    case english = "en"

    var locale: Locale {
        switch self {
        case .arabic:
            return Locale(identifier: "ar")
        case .english:
            return Locale(identifier: "en_US_POSIX")
        }
    }

    var isRightToLeft: Bool {
        return self == .arabic
    }
}

enum PrayerLocationMode: String {
    case automatic
    case manual
}

struct PrayerTimeSettings {
    let method: Int
    let language: PrayerLanguage
    let locationMode: PrayerLocationMode
    let manualLatitude: Double
    let manualLongitude: Double
    let defaultIqamaMinutes: Int
    let maghribIqamaMinutes: Int

    static let defaultMethod = 8
    static let defaultLanguage = PrayerLanguage.arabic
    static let defaultLocationMode = PrayerLocationMode.automatic
    static let defaultLatitude = 25.2048
    static let defaultLongitude = 55.2708
    static let defaultIqamaMinutes = 20
    static let defaultMaghribIqamaMinutes = 5

    static func load() -> PrayerTimeSettings {
        let defaults = UserDefaults.standard
        let language = PrayerLanguage(rawValue: defaults.string(forKey: PrayerTimeKeys.language) ?? "") ?? defaultLanguage
        let locationMode = PrayerLocationMode(rawValue: defaults.string(forKey: PrayerTimeKeys.locationMode) ?? "") ?? defaultLocationMode
        let method = clampedInt(defaults.object(forKey: PrayerTimeKeys.method) as? Int, defaultValue: defaultMethod, range: 1...23)
        let latitude = clampedDouble(defaults.object(forKey: PrayerTimeKeys.manualLatitude) as? Double, defaultValue: defaultLatitude, range: -90...90)
        let longitude = clampedDouble(defaults.object(forKey: PrayerTimeKeys.manualLongitude) as? Double, defaultValue: defaultLongitude, range: -180...180)
        let defaultIqama = clampedInt(
            defaults.object(forKey: PrayerTimeKeys.defaultIqamaMinutes) as? Int,
            defaultValue: defaultIqamaMinutes,
            range: 0...120
        )
        let maghribIqama = clampedInt(
            defaults.object(forKey: PrayerTimeKeys.maghribIqamaMinutes) as? Int,
            defaultValue: defaultMaghribIqamaMinutes,
            range: 0...120
        )

        return PrayerTimeSettings(
            method: method,
            language: language,
            locationMode: locationMode,
            manualLatitude: latitude,
            manualLongitude: longitude,
            defaultIqamaMinutes: defaultIqama,
            maghribIqamaMinutes: maghribIqama
        )
    }

    static func reset() {
        let defaults = UserDefaults.standard
        [
            PrayerTimeKeys.method,
            PrayerTimeKeys.language,
            PrayerTimeKeys.locationMode,
            PrayerTimeKeys.manualLatitude,
            PrayerTimeKeys.manualLongitude,
            PrayerTimeKeys.defaultIqamaMinutes,
            PrayerTimeKeys.maghribIqamaMinutes,
            PrayerTimeKeys.scheduleCache,
            PrayerTimeKeys.locationCache
        ].forEach(defaults.removeObject(forKey:))
        NotificationCenter.default.post(name: .prayerTimeWidgetPreferencesChanged, object: nil)
    }

    var manualCoordinate: CLLocationCoordinate2D? {
        guard (-90...90).contains(manualLatitude),
              (-180...180).contains(manualLongitude) else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: manualLatitude, longitude: manualLongitude)
    }

    func iqamaMinutes(for prayerKey: String) -> Int {
        return prayerKey == "Maghrib" ? maghribIqamaMinutes : defaultIqamaMinutes
    }

    private static func clampedInt(_ value: Int?, defaultValue: Int, range: ClosedRange<Int>) -> Int {
        guard let value = value else {
            return defaultValue
        }

        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clampedDouble(_ value: Double?, defaultValue: Double, range: ClosedRange<Double>) -> Double {
        guard let value = value, value.isFinite else {
            return defaultValue
        }

        return min(max(value, range.lowerBound), range.upperBound)
    }
}

public final class PrayerTimeWidget: NSObject, PKWidget {
    public static let identifier = "com.ghalebaldoboni.pock.prayertime"

    public var customizationLabel = "وقت الصلاة"
    public var view: NSView!

    private enum Defaults {
        static let refreshInterval: TimeInterval = 6 * 60 * 60
        static let cachedLocationMaxAge: TimeInterval = 24 * 60 * 60
        static let criticalIqamaThreshold: TimeInterval = 5 * 60
        static let retryInterval: TimeInterval = 60
    }

    private struct PrayerMoment: Codable {
        let key: String
        let date: Date
    }

    private struct CachedSchedule: Codable {
        let moments: [PrayerMoment]
        let timezoneIdentifier: String
        let fetchedAt: Date
    }

    private struct CachedLocation: Codable {
        let latitude: Double
        let longitude: Double
        let timestamp: Date
    }

    private struct AladhanResponse: Decodable {
        let code: Int
        let data: AladhanData
    }

    private struct AladhanData: Decodable {
        let timings: [String: String]
        let meta: AladhanMeta?
    }

    private struct AladhanMeta: Decodable {
        let timezone: String?
    }

    private let prayerNameLabel = NSTextField(labelWithString: "الصلاة")
    private let prayerTimeLabel = NSTextField(labelWithString: "--:--")
    private let detailLabel = NSTextField(labelWithString: "")
    private let criticalIqamaLabel = NSTextField(labelWithString: "")
    private let locationManager = CLLocationManager()

    private var timer: Timer?
    private var settings = PrayerTimeSettings.load()
    private var prayerMoments: [PrayerMoment] = []
    private var displayTimeZone = TimeZone.current
    private var lastFetchAt: Date?
    private var lastFetchAttemptAt: Date?
    private var currentLocation: CLLocation?
    private var isFetching = false
    private var isLocating = false

    public required override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        view = makeView()
        applyLanguageLayout()
        loadCachedState()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: .prayerTimeWidgetPreferencesChanged,
            object: nil
        )
        start()
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc public var imageForCustomization: NSImage {
        let image = NSImage(size: NSSize(width: 120, height: 30))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 30).fill()
        let text = settings.language == .arabic ? "العصر 3:40 PM" : "Asr 3:40 PM"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        text.draw(at: NSPoint(x: 8, y: 8), withAttributes: attributes)
        image.unlockFocus()
        return image
    }

    private func makeView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 132, height: 30))
        container.translatesAutoresizingMaskIntoConstraints = false

        let prayerStack = NSStackView(views: [prayerNameLabel, prayerTimeLabel])
        prayerStack.orientation = .horizontal
        prayerStack.alignment = .centerY
        prayerStack.distribution = .fill
        prayerStack.spacing = 6
        prayerStack.translatesAutoresizingMaskIntoConstraints = false

        [prayerNameLabel, prayerTimeLabel, detailLabel].forEach(configureLabel)
        prayerNameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        prayerTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        detailLabel.font = NSFont.systemFont(ofSize: 8, weight: .regular)

        configureLabel(criticalIqamaLabel)
        criticalIqamaLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        criticalIqamaLabel.alignment = .center
        criticalIqamaLabel.textColor = .systemRed
        criticalIqamaLabel.isHidden = true

        container.addSubview(prayerStack)
        container.addSubview(detailLabel)
        container.addSubview(criticalIqamaLabel)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 132),
            container.heightAnchor.constraint(equalToConstant: 30),

            prayerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            prayerStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            prayerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),

            detailLabel.leadingAnchor.constraint(equalTo: prayerStack.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: prayerStack.bottomAnchor, constant: -2),

            criticalIqamaLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            criticalIqamaLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            criticalIqamaLabel.topAnchor.constraint(equalTo: container.topAnchor),
            criticalIqamaLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func configureLabel(_ label: NSTextField) {
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.alignment = settings.language.isRightToLeft ? .right : .left
        label.baseWritingDirection = settings.language.isRightToLeft ? .rightToLeft : .leftToRight
    }

    private func applyLanguageLayout() {
        let isRTL = settings.language.isRightToLeft
        customizationLabel = isRTL ? "وقت الصلاة" : "Prayer Time"
        view.userInterfaceLayoutDirection = isRTL ? .rightToLeft : .leftToRight
        view.subviews.forEach { subview in
            subview.userInterfaceLayoutDirection = isRTL ? .rightToLeft : .leftToRight
        }
        [prayerNameLabel, prayerTimeLabel, detailLabel].forEach { label in
            label.alignment = isRTL ? .right : .left
            label.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
        }
    }

    private func start() {
        updateNextPrayer()
        fetchPrayerTimesIfNeeded(force: false)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        updateNextPrayer()
        fetchPrayerTimesIfNeeded(force: false)
    }

    @objc private func preferencesChanged() {
        settings = PrayerTimeSettings.load()
        applyLanguageLayout()
        currentLocation = nil
        prayerMoments = []
        lastFetchAt = nil
        lastFetchAttemptAt = nil
        displayTimeZone = TimeZone.current
        UserDefaults.standard.removeObject(forKey: PrayerTimeKeys.scheduleCache)
        loadCachedState()
        updateNextPrayer()
        fetchPrayerTimesIfNeeded(force: true)
    }

    private func fetchPrayerTimesIfNeeded(force: Bool) {
        let now = Date()
        guard ensureConfiguredLocation(showStatus: !hasDisplayablePrayer()) else {
            return
        }

        if !force,
           let lastFetchAt = lastFetchAt,
           now.timeIntervalSince(lastFetchAt) < Defaults.refreshInterval,
           !prayerMoments.isEmpty {
            return
        }

        if !force,
           let lastFetchAttemptAt = lastFetchAttemptAt,
           now.timeIntervalSince(lastFetchAttemptAt) < Defaults.retryInterval {
            return
        }

        if prayerMoments.isEmpty {
            fetchPrayerTimes(for: now)
            return
        }

        if force == false, settings.locationMode == .automatic {
            requestDeviceLocation()
            return
        }

        fetchPrayerTimes(for: now)
    }

    private func fetchPrayerTimes(for date: Date) {
        guard isFetching == false,
              let location = currentLocation,
              let url = makeTimingsURL(for: date, coordinate: location.coordinate) else {
            return
        }

        isFetching = true
        lastFetchAttemptAt = Date()
        if hasDisplayablePrayer() == false {
            setStatus(localizedStatus(arabic: "جار التحميل", english: "Loading"))
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else {
                return
            }

            defer {
                DispatchQueue.main.async {
                    self.isFetching = false
                }
            }

            if error != nil {
                DispatchQueue.main.async {
                    if self.hasDisplayablePrayer() == false {
                        self.setStatus(self.localizedStatus(arabic: "لا يوجد اتصال", english: "Offline"))
                    }
                }
                return
            }

            guard let data = data,
                  let response = try? JSONDecoder().decode(AladhanResponse.self, from: data),
                  response.code == 200 else {
                DispatchQueue.main.async {
                    if self.hasDisplayablePrayer() == false {
                        self.setStatus(self.localizedStatus(arabic: "لا توجد بيانات", english: "No data"))
                    }
                }
                return
            }

            let timezone = response.data.meta?.timezone.flatMap(TimeZone.init(identifier:)) ?? TimeZone.current
            let moments = self.makePrayerMoments(from: response.data.timings, on: date, in: timezone)

            DispatchQueue.main.async {
                let fetchedAt = Date()
                self.displayTimeZone = timezone
                self.lastFetchAt = fetchedAt
                self.prayerMoments = moments
                self.saveCachedSchedule(moments: moments, timezone: timezone, fetchedAt: fetchedAt)
                self.updateNextPrayer()
            }
        }.resume()
    }

    private func makeTimingsURL(for date: Date, coordinate: CLLocationCoordinate2D) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy"
        formatter.timeZone = displayTimeZone

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.aladhan.com"
        components.path = "/v1/timings/\(formatter.string(from: date))"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), coordinate.longitude)),
            URLQueryItem(name: "method", value: String(settings.method))
        ]

        return components.url
    }

    private func makePrayerMoments(from timings: [String: String], on date: Date, in timezone: TimeZone) -> [PrayerMoment] {
        let prayers = ["Fajr", "Dhuhr", "Asr", "Maghrib", "Isha"]
        return prayers.compactMap { key in
            guard let time = timings[key], let parsed = parsePrayerDate(time, on: date, in: timezone) else {
                return nil
            }
            return PrayerMoment(key: key, date: parsed)
        }.sorted { $0.date < $1.date }
    }

    private func prayerName(for key: String) -> String {
        if settings.language == .english {
            return key == "Dhuhr" ? "Dhuhr" : key
        }

        switch key {
        case "Fajr":
            return "الفجر"
        case "Dhuhr":
            return "الظهر"
        case "Asr":
            return "العصر"
        case "Maghrib":
            return "المغرب"
        case "Isha":
            return "العشاء"
        default:
            return key
        }
    }

    private func parsePrayerDate(_ value: String, on date: Date, in timezone: TimeZone) -> Date? {
        let time = value.prefix { character in
            character.isNumber || character == ":"
        }
        guard time.count >= 4 else {
            return nil
        }

        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = parts[0]
        components.minute = parts[1]
        components.second = 0
        return calendar.date(from: components)
    }

    private func updateNextPrayer() {
        let now = Date()

        guard prayerMoments.isEmpty == false else {
            if isFetching == false {
                setStatus(localizedStatus(arabic: "جار التحميل", english: "Loading"))
            }
            return
        }

        if let iqama = activeIqamaMoment(at: now) {
            renderIqama(prayer: iqama.prayer, remaining: iqama.remaining)
            return
        }

        if let next = prayerMoments.first(where: { $0.date > now }) {
            renderUpcoming(next)
            return
        }

        if isFetching == false {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
            fetchPrayerTimes(for: tomorrow)
        }
    }

    private func activeIqamaMoment(at date: Date) -> (prayer: PrayerMoment, remaining: TimeInterval)? {
        guard let current = prayerMoments.last(where: { $0.date <= date }) else {
            return nil
        }

        let iqamaEnd = current.date.addingTimeInterval(TimeInterval(settings.iqamaMinutes(for: current.key) * 60))
        guard date < iqamaEnd else {
            return nil
        }

        return (current, iqamaEnd.timeIntervalSince(date))
    }

    private func hasDisplayablePrayer() -> Bool {
        let now = Date()
        return activeIqamaMoment(at: now) != nil || prayerMoments.contains { $0.date > now }
    }

    private func ensureConfiguredLocation(showStatus: Bool) -> Bool {
        if settings.locationMode == .manual {
            guard let coordinate = settings.manualCoordinate else {
                if showStatus {
                    setStatus(localizedStatus(arabic: "موقع غير صحيح", english: "Bad location"))
                }
                return false
            }

            currentLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return true
        }

        guard currentLocation != nil else {
            if useRecentSystemLocationIfAvailable() {
                return true
            }

            requestDeviceLocation()
            return false
        }

        return true
    }

    private func requestDeviceLocation() {
        guard settings.locationMode == .automatic else {
            _ = ensureConfiguredLocation(showStatus: true)
            return
        }

        guard CLLocationManager.locationServicesEnabled() else {
            if hasDisplayablePrayer() == false {
                setStatus(localizedStatus(arabic: "الموقع مغلق", english: "Location off"))
            }
            return
        }

        switch CLLocationManager.authorizationStatus() {
        case .notDetermined:
            if hasDisplayablePrayer() == false {
                setStatus(localizedStatus(arabic: "اسمح بالموقع", english: "Allow location"))
            }
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if currentLocation == nil, useRecentSystemLocationIfAvailable() {
                fetchPrayerTimesIfNeeded(force: true)
            }

            guard isLocating == false else {
                return
            }

            if hasDisplayablePrayer() == false {
                setStatus(localizedStatus(arabic: "تحديد الموقع", english: "Locating"))
            }
            isLocating = true
            locationManager.requestLocation()
        case .denied, .restricted:
            if hasDisplayablePrayer() == false {
                setStatus(localizedStatus(arabic: "لا يوجد موقع", english: "No location"))
            }
        @unknown default:
            if hasDisplayablePrayer() == false {
                setStatus(localizedStatus(arabic: "لا يوجد موقع", english: "No location"))
            }
        }
    }

    private func useRecentSystemLocationIfAvailable() -> Bool {
        guard let location = locationManager.location,
              location.horizontalAccuracy >= 0,
              Date().timeIntervalSince(location.timestamp) <= Defaults.cachedLocationMaxAge else {
            return false
        }

        currentLocation = location
        saveCachedLocation(location)
        return true
    }

    private func renderUpcoming(_ prayer: PrayerMoment) {
        setCriticalIqamaVisible(false)
        prayerNameLabel.stringValue = prayerName(for: prayer.key)
        prayerTimeLabel.stringValue = timeString(from: prayer.date)

        let minutes = max(0, Int(prayer.date.timeIntervalSince(Date()) / 60))
        if settings.language == .arabic {
            detailLabel.stringValue = minutes >= 60
                ? "بعد \(minutes / 60)س \(minutes % 60)د"
                : "بعد \(minutes)د"
        } else {
            detailLabel.stringValue = minutes >= 60
                ? "in \(minutes / 60)h \(minutes % 60)m"
                : "in \(minutes)m"
        }
    }

    private func renderIqama(prayer: PrayerMoment, remaining: TimeInterval) {
        if remaining <= Defaults.criticalIqamaThreshold {
            criticalIqamaLabel.stringValue = countdownString(from: remaining)
            setCriticalIqamaVisible(true)
            return
        }

        setCriticalIqamaVisible(false)
        prayerNameLabel.stringValue = localizedStatus(arabic: "الإقامة:", english: "Iqama:")
        prayerTimeLabel.stringValue = countdownString(from: remaining)
        detailLabel.stringValue = ""
    }

    private func setCriticalIqamaVisible(_ visible: Bool) {
        criticalIqamaLabel.isHidden = !visible
        prayerNameLabel.isHidden = visible
        prayerTimeLabel.isHidden = visible
        detailLabel.isHidden = visible
        prayerNameLabel.textColor = .white
        prayerTimeLabel.textColor = .white
        detailLabel.textColor = .white
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = displayTimeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func countdownString(from remaining: TimeInterval) -> String {
        let totalSeconds = max(0, Int(ceil(remaining)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func localizedStatus(arabic: String, english: String) -> String {
        return settings.language == .arabic ? arabic : english
    }

    private func setStatus(_ status: String) {
        setCriticalIqamaVisible(false)
        prayerNameLabel.stringValue = status
        prayerTimeLabel.stringValue = "--:--"
        detailLabel.stringValue = ""
    }

    private func loadCachedState() {
        if settings.locationMode == .manual, let coordinate = settings.manualCoordinate {
            currentLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        } else if let cachedLocation = loadCachedLocation() {
            currentLocation = CLLocation(
                latitude: cachedLocation.latitude,
                longitude: cachedLocation.longitude
            )
        }

        guard let data = UserDefaults.standard.data(forKey: PrayerTimeKeys.scheduleCache),
              let cached = try? JSONDecoder().decode(CachedSchedule.self, from: data),
              let timezone = TimeZone(identifier: cached.timezoneIdentifier),
              cached.moments.isEmpty == false else {
            return
        }

        displayTimeZone = timezone
        lastFetchAt = cached.fetchedAt
        prayerMoments = cached.moments
    }

    private func loadCachedLocation() -> CachedLocation? {
        guard let data = UserDefaults.standard.data(forKey: PrayerTimeKeys.locationCache),
              let cached = try? JSONDecoder().decode(CachedLocation.self, from: data),
              Date().timeIntervalSince(cached.timestamp) <= Defaults.cachedLocationMaxAge else {
            return nil
        }

        return cached
    }

    private func saveCachedSchedule(moments: [PrayerMoment], timezone: TimeZone, fetchedAt: Date) {
        let cached = CachedSchedule(
            moments: moments,
            timezoneIdentifier: timezone.identifier,
            fetchedAt: fetchedAt
        )

        guard let data = try? JSONEncoder().encode(cached) else {
            return
        }

        UserDefaults.standard.set(data, forKey: PrayerTimeKeys.scheduleCache)
    }

    private func saveCachedLocation(_ location: CLLocation) {
        let cached = CachedLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp
        )

        guard let data = try? JSONEncoder().encode(cached) else {
            return
        }

        UserDefaults.standard.set(data, forKey: PrayerTimeKeys.locationCache)
    }
}

extension PrayerTimeWidget: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            if hasDisplayablePrayer() == false {
                setStatus(localizedStatus(arabic: "لا يوجد موقع", english: "No location"))
            }
        case .notDetermined:
            if hasDisplayablePrayer() == false {
                setStatus(localizedStatus(arabic: "اسمح بالموقع", english: "Allow location"))
            }
        @unknown default:
            if hasDisplayablePrayer() == false {
                setStatus(localizedStatus(arabic: "لا يوجد موقع", english: "No location"))
            }
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        isLocating = false

        guard settings.locationMode == .automatic else {
            fetchPrayerTimesIfNeeded(force: true)
            return
        }

        guard let location = locations.last else {
            if hasDisplayablePrayer() == false {
                setStatus(localizedStatus(arabic: "لا يوجد موقع", english: "No location"))
            }
            return
        }

        currentLocation = location
        saveCachedLocation(location)
        fetchPrayerTimesIfNeeded(force: true)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isLocating = false

        if currentLocation != nil {
            fetchPrayerTimesIfNeeded(force: true)
        } else if hasDisplayablePrayer() == false {
            setStatus(localizedStatus(arabic: "الموقع", english: "Location"))
        }
    }
}

public final class PrayerTimeWidgetPreferences: NSViewController, PKWidgetPreference {
    public static var nibName: NSNib.Name {
        return NSNib.Name("PrayerTimeWidgetPreferences")
    }

    private let languagePopup = NSPopUpButton()
    private let locationModePopup = NSPopUpButton()
    private let latitudeField = NSTextField(string: "")
    private let longitudeField = NSTextField(string: "")
    private let methodField = NSTextField(string: "")
    private let defaultIqamaField = NSTextField(string: "")
    private let maghribIqamaField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        view.translatesAutoresizingMaskIntoConstraints = false
        buildView()
        loadSettingsIntoControls()
    }

    public func reset() {
        PrayerTimeSettings.reset()
        loadSettingsIntoControls()
        showStatus("Reset to defaults")
    }

    private func buildView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Prayer Time")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)

        configurePopup(languagePopup, items: [
            ("Arabic / العربية", 0),
            ("English", 1)
        ])
        configurePopup(locationModePopup, items: [
            ("Use device location", 0),
            ("Manual coordinates", 1)
        ])

        [latitudeField, longitudeField, methodField, defaultIqamaField, maghribIqamaField].forEach(configureTextField)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(makeRow(title: "Language", control: languagePopup))
        stack.addArrangedSubview(makeRow(title: "Location", control: locationModePopup))
        stack.addArrangedSubview(makeRow(title: "Latitude", control: latitudeField))
        stack.addArrangedSubview(makeRow(title: "Longitude", control: longitudeField))
        stack.addArrangedSubview(makeRow(title: "AlAdhan method", control: methodField))
        stack.addArrangedSubview(makeRow(title: "Iqama minutes", control: defaultIqamaField))
        stack.addArrangedSubview(makeRow(title: "Maghrib iqama", control: maghribIqamaField))
        stack.addArrangedSubview(saveButton)
        stack.addArrangedSubview(statusLabel)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18)
        ])
    }

    private func configurePopup(_ popup: NSPopUpButton, items: [(String, Int)]) {
        popup.removeAllItems()
        items.forEach { title, tag in
            popup.addItem(withTitle: title)
            popup.lastItem?.tag = tag
        }
        popup.widthAnchor.constraint(equalToConstant: 190).isActive = true
    }

    private func configureTextField(_ field: NSTextField) {
        field.widthAnchor.constraint(equalToConstant: 190).isActive = true
        field.alignment = .left
        field.lineBreakMode = .byTruncatingTail
    }

    private func makeRow(title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 130).isActive = true
        label.alignment = .right

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func loadSettingsIntoControls() {
        let settings = PrayerTimeSettings.load()
        languagePopup.selectItem(withTag: settings.language == .arabic ? 0 : 1)
        locationModePopup.selectItem(withTag: settings.locationMode == .automatic ? 0 : 1)
        latitudeField.stringValue = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), settings.manualLatitude)
        longitudeField.stringValue = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), settings.manualLongitude)
        methodField.stringValue = "\(settings.method)"
        defaultIqamaField.stringValue = "\(settings.defaultIqamaMinutes)"
        maghribIqamaField.stringValue = "\(settings.maghribIqamaMinutes)"
    }

    @objc private func save() {
        guard let method = validatedInt(methodField.stringValue, range: 1...23),
              let defaultIqama = validatedInt(defaultIqamaField.stringValue, range: 0...120),
              let maghribIqama = validatedInt(maghribIqamaField.stringValue, range: 0...120),
              let latitude = validatedDouble(latitudeField.stringValue, range: -90...90),
              let longitude = validatedDouble(longitudeField.stringValue, range: -180...180) else {
            NSSound.beep()
            showStatus("Check the values and save again.")
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(method, forKey: PrayerTimeKeys.method)
        defaults.set(languagePopup.selectedTag() == 0 ? PrayerLanguage.arabic.rawValue : PrayerLanguage.english.rawValue, forKey: PrayerTimeKeys.language)
        defaults.set(locationModePopup.selectedTag() == 0 ? PrayerLocationMode.automatic.rawValue : PrayerLocationMode.manual.rawValue, forKey: PrayerTimeKeys.locationMode)
        defaults.set(latitude, forKey: PrayerTimeKeys.manualLatitude)
        defaults.set(longitude, forKey: PrayerTimeKeys.manualLongitude)
        defaults.set(defaultIqama, forKey: PrayerTimeKeys.defaultIqamaMinutes)
        defaults.set(maghribIqama, forKey: PrayerTimeKeys.maghribIqamaMinutes)
        defaults.removeObject(forKey: PrayerTimeKeys.scheduleCache)
        defaults.synchronize()

        NotificationCenter.default.post(name: .prayerTimeWidgetPreferencesChanged, object: nil)
        showStatus("Saved. The widget will refresh now.")
    }

    private func validatedInt(_ value: String, range: ClosedRange<Int>) -> Int? {
        guard let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              range.contains(parsed) else {
            return nil
        }

        return parsed
    }

    private func validatedDouble(_ value: String, range: ClosedRange<Double>) -> Double? {
        guard let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed.isFinite,
              range.contains(parsed) else {
            return nil
        }

        return parsed
    }

    private func showStatus(_ value: String) {
        statusLabel.stringValue = value
    }
}
