import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue, updateRecord } from 'lightning/uiRecordApi';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import STATUS_FIELD from '@salesforce/schema/Lead.FAYDA_Verification_Status__c';
import FCN_FIELD from '@salesforce/schema/Lead.National_ID_FCN__c';
import ID_FIELD from '@salesforce/schema/Lead.Id';

// Import Apex methods
import fetchOTP from '@salesforce/apex/FetchOTPFromFAYDASystem.fetchOTP';
import fetchKYCDetails from '@salesforce/apex/FetchKYCDetailsFromFAYDASystem.fetchOTP';

export default class RetryButton extends LightningElement {
    @api recordId;
    @api message = 'Click verify client to perform action.';
    @api retryButtonLabel = 'Verify Client';

    @track isRateLimited = false;
    @track remainingAttempts = 3;
    @track timeUntilReset = '';
    @track status = '';
    @track fcnId = '';
    @track currentStep = 'initial'; // initial, otpInput, processing, success, error
    @track showOtpModal = false;
    @track otpValue = '';
    @track otpProcessing = false;
    @track transactionId = '';
    @track individualId = '';
    @track individualType = 'FCN';
    @track kycDetails = {};
    @track showKycModal = false;
    @track errorMessage = '';

    headerIcon = 'utility:info';
    headerLabel = '';
    @track executedFlow = false;

    // Rate limiting constants
    MAX_ATTEMPTS = 3;
    TIME_WINDOW_MINUTES = 10;
    STORAGE_KEY_PREFIX = 'retryAttempts_';
    FLOW_EXECUTION_KEY_PREFIX = 'flowExecution_';

    flowStarted = false;
    lastProcessedStatus = null;
    wiredRecordResult; // Store wired result for refreshApex

    @wire(getRecord, { recordId: '$recordId', fields: [STATUS_FIELD, FCN_FIELD] })
    wired(result) {
        this.wiredRecordResult = result; // Store for refreshApex
        const { data, error } = result;

        if (data) {
            const newStatus = getFieldValue(data, STATUS_FIELD);
            const fcnValue = getFieldValue(data, FCN_FIELD);

            console.log('Wire - Status:', newStatus);
            console.log('Wire - FCN Value:', fcnValue);

            this.lastProcessedStatus = newStatus;
            this.status = newStatus;
            this.fcnId = fcnValue;
            this.individualId = fcnValue;

            console.log('Updated individualId:', this.individualId);
            console.log('Updated individualType:', this.individualType);

            this.setHeaderByStatus();
            this.updateButtonState();
        }
        if (error) {
            console.error('Error fetching record:', error);
        }
    }

    setHeaderByStatus() {
        if (this.status === 'Verification Successful') {
            this.headerIcon = '';
            this.headerLabel = '✅ Verification Successful';
        } else if (this.status === 'Verification Failed') {
            this.headerIcon = '';
            this.headerLabel = '❌ Verification Unsuccessful';
        } else {
            this.headerIcon = 'utility:info';
            this.headerLabel = 'Please Verify Client Before convert.';
        }
    }

    connectedCallback() {
        this.checkRateLimit();
        this.startCountdownTimer();
    }

    disconnectedCallback() {
        this.stopCountdownTimer();
    }

    startCountdownTimer() {
        if (this.intervalId) {
            clearInterval(this.intervalId);
        }

        this.intervalId = setInterval(() => {
            if (this.status !== 'Verification Successful' && this.isRateLimited) {
                this.updateLiveCountdown();
            }
        }, 1000);
    }

    stopCountdownTimer() {
        if (this.intervalId) {
            clearInterval(this.intervalId);
            this.intervalId = null;
        }
    }

    updateLiveCountdown() {
        if (!this.isRateLimited || this.status === 'Verification Successful') {
            return;
        }

        const storageKey = this.STORAGE_KEY_PREFIX + this.recordId;
        const storedData = localStorage.getItem(storageKey);

        if (storedData) {
            const attempts = JSON.parse(storedData);
            const now = Date.now();
            const timeWindowMs = this.TIME_WINDOW_MINUTES * 60 * 1000;

            if (attempts.length > 0) {
                const oldestAttempt = Math.min(...attempts);
                const resetTime = oldestAttempt + timeWindowMs;
                const timeLeft = resetTime - now;

                if (timeLeft > 0) {
                    this.updateTimeUntilReset(timeLeft);
                } else {
                    this.checkRateLimit();
                }
            }
        }
    }

