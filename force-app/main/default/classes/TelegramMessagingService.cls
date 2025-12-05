public with sharing class TelegramMessagingService {

    // Get or create conversation thread for a record
        @AuraEnabled(cacheable=true)
    public static ConversationData getOrCreateConversation(String recordId) {
        ConversationData data = new ConversationData();
        
        try {
            System.debug('🔍 START: getOrCreateConversation for record: ' + recordId);
            System.debug('🔍 Record ID prefix: ' + recordId.substring(0, 3));
            
            // Find existing conversation thread
            Conversation_Thread__c thread = findConversationThread(recordId);
            System.debug('📝 Thread search result: ' + thread);
            
            if (thread == null) {
                System.debug('🆕 No thread found, proceeding to create new one...');
                
                // DIRECT QUERY APPROACH - Fix for private method issue
                String chatId = null;
                if (recordId.startsWith('00Q')) { // Lead
                    List<Lead> leads = [SELECT Id, Telegram_Chat_ID__c FROM Lead WHERE Id = :recordId LIMIT 1];
                    chatId = leads.isEmpty() ? null : leads[0].Telegram_Chat_ID__c;
                    System.debug('🔍 DIRECT QUERY - Lead Chat ID: ' + chatId);
                } else if (recordId.startsWith('500')) { // Case
                    List<Case> cases = [SELECT Id, CaseNumber, Contact.Telegram_Chat_ID__c, ContactId FROM Case WHERE Id = :recordId LIMIT 1];
                    if (!cases.isEmpty() && cases[0].ContactId != null) {
                        chatId = cases[0].Contact.Telegram_Chat_ID__c;
                        System.debug('🔍 DIRECT QUERY - Case Chat ID via Contact: ' + chatId);
                    } else {
                        System.debug('🔍 DIRECT QUERY - Case has no Contact with Chat ID');
                    }
                }
                
                // String chatId = getChatIdForRecord(recordId); // REMOVED - Using direct query instead
                System.debug('💬 Chat ID retrieved: ' + chatId);
                
                if (String.isBlank(chatId)) {
                    String recordType = getRecordType(recordId);
                    String errorMsg = 'No Telegram chat ID found for this ' + recordType + '. ';
                    
                    if (recordType == 'Lead') {
                        errorMsg += 'Please ensure the Lead has a valid Telegram Chat ID stored in the Telegram Chat ID field.';
                    } else if (recordType == 'Case') {
                        errorMsg += 'This Case needs to be associated with a Contact that has a Telegram Chat ID.';
                    } else {
                        errorMsg += 'Telegram communication is only available for Leads and Cases.';
                    }
                    
                    data.error = errorMsg;
                    data.hasActiveSession = false;
                    System.debug('❌ Returning error: ' + errorMsg);
                    return data;
                }
                
                System.debug('🔄 About to create conversation thread...');
                
                // FOR LEAD/CASE: Create thread with Active status
                String initialStatus = 'Closed';
                
                thread = createConversationThread(recordId, chatId, initialStatus);
                
                if (thread == null) {
                    System.debug('❌ Thread creation returned null');
                    data.error = 'Failed to create conversation thread.';
                    return data;
                }
                
                System.debug('✅ New thread created: ' + thread.Id + ' with status: ' + initialStatus);
            }
            
            data.thread = new ConversationThread(thread);
            data.messages = getMessageSessions(thread.Id);
            data.hasActiveSession = thread.Status__c == 'Active';
            
            System.debug('✅ Conversation data loaded successfully');
            System.debug('✅ Thread: ' + thread.Id + ', Messages: ' + data.messages.size() + ', Active: ' + data.hasActiveSession);
            
        } catch (Exception e) {
            String errorMsg = 'Error getting conversation: ' + e.getMessage() + ' at ' + e.getLineNumber();
            System.debug('❌ Exception: ' + errorMsg);
            System.debug('❌ Stack trace: ' + e.getStackTraceString());
            data.error = errorMsg;
        }
        
        return data;
    }

    // Helper method to get record type name
    private static String getRecordType(String recordId) {
        if (recordId.startsWith('003')) return 'Contact';
        if (recordId.startsWith('00Q')) return 'Lead';
        if (recordId.startsWith('500')) return 'Case';
        if (recordId.startsWith('01I')) return 'Conversation Message';
        return 'record';
    }

    // Start a new session in existing conversation
    @AuraEnabled
    public static String startNewSession(String threadId) {
        try {
            System.debug('🚀 Starting new session for thread: ' + threadId);
            
            Conversation_Thread__c thread = [
                SELECT Id, Status__c, Session_Count__c, Telegram_Chat_ID__c
                FROM Conversation_Thread__c 
                WHERE Id = :threadId 
                LIMIT 1
            ];
            
            // Increment session count
            thread.Session_Count__c = (thread.Session_Count__c == null) ? 1 : thread.Session_Count__c + 1;
            thread.Status__c = 'Active';
            thread.Last_Message_Date__c = System.now();
            update thread;
            
            // Use real name instead of "agent"
            String agentName = UserInfo.getName();
            createSystemMessage(threadId, agentName + ' joined the session', thread.Session_Count__c);
            
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
            
            // Make the callout FIRST before any DML operations
            System.debug('🚀 Making Telegram callout...');
            Boolean success = sendToTelegram(thread.Telegram_Chat_ID__c, messageText, attachmentUrl);
            System.debug('🚀 Telegram send result: ' + success);
            
            // Create message with session number
            Conversation_Message__c newMessage = new Conversation_Message__c(
                Conversation_Thread__c = thread.Id,
                Message_Text__c = messageText,
                Direction__c = 'Outbound',
                Message_Date__c = System.now(),
                Status__c = success ? 'Sent' : 'Failed',
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

    // End current session
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
            
            // Use real name instead of "agent"
            String agentName = UserInfo.getName();
            createSystemMessage(threadId, 'Session ended by ' + agentName, thread.Session_Count__c);
            
            return 'SUCCESS: Session ended. Conversation thread preserved for history.';
            
        } catch (Exception e) {
            return 'ERROR: ' + e.getMessage();
        }
    }

    // Get message sessions
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
            System.debug('📥 Storing incoming message from chat: ' + chatId);
            
            // Find conversation thread by Telegram Chat ID
            List<Conversation_Thread__c> threads = [
                SELECT Id, Status__c, Session_Count__c, Contact__c, Lead__c, Case__c
                FROM Conversation_Thread__c 
                WHERE Telegram_Chat_ID__c = :chatId 
                ORDER BY Last_Message_Date__c DESC 
                LIMIT 1
            ];
            
            Conversation_Thread__c thread;
            if (threads.isEmpty()) {
                // Create new thread for incoming message
                String recordId = findRecordIdByChatId(chatId);
                if (recordId != null) {
                    thread = createConversationThread(recordId, chatId, 'Active');
                    System.debug('✅ Created new thread for incoming message');
                } else {
                    System.debug('❌ No record found for chat ID: ' + chatId);
                    return;
                }
            } else {
                thread = threads[0];
                
                // If thread is closed, start new session for incoming message
            if (thread.Status__c == 'Closed') {
                thread.Session_Count__c = (thread.Session_Count__c == null) ? 1 : thread.Session_Count__c + 1;
                thread.Status__c = 'Active';
                thread.Last_Message_Date__c = System.now();
                update thread;
                
                // Use customer name instead of generic "customer"
                String customerName = 'Customer';
                if (userData != null && userData.containsKey('first_name')) {
                    customerName = (String)userData.get('first_name');
                }
                createSystemMessage(thread.Id, customerName + ' joined the session', thread.Session_Count__c);
                System.debug('✅ New session started by customer');
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
            
            System.debug('✅ Incoming message stored: ' + incomingMessage.Id);
            
        } catch (Exception e) {
            System.debug('❌ Error storing incoming message: ' + e.getMessage());
        }
    }

    // Find conversation thread for record
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
                System.debug('❌ Unsupported record ID prefix: ' + recordId);
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
    private static Conversation_Thread__c createConversationThread(String recordId, String chatId, String initialStatus) {
        try {
            System.debug('🆕 START: createConversationThread');
            System.debug('🆕 Record ID: ' + recordId + ', Chat ID: ' + chatId + ', Initial Status: ' + initialStatus);
            
            // Check if a thread already exists for this chat ID
            List<Conversation_Thread__c> existingThreads = [
                SELECT Id, Status__c, Contact__c, Lead__c, Case__c 
                FROM Conversation_Thread__c 
                WHERE Telegram_Chat_ID__c = :chatId 
                LIMIT 1
            ];
            
            if (!existingThreads.isEmpty()) {
                System.debug('⚠️ Thread already exists for chat ID: ' + chatId + ', thread: ' + existingThreads[0].Id);
                
                Conversation_Thread__c existingThread = existingThreads[0];
                Boolean needsUpdate = false;
                
                // Link thread to current record if not already linked
                if (recordId.startsWith('00Q') && existingThread.Lead__c == null) {
                    existingThread.Lead__c = recordId;
                    needsUpdate = true;
                } else if (recordId.startsWith('500') && existingThread.Case__c == null) {
                    existingThread.Case__c = recordId;
                    needsUpdate = true;
                }
                
                if (needsUpdate) {
                    update existingThread;
                    System.debug('✅ Updated thread linkage for record: ' + recordId);
                }
                
                return existingThread;
            }
            
            // Create new thread
            Conversation_Thread__c thread = new Conversation_Thread__c(
                Telegram_Chat_ID__c = chatId,
                Status__c = initialStatus,
                Session_Count__c = 1,
                Last_Message_Date__c = System.now()
            );
            
            // Assign to appropriate object
            if (recordId.startsWith('00Q')) {
                thread.Lead__c = recordId;
                System.debug('📞 Assigning to Lead: ' + recordId);
            } else if (recordId.startsWith('500')) {
                thread.Case__c = recordId;
                System.debug('📞 Assigning to Case: ' + recordId);
            } else {
                System.debug('❌ Unsupported record ID for thread creation: ' + recordId);
                return null;
            }
            
            System.debug('🔄 About to insert thread...');
            insert thread;
            System.debug('✅ Thread inserted successfully: ' + thread.Id);
            
            // Create system message
            String systemMessage = 'Conversation thread created - Session 1 started';
            createSystemMessage(thread.Id, systemMessage, 1);
            
            System.debug('✅ Successfully created thread: ' + thread.Id + ' with status: ' + initialStatus);
            return thread;
            
        } catch (Exception e) {
            System.debug('❌ Error in createConversationThread: ' + e.getMessage());
            System.debug('❌ Stack trace: ' + e.getStackTraceString());
            return null;
        }
    }

        // Create thread from Flow
    public static void createThreadFromFlow(String recordId, String chatId) {
        try {
            // ALWAYS create a NEW thread for each record, even with same Chat ID
            Conversation_Thread__c thread = new Conversation_Thread__c(
                Telegram_Chat_ID__c = chatId,
                Status__c = 'Active',
                Session_Count__c = 1,
                Last_Message_Date__c = System.now()
            );
            
            if (recordId.startsWith('00Q')) {
                thread.Lead__c = recordId;
            } else if (recordId.startsWith('500')) {
                thread.Case__c = recordId;
            }
            
            insert thread;
            System.debug('✅ Created NEW thread: ' + thread.Id + ' for record: ' + recordId);
            
        } catch (Exception e) {
            System.debug('❌ Thread creation failed: ' + e.getMessage());
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

    // Find record by chat ID
    private static String findRecordIdByChatId(String chatId) {
        try {
            System.debug('🔍 Finding record for chat ID: ' + chatId);
            
            // Check Lead first
            List<Lead> leads = [SELECT Id, Name FROM Lead WHERE Telegram_Chat_ID__c = :chatId LIMIT 1];
            if (!leads.isEmpty()) {
                System.debug('✅ Found Lead: ' + leads[0].Id + ' - ' + leads[0].Name);
                return leads[0].Id;
            }
            
            // Check Contact
            List<Contact> contacts = [SELECT Id, Name FROM Contact WHERE Telegram_Chat_ID__c = :chatId LIMIT 1];
            if (!contacts.isEmpty()) {
                System.debug('✅ Found Contact: ' + contacts[0].Id + ' - ' + contacts[0].Name);
                return contacts[0].Id;
            }
            
            System.debug('❌ No record found for chat ID: ' + chatId);
            
        } catch (Exception e) {
            System.debug('❌ Error finding record by chat ID: ' + e.getMessage());
        }
        return null;
    }

    // Get Chat ID for record
    private static String getChatIdForRecord(String recordId) {
        try {
            System.debug('🔍 Getting chat ID for record: ' + recordId);
            
            if (recordId.startsWith('00Q')) { // Lead
                List<Lead> leads = [SELECT Id, Name, Telegram_Chat_ID__c FROM Lead WHERE Id = :recordId LIMIT 1];
                String chatId = leads.isEmpty() ? null : leads[0].Telegram_Chat_ID__c;
                System.debug('📞 Lead Chat ID: ' + chatId + ' for Lead: ' + (leads.isEmpty() ? 'Not found' : leads[0].Name));
                return chatId;
                
            } else if (recordId.startsWith('500')) { // Case
                List<Case> cases = [SELECT Id, CaseNumber, Contact.Telegram_Chat_ID__c, ContactId FROM Case WHERE Id = :recordId LIMIT 1];
                if (!cases.isEmpty() && cases[0].ContactId != null) {
                    String chatId = cases[0].Contact.Telegram_Chat_ID__c;
                    System.debug('📞 Case Chat ID: ' + chatId + ' for Case: ' + cases[0].CaseNumber + ' via Contact: ' + cases[0].ContactId);
                    return chatId;
                } else {
                    System.debug('❌ Case has no associated Contact with Telegram Chat ID');
                    return null;
                }
            } else if (recordId.startsWith('003')) { // Contact - Return null since we don't want Contact communication
                System.debug('❌ Contact communication disabled - returning null');
                return null;
            } else {
                System.debug('❌ Unsupported record type: ' + recordId);
                return null;
            }
        } catch (Exception e) {
            System.debug('❌ Error getting chat ID: ' + e.getMessage());
            return null;
        }
    }

    // Wrapper classes
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
        @AuraEnabled public String currentUserName;
        
        public ConversationThread(Conversation_Thread__c thread) {
            this.id = thread.Id;
            this.name = thread.Name;
            this.status = thread.Status__c;
            this.sessionCount = thread.Session_Count__c != null ? Integer.valueOf(thread.Session_Count__c) : 1;
            this.lastMessageDate = thread.Last_Message_Date__c?.format('MMM d, h:mm a');
            this.isActive = thread.Status__c == 'Active';
            this.currentUserName = UserInfo.getName(); 
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
        @AuraEnabled public String statusIcon;
        
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
            this.statusIcon = getStatusIcon(msg.Status__c);
        }
        
        private String getStatusIcon(String status) {
            if (status == 'Sent') return 'utility:success';
            if (status == 'Sending') return 'utility:spinner';
            if (status == 'Failed') return 'utility:error';
            return 'utility:success';
        }
    }
}