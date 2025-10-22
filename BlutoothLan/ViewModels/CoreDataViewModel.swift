//
//  DummyViewModel.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/22/25.
//

import Combine
import CoreBluetooth
import CoreData

final class CoreDataViewModel: ObservableObject {
    @Published private(set) var items: [DeviceEntity] = []
    
    let manager = CoreDataManager.instance
    
    init() {
        fetchDevices()
    }
    
    func fetchDevices() {
        let request = NSFetchRequest<DeviceEntity>(entityName: "DeviceEntity")
        
        Task {
            do {
                items = try manager.context.fetch(request)
            } catch let err {
                print("Something went wrong DummyViewModel: \(err.localizedDescription)")
            }
        }
    }
    
    func addDevice(new name: String) {
        let newDevice = DeviceEntity(context: manager.context)
        
        newDevice.name = name
        
        save()
    }
    
    func deleteDevice(at index: Int) {
        let entity = items[index]
        manager.context.delete(entity)
        save()
        
    }
    
    func save() {
        DispatchQueue.main.asyncAfter(deadline: .now()) {
            self.manager.save()
            self.fetchDevices()
        }
    }
    
}
