//
//  DummyView.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/22/25.
//

import SwiftUI

struct DummyView: View {
    @StateObject var vm = DummyViewModel()
    
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
            .navigationTitle("Relationships")
            
            
        }
    }
    
    func delete(set: IndexSet) {
        for id in set {
            vm.deleteDevice(at: id)
        }
    }
}

#Preview {
    DummyView()
}
