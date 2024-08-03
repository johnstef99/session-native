import Foundation
import SwiftUI

struct ConversationsToolbar: ToolbarContent {
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject var viewManager: ViewManager
  
  var body: some ToolbarContent {
    ToolbarItem {
      Spacer()
    }
    ToolbarItem {
      Button {
        withAnimation {
          viewManager.searchVisible.toggle()
        }
      } label: {
        Label("Search", systemImage: "magnifyingglass")
      }
      .if(viewManager.searchVisible, { view in
        view
          .background(Color.accentColor)
          .cornerRadius(5)
      })
    }
    ToolbarItem {
      Button(
        action: {
          if(viewManager.navigationSelection == "new") {
            viewManager.setActiveNavigationSelection(nil)
          } else {
            viewManager.setActiveNavigationSelection("new")
          }
        }
      ) {
        Label("New conversation", systemImage: "square.and.pencil")
      }
      .if(viewManager.navigationSelection == "new", { view in
        view
          .background(Color.accentColor)
          .cornerRadius(5)
      })
    }
  }
}
