//
//  DummyView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/22/25.
//

import SwiftUI

struct CoreDataView: View {
    @StateObject var vm = CoreDataViewModel()
    
    var body: some View {
        NavigationView {
            List(content: {
                Section(header: Text("Add")
                    .onTapGesture {
                        vm.addDevice(new: "new one")
                    }) {
                        ForEach(vm.items, id: \.self) { item in
                            Text(item.name ?? "Unknown")
                        }.onDelete(perform: delete)
                    }
            })
            .navigationTitle("CoreData fetch")
            
        }
    }
    
    func delete(set: IndexSet) {
        for id in set {
            vm.deleteDevice(at: id)
        }
    }
}

#Preview {
    CoreDataView()
}