    checkRateLimit() {
        if (!this.recordId) {
            console.error('Lead ID is required for rate limiting');
            return;
        }

        if (this.status === 'Verification Successful') {
            this.isRateLimited = true;
            this.timeUntilReset = '';
            this.stopCountdownTimer();
            return;
        }

        const storageKey = this.STORAGE_KEY_PREFIX + this.recordId;
        const storedData = localStorage.getItem(storageKey);

        if (!storedData) {
            this.remainingAttempts = this.MAX_ATTEMPTS;
            this.isRateLimited = false;
            this.timeUntilReset = '';
            return;
        }

        const attempts = JSON.parse(storedData);
        const now = Date.now();
        const timeWindowMs = this.TIME_WINDOW_MINUTES * 60 * 1000;

        const recentAttempts = attempts.filter(timestamp =>
            now - timestamp < timeWindowMs
        );

        if (recentAttempts.length !== attempts.length) {
            localStorage.setItem(storageKey, JSON.stringify(recentAttempts));
        }

        this.remainingAttempts = this.MAX_ATTEMPTS - recentAttempts.length;

        if (recentAttempts.length >= this.MAX_ATTEMPTS) {
            this.isRateLimited = true;
            const oldestAttempt = Math.min(...recentAttempts);
            const resetTime = oldestAttempt + timeWindowMs;
            const timeLeft = resetTime - now;
            this.updateTimeUntilReset(timeLeft);
        } else {
            this.isRateLimited = false;
            this.timeUntilReset = '';
        }
    }

    updateButtonState() {
        if (this.status === 'Verification Successful') {
            this.isRateLimited = true;
            this.timeUntilReset = '';
            this.stopCountdownTimer();
        } else {
            this.checkRateLimit();
        }
    }

    updateTimeUntilReset(timeLeft) {
        if (timeLeft <= 0) {
            this.timeUntilReset = '';
            return;
        }

        const minutes = Math.floor(timeLeft / (1000 * 60));
        const seconds = Math.floor((timeLeft % (1000 * 60)) / 1000);

        const formattedMinutes = minutes.toString().padStart(2, '0');
        const formattedSeconds = seconds.toString().padStart(2, '0');

        this.timeUntilReset = `${formattedMinutes}:${formattedSeconds}`;
    }

    hasFlowExecutedRecently() {
        const flowKey = this.FLOW_EXECUTION_KEY_PREFIX + this.recordId;
        const lastExecution = localStorage.getItem(flowKey);

        if (lastExecution) {
            const executionTime = parseInt(lastExecution, 10);
            const timeSinceExecution = Date.now() - executionTime;
            return timeSinceExecution < 5000;
        }

        return false;
    }

    markFlowAsExecuted() {
        const flowKey = this.FLOW_EXECUTION_KEY_PREFIX + this.recordId;
        localStorage.setItem(flowKey, Date.now().toString());
    }

    async handleRetry() {
        if (this.isRateLimited ||
            !this.recordId ||
            this.status === 'Verification Successful' ||
            this.flowStarted ||
            this.hasFlowExecutedRecently()) {
            console.log('Retry blocked - conditions not met');
            return;
        }

        // Check if FCN ID exists
        if (!this.fcnId) {
            this.showErrorMessage('Please Check The Selected Lead has National FCN Id Or Not');
            return;
        }

        this.flowStarted = true;
        this.markFlowAsExecuted();
        this.currentStep = 'processing';

        // Update attempt tracking
        this.updateAttemptTracking();

        //try {
        // Call OTP API
        await this.sendOTP();
        //} catch (error) {
        // this.handleError('Error during verification process: ' + error.message);
        //}
    }

