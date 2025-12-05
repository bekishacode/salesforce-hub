public with sharing class TelegramMessagingService {

    // FIXED: Added cacheable=true since this is called via @wire
    @AuraEnabled(cacheable=true)
    public static ConversationData getOrCreateConversation(String recordId) {
        ConversationData data = new ConversationData();
        
        try {
            System.debug('🔍 Getting conversation for record: ' + recordId);
            
            // Find existing conversation thread
            Conversation_Thread__c thread = findConversationThread(recordId);
            System.debug('📝 Found thread: ' + thread);
            
            if (thread == null) {
                System.debug('🆕 No thread found, creating new one...');
                // Create new conversation thread
                String chatId = getChatIdForRecord(recordId);
                System.debug('💬 Chat ID found: ' + chatId);
                
                if (String.isBlank(chatId)) {
                    data.error = 'No Telegram chat ID found for this record. Customer needs to initiate conversation first via Telegram bot.';
                    data.hasActiveSession = false;
                    return data;
                }
                
                // FIXED: Cannot perform DML in cacheable method, so we'll return error and handle creation in LWC
                data.error = 'CONVERSATION_NOT_FOUND';
                data.hasActiveSession = false;
                return data;
            }
            
            data.thread = new ConversationThread(thread);
            data.messages = getMessageSessions(thread.Id);
            data.hasActiveSession = thread.Status__c == 'Active';
            
            System.debug('✅ Conversation data loaded - Thread: ' + thread.Id + ', Messages: ' + data.messages.size() + ', Active: ' + data.hasActiveSession);
            
        } catch (Exception e) {
            String errorMsg = 'Error getting conversation: ' + e.getMessage() + ' at ' + e.getLineNumber();
            System.debug('❌ ' + errorMsg);
            data.error = errorMsg;
        }
        
        return data;
    }

    // NEW: Separate method to create conversation (non-cacheable)
    @AuraEnabled
    public static ConversationData createConversation(String recordId) {
        ConversationData data = new ConversationData();
        
        try {
            System.debug('🆕 Creating conversation for record: ' + recordId);
            
            String chatId = getChatIdForRecord(recordId);
            System.debug('💬 Chat ID found: ' + chatId);
            
            if (String.isBlank(chatId)) {
                data.error = 'No Telegram chat ID found for this record. Customer needs to initiate conversation first via Telegram bot.';
                data.hasActiveSession = false;
                return data;
            }
            
            Conversation_Thread__c thread = createConversationThread(recordId, chatId);
            System.debug('✅ New thread created: ' + thread.Id);
            
            data.thread = new ConversationThread(thread);
            data.messages = getMessageSessions(thread.Id);
            data.hasActiveSession = thread.Status__c == 'Closed';
            
        } catch (Exception e) {
            String errorMsg = 'Error creating conversation: ' + e.getMessage() + ' at ' + e.getLineNumber();
            System.debug('❌ ' + errorMsg);
            data.error = errorMsg;
        }
        
        return data;
    }

    // Start a new session in existing conversation
    @AuraEnabled
    public static String startNewSession(String threadId) {
        try {
            System.debug('🚀 Starting new session for thread: ' + threadId);
            
            Conversation_Thread__c thread = [
                SELECT Id, Status__c, Session_Count__c 
                FROM Conversation_Thread__c 
                WHERE Id = :threadId 
                LIMIT 1
            ];
            
            // Increment session count
            thread.Session_Count__c = (thread.Session_Count__c == null) ? 1 : thread.Session_Count__c + 1;
            thread.Status__c = 'Active';
            thread.Last_Message_Date__c = System.now();
            update thread;
            
            // Create system message for new session
            createSystemMessage(threadId, 'New conversation session started', thread.Session_Count__c);
            
            String result = 'SUCCESS: Session ' + thread.Session_Count__c + ' started';
            System.debug('✅ ' + result);
            return result;
            
        } catch (Exception e) {
            String errorMsg = 'ERROR starting session: ' + e.getMessage() + ' at ' + e.getLineNumber();
            System.debug('❌ ' + errorMsg);
            return errorMsg;
        }
    }

    // Send message in current session
        // Send message in current session - FIXED VERSION
    @AuraEnabled
    public static String sendMessage(String threadId, String messageText, String attachmentUrl) {
        try {
            System.debug('🚀 LWC sendMessage called');
            System.debug('🚀 Thread ID: ' + threadId);
            System.debug('🚀 Message Text: ' + messageText);
            System.debug('🚀 Attachment URL: ' + attachmentUrl);
            
            if (String.isBlank(messageText) && String.isBlank(attachmentUrl)) {
                return 'ERROR: Please enter a message or attach a file.';
            }
            
            Conversation_Thread__c thread = [
                SELECT Id, Telegram_Chat_ID__c, Status__c, Session_Count__c 
                FROM Conversation_Thread__c 
                WHERE Id = :threadId 
                LIMIT 1
            ];
            
            System.debug('🚀 Found thread: ' + thread);
            System.debug('🚀 Thread Chat ID: ' + thread.Telegram_Chat_ID__c);
            System.debug('🚀 Thread Status: ' + thread.Status__c);
            
            if (thread.Status__c != 'Active') {
                return 'ERROR: No active session. Please start a conversation first.';
            }
            
            // FIXED: Make the callout FIRST before any DML operations
            System.debug('🚀 Making Telegram callout...');
            Boolean success = sendToTelegram(thread.Telegram_Chat_ID__c, messageText, attachmentUrl);
            System.debug('🚀 Telegram send result: ' + success);
            
            // Create message with session number
            Conversation_Message__c newMessage = new Conversation_Message__c(
                Conversation_Thread__c = thread.Id,
                Message_Text__c = messageText,
                Direction__c = 'Outbound',
                Message_Date__c = System.now(),
                Status__c = success ? 'Sent' : 'Failed', // Set status based on callout result
                Attachment_URL__c = attachmentUrl,
                Session_Number__c = thread.Session_Count__c
            );
            
            insert newMessage;
            System.debug('✅ Message record created: ' + newMessage.Id);
            
            if (success) {
                thread.Last_Message_Date__c = System.now();
                update thread;
                
                System.debug('✅ Message sent successfully via Telegram');
                return 'SUCCESS: Message sent!';
            } else {
                System.debug('❌ Failed to send via Telegram');
                return 'ERROR: Failed to send via Telegram.';
            }
            
        } catch (Exception e) {
            System.debug('❌ Exception in sendMessage: ' + e.getMessage());
            System.debug('❌ Stack trace: ' + e.getStackTraceString());
            return 'ERROR: ' + e.getMessage();
        }
    }

    // End current session (but keep thread active for history)
    @AuraEnabled
    public static String endSession(String threadId) {
        try {
            Conversation_Thread__c thread = [
                SELECT Id, Status__c, Session_Count__c 
                FROM Conversation_Thread__c 
                WHERE Id = :threadId 
                LIMIT 1
            ];
            
            thread.Status__c = 'Closed';
            thread.Last_Message_Date__c = System.now();
            update thread;
            
            createSystemMessage(threadId, 'Conversation session ended', thread.Session_Count__c);
            
            return 'SUCCESS: Session ended. Conversation thread preserved for history.';
            
        } catch (Exception e) {
            return 'ERROR: ' + e.getMessage();
        }
    }

    // FIXED: Added cacheable=true for wire method
    @AuraEnabled(cacheable=true)
    public static List<MessageSession> getMessageSessions(String threadId) {
        List<MessageSession> sessions = new List<MessageSession>();
        
        try {
            List<Conversation_Message__c> messageRecords = [
                SELECT Id, Name, Message_Text__c, Direction__c, Message_Date__c, 
                       Status__c, Telegram_Message_ID__c, Attachment_URL__c, Session_Number__c,
                       Conversation_Thread__r.Name, Conversation_Thread__r.Session_Count__c
                FROM Conversation_Message__c 
                WHERE Conversation_Thread__c = :threadId 
                ORDER BY Message_Date__c ASC
                LIMIT 1000
            ];
            
            for (Conversation_Message__c msg : messageRecords) {
                sessions.add(new MessageSession(msg));
            }
            
        } catch (Exception e) {
            System.debug('Error getting message sessions: ' + e.getMessage());
        }
        
        return sessions;
    }

    // Store incoming message from Telegram
    public static void storeIncomingMessage(String chatId, String messageText, String telegramMessageId, Map<String, Object> userData) {
        try {
            // Find conversation thread by chat ID
            List<Conversation_Thread__c> threads = [
                SELECT Id, Status__c, Session_Count__c 
                FROM Conversation_Thread__c 
                WHERE Telegram_Chat_ID__c = :chatId 
                ORDER BY Last_Message_Date__c DESC 
                LIMIT 1
            ];
            
            Conversation_Thread__c thread;
            if (threads.isEmpty()) {
                // Create new thread if none exists
                thread = createThreadFromChatId(chatId);
                if (thread == null) {
                    System.debug('❌ Could not create thread for chat ID: ' + chatId);
                    return;
                }
            } else {
                thread = threads[0];
                
                // If thread is closed, start new session
                if (thread.Status__c == 'Closed') {
                    thread.Session_Count__c = (thread.Session_Count__c == null) ? 1 : thread.Session_Count__c + 1;
                    thread.Status__c = 'Active';
                    createSystemMessage(thread.Id, 'New session started by customer', thread.Session_Count__c);
                }
            }
            
            // Create inbound message
            Conversation_Message__c incomingMessage = new Conversation_Message__c(
                Conversation_Thread__c = thread.Id,
                Message_Text__c = messageText,
                Direction__c = 'Inbound',
                Message_Date__c = System.now(),
                Telegram_Message_ID__c = telegramMessageId,
                Status__c = 'Received',
                Session_Number__c = thread.Session_Count__c
            );
            
            insert incomingMessage;
            
            thread.Last_Message_Date__c = System.now();
            update thread;
            
        } catch (Exception e) {
            System.debug('Error storing incoming message: ' + e.getMessage());
        }
    }

    // Find conversation thread for record (Contact/Lead/Case)
    private static Conversation_Thread__c findConversationThread(String recordId) {
        try {
            String query = 'SELECT Id, Name, Telegram_Chat_ID__c, Status__c, Session_Count__c, Last_Message_Date__c ';
            query += 'FROM Conversation_Thread__c WHERE ';
            
            if (recordId.startsWith('003')) {
                query += 'Contact__c = :recordId';
            } else if (recordId.startsWith('00Q')) {
                query += 'Lead__c = :recordId';
            } else if (recordId.startsWith('500')) {
                query += 'Case__c = :recordId';
            } else {
                System.debug('❌ Invalid record ID prefix: ' + recordId);
                return null;
            }
            
            query += ' ORDER BY Last_Message_Date__c DESC LIMIT 1';
            
            List<Conversation_Thread__c> threads = Database.query(query);
            System.debug('🔍 Found ' + threads.size() + ' threads for record: ' + recordId);
            return threads.isEmpty() ? null : threads[0];
            
        } catch (Exception e) {
            System.debug('❌ Error finding conversation thread: ' + e.getMessage());
            return null;
        }
    }

    // Create new conversation thread
    private static Conversation_Thread__c createConversationThread(String recordId, String chatId) {
        try {
            System.debug('🆕 Creating conversation thread for record: ' + recordId + ' with chat ID: ' + chatId);
            
            Conversation_Thread__c thread = new Conversation_Thread__c(
                Telegram_Chat_ID__c = chatId,
                Status__c = 'Active',
                Session_Count__c = 1,
                Last_Message_Date__c = System.now()
            );
            
            if (recordId.startsWith('003')) {
                thread.Contact__c = recordId;
                System.debug('📞 Assigning to Contact: ' + recordId);
            } else if (recordId.startsWith('00Q')) {
                thread.Lead__c = recordId;
                System.debug('📞 Assigning to Lead: ' + recordId);
            } else if (recordId.startsWith('500')) {
                thread.Case__c = recordId;
                System.debug('📞 Assigning to Case: ' + recordId);
            } else {
                System.debug('❌ Invalid record ID for thread creation: ' + recordId);
                return null;
            }
            
            insert thread;
            
            // Create system message for first session
            createSystemMessage(thread.Id, 'Conversation thread created - Session 1 started', 1);
            
            System.debug('✅ Successfully created thread: ' + thread.Id);
            return thread;
        } catch (Exception e) {
            System.debug('❌ Error creating conversation thread: ' + e.getMessage());
            return null;
        }
    }

    // Create system message
    private static void createSystemMessage(String threadId, String message, Decimal sessionNumber) {
        try {
            Conversation_Message__c systemMsg = new Conversation_Message__c(
                Conversation_Thread__c = threadId,
                Message_Text__c = message,
                Direction__c = 'System',
                Message_Date__c = System.now(),
                Status__c = 'Sent',
                Session_Number__c = sessionNumber
            );
            insert systemMsg;
        } catch (Exception e) {
            System.debug('Error creating system message: ' + e.getMessage());
        }
    }

    // Send message to Telegram
        // Send message to Telegram - WORKING VERSION
    private static Boolean sendToTelegram(String chatId, String message, String attachmentUrl) {
        try {
            System.debug('🚨 START: sendToTelegram called');
            System.debug('🚨 Chat ID: ' + chatId);
            System.debug('🚨 Message: ' + message);
            
            if (String.isBlank(chatId)) {
                System.debug('❌ Chat ID is blank');
                return false;
            }
            
            // Clean chat ID (remove any non-numeric characters)
            String cleanChatId = chatId.replaceAll('[^0-9]', '');
            System.debug('🚨 Cleaned Chat ID: ' + cleanChatId);
            
            if (String.isBlank(cleanChatId)) {
                System.debug('❌ Cleaned Chat ID is blank');
                return false;
            }
            
            Http http = new Http();
            HttpRequest request = new HttpRequest();
            
            String webhookUrl = 'https://telegram-bot-fotq.onrender.com/api/send-to-user';
            System.debug('🚨 Webhook URL: ' + webhookUrl);
            
            request.setEndpoint(webhookUrl);
            request.setMethod('POST');
            request.setHeader('Content-Type', 'application/json');
            request.setTimeout(30000);
            
            Map<String, Object> messageData = new Map<String, Object>{
                'chat_id' => cleanChatId,
                'message' => message,
                'attachment_url' => attachmentUrl
            };
            
            String requestBody = JSON.serialize(messageData);
            request.setBody(requestBody);
            
            System.debug('🚨 Request Body: ' + requestBody);
            System.debug('🚨 Making callout...');
            
            // Make the callout
            HttpResponse response = http.send(request);
            
            System.debug('🚨 Response Status: ' + response.getStatusCode());
            System.debug('🚨 Response Body: ' + response.getBody());
            
            // SIMPLE SUCCESS CHECK - Just like the test method
            if (response.getStatusCode() == 200) {
                // If we get 200 status, consider it successful
                System.debug('✅ Callout successful with 200 status');
                return true;
            } else {
                System.debug('❌ Callout failed with status: ' + response.getStatusCode());
                return false;
            }
            
        } catch (Exception e) {
            System.debug('❌ Exception in sendToTelegram: ' + e.getMessage());
            System.debug('❌ Stack trace: ' + e.getStackTraceString());
            return false;
        }
    }


    private static Conversation_Thread__c createThreadFromChatId(String chatId) {
        String recordId = findRecordIdByChatId(chatId);
        if (String.isNotBlank(recordId)) {
            return createConversationThread(recordId, chatId);
        }
        System.debug('❌ No record found for chat ID: ' + chatId);
        return null;
    }
    
    private static String findRecordIdByChatId(String chatId) {
        try {
            System.debug('🔍 Finding record for chat ID: ' + chatId);
            
            // Check Contact
            List<Contact> contacts = [SELECT Id, Name FROM Contact WHERE Telegram_Chat_ID__c = :chatId LIMIT 1];
            if (!contacts.isEmpty()) {
                System.debug('✅ Found Contact: ' + contacts[0].Id + ' - ' + contacts[0].Name);
                return contacts[0].Id;
            }
            
            // Check Lead
            List<Lead> leads = [SELECT Id, Name FROM Lead WHERE Telegram_Chat_ID__c = :chatId LIMIT 1];
            if (!leads.isEmpty()) {
                System.debug('✅ Found Lead: ' + leads[0].Id + ' - ' + leads[0].Name);
                return leads[0].Id;
            }
            
            // Check Case (via Contact)
            List<Case> cases = [SELECT Id, CaseNumber FROM Case WHERE Contact.Telegram_Chat_ID__c = :chatId LIMIT 1];
            if (!cases.isEmpty()) {
                System.debug('✅ Found Case: ' + cases[0].Id + ' - ' + cases[0].CaseNumber);
                return cases[0].Id;
            }
            
            System.debug('❌ No record found for chat ID: ' + chatId);
            
        } catch (Exception e) {
            System.debug('❌ Error finding record by chat ID: ' + e.getMessage());
        }
        return null;
    }

    // Helper method to get Chat ID for record - IMPROVED DEBUGGING
    private static String getChatIdForRecord(String recordId) {
        try {
            System.debug('🔍 Getting chat ID for record: ' + recordId);
            
            if (recordId.startsWith('003')) {
                List<Contact> contacts = [SELECT Id, Name, Telegram_Chat_ID__c FROM Contact WHERE Id = :recordId LIMIT 1];
                String chatId = contacts.isEmpty() ? null : contacts[0].Telegram_Chat_ID__c;
                System.debug('📞 Contact Chat ID: ' + chatId + ' for Contact: ' + (contacts.isEmpty() ? 'Not found' : contacts[0].Name));
                return chatId;
            } else if (recordId.startsWith('00Q')) {
                List<Lead> leads = [SELECT Id, Name, Telegram_Chat_ID__c FROM Lead WHERE Id = :recordId LIMIT 1];
                String chatId = leads.isEmpty() ? null : leads[0].Telegram_Chat_ID__c;
                System.debug('📞 Lead Chat ID: ' + chatId + ' for Lead: ' + (leads.isEmpty() ? 'Not found' : leads[0].Name));
                return chatId;
            } else if (recordId.startsWith('500')) {
                List<Case> cases = [SELECT Id, CaseNumber, Contact.Telegram_Chat_ID__c FROM Case WHERE Id = :recordId LIMIT 1];
                String chatId = cases.isEmpty() ? null : cases[0].Contact.Telegram_Chat_ID__c;
                System.debug('📞 Case Chat ID: ' + chatId + ' for Case: ' + (cases.isEmpty() ? 'Not found' : cases[0].CaseNumber));
                return chatId;
            }
        } catch (Exception e) {
            System.debug('❌ Error getting chat ID: ' + e.getMessage());
        }
        return null;
    }

    // Wrapper classes with statusIcon field
    public class ConversationData {
        @AuraEnabled public ConversationThread thread;
        @AuraEnabled public List<MessageSession> messages;
        @AuraEnabled public Boolean hasActiveSession;
        @AuraEnabled public String error;
    }

    public class ConversationThread {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public Integer sessionCount;
        @AuraEnabled public String lastMessageDate;
        @AuraEnabled public Boolean isActive;
        
        public ConversationThread(Conversation_Thread__c thread) {
            this.id = thread.Id;
            this.name = thread.Name;
            this.status = thread.Status__c;
            this.sessionCount = thread.Session_Count__c != null ? Integer.valueOf(thread.Session_Count__c) : 1;
            this.lastMessageDate = thread.Last_Message_Date__c?.format('MMM d, h:mm a');
            this.isActive = thread.Status__c == 'Active';
        }
    }

    public class MessageSession {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String text;
        @AuraEnabled public String direction;
        @AuraEnabled public String messageTime;
        @AuraEnabled public String status;
        @AuraEnabled public String attachmentUrl;
        @AuraEnabled public Integer sessionNumber;
        @AuraEnabled public Boolean isOutbound;
        @AuraEnabled public Boolean isInbound;
        @AuraEnabled public Boolean isSystem;
        @AuraEnabled public Boolean hasAttachment;
        @AuraEnabled public Boolean showSessionHeader;
        @AuraEnabled public String statusIcon; // ADDED STATUS ICON FIELD
        
        public MessageSession(Conversation_Message__c msg) {
            this.id = msg.Id;
            this.name = msg.Name;
            this.text = msg.Message_Text__c;
            this.direction = msg.Direction__c;
            this.messageTime = msg.Message_Date__c.format('MMM d, yyyy h:mm a');
            this.status = msg.Status__c;
            this.attachmentUrl = msg.Attachment_URL__c;
            this.sessionNumber = msg.Session_Number__c != null ? Integer.valueOf(msg.Session_Number__c) : 1;
            this.isOutbound = msg.Direction__c == 'Outbound';
            this.isInbound = msg.Direction__c == 'Inbound';
            this.isSystem = msg.Direction__c == 'System';
            this.hasAttachment = String.isNotBlank(msg.Attachment_URL__c);
            this.statusIcon = getStatusIcon(msg.Status__c); // SET STATUS ICON
        }
        
        private String getStatusIcon(String status) {
            if (status == 'Sent') return 'utility:success';
            if (status == 'Sending') return 'utility:spinner';
            if (status == 'Failed') return 'utility:error';
            return 'utility:success';
        }
    }
}