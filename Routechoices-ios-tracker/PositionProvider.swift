import UIKit
import CoreLocation

class PositionProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
 
    var locationManager: CLLocationManager
    var lastLocation: CLLocation?
    @Published var lastTimeSinceFix: Double
    var locBuffer: [Position]
    var deviceId: String
    var timer: Timer
    @Published var started: Bool
    var pendingStart = false
    var flushInterval = 5.0
    var currentTask: URLSessionDataTask?
    
    override init() {
        let userDefaults = UserDefaults.standard
        deviceId = userDefaults.string(forKey: "device_id_preference") ?? ""
        locBuffer = []
        locationManager = CLLocationManager()
        timer = Timer()
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.allowsBackgroundLocationUpdates = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        started = false
        lastTimeSinceFix = 60
        super.init()

        locationManager.delegate = self
    }
    
    @objc func flushBuffer() {
        let nPos = self.locBuffer.count
        print("Flushing ", nPos)
        if (nPos == 0) {
            return
        }
        if (self.currentTask != nil) {
            self.currentTask!.cancel()
            self.currentTask = nil
        }
        
        let maxPos = min(nPos, 300)
        let bufferChunk = self.locBuffer[..<maxPos]
        
        let session = URLSession.shared
        var request = URLRequest(url: URL(string: "https://api.routechoices.com/locations")!)
        request.httpMethod = "POST"
        
        var lats = ""
        var lons = ""
        var times = ""
        let batt = Int(round(UIDevice.current.batteryLevel * 100))
        
        for loc in bufferChunk {
            lats += String(describing: loc.latitude) + ","
            lons += String(describing: loc.longitude) + ","
            times += String(describing: loc.time.timeIntervalSince1970) + ","
        }
        
        let userDefaults = UserDefaults.standard
        self.deviceId = userDefaults.string(forKey: "device_id_preference") ?? ""
        
        var params: [String:Any] = ["latitudes": lats, "longitudes": lons, "timestamps": times, "device_id": self.deviceId]
        if (batt >= 0 && batt <= 100) {
            params["battery"] = batt
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: params)
        } catch _ {
            return
        }
        
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let secret = Bundle.main.infoDictionary?["POST_LOCATION_SECRET"] as! String
        request.addValue("Bearer " + secret, forHTTPHeaderField: "Authorization")

        let task = session.dataTask(with: request, completionHandler: {(data, response, error) -> Void in
            self.currentTask = nil
            if let httpResponse = response as? HTTPURLResponse {
                if (httpResponse.statusCode == 201) {
                    let nPos = self.locBuffer.count
                    let maxPos = min(nPos, 300)
                    self.locBuffer = Array(self.locBuffer[maxPos...])
                    print("Positions sent ", Date())
                    if (maxPos < nPos) {
                        self.flushBuffer()
                    }
                }
            }
        })
        self.currentTask = task
        task.resume()
    }

    func startUpdates() {
        let manager = CLLocationManager()

        switch manager.authorizationStatus {
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
            timer = Timer.scheduledTimer(timeInterval: flushInterval, target: self, selector: #selector(flushBuffer), userInfo: nil, repeats: true)
        default:
            pendingStart = true
            locationManager.requestAlwaysAuthorization()
        }
        
        DispatchQueue.main.async {
            self.started = true
        }
    }
    
    func stopUpdates() {
        locationManager.stopUpdatingLocation()
        timer.invalidate()
        self.flushBuffer()
        
        DispatchQueue.main.async {
            self.started = false
        }
        
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            if pendingStart {
                pendingStart = false
                locationManager.startUpdatingLocation()
                timer = Timer.scheduledTimer(timeInterval: flushInterval, target: self, selector: #selector(flushBuffer), userInfo: nil, repeats: true)
            }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            if location.horizontalAccuracy <= 50 {
                let position = Position(location)
                locBuffer.append(position)
                print("TS: " + String(describing: position.time))
                if lastLocation == nil || location.timestamp.timeIntervalSince(lastLocation!.timestamp) >= 1 {
                    lastLocation = location
                }
            }
            DispatchQueue.main.async {
                self.lastTimeSinceFix = location.timestamp.timeIntervalSince(self.lastLocation!.timestamp)
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    }

}
