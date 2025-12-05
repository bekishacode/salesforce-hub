public without sharing class FaydaVerificationHandler {
    
    private static final String CLIENT_ID = 'wHti5bUhoPit3DiCFXMKYfop9DhBrFZ2Pt7hBj-emp4';
    private static final String SALESFORCE_REDIRECT_URI = 'https://boa--boacustom.sandbox.my.site.com/faydauth/FaydaAuthCallback';
    
    @AuraEnabled
    public static String generateVerificationUrl(String leadId) {
        try {
            // Generate random nonce and state component
            String nonce = generateRandomString(16);
            String randomComponent = generateRandomString(8);
            
            // Create state that includes both leadId and random component
            String state = leadId + '|' + randomComponent;
            
            // Store state in lead (for verification if needed)
            Lead currentLead = new Lead(
                Id = leadId, 
                Verification_State__c = state,
                Verification_Nonce__c = nonce,
                FAYDA_Verification_Status__c = 'Pending'
            );
            update currentLead;
            
            // Build the verification URL for Fayda
            String authUrl = 'http://test.fayda.ethswitch.et/authorize?' +
                'nonce=' + EncodingUtil.urlEncode(nonce, 'UTF-8') +
                '&state=' + EncodingUtil.urlEncode(state, 'UTF-8') +
                '&client_id=' + CLIENT_ID +
                '&redirect_uri=' + EncodingUtil.urlEncode(SALESFORCE_REDIRECT_URI, 'UTF-8') +
                '&scope=openid%20profile' +
                '&response_type=code' +
                '&acr_values=mosip:idp:acr:generated-code%20mosip:idp:acr:biometrics' +
                '&claims=' + EncodingUtil.urlEncode('{"userinfo":{"email":{"essential":true},"nationality":{"essential":true}}}', 'UTF-8') +
                '&claims_locales=en' +
                '&display=page' +
                '&ui_locales=en';
                
            return authUrl;
            
        } catch (Exception e) {
            throw new AuraHandledException('Error generating verification URL: ' + e.getMessage());
        }
    }
    
    // Secure random string generator
    private static String generateRandomString(Integer len) {
        Blob randomBlob = Crypto.generateAesKey(128);
        String randomHex = EncodingUtil.convertToHex(randomBlob);
        return randomHex.substring(0, len);
    }
}