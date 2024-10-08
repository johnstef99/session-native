import Foundation
import SwiftUI
import SwiftData
import MessagePack
import UniformTypeIdentifiers

struct ConversationView: View {
  @Environment(\.modelContext) var modelContext
  @EnvironmentObject var viewManager: ViewManager
  @EnvironmentObject var userManager: UserManager
  @State var conversationModel: Conversation?
  @State var showProfilePopover: Bool = false
  
  private func fetchConversation() {
    if let conversationId = viewManager.navigationSelection {
      if let conversationUuid = UUID(uuidString: conversationId) {
        if let conversation = try? modelContext.fetch(
          FetchDescriptor(predicate: #Predicate<Conversation> { conversation in
            conversation.id == conversationUuid
          })
        ).first {
          conversationModel = conversation
          conversationModel?.unreadMessages = 0
          let unreadMessages = conversation.messages!.filter({ msg in
            msg.from != nil && msg.read == false && msg.timestamp != nil
          })
          .map({ msg in
            MessagePackValue.int(msg.timestamp!)
          })
          
          let privacySettings_showReadCheckmarks = UserDefaults.standard.optionalBool(forKey: "sendReadCheckmarks_" + conversation.id.uuidString)
            ?? UserDefaults.standard.optionalBool(forKey: "sendReadCheckmarksByDefault")
            ?? true
          if !unreadMessages.isEmpty && privacySettings_showReadCheckmarks {
            request([
              "type": "mark_as_read",
              "conversation": .string(conversation.recipient.sessionId),
              "messagesTimestamps": .array(unreadMessages)
            ])
          }
        }
      } else {
        conversationModel = nil
      }
    } else {
      conversationModel = nil
    }
  }
  
  var body: some View {
    Group {
      if let conversation = conversationModel {
        Group {
          Messages(
            context: modelContext,
            userManager: userManager,
            conversation: conversation
          )
          .navigationTitle(conversation.contact?.name ?? conversation.recipient.displayName ?? getSessionIdPlaceholder(sessionId: conversation.recipient.sessionId))
          .background(Color.conversationDefaultBackground)
        }
        .toolbar {
          ToolbarItem(placement: .navigation) {
            ProfileView(
              conversation: conversation,
              showProfilePopover: $showProfilePopover
            )
          }
          ToolbarItem() {
            Button {
              
            } label: {
              Image(systemName: "phone")
            }
          }
        }
      } else {
        Text("Conversation not found")
          .foregroundStyle(Color.gray)
      }
    }
    .onAppear {
      fetchConversation()
    }
    .onChange(of: viewManager.navigationSelection) {
      fetchConversation()
    }
  }
}

struct Messages: View {
  @Environment(\.modelContext) var modelContext
  var userManager: UserManager
  var conversation: Conversation
  @StateObject private var viewModel: MessageViewModel
  @State var dragndropVisible: Bool = false
  
  init(context: ModelContext, userManager: UserManager, conversation: Conversation) {
    self.userManager = userManager
    self.conversation = conversation
    _viewModel = StateObject(
      wrappedValue: MessageViewModel(
        context: context,
        conversation: conversation
      )
    )
  }
  
