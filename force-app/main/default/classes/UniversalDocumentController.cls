public with sharing class UniversalDocumentController {
    
    @AuraEnabled(cacheable=true)
    public static List<DocumentWrapper> getRecordDocuments(String recordId) {
        try {
            List<DocumentWrapper> wrappers = new List<DocumentWrapper>();
            
            // Get the object type from the record ID
            Id recId = (Id)recordId;
            String objectType = recId.getSObjectType().getDescribe().getName();
            
            // Query based on object type
            if(objectType == 'Account') {
                wrappers = getReceivedDocumentsWithFiles('Related_Account__c', recordId);
            } else if(objectType == 'Case') {
                wrappers = getReceivedDocumentsWithFiles('Related_Case__c', recordId);
            } else if(objectType == 'Lead') {
                wrappers = getReceivedDocumentsWithFiles('Related_Lead__c', recordId);
            } else if(objectType == 'Opportunity') {
                wrappers = getReceivedDocumentsWithFiles('Related_Opportunity__c', recordId);
            } else {
                // For other objects, use standard ContentDocumentLink approach
                wrappers = getStandardFiles(recordId);
            }
            
            return wrappers;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error loading documents: ' + e.getMessage());
        }
    }
    
    private static List<DocumentWrapper> getReceivedDocumentsWithFiles(String relationshipField, String recordId) {
        List<DocumentWrapper> wrappers = new List<DocumentWrapper>();
        
        // Build dynamic SOQL query for ReceivedDocument
        String query = 'SELECT Id, Name, Document_Type__c, Status__c, ' +
                      'CreatedDate, CreatedBy.Name, CreatedBy.Id, ' +
                      'Description__c, Customer_Unique_Id__c ' +
                      'FROM ReceivedDocument ' +
                      'WHERE ' + relationshipField + ' = :recordId ' +
                      'ORDER BY CreatedDate';
        
        List<ReceivedDocument> receivedDocs = Database.query(query);
        
        // Only proceed if we have ReceivedDocument records
        if(!receivedDocs.isEmpty()) {
            // Get all Files linked to these ReceivedDocument records
            Set<Id> receivedDocIds = new Set<Id>();
            for(ReceivedDocument doc : receivedDocs) {
                receivedDocIds.add(doc.Id);
            }
            
            // Only query ContentDocumentLink if we have ReceivedDocument IDs
            if(!receivedDocIds.isEmpty()) {
                List<ContentDocumentLink> fileLinks = [
                    SELECT ContentDocumentId, ContentDocument.Title, 
                           ContentDocument.FileExtension, ContentDocument.ContentSize,
                           ContentDocument.CreatedDate, ContentDocument.CreatedBy.Name,
                           LinkedEntityId
                    FROM ContentDocumentLink 
                    WHERE LinkedEntityId IN :receivedDocIds
                    ORDER BY ContentDocument.CreatedDate
                ];
                
                // Create a map of Files by their LinkedEntityId (ReceivedDocument Id)
                Map<Id, ContentDocumentLink> filesByReceivedDocId = new Map<Id, ContentDocumentLink>();
                for(ContentDocumentLink link : fileLinks) {
                    filesByReceivedDocId.put(link.LinkedEntityId, link);
                }
                
                // Combine ReceivedDocument with their Files
                for(ReceivedDocument doc : receivedDocs) {
                    ContentDocumentLink fileLink = filesByReceivedDocId.get(doc.Id);
                    wrappers.add(new DocumentWrapper(doc, fileLink));
                }
            } else {
                // If no ReceivedDocument IDs, return empty wrappers
                return new List<DocumentWrapper>();
            }
        }
        // If no ReceivedDocuments found, return empty list
        return wrappers;
    }
    
    private static List<DocumentWrapper> getStandardFiles(String recordId) {
        List<DocumentWrapper> wrappers = new List<DocumentWrapper>();
        
        // For other objects, use standard ContentDocumentLink approach
        List<ContentDocumentLink> fileLinks = [
            SELECT ContentDocumentId, ContentDocument.Title, 
                   ContentDocument.FileExtension, ContentDocument.ContentSize,
                   ContentDocument.CreatedDate, ContentDocument.CreatedBy.Name,
                   LinkedEntityId
            FROM ContentDocumentLink 
            WHERE LinkedEntityId = :recordId
            ORDER BY ContentDocument.CreatedDate
        ];
        
        for(ContentDocumentLink link : fileLinks) {
            wrappers.add(new DocumentWrapper(link));
        }
        
        return wrappers;
    }
    
    // Your existing DocumentWrapper class remains the same
    public class DocumentWrapper {
        @AuraEnabled public String DocumentId { get; set; }
        @AuraEnabled public String Title { get; set; }
        @AuraEnabled public String DocumentType { get; set; }
        @AuraEnabled public String Status { get; set; }
        @AuraEnabled public String Description { get; set; }
        @AuraEnabled public String CustomerUniqueId { get; set; }
        @AuraEnabled public Datetime CreatedDate { get; set; }
        @AuraEnabled public String CreatedByName { get; set; }
        @AuraEnabled public String DownloadUrl { get; set; }
        @AuraEnabled public String FilePreviewUrl { get; set; }
        @AuraEnabled public String FileExtension { get; set; }
        @AuraEnabled public String FormattedSize { get; set; }
        @AuraEnabled public String ContentDocumentId { get; set; }
        @AuraEnabled public Boolean hasFile { get; set; }
        @AuraEnabled public Boolean isImage { get; set; }
        @AuraEnabled public Boolean isPdf { get; set; }
        
        // Constructor for ReceivedDocument with File
        public DocumentWrapper(ReceivedDocument doc, ContentDocumentLink fileLink) {
            this.DocumentId = doc.Id;
            this.Title = doc.Name;
            this.DocumentType = doc.Document_Type__c;
            this.Status = doc.Status__c;
            this.Description = doc.Description__c;
            this.CustomerUniqueId = String.valueOf(doc.Customer_Unique_Id__c);
            this.CreatedDate = doc.CreatedDate;
            this.CreatedByName = doc.CreatedBy.Name;
            
            if(fileLink != null) {
                this.ContentDocumentId = fileLink.ContentDocumentId;
                this.FileExtension = fileLink.ContentDocument.FileExtension;
                this.FormattedSize = formatFileSize(fileLink.ContentDocument.ContentSize);
                this.DownloadUrl = '/sfc/servlet.shepherd/document/download/' + fileLink.ContentDocumentId;
                
                // Set file type flags
                this.isImage = isImageFile(fileLink.ContentDocument.FileExtension);
                this.isPdf = isPdfFile(fileLink.ContentDocument.FileExtension);
                
                // Use Google Docs viewer for PDF preview to avoid automatic download
                if(this.isPdf) {
                    String baseUrl = URL.getOrgDomainUrl().toExternalForm();
                    String pdfUrl = baseUrl + '/sfc/servlet.shepherd/document/download/' + fileLink.ContentDocumentId;
                    this.FilePreviewUrl = 'https://docs.google.com/gview?url=' + EncodingUtil.urlEncode(pdfUrl, 'UTF-8') + '&embedded=true';
                } else if(this.isImage) {
                    // For images, use content delivery URL
                    this.FilePreviewUrl = '/sfc/servlet.shepherd/document/download/' + fileLink.ContentDocumentId + '?operationContext=S1';
                } else {
                    // For other files, use direct URL
                    this.FilePreviewUrl = '/sfc/servlet.shepherd/document/download/' + fileLink.ContentDocumentId;
                }
                
                this.hasFile = true;
            } else {
                this.FileExtension = getFileExtensionFromType(doc.Document_Type__c);
                this.FormattedSize = 'N/A';
                this.DownloadUrl = '/lightning/r/ReceivedDocument/' + doc.Id + '/view';
                this.FilePreviewUrl = null;
                this.hasFile = false;
                this.isImage = false;
                this.isPdf = false;
            }
        }
        
        // Constructor for standard ContentDocumentLink (for other objects)
        public DocumentWrapper(ContentDocumentLink fileLink) {
            this.DocumentId = fileLink.ContentDocumentId;
            this.Title = fileLink.ContentDocument.Title;
            this.DocumentType = 'File';
            this.Status = 'Available';
            this.Description = '';
            this.CustomerUniqueId = '';
            this.CreatedDate = fileLink.ContentDocument.CreatedDate;
            this.CreatedByName = fileLink.ContentDocument.CreatedBy.Name;
            this.ContentDocumentId = fileLink.ContentDocumentId;
            this.FileExtension = fileLink.ContentDocument.FileExtension;
            this.FormattedSize = formatFileSize(fileLink.ContentDocument.ContentSize);
            this.DownloadUrl = '/sfc/servlet.shepherd/document/download/' + fileLink.ContentDocumentId;
            
            // Set file type flags
            this.isImage = isImageFile(fileLink.ContentDocument.FileExtension);
            this.isPdf = isPdfFile(fileLink.ContentDocument.FileExtension);
            
            // Use Google Docs viewer for PDF preview to avoid automatic download
            if(this.isPdf) {
                String baseUrl = URL.getOrgDomainUrl().toExternalForm();
                String pdfUrl = baseUrl + '/sfc/servlet.shepherd/document/download/' + fileLink.ContentDocumentId;
                this.FilePreviewUrl = 'https://docs.google.com/gview?url=' + EncodingUtil.urlEncode(pdfUrl, 'UTF-8') + '&embedded=true';
            } else if(this.isImage) {
                // For images, use content delivery URL
                this.FilePreviewUrl = '/sfc/servlet.shepherd/document/download/' + fileLink.ContentDocumentId + '?operationContext=S1';
            } else {
                // For other files, use direct URL
                this.FilePreviewUrl = '/sfc/servlet.shepherd/document/download/' + fileLink.ContentDocumentId;
            }
            
            this.hasFile = true;
        }
        
        private Boolean isImageFile(String fileExtension) {
            if(fileExtension == null) return false;
            Set<String> imageExtensions = new Set<String>{'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'};
            return imageExtensions.contains(fileExtension.toLowerCase());
        }
        
        private Boolean isPdfFile(String fileExtension) {
            if(fileExtension == null) return false;
            return fileExtension.toLowerCase() == 'pdf';
        }
        
        private String formatFileSize(Decimal size) {
            if(size == null) return '0 B';
            if(size < 1024) return size + ' B';
            else if(size < 1048576) return (size / 1024).setScale(1) + ' KB';
            else return (size / 1048576).setScale(1) + ' MB';
        }
        
        private String getFileExtensionFromType(String docType) {
            if(docType == null) return 'file';
            Map<String, String> typeToExtension = new Map<String, String>{
                'National ID' => 'pdf', 'ID Photograph' => 'jpg',
                'Proof of Address' => 'pdf', 'Income Proof' => 'pdf',
                'Passport' => 'pdf', 'Driving License' => 'pdf'
            };
            return typeToExtension.get(docType) ?? 'file';
        }
    }
}