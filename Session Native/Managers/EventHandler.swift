import Foundation
import SwiftData
import MessagePack
import SwiftUI

class EventHandler: ObservableObject {
  @Published var modelContext: ModelContext
  @Published var userManager: UserManager
  @Published var appViewManager: ViewManager
  @Published var connectionStatusManager: ConnectionStatusManager
  
  private var isSubscribed = false
  
  private var newMessageHandler: (([MessagePackValue : MessagePackValue]) -> Void)?
  private var messageDeletedHandler: (([MessagePackValue : MessagePackValue]) -> Void)?
  private var typingIndicatorHandler: (([MessagePackValue : MessagePackValue]) -> Void)?
  private var messageReadHandler: (([MessagePackValue : MessagePackValue]) -> Void)?
  private var connectionReportHandler: (([MessagePackValue : MessagePackValue]) -> Void)?
  
  private var typingIndicatorTimer: Timer?
  
  init(modelContext: ModelContext, userManager: UserManager, viewManager: ViewManager, connectionStatusManager: ConnectionStatusManager) {
    self.modelContext = modelContext
    self.userManager = userManager
    self.appViewManager = viewManager
    self.connectionStatusManager = connectionStatusManager
  }
  
  func subscribeToEvents() {
    if !isSubscribed {
      newMessageHandler = { [weak self] message in
        self?.handleNewMessage(message)
      }
      messageDeletedHandler = { [weak self] message in
        self?.handleMessageDeleted(message)
      }
      typingIndicatorHandler = { [weak self] message in
        self?.handleTypingIndicator(message)
      }
      messageReadHandler = { [weak self] message in
        self?.handleMessageRead(message)
      }
      connectionReportHandler = { [weak self] message in
        self?.handleConnectionReport(message)
      }
      
      backendApiClient.on(event: "new_message", handler: newMessageHandler!)
      backendApiClient.on(event: "message_deleted", handler: messageDeletedHandler!)
      backendApiClient.on(event: "typing_indicator", handler: typingIndicatorHandler!)
      backendApiClient.on(event: "message_read", handler: messageReadHandler!)
      backendApiClient.on(event: "connection_report", handler: connectionReportHandler!)
      
      isSubscribed = true
    }
  }
  
  func unsubscribeFromEvents() {
    if isSubscribed {
      if let newMessageHandler = newMessageHandler {
        backendApiClient.off(event: "new_message", handler: newMessageHandler)
      }
      if let messageDeletedHandler = messageDeletedHandler {
        backendApiClient.off(event: "message_deleted", handler: messageDeletedHandler)
      }
      if let typingIndicatorHandler = typingIndicatorHandler {
        backendApiClient.off(event: "typing_indicator", handler: typingIndicatorHandler)
      }
      if let messageReadHandler = messageReadHandler {
        backendApiClient.off(event: "message_read", handler: messageReadHandler)
      }
      if let connectionReportHandler = connectionReportHandler {
        backendApiClient.off(event: "connection_report", handler: connectionReportHandler)
      }
      
      isSubscribed = false
    }
  }
  
