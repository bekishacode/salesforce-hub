public without sharing class FaydaAuthController {
    public String message { get; set; }
    public String messageType { get; set; }
    public Boolean shouldClose { get; set; }
    
    public FaydaAuthController() {
        processCallback();
    }
    
    public void processCallback() {
        try {
            Map<String, String> params = ApexPages.currentPage().getParameters();
            String code = params.get('code');
            String state = params.get('state');
            String error = params.get('error');
            
            // 🎯 DEBUG LOGGING - This will appear in Setup → Debug Logs
            System.debug('=== FAYDA CALLBACK START ===');
            System.debug('📥 Raw Code: ' + code);
            System.debug('📥 Raw State: ' + state);
            System.debug('📥 Raw Error: ' + error);
            System.debug('📥 All Parameters: ' + JSON.serializePretty(params));
            
            if (String.isNotBlank(error)) {
                handleError('Verification failed: ' + error);
            } else if (String.isNotBlank(code) && String.isNotBlank(state)) {
                handleSuccess(code, state);
            } else {
                handleError('Missing authorization parameters - code and state are required');
            }
            
        } catch (Exception e) {
            System.debug('❌ CALLBACK ERROR: ' + e.getMessage());
            handleError('System error: ' + e.getMessage());
        }
    }
    
    private void handleSuccess(String code, String state) {
        try {
            System.debug('=== PROCESSING SUCCESS ===');
            
            // URL decode the state parameter
            String decodedState = EncodingUtil.urlDecode(state, 'UTF-8');
            System.debug('🔓 Decoded State: ' + decodedState);
            
            // Parse lead ID from state (format: "leadId|randomString")
            String[] stateParts = decodedState.split('\\|');
            System.debug('🔍 State Parts: ' + stateParts);
            
            if (stateParts.size() != 2) {
                handleError('Invalid state format. Expected: "leadId|randomString" but got: ' + decodedState);
                return;
            }
            
            String leadId = stateParts[0];
            String randomComponent = stateParts[1];
            
            System.debug('👤 Lead ID: ' + leadId);
            System.debug('🎲 Random Component: ' + randomComponent);
            
            // ✅ JUST VERIFY LEAD EXISTS (READ-ONLY, NO PERMISSIONS NEEDED)
            try {
                List<Lead> leads = [SELECT Id, Name FROM Lead WHERE Id = :leadId LIMIT 1];
                System.debug('🔍 Lead Query Result: ' + leads.size() + ' leads found');
                
                if (!leads.isEmpty()) {
                    String leadName = leads[0].Name;
                    System.debug('✅ SUCCESS - Code captured for Lead: ' + leadName);
                    
                    // 🎯 DISPLAY SUCCESS MESSAGE WITH CODE
                    this.message = 'Verification Successful! Code: ' + code + '&state:' + state + ' | Lead: ' + leadName;
                    
                    this.messageType = 'success';
                    this.shouldClose = true;
                    
                    System.debug('🎯 READY FOR MULESOFT - Would call API with code: ' + code);
                    System.debug('=== FAYDA CALLBACK COMPLETE ===');
                } else {
                    handleError('Lead not found with ID: ' + leadId + ' | Code captured: ' + code);
                }
            } catch (QueryException e) {
                // Even if lead query fails, we still captured the code
                System.debug('⚠️ Lead query failed but code captured: ' + code);
                this.message = 'Code captured: ' + code + ' | Note: Could not verify lead';
                this.messageType = 'success';
                this.shouldClose = true;
            }
            
        } catch (Exception e) {
            System.debug('❌ SUCCESS HANDLER ERROR: ' + e.getMessage());
            handleError('Error processing verification: ' + e.getMessage());
        }
    }
    
    private void handleError(String errorMessage) {
        System.debug('❌ ERROR: ' + errorMessage);
        this.message = errorMessage;
        this.messageType = 'error';
        this.shouldClose = true;
    }
}