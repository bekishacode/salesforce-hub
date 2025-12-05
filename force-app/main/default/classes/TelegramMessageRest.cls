@RestResource(urlMapping='/TelegramMessage/*')
global with sharing class TelegramMessageRest {
    
    @HttpPost
    global static String handleIncomingMessage() {
        try {
            RestRequest request = RestContext.request;
            String requestBody = request.requestBody.toString();
            
            Map<String, Object> requestData = (Map<String, Object>)JSON.deserializeUntyped(requestBody);
            
            String chatId = (String)requestData.get('chatId');
            String messageText = (String)requestData.get('messageText');
            String telegramMessageId = (String)requestData.get('telegramMessageId');
            Map<String, Object> userData = (Map<String, Object>)requestData.get('userData');
            
            // Call the service method to store the message
            TelegramMessagingService.storeIncomingMessage(chatId, messageText, telegramMessageId, userData);
            
            RestContext.response.statusCode = 200;
            return '{"status": "success"}';
            
        } catch (Exception e) {
            RestContext.response.statusCode = 500;
            return '{"error": "' + e.getMessage() + '"}';
        }
    }
}