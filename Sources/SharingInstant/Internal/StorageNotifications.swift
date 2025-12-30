import Foundation

enum StorageNotifications {
  static let stateDidChange = Notification.Name("SharingInstant.storage.stateDidChange")

  static let appIDKey = "appID"
  static let pathKey = "path"

  static func postStateDidChange(appID: String, path: String?) {
    var userInfo: [String: Any] = [appIDKey: appID]
    if let path {
      userInfo[pathKey] = path
    }
    NotificationCenter.default.post(name: stateDidChange, object: nil, userInfo: userInfo)
  }
}

