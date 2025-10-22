//
//  LocalNotificationManager.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/23/25.
//

import UserNotifications

actor LocalNotificationManager {
    static let instance = LocalNotificationManager()
    
   nonisolated func requestAuthorization() {
        // We would require options like alert, sound, badge
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        
        // check for NotificaionCenter
        UNUserNotificationCenter.current().requestAuthorization(options: options) {_,err in
            if let safeErr = err {
                print("Err on notifications: \(safeErr)")
            } else {
                print("Success on notifications")
            }
        }
    }
    // MARK: Schudule Notification
   nonisolated func scheduleNotifications() {
        // Content
        let content = UNMutableNotificationContent()
        content.title = "this is local notifier motherfucker"
        content.sound = .defaultRingtone
        content.badge = 1
        
        // After Notification requst we'll ask you for trigger
        let timeTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 5.0, repeats: false)
        
        
        // Next we'll need Notification request
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                              content: content,
                              trigger: timeTrigger)
        
        // Add it thrhough User Notification center
        UNUserNotificationCenter.current().add(request)
        
    }
}