    async sendOTP() {
        // try {
        // Debug the values first
        console.log('Individual ID:', this.individualId);
        console.log('Individual Type:', this.individualType);

        if (!this.individualId) {
            this.handleError('Individual ID (FCN) is required');
            return;
        }

        console.log('Calling fetchOTP with simple parameters');

        const result = await fetchOTP({
            individualId: this.individualId,
            individualType: this.individualType
        });

        if (result && result.length > 0) {
            const otpResponse = result[0];

            if (otpResponse.statusCode == 200 || otpResponse.statusCode == 201) {
                this.transactionId = otpResponse.transactionId;
                this.otpValue = ''; // Clear OTP input
                this.showOtpModal = true; // Show modal instead of inline
                this.flowStarted = false;

                this.dispatchEvent(new ShowToastEvent({
                    title: 'OTP Sent',
                    message: 'OTP has been sent successfully. Please enter the OTP.',
                    variant: 'success'
                }));
            } else {
                this.handleError('Oops! The FAYDA Service is currently offline. Please try again in 2 minutes');
            }
        } else {
            this.handleError('No response received from OTP service.');
        }
        // } /*catch (error) {
        //this.handleError('Error sending OTP: ' + error.message);
        // }
    }

    handleOtpChange(event) {
        this.otpValue = event.target.value;
    }