  private func handleNewMessage(_ message: [MessagePackValue : MessagePackValue]) {
    DispatchQueue.main.async {
      if let newMessage = message["message"]?.dictionaryValue,
         let sessionId = newMessage["from"]?.stringValue,
         let messageHash = newMessage["id"]?.stringValue,
         let timestamp = newMessage["timestamp"]?.uintValue,
         let activeUser = self.userManager.activeUser,
         let author = newMessage["author"]?.dictionaryValue {
        let activeUserId = activeUser.persistentModelID
        do {
          var conversation = try self.modelContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { conversation in
            conversation.recipient.sessionId == sessionId
            && conversation.user.persistentModelID == activeUserId
          })).first
          var recipient: Recipient?
          if conversation == nil {
            recipient = try self.modelContext.fetch(FetchDescriptor<Recipient>(predicate: #Predicate { recipient in
              recipient.sessionId == sessionId
            })).first
            if(recipient == nil) {
              recipient = Recipient(
                id: UUID(),
                sessionId: sessionId,
                displayName: author["displayName"]?.stringValue
              )
              self.modelContext.insert(recipient!)
            }
            var contact = try self.modelContext.fetch(FetchDescriptor<Contact>(predicate: #Predicate { contact in
              contact.recipient.sessionId == sessionId
              && contact.user.persistentModelID == activeUserId
            })).first
            let autoarchiveNewChats = UserDefaults.standard.optionalBool(forKey: "autoarchiveNewChats") ?? false
            conversation = Conversation(
              id: UUID(),
              user: activeUser,
              recipient: recipient!,
              archived: autoarchiveNewChats,
              lastMessage: nil,
              typingIndicator: false,
              notifications: AppNotification(enabled: autoarchiveNewChats ? false : true),
              pinned: false,
              contact: contact
            )
            self.modelContext.insert(conversation!)
            if(contact != nil) {
              contact!.conversation = conversation
            }
          } else {
            recipient = conversation!.recipient
          }
          
          var attachmentPreviews: [AttachmentPreview] = []
          if let newMessageAttachments = newMessage["attachments"]?.arrayValue {
            for attachment in newMessageAttachments {
              if let fileserverId = attachment["id"]?.stringValue {
                attachmentPreviews.append(
                  AttachmentPreview(
                    id: UUID(),
                    name: attachment["name"]?.stringValue ?? "unnamed",
                    size: attachment["size"]?.intValue ?? 0,
                    mimeType: attachment["metadata"]?.dictionaryValue?["contentType"]?.stringValue ?? "application/octet-stream",
                    digest: attachment["digest"]?.stringValue,
                    attachmentKey: attachment["key"]?.stringValue,
                    fileserverId: fileserverId
                  )
                )
              }
            }
          }
          
          let message = Message(
            id: UUID(),
            conversation: conversation!,
            messageHash: messageHash,
            createdAt: Date(),
            from: conversation!.recipient,
            body: newMessage["text"]?.stringValue ?? "",
            attachments: attachmentPreviews,
            replyTo: nil,
            timestamp: Int64(timestamp),
            read: false,
            status: .sent
          )
          self.modelContext.insert(message)
          conversation!.updatedAt = Date()
          conversation!.lastMessage = message
          
          var conversationVisible = false
          if let selectedConversationSessionId = self.appViewManager.navigationSelection {
            conversationVisible = selectedConversationSessionId == conversation!.id.uuidString
          }
          
          if(!conversationVisible) {
            conversation!.unreadMessages += 1
          }
          
          if let reply = newMessage["replyToMessage"],
             let replyReferenceTimestamp = reply["timestamp"]?.uintValue,
             let replyReferenceAuthorSessionId = reply["author"]?.stringValue {
            
            let replyReferenceTimestampInt64 = Int64(replyReferenceTimestamp)
            
            let isReplyReferenceAuthorMe = replyReferenceAuthorSessionId == activeUser.sessionId
            
            if let replyReferenceMessage = try self.modelContext.fetch(FetchDescriptor<Message>(predicate: #Predicate { message in
              if isReplyReferenceAuthorMe {
                return message.from == nil 
                  && message.timestamp == replyReferenceTimestampInt64
              } else {
                if let curMsgFrom = message.from,
                   let conversation = message.conversation {
                  return curMsgFrom.sessionId == replyReferenceAuthorSessionId
                    && message.timestamp == replyReferenceTimestampInt64
                    && conversation.user.persistentModelID == activeUserId
                } else {
                  return false
                }
              }
            })).first {
              message.replyTo = replyReferenceMessage
            }
              
