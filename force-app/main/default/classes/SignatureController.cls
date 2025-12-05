public with sharing class SignatureController {
    
    public class SignatureResult {
        @AuraEnabled public String recordId { get; set; }
        @AuraEnabled public String fileName { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public String status { get; set; }
    }
    
    @AuraEnabled
    public static SignatureResult saveSignature(String accountId, String leadId, 
                                                String opportunityId, String customerName,
                                                String documentName, String signatureData, 
                                                String metadata) {
        SignatureResult result = new SignatureResult();
        
        try {
            // 1. CLEAN BASE64 DATA
            signatureData = signatureData.replace(' ', '+');
            Blob signatureBlob = EncodingUtil.base64Decode(signatureData);
            
            // 2. CREATE RECEIVED DOCUMENT RECORD
            ReceivedDocument doc = new ReceivedDocument();
            
            // Set required fields
            doc.Document_Type__c = 'Signature';
            doc.Status = 'Completed';
            doc.Status__c = 'New';
            doc.Name = documentName;
            
            // Link to Account if provided
            if (String.isNotBlank(accountId)) {
                doc.Related_Account__c = accountId;
            }
            
            // Link to Contact if provided
            if (String.isNotBlank(leadId)) {
                doc.Related_Lead__c = leadId;
            }
            
            // Link to Opportunity if provided
            if (String.isNotBlank(opportunityId)) {
                doc.Related_Opportunity__c = opportunityId;
            }
            
            insert doc;
            
            // 3. CREATE CONTENT VERSION (FILE)
            ContentVersion cv = new ContentVersion();
            cv.VersionData = signatureBlob;
            cv.Title = documentName + ' - Signature';
            cv.PathOnClient = 'signature_' + DateTime.now().getTime() + '.png';
            cv.FirstPublishLocationId = doc.Id; // Attach to ReceivedDocument
            cv.Origin = 'H';
            
            insert cv;
            
            // 4. PREPARE RESULT
            result.recordId = doc.Id;
            result.fileName = cv.Title;
            result.status = 'Success';
            
            // 5. GET ACCOUNT NAME FOR RESULT
            if (String.isNotBlank(accountId)) {
                try {
                    List<Account> accounts = [SELECT Name FROM Account WHERE Id = :accountId LIMIT 1];
                    if (!accounts.isEmpty()) {
                        result.accountName = accounts[0].Name;
                    }
                } catch (Exception e) {
                    // Ignore if can't get Account name
                }
            }
            
            // 6. CREATE ACTIVITY (Optional)
            createSignatureActivity(doc.Id, accountId, customerName, metadata);
            
        } catch (Exception e) {
            System.debug('Error saving signature: ' + e.getMessage() + ' | ' + e.getStackTraceString());
            throw new AuraHandledException('Failed to save signature: ' + e.getMessage());
        }
        
        return result;
    }
    
    private static void createSignatureActivity(String documentId, String accountId, String customerName, String metadata) {
        try {
            Task signatureTask = new Task();
            signatureTask.Subject = 'Digital Signature Captured';
            signatureTask.Status = 'Completed';
            signatureTask.Priority = 'Normal';
            signatureTask.WhatId = documentId; // Link to ReceivedDocument
            
            String description = 'Digital signature captured';
            if (String.isNotBlank(customerName)) {
                description += ' for: ' + customerName;
            }
            if (String.isNotBlank(accountId)) {
                description += '\nLinked to Account: ' + accountId;
            }
            if (String.isNotBlank(metadata)) {
                description += '\nTimestamp: ' + System.now().format();
            }
            
            signatureTask.Description = description;
            
            insert signatureTask;
            
        } catch (Exception e) {
            System.debug('Note: Could not create activity: ' + e.getMessage());
        }
    }
}