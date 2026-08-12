//
//  ResourcesView.swift
//  DecoderSec
//
//  Created by NodePassProject on 5/2/26.
//

import SwiftUI

struct ResourcesView: View {
    var body: some View {
        Form {
            Section {
                ForEach(CoreType.allCases) { core in
                    NavigationLink {
                        DirectoryBrowserView(
                            url: ResourcesStore.directory(for: core),
                            title: core.displayName
                        )
                    } label: {
                        Label {
                            Text(core.displayName)
                        } icon: {
                            Image(core.rawValue)
                                .interpolation(.high)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 25, height: 25)
                        }
                    }
                }
            } footer: {
                Text("Files here live in the app sandbox. The Packet Tunnel extension uses a separate container — geo .dat files are downloaded automatically when you connect (see Diagnostics). App Group sharing is not enabled.")
            }
        }
        .navigationTitle("Resources")
        .navigationBarTitleDisplayMode(.inline)
    }
}