  var body: some View {
    VStack {
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack {
            Spacer()
              .frame(height: 12)
              .onAppear() {
                if(viewModel.items.count > 10) {
                  viewModel.fetchItems()
                }
              }
            ForEach(viewModel.items) { message in
              ChatMessage(
                message,
                scrollProxy: proxy,
                viewModel: viewModel
              )
            }
            if conversation.typingIndicator {
              HStack(alignment: .center) {
                Text("typing")
                  .foregroundStyle(Color.gray)
                TypingIndicatorView(size: 6)
                  .padding(.top, 2)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 2)
              .padding(.leading, 12)
            }
            Spacer()
              .id("ConversationBottom")
          }
          .padding(.horizontal, 10)
        }
        .onChange(of: conversation) { oldConversation, newConversation in
          if(oldConversation.persistentModelID != newConversation.persistentModelID) {
            viewModel.updateConversation(newConversation)
          }
        }
        .onChange(of: viewModel.items, {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.linear(duration: 10)) {
              proxy.scrollTo("ConversationBottom")
            }
          }
        })
      }
      .scrollContentBackground(.hidden)
      .defaultScrollAnchor(.bottom)
      .listStyle(.plain)
      .background(Color.conversationDefaultBackground)
      NewMessageInput(
        conversation: conversation,
        messageModel: viewModel
      )
    }
    .overlay(
      VStack {
        Text("Drop your files here")
          .font(.title)
          .fontWeight(.semibold)
        Text("to attach them to your message")
          .font(.subheadline)
          .padding(.top, 2)
      }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .stroke(style: StrokeStyle(lineWidth: 2, dash: [2]))
            .foregroundColor(Color.accentColor)
        )
        .padding(.all, 8)
        .background(Color.black.opacity(0.75))
        .opacity(dragndropVisible ? 1 : 0)
    )
    .onDrop(of: [UTType.item], isTargeted: $dragndropVisible) {
      providers, _ in
      
      providers.forEach { provider in
        provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, error in
          guard let fileUrl = url else {
            print("Failed to load file url: \(error)")
            return
          }
          
          do {
            let fileData = try Data(contentsOf: fileUrl)
            let filename = fileUrl.lastPathComponent
            let filesize = fileData.count
            if(filesize > kMaxFileSize) {
              viewModel.attachmentTooBigAlert = true
              return
            }
            let mimeType = UTType(filenameExtension: fileUrl.pathExtension)
            
            DispatchQueue.main.async {
              viewModel.attachments.append(
                Attachment(
                  id: UUID(),
                  name: filename,
                  size: filesize,
                  mimeType: mimeType?.preferredMIMEType ?? "text/plain",
                  data: fileData
                )
              )
            }
          } catch {
            print("Error reading file data: \(error.localizedDescription)")
          }
        }
      }
      return true
    }
    .alert(isPresented: $viewModel.attachmentTooBigAlert) {
      Alert(
        title: Text("Attachment is too big"),
        message: Text("Session Network allows attachments up to " + getFilesizePlaceholder(filesize: kMaxFileSize)),
        dismissButton: .cancel()
      )
    }
    .alert("Delete message?", isPresented: $viewModel.deleteConfirmation) {
      Button("Delete everywhere", role: .destructive) {
        if let message = viewModel.deleteConfirmationMessage {
          let deleteMessageRequest: [MessagePackValue: MessagePackValue] = [
            "type": "delete_messages",
            "conversation": .string(conversation.recipient.sessionId),
            "messages": .array([
              .map([
                "timestamp": .int(message.timestamp!),
                "hash": .string(message.messageHash!)
              ])
            ])
          ]
          request(.map(deleteMessageRequest), { response in
            if(response["ok"]?.boolValue == true) {
              DispatchQueue.main.async {
                viewModel.deleteConfirmationMessage!.deletedByUser = true
                viewModel.deleteConfirmationMessage = nil
              }
            }
          })
        }
      }
      Button("Delete locally", role: .destructive) {
        if let message = viewModel.deleteConfirmationMessage {
          let messageId = message.persistentModelID
          var predicate = FetchDescriptor<Message>(predicate: #Predicate<Message> { msg in
            msg.persistentModelID == messageId
          })
          predicate.fetchLimit = 1
          let messages = try! modelContext.fetch(predicate)
          if !messages.isEmpty {
            DispatchQueue.main.async {
              messages[0].deletedByUser = true
            }
          }
        }
        viewModel.deleteConfirmationMessage = nil
      }
      Button("Cancel", role: .cancel) {
        viewModel.deleteConfirmation = false
        viewModel.deleteConfirmationMessage = nil
      }
    }
  }
}

func getFormattedDate(date: Date) -> String {
  let dateFormatter = DateFormatter()
  dateFormatter.dateFormat = "HH:mm"
  return dateFormatter.string(from: date)
}

struct ConversationView_Preview: PreviewProvider {
  static var previews: some View {
    var convo = ""
    
    let inMemoryModelContainer: ModelContainer = {
      do {
        let users = getUsersPreviewMocks()
        let convos = getConversationsPreviewMocks(user: users[0])
        convo = convos[0].id.uuidString
        let container = try ModelContainer(for: Schema(storageSchema), configurations: [.init(isStoredInMemoryOnly: true)])
        container.mainContext.insert(convos[0])
        let messages = getMessagePreviewMocks(conversation: convos[0])
        for message in messages {
          container.mainContext.insert(message)
        }
        try container.mainContext.save()
        UserDefaults.standard.set(users[0].id.uuidString, forKey: "activeUser")
        return container
      } catch {
        fatalError("Could not create ModelContainer: \(error)")
      }
    }()
    
    ConversationView()
      .modelContainer(inMemoryModelContainer)
      .environmentObject(ViewManager(.conversations, convo))
      .environmentObject(UserManager(container: inMemoryModelContainer, preview: true))
      .environmentObject(GlobalKeyMonitor())
      .frame(width: 500, height: 300)
  }
}
