public with sharing class TelegramMessageSender {

    // Method to get record information for the UI
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getRecordInfo(String recordId) {
        Map<String, String> result = new Map<String, String>();
        try {
            if (recordId.startsWith('003')) { // Contact
                Contact contact = [SELECT Id, Name, Phone, Email, Telegram_Chat_ID__c 
                                 FROM Contact WHERE Id = :recordId LIMIT 1];
                result.put('name', contact.Name);
                result.put('type', 'Contact');
                result.put('phone', contact.Phone != null ? contact.Phone : 'Not provided');
                result.put('email', contact.Email != null ? contact.Email : 'Not provided');
                result.put('hasTelegram', contact.Telegram_Chat_ID__c != null ? 'true' : 'false');
                result.put('chatId', contact.Telegram_Chat_ID__c);
            } else if (recordId.startsWith('00Q')) { // Lead
                Lead lead = [SELECT Id, Name, Company, Phone, Email, Telegram_Chat_ID__c 
                           FROM Lead WHERE Id = :recordId LIMIT 1];
                result.put('name', lead.Name);
                result.put('type', 'Lead');
                result.put('company', lead.Company != null ? lead.Company : 'Not provided');
                result.put('phone', lead.Phone != null ? lead.Phone : 'Not provided');
                result.put('email', lead.Email != null ? lead.Email : 'Not provided');
                result.put('hasTelegram', lead.Telegram_Chat_ID__c != null ? 'true' : 'false');
                result.put('chatId', lead.Telegram_Chat_ID__c);
            } else {
                result.put('error', 'Unsupported record type');
            }
        } catch (Exception e) {
            System.debug('Error getting record info: ' + e.getMessage());
            result.put('error', 'Error: ' + e.getMessage());
        }
        return result;
    }

    // Send direct message to customer via Telegram
    @AuraEnabled
    public static String sendDirectMessage(String recordId, String message, String attachmentUrl) {
        try {
            if (String.isBlank(message)) {
                return '❌ Please enter a message to send.';
            }
        
            // Find the chat ID for this record
            String chatId = findChatIdForRecord(recordId);
        
            if (chatId == null) {
                return '❌ No Telegram chat ID found for this record. Customer needs to start conversation with the bot first using /start command.';
            }
        
            // Send direct message via your Python bot
            Boolean success = sendTelegramMessageToUser(chatId, message, attachmentUrl);
        
            if (success) {
                // Store message in conversation history - FIXED CALL
                storeConversationMessage(recordId, message, 'OUTBOUND', attachmentUrl);
                return '✅ Message sent to customer successfully!';
            } else {
                return '❌ Failed to send message. Please check if the bot is running and try again.';
            }
        
        } catch (Exception e) {
            System.debug('Error in sendDirectMessage: ' + e.getMessage() + ' - ' + e.getStackTraceString());
            return '❌ Error: ' + e.getMessage();
        }
    }

    // Get conversation history for the UI
        @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getConversationHistory(String recordId) {
        List<Map<String, String>> messages = new List<Map<String, String>>();
        
        try {
            System.debug('🔍 Getting conversation history for record: ' + recordId);
            
            // For Leads, we need to find the related Contact's Chat ID and get tasks for both
            Set<Id> relatedRecordIds = new Set<Id>();
            relatedRecordIds.add(recordId);
            
            // If it's a Lead, find the related Contact
            if (recordId.startsWith('00Q')) {
                String chatId = findChatIdForRecord(recordId);
                if (chatId != null) {
                    // Find the Contact that has this Chat ID
                    List<Contact> relatedContacts = [
                        SELECT Id FROM Contact 
                        WHERE Telegram_Chat_ID__c = :chatId 
                        LIMIT 1
                    ];
                    if (!relatedContacts.isEmpty()) {
                        relatedRecordIds.add(relatedContacts[0].Id);
                        System.debug('🔗 Found related Contact: ' + relatedContacts[0].Id + ' for Lead: ' + recordId);
                    }
                }
            }
            
            // Get all tasks for this record AND any related records
            // REMOVED Description LIKE filter since it's not allowed on long text areas
            List<Task> conversationTasks = [
                SELECT Id, Subject, Description, CreatedDate, WhatId, WhoId, Status, Priority
                FROM Task 
                WHERE (WhatId IN :relatedRecordIds OR WhoId IN :relatedRecordIds)
                AND (
                    Subject LIKE '%Telegram%' 
                    OR Subject LIKE '%Sent to%'
                    OR Subject LIKE '%Incoming%'
                )
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];
            
            System.debug('📋 Found ' + conversationTasks.size() + ' conversation tasks for records: ' + relatedRecordIds);
            
            // Now filter in Apex instead of SOQL for Description field
            List<Task> filteredTasks = new List<Task>();
            for (Task task : conversationTasks) {
                // Check Description in Apex code (allowed) instead of SOQL (not allowed)
                if (task.Description != null && task.Description.contains('Telegram')) {
                    filteredTasks.add(task);
                } else if (task.Subject.contains('Telegram') || 
                        task.Subject.contains('Sent to') || 
                        task.Subject.contains('Incoming')) {
                    filteredTasks.add(task);
                }
            }
            
            System.debug('🎯 After filtering: ' + filteredTasks.size() + ' conversation tasks');
            
            for (Task task : filteredTasks) {
                System.debug('📝 Processing task: ' + task.Subject + ' - WhatId: ' + task.WhatId + ' - WhoId: ' + task.WhoId);
                
                String direction = 'OUTBOUND';
                String messageText = '';
                String status = task.Status;
                
                // Check for inbound messages
                if (task.Subject.contains('Incoming') || 
                    task.Subject.contains('New Telegram') ||
                    task.Subject.contains('from Customer') ||
                    (task.Description != null && task.Description.contains('Telegram'))) {
                    
                    direction = 'INBOUND';
                    
                    // Extract message from task description
                    if (task.Description != null) {
                        if (task.Description.contains('**Message:**')) {
                            messageText = task.Description.substringAfter('**Message:**').substringBefore('\n').trim();
                        } else if (task.Description.contains('Message:')) {
                            messageText = task.Description.substringAfter('Message:').substringBefore('\n').trim();
                        } else {
                            // For inbound messages without specific markers, try to extract the message
                            String[] descLines = task.Description.split('\n');
                            for (String line : descLines) {
                                if (line.contains('Message') || line.trim().length() > 10) {
                                    messageText = line.replace('Message:', '').replace('**Message:**', '').trim();
                                    break;
                                }
                            }
                            // If still no message, use first line of description
                            if (String.isBlank(messageText) && descLines.size() > 0) {
                                messageText = descLines[0].length() > 100 ? descLines[0].left(100) + '...' : descLines[0];
                            }
                        }
                    }
                } 
                // Check for outbound messages
                else if (task.Subject.contains('Sent to') || task.Subject.contains('Telegram')) {
                    direction = 'OUTBOUND';
                    
                    // Extract message from subject
                    if (task.Subject.contains('Sent to Telegram:')) {
                        messageText = task.Subject.substringAfter('Sent to Telegram:').trim();
                    } else if (task.Subject.contains(':')) {
                        messageText = task.Subject.substringAfter(':').trim();
                    } else {
                        messageText = task.Subject;
                    }
                    
                    // If message is too long, truncate it
                    if (messageText.length() > 100) {
                        messageText = messageText.left(100) + '...';
                    }
                }
                
                if (String.isNotBlank(messageText)) {
                    Map<String, String> messageMap = new Map<String, String>{
                        'id' => task.Id,
                        'text' => messageText,
                        'direction' => direction,
                        'time' => task.CreatedDate.format('MMM d, yyyy h:mm a'),
                        'status' => status,
                        'priority' => task.Priority
                    };
                    messages.add(messageMap);
                    System.debug('✅ Added message to history: ' + messageText);
                } else {
                    System.debug('❌ Skipped task - no message text extracted: ' + task.Subject);
                }
            }
            
            System.debug('🎯 Final messages count: ' + messages.size());
            
        } catch (Exception e) {
            System.debug('❌ Error getting conversation history: ' + e.getMessage() + ' - ' + e.getStackTraceString());
        }
        
        return messages;
    }
     //Debug method to check tasks associated with a record
        @AuraEnabled
    public static String debugCheckTasks(String recordId) {
        try {
            List<Task> tasks = [
                SELECT Id, Subject, CreatedDate, Description 
                FROM Task 
                WHERE (WhatId = :recordId OR WhoId = :recordId)
                ORDER BY CreatedDate DESC 
                LIMIT 10
            ];
            
            String result = 'Found ' + tasks.size() + ' tasks:\n';
            for (Task t : tasks) {
                result += '• ' + t.Subject + ' - ' + t.CreatedDate + '\n';
            }
            return result;
        } catch (Exception e) {
            return 'Error: ' + e.getMessage();
        }
    }
    // Send promotional messages (your existing functionality)
    @AuraEnabled
    public static String sendToTelegram(String recordId, String messageType, String customMessage) {
        try {
            System.debug('Sending to Telegram - RecordId: ' + recordId + ', Type: ' + messageType);
            
            String title = '';
            String description = '';
            
            if (messageType == 'Opportunity') {
                Opportunity opp = [SELECT Id, Name, Description, Amount, CloseDate, StageName 
                                 FROM Opportunity WHERE Id = :recordId LIMIT 1];
                title = '🏢 Opportunity: ' + opp.Name;
                description = customMessage != null && customMessage != '' ? customMessage : 
                    '**Details:**\n' +
                    '• Amount: $' + (opp.Amount != null ? opp.Amount.format() : '0') + '\n' +
                    '• Stage: ' + opp.StageName + '\n' +
                    '• Close Date: ' + opp.CloseDate + '\n' +
                    '• Description: ' + (opp.Description != null ? opp.Description : 'No description');
            } 
            else if (messageType == 'Campaign') {
                Campaign camp = [SELECT Id, Name, Description, Type, Status, StartDate, EndDate 
                               FROM Campaign WHERE Id = :recordId LIMIT 1];
                title = '🎯 Campaign: ' + camp.Name;
                description = customMessage != null && customMessage != '' ? customMessage : 
                    '**Campaign Details:**\n' +
                    '• Type: ' + camp.Type + '\n' +
                    '• Status: ' + camp.Status + '\n' +
                    '• Start Date: ' + camp.StartDate + '\n' +
                    '• End Date: ' + camp.EndDate + '\n' +
                    '• Description: ' + (camp.Description != null ? camp.Description : 'No description');
            }
            else if (messageType == 'Lead') {
                Lead lead = [SELECT Id, Name, Company, Status, Email, Phone, Industry 
                           FROM Lead WHERE Id = :recordId LIMIT 1];
                title = '👤 New Lead: ' + lead.Name;
                description = customMessage != null && customMessage != '' ? customMessage : 
                    '**Lead Details:**\n' +
                    '• Company: ' + (lead.Company != null ? lead.Company : 'N/A') + '\n' +
                    '• Status: ' + lead.Status + '\n' +
                    '• Email: ' + (lead.Email != null ? lead.Email : 'N/A') + '\n' +
                    '• Phone: ' + (lead.Phone != null ? lead.Phone : 'N/A') + '\n' +
                    '• Industry: ' + (lead.Industry != null ? lead.Industry : 'N/A');
            }
            else if (messageType == 'Custom') {
                title = '📢 Announcement';
                description = customMessage;
            }
            else if (messageType == 'Contact') {
                Contact contact = [SELECT Id, Name, Phone, Email FROM Contact WHERE Id = :recordId LIMIT 1];
                title = '👤 Contact: ' + contact.Name;
                description = customMessage != null && customMessage != '' ? customMessage : 
                    '**Contact Details:**\n' +
                    '• Phone: ' + (contact.Phone != null ? contact.Phone : 'N/A') + '\n' +
                    '• Email: ' + (contact.Email != null ? contact.Email : 'N/A');
            }
            
            // Send to Telegram webhook
            Boolean success = makeTelegramCallout(title, description, recordId);
            
            if (success) {
                // Create a task to track the send
                createActivityTask(recordId, title);
                return '✅ Message sent to Telegram successfully!';
            } else {
                return '❌ Failed to send message to Telegram. Check debug logs.';
            }
            
        } catch (Exception e) {
            System.debug('Error in sendToTelegram: ' + e.getMessage() + ' - ' + e.getStackTraceString());
            return '❌ Error: ' + e.getMessage();
        }
    }

    // PRIVATE HELPER METHODS

    private static String findChatIdForRecord(String recordId) {
        try {
            if (recordId.startsWith('003')) { // Contact
                List<Contact> contacts = [SELECT Telegram_Chat_ID__c FROM Contact WHERE Id = :recordId LIMIT 1];
                if (!contacts.isEmpty()) {
                    return contacts[0].Telegram_Chat_ID__c;
                }
            } else if (recordId.startsWith('00Q')) { // Lead
                List<Lead> leads = [SELECT Telegram_Chat_ID__c FROM Lead WHERE Id = :recordId LIMIT 1];
                if (!leads.isEmpty()) {
                    return leads[0].Telegram_Chat_ID__c;
                }
            }
        } catch (Exception e) {
            System.debug('Error finding chat ID: ' + e.getMessage());
        }
        return null;
    }

    private static Boolean sendTelegramMessageToUser(String chatId, String message, String attachmentUrl) {
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        
        // Use your Render app URL
        String webhookUrl = 'https://telegram-bot-fotq.onrender.com/api/send-to-user';
        
        request.setEndpoint(webhookUrl);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(60000);
        
        Map<String, Object> messageData = new Map<String, Object>{
            'chat_id' => chatId,
            'message' => message,
            'attachment_url' => attachmentUrl
        };
        
        request.setBody(JSON.serialize(messageData));
        
        try {
            HttpResponse response = http.send(request);
            System.debug('Telegram Response Status: ' + response.getStatusCode());
            System.debug('Telegram Response Body: ' + response.getBody());
            
            return response.getStatusCode() == 200;
        } catch (Exception e) {
            System.debug('Callout error: ' + e.getMessage());
            return false;
        }
    }

    private static void storeConversationMessage(String recordId, String message, String direction, String attachmentUrl) {
        try {
            Task conversationTask = new Task();
            
            if (direction == 'OUTBOUND') {
                conversationTask.Subject = 'Sent to Telegram: ' + (message.length() > 50 ? message.left(50) + '...' : message);
                conversationTask.Status = 'Completed';
                conversationTask.Priority = 'Normal';
                conversationTask.Description = 'Message sent to customer via Telegram.\n' +
                    'Message: ' + message + '\n' +
                    (String.isNotBlank(attachmentUrl) ? 'Attachment: ' + attachmentUrl + '\n' : '') +
                    'Sent: ' + System.now();
            } else {
                conversationTask.Subject = 'Incoming Telegram Message';
                conversationTask.Status = 'Completed';
                conversationTask.Priority = 'High';
                conversationTask.Description = 'Message received from customer via Telegram.\n' +
                    'Message: ' + message + '\n' +
                    'Received: ' + System.now();
            }
            
            // IMPORTANT: Link to the correct record type
            if (recordId.startsWith('003')) { // Contact
                conversationTask.WhoId = recordId;
            } else if (recordId.startsWith('00Q')) { // Lead
                conversationTask.WhatId = recordId;
            } else {
                // Fallback for other record types
                conversationTask.WhatId = recordId;
            }
            
            conversationTask.ActivityDate = System.today();
            
            insert conversationTask;
            System.debug('✅ Conversation message stored for ' + recordId + ': ' + conversationTask.Id + ' - ' + conversationTask.Subject);
            
        } catch (Exception e) {
            System.debug('❌ Error storing conversation message: ' + e.getMessage() + ' - ' + e.getStackTraceString());
        }
    }

    private static Boolean makeTelegramCallout(String title, String description, String recordId) {
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        
        // Use your Render app URL for promotional messages
        String webhookUrl = 'https://telegram-bot-fotq.onrender.com/api/send-to-group';
        
        request.setEndpoint(webhookUrl);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(60000);
        
        // Prepare data for promotional message
        Map<String, Object> telegramData = new Map<String, Object>{
            'message' => title + '\n\n' + description,
            'group_id' => 'main_promotions', // or get from custom setting
            'recordId' => recordId,
            'source' => 'Salesforce CRM',
            'timestamp' => System.now()
        };
        
        request.setBody(JSON.serialize(telegramData));
        
        try {
            HttpResponse response = http.send(request);
            System.debug('Telegram Promo Response Status: ' + response.getStatusCode());
            System.debug('Telegram Promo Response Body: ' + response.getBody());
            
            return response.getStatusCode() == 200;
            
        } catch (Exception e) {
            System.debug('Promo callout error: ' + e.getMessage() + ' - ' + e.getStackTraceString());
            return false;
        }
    }
    
    private static void createActivityTask(String recordId, String subject) {
        try {
            Task telegramTask = new Task(
                Subject = 'Sent to Telegram: ' + subject,
                Status = 'Completed',
                Priority = 'Normal',
                WhatId = recordId,
                Description = 'Promotional message was successfully sent to Telegram group',
                ActivityDate = System.today()
            );
            insert telegramTask;
        } catch (Exception e) {
            System.debug('Error creating task: ' + e.getMessage());
        }
    }

    // Webhook method to handle incoming Telegram messages from Python bot
    @AuraEnabled
    public static String handleIncomingMessage(String chatId, String message, String telegramMessageId, String userData) {
        try {
            System.debug('Handling incoming message - ChatId: ' + chatId + ', Message: ' + message);
            
            // Find contact/lead by chat ID
            String recordId = findRecordByChatId(chatId);
            
            if (recordId != null) {
                // Store incoming message
                storeConversationMessage(recordId, message, 'INBOUND', null);
                
                // Create additional task for agent notification
                createIncomingMessageTask(recordId, message, userData, telegramMessageId);
                
                return '✅ Message stored successfully for record: ' + recordId;
            } else {
                return '❌ No record found for chat ID: ' + chatId;
            }
            
        } catch (Exception e) {
            System.debug('Error handling incoming message: ' + e.getMessage());
            return '❌ Error: ' + e.getMessage();
        }
    }

    private static String findRecordByChatId(String chatId) {
        try {
            // Check contacts
            List<Contact> contacts = [SELECT Id FROM Contact WHERE Telegram_Chat_ID__c = :chatId LIMIT 1];
            if (!contacts.isEmpty()) return contacts[0].Id;
            
            // Check leads
            List<Lead> leads = [SELECT Id FROM Lead WHERE Telegram_Chat_ID__c = :chatId LIMIT 1];
            if (!leads.isEmpty()) return leads[0].Id;
            
        } catch (Exception e) {
            System.debug('Error finding record by chat ID: ' + e.getMessage());
        }
        return null;
    }

    private static void createIncomingMessageTask(String recordId, String message, String userData, String telegramMessageId) {
        try {
            // Parse user data if it's JSON
            Map<String, Object> userInfo = new Map<String, Object>();
            try {
                if (userData != null) {
                    userInfo = (Map<String, Object>)JSON.deserializeUntyped(userData);
                }
            } catch (Exception e) {
                System.debug('Error parsing user data: ' + e.getMessage());
            }
            
            String userName = (String)userInfo.get('first_name');
            String userLastName = (String)userInfo.get('last_name');
            String userUsername = (String)userInfo.get('username'); // Changed variable name to avoid conflict
            
            Task incomingTask = new Task(
                Subject = 'New Telegram Message from Customer - Action Required',
                Status = 'Not Started',
                Priority = 'High',
                WhatId = recordId,
                Description = '📱 **New Telegram Message Received**\n\n' +
                            '**From:** ' + (userName != null ? userName : 'Unknown') + 
                            (userLastName != null ? ' ' + userLastName : '') +
                            (userUsername != null ? ' (@' + userUsername + ')' : '') + '\n' +
                            '**Message:** ' + message + '\n' +
                            '**Telegram Message ID:** ' + telegramMessageId + '\n' +
                            '**Received:** ' + System.now() + '\n\n' +
                            '**Please respond using the Telegram Conversation component on the record page.**',
                ActivityDate = System.today()
            );
            insert incomingTask;
            System.debug('✅ Incoming message task created: ' + incomingTask.Id);
        } catch (Exception e) {
            System.debug('Error creating incoming message task: ' + e.getMessage());
        }
    }

    // Method to check if record has Telegram integration
    @AuraEnabled(cacheable=true)
    public static Boolean hasTelegramIntegration(String recordId) {
        try {
            String chatId = findChatIdForRecord(recordId);
            return chatId != null;
        } catch (Exception e) {
            System.debug('Error checking Telegram integration: ' + e.getMessage());
            return false;
        }
    }

    // Method to get recent conversations for dashboard
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getRecentConversations(Integer limitCount) {
        List<Map<String, String>> conversations = new List<Map<String, String>>();
        
        try {
            if (limitCount == null || limitCount > 50) {
                limitCount = 10;
            }
            
            // Get recent incoming messages
            List<Task> recentTasks = [
                SELECT Id, Subject, Description, CreatedDate, WhatId, WhoId, Status, Priority
                FROM Task 
                WHERE (Subject LIKE 'New Telegram Message%' OR Subject LIKE 'Incoming Telegram Message%')
                AND Status = 'Not Started'
                ORDER BY CreatedDate DESC
                LIMIT :limitCount
            ];
            
            for (Task task : recentTasks) {
                String recordId = task.WhatId != null ? task.WhatId : task.WhoId;
                String recordName = '';
                String recordType = '';
                
                try {
                    if (recordId != null) {
                        if (recordId.startsWith('003')) {
                            List<Contact> contacts = [SELECT Name FROM Contact WHERE Id = :recordId LIMIT 1];
                            if (!contacts.isEmpty()) {
                                recordName = contacts[0].Name;
                                recordType = 'Contact';
                            }
                        } else if (recordId.startsWith('00Q')) {
                            List<Lead> leads = [SELECT Name FROM Lead WHERE Id = :recordId LIMIT 1];
                            if (!leads.isEmpty()) {
                                recordName = leads[0].Name;
                                recordType = 'Lead';
                            }
                        }
                    }
                } catch (Exception e) {
                    System.debug('Error getting record name: ' + e.getMessage());
                }
                
                String messagePreview = '';
                if (task.Description != null && task.Description.contains('**Message:**')) {
                    messagePreview = task.Description.substringAfter('**Message:**').substringBefore('\n').trim();
                    if (messagePreview.length() > 50) {
                        messagePreview = messagePreview.left(50) + '...';
                    }
                }
                
                conversations.add(new Map<String, String>{
                    'taskId' => task.Id,
                    'recordId' => recordId,
                    'recordName' => recordName,
                    'recordType' => recordType,
                    'messagePreview' => messagePreview,
                    'receivedTime' => task.CreatedDate.format('MMM d, h:mm a'),
                    'priority' => task.Priority
                });
            }
        } catch (Exception e) {
            System.debug('Error getting recent conversations: ' + e.getMessage());
        }
        
        return conversations;
    }
}