            if let attachments = reply["attachments"]?.arrayValue {
              // TODO: attachments
            }
          }
          
          if recipient != nil {
            recipient!.displayName = author["displayName"]?.stringValue
            if let avatar = author["avatar"]?.dictionaryValue,
               let avatarUrl = avatar["url"]?.stringValue,
               let newProfileKey = avatar["key"]?.stringValue {
              if(recipient!._profileKey != newProfileKey) {
                DispatchQueue.main.async {
                  request([
                    "type": "download_avatar",
                    "url": .string(avatarUrl),
                    "key": .string(newProfileKey)
                  ], { response in
                    if let newAvatar = response["avatar"]?.dataValue {
                      recipient!.avatar = newAvatar
                      recipient!._profileKey = newProfileKey
                    }
                  })
                }
              }
            }
          }
          
          try self.modelContext.save()
          
          if (conversationVisible) {
            MessageViewModelNotifier.shared.newMessageReceived.send(message)
          } else {
            pushNotification(
              id: messageHash,
              title: conversation?.recipient.displayName ?? getSessionIdPlaceholder(sessionId: sessionId),
              body: message.body ?? "New message"
            )
          }
        } catch {
          print("Failed to save new message.")
        }
      }
    }
  }
  
  private func handleMessageDeleted(_ message: [MessagePackValue : MessagePackValue]) {
    DispatchQueue.main.async {
      if let readMessage = message["message"]?.dictionaryValue,
         let sessionId = readMessage["from"]?.stringValue,
         let timestamp = readMessage["timestamp"]?.int64Value {
        do {
          if let messageDb = try self.modelContext.fetch(FetchDescriptor<Message>(predicate: #Predicate { message in
            if let msgTimestamp = message.timestamp {
              if let conversation = message.conversation {
                return conversation.recipient.sessionId == sessionId && msgTimestamp == timestamp
              } else {
                return false
              }
            } else {
              return false
            }
          })).first {
            // Dirty hack: instead of actually deleting this message, we assign it a deleted state
            // For security we also clear its content in database so that it cannot be easily recovered
            messageDb.deletedByUser = true
            messageDb.body = ""
            messageDb.attachments = []
            try self.modelContext.save()
          }
        } catch {
          print("Failed to update deleted state of message.")
        }
      }
    }
  }
  
  private func handleTypingIndicator(_ message: [MessagePackValue : MessagePackValue]) {
    DispatchQueue.main.async {
      if let indicator = message["indicator"]?.dictionaryValue,
         let sessionId = indicator["conversation"]?.stringValue,
         let isTyping = indicator["isTyping"]?.boolValue {
        if(sessionId == self.userManager.activeUser?.sessionId) {
          return
        }
        do {
          if let conversation = try self.modelContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { conversation in
            conversation.recipient.sessionId == sessionId
          })).first {
            conversation.typingIndicator = isTyping
            
            self.typingIndicatorTimer?.invalidate()
            
            if isTyping {
              self.typingIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                  conversation.typingIndicator = false
                  do {
                    try self?.modelContext.save()
                  } catch {
                    print("Failed to update typing indicator after timer.")
                  }
                }
              }
            }
            
            try self.modelContext.save()
          }
        } catch {
          print("Failed to update typing indicator.")
        }
      }
    }
  }
  
  private func handleMessageRead(_ message: [MessagePackValue : MessagePackValue]) {
    DispatchQueue.main.async {
      if let readMessage = message["message"]?.dictionaryValue,
         let sessionId = readMessage["conversation"]?.stringValue,
         let timestamp = readMessage["timestamp"]?.uintValue {
        do {
          let timestampInt64 = Int64(timestamp)
          if let messageDb = try self.modelContext.fetch(FetchDescriptor<Message>(predicate: #Predicate { message in
            if let msgTimestamp = message.timestamp,
               let conversation = message.conversation {
              return conversation.recipient.sessionId == sessionId && msgTimestamp == timestampInt64
            } else {
              return false
            }
          })).first {
            messageDb.read = true
            try self.modelContext.save()
          }
        } catch {
          print("Failed to update read state of message.")
        }
      }
    }
  }
  
  private func handleConnectionReport(_ message: [MessagePackValue : MessagePackValue]) {
    DispatchQueue.main.async {
      if let connected = message["connected"]?.boolValue {
        self.connectionStatusManager.setConnected(connected)
      }
      if let error = message["connectionError"]?.stringValue {
        self.connectionStatusManager.setError(error)
      }
    }
  }
}
