//
//  LocalNotificationView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/23/25.
//

import SwiftUI
import UserNotifications

struct LocalNotificationView: View {
    
    var body: some View {
        VStack {
            Button {
                LocalNotificationManager.instance.requestAuthorization()
            } label: {
                Text("Request for Notification")
            }
            
            Button {
                LocalNotificationManager.instance.scheduleNotifications()
            } label: {
                Text("Trigger for 5 sec")
            }


        }
    }
}

#Preview {
    LocalNotificationView()
}