  async handleOtpVerification() {
    if (!this.otpValue) {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Error',
            message: 'Please enter the OTP.',
            variant: 'error'
        }));
        return;
    }

    this.otpProcessing = true;

    try {
        console.log('Calling fetchKYCDetails with parameters:', {
            transactionId: this.transactionId,
            individualId: this.individualId,
            individualType: this.individualType,
            generatedOTP: this.otpValue
        });

        const result = await fetchKYCDetails({
            transactionId: this.transactionId,
            individualId: this.individualId,
            individualType: this.individualType,
            generatedOTP: this.otpValue
        });

        // 🔍 COMPREHENSIVE DEBUGGING
        console.log('=== DEBUGGING KYC RESPONSE ===');
        console.log('1. Raw result:', result);
        console.log('2. Result type:', typeof result);
        console.log('3. Is array?', Array.isArray(result));
        console.log('4. Result length:', result ? result.length : 'null/undefined');

        if (result && result.length > 0) {
            const kycResponse = result[0];
            
            console.log('5. kycResponse object:', kycResponse);
            console.log('6. kycResponse type:', typeof kycResponse);
            console.log('7. kycResponse keys:', Object.keys(kycResponse));
            
            // 🔍 SPECIFIC DEBUGGING FOR outputKYCError
            console.log('8. outputKYCError value:', kycResponse.outputKYCError);
            console.log('9. outputKYCError type:', typeof kycResponse.outputKYCError);
            console.log('10. outputKYCError === true:', kycResponse.outputKYCError === true);
            console.log('11. outputKYCError == true:', kycResponse.outputKYCError == true);
            console.log('12. outputKYCError === "true":', kycResponse.outputKYCError === "true");
            console.log('13. outputKYCError == "true":', kycResponse.outputKYCError == "true");
            console.log('14. Boolean(outputKYCError):', Boolean(kycResponse.outputKYCError));
            
            // 🔍 CHECK ALL BOOLEAN-RELATED PROPERTIES
            console.log('15. All properties ending with "Error":', 
                Object.keys(kycResponse).filter(key => key.toLowerCase().includes('error')));
            
            console.log('16. statusCode:', kycResponse.statusCode);
            console.log('17. statusCode type:', typeof kycResponse.statusCode);
            
            // 🔍 STRINGIFY THE ENTIRE RESPONSE
            console.log('18. Full JSON:', JSON.stringify(kycResponse, null, 2));
            
            if (kycResponse.statusCode == 200 || kycResponse.statusCode == 201) {
                console.log('19. Status code check passed');
                
                // 🔍 TRY DIFFERENT WAYS TO CHECK THE BOOLEAN
                let kycErrorCheck1 = kycResponse.outputKYCError == true;
                let kycErrorCheck2 = kycResponse.outputKYCError == true;
                let kycErrorCheck3 = kycResponse.outputKYCError == "true";
                let kycErrorCheck4 = String(kycResponse.outputKYCError).toLowerCase() == "true";
                
                console.log('20. kycErrorCheck1 (===):', kycErrorCheck1);
                console.log('21. kycErrorCheck2 (==):', kycErrorCheck2);
                console.log('22. kycErrorCheck3 (=== "true"):', kycErrorCheck3);
                console.log('23. kycErrorCheck4 (string comparison):', kycErrorCheck4);
                
                // Use the most appropriate check based on what we discover
                if (kycErrorCheck1 || kycErrorCheck2 || kycErrorCheck3 || kycErrorCheck4) {
                    console.log('24. KYC Validation Success - Processing...');
                    this.kycDetails = kycResponse;

                    // Show KYC details in modal
                    this.showKycModal = true;
                    this.showOtpModal = false;
                    this.otpValue = '';

                    await this.updateLeadRecord(true);
                    this.currentStep = 'success';

                    // Refresh wire data
                    await this.refreshWireData();

                } else {
                    console.log('25. KYC Error - All checks failed');
                    console.log('26.1. Actual Json value :', JSON.stringify(kycResponse));

                    console.log('26. Actual value received:', kycResponse.outputKYCError);
                    this.handleError('OTP verification failed or KYC validation unsuccessful');
                    await this.updateLeadRecord(false);
                    this.showOtpModal = false;
                    await this.refreshWireData();
                }
            } else {
                console.log('27. Status code check failed:', kycResponse.statusCode);
                this.handleError('Service returned error status: ' + kycResponse.statusCode);
                await this.updateLeadRecord(false);
                this.showOtpModal = false;
                await this.refreshWireData();
            }
        } else {
            console.log('28. No response or empty response');
            this.handleError('No response received from verification service.');
            await this.updateLeadRecord(false);
            this.showOtpModal = false;
            await this.refreshWireData();
        }
    } catch (error) {
        console.error('29. Exception caught:', error);
        console.error('30. Error message:', error.message);
        console.error('31. Error stack:', error.stack);
        this.handleError('Error during KYC verification: ' + error.message);
        await this.updateLeadRecord(false);
        this.showOtpModal = false;
        await this.refreshWireData();
    } finally {
        this.otpProcessing = false;
        console.log('32. OTP processing completed');
    }
}

    async updateLeadRecord(isSuccessful) {
        try {
            const fields = {
                [ID_FIELD.fieldApiName]: this.recordId
            };

            if (isSuccessful && this.kycDetails) {
                console.log('33.Date value--->',this.kycDetails.outputDobDate);
                fields[STATUS_FIELD.fieldApiName] = 'Verification Successful';
                fields['FirstName'] = this.kycDetails.outputFirstName;
                fields['LastName'] = this.kycDetails.outputLastName;
                fields['MiddleName'] = this.kycDetails.outputMiddleName;
                fields['Email'] = this.kycDetails.outputEmail;
                fields['MobilePhone'] = this.kycDetails.phoneNumber;
                fields['Gender__c'] = this.kycDetails.outputEngGender;
                fields['City_Town__c'] = this.kycDetails.outputRegionCity;
                fields['Region__c'] = this.kycDetails.outputRegionCity;
                fields['Sub_City_Zone__c'] = this.kycDetails.outputSubCity;
                fields['Woreda_Kebele__c'] = this.kycDetails.outputWoreda;
                fields['Birth_of_date__c'] = this.kycDetails.outputDobDate;
            } else {
                fields[STATUS_FIELD.fieldApiName] = 'Verification Failed';
            }

            const recordInput = { fields };
            await updateRecord(recordInput);

        } catch (error) {
            console.error('Error updating lead record:', error);
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error',
                message: 'Error updating lead record: ' + error.message,
                variant: 'error'
            }));
        }
    }

    // Refresh wire data without page reload
    async refreshWireData() {
        try {
            // First try refreshApex
            if (this.wiredRecordResult) {
                await refreshApex(this.wiredRecordResult);
            }

            // Also notify record change as backup
            getRecordNotifyChange([{ recordId: this.recordId }]);

            console.log('Wire data refreshed successfully');
        } catch (error) {
            console.error('Error refreshing wire data:', error);
            // Fallback to record notify change
            getRecordNotifyChange([{ recordId: this.recordId }]);
        }
    }

    updateAttemptTracking() {
        const storageKey = this.STORAGE_KEY_PREFIX + this.recordId;
        const now = Date.now();
        const storedData = localStorage.getItem(storageKey);
        let attempts = storedData ? JSON.parse(storedData) : [];
        attempts.push(now);
        localStorage.setItem(storageKey, JSON.stringify(attempts));

        this.checkRateLimit();

        this.dispatchEvent(new ShowToastEvent({
            title: 'Verification Started',
            message: `Verification initiated. Remaining attempts: ${this.remainingAttempts}`,
            variant: 'success'
        }));

        this.dispatchEvent(new CustomEvent('retry', {
            detail: { recordId: this.recordId, remainingAttempts: this.remainingAttempts, timestamp: now }
        }));

        if (this.remainingAttempts === 1) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Rate Limit Warning',
                message: 'You have 1 retry attempt remaining in the next 10 minutes.',
                variant: 'warning'
            }));
        } else if (this.remainingAttempts === 0) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Rate Limit Reached',
                message: `Max retry attempts reached. Try again after ${this.timeUntilReset}.`,
                variant: 'error'
            }));
        }
    }

    handleError(message) {
        this.errorMessage = message;
        this.currentStep = 'error';
        this.flowStarted = false;
        this.otpProcessing = false;
        this.showOtpModal = false; // Close modal on error
    }

    showErrorMessage(message) {
        this.errorMessage = message;
        this.currentStep = 'error';
        this.flowStarted = false;
        this.showOtpModal = false; // Close modal on error
    }

    handleCancel() {
        this.currentStep = 'initial';
        this.otpValue = '';
        this.flowStarted = false;
        this.otpProcessing = false;
        this.showOtpModal = false; // Close modal
    }

    handleCancelOtp() {
        this.showOtpModal = false;
        this.otpValue = '';
        this.flowStarted = false;
        this.otpProcessing = false;
        this.currentStep = 'initial';
    }

    handleCloseDetails() {
        this.currentStep = 'initial';
        this.otpValue = '';
        this.flowStarted = false;
        this.otpProcessing = false;
        this.showOtpModal = false;
    }

    handleErrorRetry() {
        this.currentStep = 'initial';
        this.errorMessage = '';
        this.flowStarted = false;
        this.otpProcessing = false;
        this.showOtpModal = false;
    }

    handleCloseKycModal() {
        this.showKycModal = false;
        // Refresh wire data after closing
        this.refreshWireData();
    }

    // Getters for template conditions
    get buttonVariant() {
        if (this.status === 'Verification Successful') {
            return 'neutral';
        }
        return this.isRateLimited ? 'neutral' : 'brand';
    }

    get isButtonDisabled() {
        return this.isRateLimited || this.flowStarted || this.showOtpModal;
    }

    get statusMessage() {
        if (this.status === 'Verification Successful') {
            return 'Verification completed successfully';
        } else if (this.isRateLimited && this.timeUntilReset) {
            return `Rate limit reached. Reset in: ${this.timeUntilReset}`;
        } else if (this.remainingAttempts < this.MAX_ATTEMPTS && this.remainingAttempts > 0) {
            return `${this.remainingAttempts} attempt${this.remainingAttempts !== 1 ? 's' : ''} remaining`;
        }
        return '';
    }

    get statusMessageClass() {
        if (this.status === 'Verification Successful') {
            return 'slds-box slds-theme_success slds-text-align_center slds-p-around_x-small';
        } else if (this.isRateLimited) {
            return 'slds-box slds-theme_error slds-text-align_center slds-p-around_x-small';
        } else if (this.remainingAttempts <= 1) {
            return 'slds-box slds-theme_warning slds-text-align_center slds-p-around_x-small';
        }
        return 'slds-box slds-theme_info slds-text-align_center slds-p-around_x-small';
    }

    get showRateLimit() {
        return this.status !== 'Verification Successful';
    }

    get showMainButton() {
        return this.currentStep === 'initial' && !this.showOtpModal;
    }

    get showKycDetails() {
        return this.currentStep === 'success';
    }

    get showError() {
        return this.currentStep === 'error';
    }

    get leadId() {
        return this.recordId;
    }
}